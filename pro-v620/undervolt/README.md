# GPU undervolt — Radeon Pro V620 (`gpu-undervolt`)

A small systemd service that applies a fixed **GFX voltage offset** (undervolt)
to the Radeon Pro V620 on the Proxmox host, persisting it across reboots.

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

**Stability:** −100 mV ran the full batch (single-user, concurrency 1→16,
input-length 128→32768, soak) with **zero** GPU faults (no resets / ring
timeouts). If you ever observe instability under load, move `OFFSET_MV` closer to
0 (e.g. `-75`).

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
# Change the offset and re-apply (OverDrive already active):
sed -i 's/^OFFSET_MV=.*/OFFSET_MV=-75/' /etc/gpu-undervolt.env
systemctl restart gpu-undervolt

# Inspect:
systemctl status gpu-undervolt
cat /sys/class/drm/card*/device/pp_od_clk_voltage     # OD_VDDGFX_OFFSET: -100mV

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
| `gpu-undervolt.env`    | `/etc/gpu-undervolt.env`                  | `OFFSET_MV` (default `-100`) and knobs |
| `gpu-undervolt.service`| `/etc/systemd/system/gpu-undervolt.service` | oneshot (`RemainAfterExit`): applies at boot, resets to 0 mV on stop **or a failed start** (`ExecStopPost`) |
| `install.sh`           | —                                         | Idempotent installer (also writes the OverDrive modprobe.d option) |
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
  ROCm-in-VM PoC in the main [`../README.md`](../README.md#rocm-in-a-passthrough-vm-poc-2026-06-29--works-but-slower-than-vulkan))
  clears the card's OverDrive state, yet this `RemainAfterExit` oneshot keeps
  reading "active" — so it will **not** re-apply. Stop `gpu-undervolt` before
  rebinding to `vfio-pci`, and `systemctl restart gpu-undervolt` (then re-check
  `pp_od_clk_voltage`) once `amdgpu` is back.
- Vulkan remains the inference runtime (see the main
  [`../README.md`](../README.md#why-vulkan-and-not-rocmhip)); the undervolt is
  orthogonal to the engine.
