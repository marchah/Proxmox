# GPU fan control — Radeon Pro V620 coolers (per-GPU instances)

Host-level (Proxmox) service that drives each V620's cooler fan from **that GPU's
own temperature**, instead of the BIOS smart-fan curve (which can only read a
motherboard temperature probe). The V620s are passively cooled datacenter cards,
so their fans are the **only** cooling.

This host runs **two V620s**, each with its own cooler on its own fan header, so the
service runs **one systemd instance per card**:

| Instance | GPU (PCI address) | Cooler | nct6687 pwm | Idle floor |
|----------|-------------------|--------|-------------|------------|
| `gpu-fan-control@blower` | PCIe-1 `0000:2d:00.0` | 9733 12V blower (Pump Fan header) | pwm2 | 12.5% (~750 RPM) |
| `gpu-fan-control@arctic` | PCIe-3 `0000:06:00.0` | 2× Arctic S4028-6K, 40 mm (fan 2 header) | pwm4 | 22% (~690 RPM) |

Each instance pins its GPU by **PCI address** (`GPU_PCI_ADDRESS`) — stable across
boots, unlike the `cardN` index which flips — and its fan by `FAN_PWM_CHANNEL`.

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
  back and persistent write failures escalate the same way. The Arctic pair share
  one header via a splitter, so only **one** fan's tach is visible — a total stall
  of the tach'd fan is caught; a single-fan failure of the other is not.
- **Failsafe:** on any stop/crash the instance hands its channel back to the
  BIOS/SIO auto curve (`pwmN_enable=2`), or a verified manual 100% if that can't be
  confirmed — never the idle floor. Via the EXIT trap and the unit's `ExecStopPost`.
  Independently, amdgpu throttles at 100 °C and emergency-shuts at ~105 °C.

## Files

| File | Installed to | Purpose |
|------|--------------|---------|
| `gpu-fan-control.sh`          | `/usr/local/sbin/gpu-fan-control`            | the control daemon (GPU pinned via `GPU_PCI_ADDRESS`) |
| `gpu-fan-control@.service`    | `/etc/systemd/system/gpu-fan-control@.service` | systemd **template** (one instance per cooler) |
| `gpu-fan-control-blower.env`  | `/etc/gpu-fan-control-blower.env`            | PCIe-1 blower: curve + PCI/channel pins |
| `gpu-fan-control-arctic.env`  | `/etc/gpu-fan-control-arctic.env`            | PCIe-3 Arctic: curve + PCI/channel pins |
| `install.sh`                  | —                                            | one-shot installer (driver + both instances) |

The daemon resolves the `nct6687` chip by **name** and the GPU by **PCI address**
each boot (the `hwmonN`/`cardN` numbers are not stable).

## Install

Run on the Proxmox host as root (idempotent — sets up the driver and **both**
instances, and migrates off any old single-instance service):

```bash
./pro-v620/fan-control/install.sh
```

The installer pins the nct6687 driver to a reviewed **full commit SHA** (it is
built and loaded into the kernel as root). To bump it, review the upstream diff and
pin its SHA: `NCT6687D_REF=<40-char-sha> ./pro-v620/fan-control/install.sh`. A
moving ref like `master` is rejected unless `NCT6687D_ALLOW_UNPINNED=1`.

## Operate

```bash
systemctl status gpu-fan-control@blower gpu-fan-control@arctic
journalctl -u gpu-fan-control@arctic -f     # watch edge/junction -> pwm decisions

# live state of both channels (resolve nct6687 hwmon first)
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nct6687 ] && echo $h; done)
echo "blower: pwm=$(cat $H/pwm2) rpm=$(cat $H/fan2_input)"
echo "arctic: pwm=$(cat $H/pwm4) rpm=$(cat $H/fan4_input)"

# retune one cooler
$EDITOR /etc/gpu-fan-control-arctic.env
systemctl restart gpu-fan-control@arctic
```

## Uninstall

```bash
systemctl disable --now gpu-fan-control@blower gpu-fan-control@arctic
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
