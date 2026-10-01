# GPU undervolt — Radeon Pro V620 (`gpu-undervolt`)

A small systemd service that applies a fixed **GFX voltage offset** (undervolt)
to the Radeon Pro V620 on the Proxmox host, persisting it across reboots.

**Both cards run at 0 mV (stock).** −100 mV silently corrupts compute (see below). −50 mV
passed the determinism test but saves only ~16 W per card in decode. The service stays
installed, so a qualified offset is a one-line change.

## Why an undervolt and not a power cap

The original goal was to power-limit the V620 from 250 W to 220 W. **It is not
possible on this card** — the board-power cap is firmware-locked:

- `power1_cap` reports `min == max == default == 250000000` µW. Writing anything
  else fails with `-EINVAL`; the driver logs it explicitly:
  ```
  amdgpu 0000:2d:00.0: New power limit (220) is out of range [250,250]
  ```
- Enabling AMD **OverDrive** (`amdgpu.ppfeaturemask` bit `0x4000`) does **not**
  unlock the cap, and the OverDrive table exposes **no clock-ceiling knob**:
  `pp_od_clk_voltage` shows an empty `OD_RANGE` (no `OD_SCLK`/`OD_MCLK`).
- The DPM table offers only 500 MHz or 2570 MHz (nothing in between), so masking
  `pp_dpm_sclk` cannot approximate a lower power envelope either.

The **only** adjustable lever OverDrive exposes is `OD_VDDGFX_OFFSET` — a GFX
voltage offset. A negative offset lowers voltage at the same clocks, which lowers
power and temperature wherever the card is *not* already pegged at the 250 W cap
(and buys a touch of extra clock where it is).

## Measured effect (A/B, `make bench PARALLEL=4`)

0 mV (stock) vs −100 mV, identical conditions, host-side power sampling (the
in-LXC telemetry suite cannot read AMD board watts):

| Under load              | 0 mV     | −100 mV  | Δ          |
| ----------------------- | -------: | -------: | ---------: |
| Avg board power         | 196 W    | 160 W    | **−18 %**  |
| Peak board power        | 252 W    | 247 W    | −5 W       |
| Junction avg            | 71 °C    | 64 °C    | **−7 °C**  |
| Junction peak           | 83 °C    | 75 °C    | **−8 °C**  |
| Core clock (avg / peak) | 2300 / 2496 MHz | 2304 / 2476 MHz | ≈ same |

Throughput: unchanged in the decode / single-user / soak regime (within 0.3 %),
and **+0.6–1.1 %** across the cap-saturated concurrency sweep (peak aggregate
122.7 → 123.7 tok/s), with slightly lower p95 latency. Single-stream decode draws
only ~96–128 W — well below the 250 W cap — so that regime is *not* power-limited;
undervolting there cuts power directly. At high concurrency / large prefills the
card hits the cap, so the lower voltage converts to a little more clock instead.

**−100 mV is not error-free.** It ran the full batch (single-user, concurrency 1→16,
input-length 128→32768, soak) with zero GPU faults. On 2026-10-01, however, repeated
perplexity runs found silent compute errors on both cards under prefill load. The runs used
llama.cpp `b11018` Vulkan, Qwen3.6-35B-A3B on wikitext-2 (40 × 2048), FA, q8_0 KV and
ubatch 1024:

| Card | 0 mV | −50 mV | −100 mV |
| --- | --- | --- | --- |
| `0000:83:00.0` | all bit-identical (5.5681 ± 0.06500), incl. 8 interleaved with −100 mV | 8/8 identical | **0/8 identical**: diverge from chunk 1, finals 5.5650–5.6221, one NaN |
| `0000:03:00.0` | all bit-identical (5.5681 ± 0.06500) | 5/5 identical | **0/5 identical**: diverge from chunks 2–15, finals 5.5673–5.5691 |

The cache is not the cause. Perplexity clears the KV cache before every chunk, and on
`0000:83:00.0` the −100 mV runs alternated minute by minute with 0 mV runs using the same
binary, model and q8_0 KV. Every 0 mV run was identical and no −100 mV run was. Several
failing runs drew only 235–241 W, so the errors do not need the power cap.

Neither the kernel nor the output gave any sign. Perplexity holds the card at the 250 W cap,
which is harder than the batch above. **Test an offset by repeating a perplexity run:** at a
correct offset the result is bit-identical every time. Details are in
[`../rocm-ab/README.md`](../rocm-ab/README.md).

**−50 mV passed the same test on both cards** (2026-10-01, `ppl-determinism.sh`):

- **Results:** all 13 runs were bit-identical to 0 mV (table above).
- **Throughput and heat:** at the cap the lower voltage buys clock, not heat. Throughput
  rose +0.7–0.8%. Peaks were 81–86 °C against 80–82 °C at 0 mV, rising as the card
  heat-soaked across back-to-back runs.
- **Power:** in decode, which runs below the cap, it saves two thirds of what −100 mV saves
  (table below).
- **Limits:** a pass bounds the error rate; it does not prove it is zero.

Single-stream decode on `0000:83:00.0`, measured 2026-10-01 with `decode-power.sh`:
Qwen3.6-35B-A3B, tg1024 at depth 8192, two interleaved rounds, medians.

| Offset | Decode | Board power | Junction |
| --- | ---: | ---: | ---: |
| 0 mV | 76.5 tok/s | 162 W | 65 °C |
| −50 mV | 76.3 tok/s | 146 W (−10%) | 62 °C |
| −100 mV | 76.3 tok/s | 136 W (−16%) | 60 °C |

