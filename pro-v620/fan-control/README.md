# GPU fan control — Radeon Pro V620 coolers (per-cooler instances)

Host-level (Proxmox) service that drives the V620 cooler fan(s) from the **GPU's own
temperature**, instead of the BIOS smart-fan curve (which can only read a motherboard
temperature probe). The V620s are passively cooled datacenter cards, so their fans are
the **only** cooling.

The service runs **one systemd instance per cooler**. Current hardware — a single
**NF-F12 iPPC-3000 in a shared shroud cools BOTH V620s**:

| Instance | GPU(s) cooled | Cooler | nct6687 pwm | Idle floor |
|----------|---------------|--------|-------------|------------|
| `gpu-fan-control@shroud` | both — `0000:2d:00.0` + `0000:06:00.0` | NF-F12 iPPC-3000, 120 mm (FAN1) | pwm3 | 50% (~1480 RPM) |

An instance pins its GPU(s) by **PCI address** (`GPU_PCI_ADDRESS` — comma-separated for a
shared cooler; stable across boots, unlike the `cardN` index) and its fan by
`FAN_PWM_CHANNEL`. When one fan cools several GPUs the curve tracks the **hottest** card,
and a required sensor missing on **any** of them forces 100%.

> **Cooling history / gotchas**
> - **The NF-F12 iPPC-3000 floor is high:** on this board it stalls below ~47% and won't
>   cold-start below ~43% (pwm 112), so the idle floor is 50% (~1480 RPM) — there is no
>   quiet idle with this fan (measured).
> - **Prior per-GPU setup (env files kept in-repo for reference):** `@blower` (9733 blower,
>   pwm2, PCIe-1) + `@arctic` (2× Arctic S4028-6K, pwm4, PCIe-3). The Arctic pair was low-CFM
>   and **overheated GPU 2 on a full solo load** (junction **106 °C**, fan maxed, throttling);
>   it only sufficed for GPU 2's *half* of a split model (~70 °C). A blower or the NF-F12
>   shroud is the fix — hence the current single-shroud setup.

## Measured thermals & 3D-printed mounts (per cooler)

Junction temperature at −100 mV undervolt (the [`undervolt/`](../undervolt/) floor).
**Split** = model split across both cards (each ~half the load — the normal config);
**solo full-load** = the whole model on one card (~250 W board power).