```bash
# Host, root. Stop the card's model service first; both leave the card at 0 mV.
./ppl-determinism.sh 123 0000:83:00.0 8 -50        # CT 123's paths: set BIN, MODEL, WIKI
./ppl-determinism.sh 120 0000:03:00.0 5 -50        # defaults match CT 120
./decode-power.sh 123 0000:83:00.0 2 0 -50 -100    # power below the cap, offsets interleaved
```

**Deeper-undervolt sweep (2026-07-09, on the second V620 — see the
`second-v620-validated` note):** offsets below −100 mV were tested and **rejected**:

| Offset | Single-stream | Under concurrent load | Result |
| --- | --- | --- | --- |
| −100 mV | correct | correct (5/5 before **and** after a c1→8 stress) | passed this check; fails perplexity determinism (above) |
| −125 mV | correct | **silent garbage output** (runs of one char), no crash, no dmesg fault | **unsafe** |
| −150 mV | — | compute-ring timeout → **MODE1 GPU reset, VRAM lost** | hard crash |

−125 mV's danger is that it fails *silently*: it passes a single-stream check and
throws no kernel fault, but under concurrency the model emits corrupt tokens. Two
gotchas when testing your own floor: (1) check output correctness **after** a load
stress, not just before — corruption is load-induced; (2) the suite's garbage
guard only flags `?`-runs, so `/`-style garbage slips through as "OK" (and inflates
tok/s, since junk generates fast). A clean `systemctl restart llamacpp` is required
to clear the corrupted model state after such an event (and after any GPU reset —
llama-server's auto-reload can come back subtly broken).

## Install / operate

Run on the Proxmox host as root:

```bash
./install.sh
```

The installer:

1. Writes `/etc/modprobe.d/amdgpu-overdrive.conf`
   (`options amdgpu ppfeaturemask=0xfff7ffff`) and rebuilds the initramfs — this
   enables OverDrive, the prerequisite for the voltage knob. **amdgpu reads
   `ppfeaturemask` at load, so a reboot is required for this to take effect.**
2. Installs the daemon (`/usr/local/sbin/gpu-undervolt`), config
   (`/etc/gpu-undervolt.env`), and unit (`gpu-undervolt.service`); enables it.
3. If OverDrive is already active, applies the offset immediately; otherwise the
   service applies it automatically on the next boot.

```bash
# Change the offset and re-apply (OverDrive already active). Qualify it first with
# ppl-determinism.sh: repeated perplexity runs must be bit-identical.
sed -i 's/^OFFSET_MV=.*/OFFSET_MV=-50/' /etc/gpu-undervolt.env
systemctl restart gpu-undervolt

# Inspect:
systemctl status gpu-undervolt
cat /sys/class/drm/card*/device/pp_od_clk_voltage     # OD_VDDGFX_OFFSET: 0mV

# Return to stock voltage (also happens automatically on `systemctl stop`):
systemctl stop gpu-undervolt
```

`ppfeaturemask` is overridable: `PPFEATUREMASK=0xffffffff ./install.sh` (the
broader, commonly-cited mask) instead of the default `0xfff7ffff` (OverDrive bit
only, on top of amdgpu's vendor default `0xfff7bfff`).

## Files

| File                   | Installed to                              | Purpose |
| ---------------------- | ----------------------------------------- | ------- |
| `gpu-undervolt.sh`     | `/usr/local/sbin/gpu-undervolt`           | Applies (`apply`) / resets (`--reset`) the offset; waits for the OverDrive node at boot |
| `gpu-undervolt.env`    | `/etc/gpu-undervolt.env`                  | `OFFSET_MV` (default `0`) and knobs |
| `gpu-undervolt.service`| `/etc/systemd/system/gpu-undervolt.service` | oneshot (`RemainAfterExit`): applies at boot, resets to 0 mV on stop **or a failed start** (`ExecStopPost`) |
| `install.sh`           | —                                         | Idempotent installer (also writes the OverDrive modprobe.d option) |
| `ppl-determinism.sh`   | —                                         | Tests an offset: repeated perplexity runs must be bit-identical to a 0 mV reference |
| `decode-power.sh`      | —                                         | Measures an offset's board power, clock and junction in single-stream decode |
| (installer writes)     | `/etc/modprobe.d/amdgpu-overdrive.conf`   | Enables OverDrive at amdgpu load |

## Uninstall / revert to stock

```bash
systemctl disable --now gpu-undervolt           # stops -> resets offset to 0 mV
rm -f /usr/local/sbin/gpu-undervolt /etc/gpu-undervolt.env \
      /etc/systemd/system/gpu-undervolt.service
rm -f /etc/modprobe.d/amdgpu-overdrive.conf      # disable OverDrive again
update-initramfs -u -k all
systemctl daemon-reload
reboot                                            # OverDrive off after reboot
```

## Notes

- Independent of [`../fan-control/`](../fan-control/) (which drives the blower off
  GPU temperature); they cooperate — a cooler card simply lets the fan curve sit
  lower.
- The offset is applied live and does **not** require the GPU to be idle or the
  model unloaded.
- **VFIO passthrough resets the offset.** Unbinding/rebinding `amdgpu` (e.g. the
  ROCm-in-VM PoC in the main [`../README.md`](../README.md#backend-and-power))
  clears the card's OverDrive state, yet this `RemainAfterExit` oneshot keeps
  reading "active" — so it will **not** re-apply. Stop `gpu-undervolt` before
  rebinding to `vfio-pci`, and `systemctl restart gpu-undervolt` (then re-check
  `pp_od_clk_voltage`) once `amdgpu` is back.
- Vulkan remains the inference runtime (see the main
  [`../README.md`](../README.md#backend-and-power)); the undervolt is
  orthogonal to the engine.