| Cooler | Card(s) | Split (½-load) | Solo full-load (250 W) | 3D-printed mount |
|--------|---------|----------------|------------------------|------------------|
| **9733 blower** (radial) | 1 (PCIe-1) | — | **~83 °C** @ ~93% fan — comfortable ✅ | [thingiverse:7296707](https://www.thingiverse.com/thing:7296707) |
| **2× Arctic S4028-6K** (40 mm axial) | 1 (PCIe-3) | ~70 °C ✅ | **106 °C**, fan maxed, throttling ❌ | [printables 1712035](https://www.printables.com/model/1712035-amd-v340-v520-v620-mi25-mi50-mi60-mi100-mi210-fan) |
| **NF-F12 iPPC-3000** (120 mm, current) | both | **~56–59 °C** @ 60% fan ✅ | GPU1 ~91 °C / GPU2 ~97 °C @ 100% fan ⚠️ | [printables 1670548](https://www.printables.com/model/1670548-v620-dual-shroud) |

Takeaways: the blower has the most headroom on a solo full-load; the low-CFM Arctic pair
**cannot** sustain one (static pressure through the passive heatsink is the bottleneck); the
single **NF-F12 shroud holds the split comfortably** but runs a solo full-load right at its
limit (fan maxed, ~8 °C from the 100 °C throttle). For solo full-load work prefer the blower —
or rely on the [`gpu-thermal-watchdog/`](../gpu-thermal-watchdog/) (stops the LLM server at
102 °C) as the last-resort safety net.

## Why a kernel driver swap is needed

The board is an **MSI MAG B550 Tomahawk Max** → Super-I/O chip **Nuvoton
NCT6687D**. Linux's *in-tree* `nct6683` driver binds it **read-only**: every
`pwmN` is `-r--r--r--` with no `pwmN_enable`, so nothing in the OS can set a fan
speed. The fix is the out-of-tree **`nct6687`** driver
([Fred78290/nct6687d](https://github.com/Fred78290/nct6687d)), installed via
DKMS, which exposes **writable** `pwmN` / `pwmN_enable`. `install.sh` blacklists
`nct6683`, loads `nct6687` at boot, and DKMS rebuilds it on kernel upgrades.

pwm↔fan channels were verified empirically (driving `pwmN` moves only `fanN`):
the **blower = pwm2** and the **Arctic pair = pwm4** (the only channel that spins
to ~6000 RPM — the S4028-6K signature). Note the driver's `System Fan #N` labels
are offset from the board silkscreen: channel `N` = `System Fan #(N-2)`.

## Control logic (per instance)

- Curve driven by the **edge** temperature; the **hottest** of the hotspot
  sensors (**junction + mem**) forces 100% as a safety override (with hysteresis).
- The fan **never stops** — `MIN_PWM_RAW` is a hard floor (the fan is the card's
  only cooling). The 9733 blower holds ~750 RPM at 12.5%. The 2× S4028-6K have a
  higher floor: they **stall below ~18%** and **won't cold-start below ~21%**, so
  the Arctic floor is **22% (pwm 56, ~690 RPM)** — the lowest that reliably spins
  both up from a dead stop on boot.
- Profiles (tune in `/etc/gpu-fan-control-<instance>.env`):
  - **blower** — `edge ≤35 °C → 12.5%`, ramp, `edge ≥88 °C → 100%`.
  - **arctic** — `edge ≤40 °C → 22%`, ramp, `edge ≥85 °C → 100%`.
  - both — `junction|mem ≥90 °C → 100%`.
- **Fail toward cooling.** Every sensor present at startup (edge *and* each of
  `HOTSPOT_TEMP_LABELS`) is then required: if any one disappears the daemon forces
  100%. Missing a configured sensor at startup is fatal.
- **Tach watchdog.** If the fan reads below `FAN_MIN_RPM` while airflow is
  commanded, the daemon forces 100% and logs `CRITICAL`; every PWM write is read
  back and persistent write failures escalate the same way. This matters most for the
  shroud — it's the **sole cooler for both GPUs**, so a stall means both lose airflow
  (the amdgpu 100 °C throttle / ~105 °C cutout is the hardware backstop).
- **Failsafe:** on any stop/crash the instance hands its channel back to the
  BIOS/SIO auto curve (`pwmN_enable=2`), or a verified manual 100% if that can't be
  confirmed — never the idle floor. Via the EXIT trap and the unit's `ExecStopPost`.
  Independently, amdgpu throttles at 100 °C and emergency-shuts at ~105 °C.

## Files

| File | Installed to | Purpose |
|------|--------------|---------|
| `gpu-fan-control.sh`          | `/usr/local/sbin/gpu-fan-control`            | the control daemon (GPU(s) pinned via `GPU_PCI_ADDRESS`) |
| `gpu-fan-control@.service`    | `/etc/systemd/system/gpu-fan-control@.service` | systemd **template** (one instance per cooler) |
| `gpu-fan-control-shroud.env`  | `/etc/gpu-fan-control-shroud.env`            | **current**: NF-F12 shroud cooling both GPUs (curve + PCI/channel pins) |
| `gpu-fan-control-blower.env`, `gpu-fan-control-arctic.env` | (not installed) | prior per-GPU coolers, kept in-repo for reference |
| `install.sh`                  | —                                            | one-shot installer (driver + the `INSTANCES` cooler(s)) |

The daemon resolves the `nct6687` chip by **name** and each GPU by **PCI address**
every boot (the `hwmonN`/`cardN` numbers are not stable).

## Install

Run on the Proxmox host as root (idempotent — sets up the driver and the cooler
instance(s) in `INSTANCES` (currently `shroud`), and retires any stale/older ones):

```bash
./pro-v620/fan-control/install.sh
```

The installer pins the nct6687 driver to a reviewed **full commit SHA** (it is
built and loaded into the kernel as root). To bump it, review the upstream diff and
pin its SHA: `NCT6687D_REF=<40-char-sha> ./pro-v620/fan-control/install.sh`. A
moving ref like `master` is rejected unless `NCT6687D_ALLOW_UNPINNED=1`.

## Operate

```bash
systemctl status gpu-fan-control@shroud
journalctl -u gpu-fan-control@shroud -f     # watch edge(max of both GPUs) -> pwm decisions

# live state of the shroud fan (resolve nct6687 hwmon first)
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nct6687 ] && echo $h; done)
echo "shroud (NF-F12, FAN1): pwm=$(cat $H/pwm3) rpm=$(cat $H/fan3_input)"

# retune the curve
$EDITOR /etc/gpu-fan-control-shroud.env
systemctl restart gpu-fan-control@shroud
```

## Uninstall

```bash
systemctl disable --now gpu-fan-control@shroud
rm -f /usr/local/sbin/gpu-fan-control /etc/gpu-fan-control-*.env \
      /etc/systemd/system/gpu-fan-control@.service
systemctl daemon-reload
# (optional) revert to the in-tree read-only driver / BIOS-only fan control:
rm -f /etc/modprobe.d/nct6687.conf /etc/modules-load.d/nct6687.conf
dkms remove nct6687d/1 --all
```

## Troubleshooting

- **`nct6687 hwmon not found`** — module not loaded; `modprobe nct6687` and check
  `dmesg | grep nct6687`. The driver only binds NCT6687D-class chips.
- **PWM not writable** — the in-tree `nct6683` won the bind. Confirm
  `/etc/modprobe.d/nct6687.conf` blacklists it, then
  `modprobe -r nct6683 && modprobe nct6687`.
- **`hwmon not found @ <pci>`** — the instance's `GPU_PCI_ADDRESS` doesn't match a
  bound amdgpu card; check `lspci -D | grep -i V620` and the env file.
- **Fan at full speed unexpectedly** — junction ≥ 90 °C (override), a stalled tach,
  or an unreadable GPU sensor (fails toward 100%); check the instance's journal.
- **Wrong fan / wrong card** — each instance is pinned by `GPU_PCI_ADDRESS` +
  `FAN_PWM_CHANNEL`; identify a channel by driving each `pwmN` and watching which
  `fanN_input` responds.
