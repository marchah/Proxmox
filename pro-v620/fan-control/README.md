# GPU fan control — Radeon Pro V620 blower (PUMP_FAN1)

Host-level (Proxmox) service that drives the V620's blower fan from the **GPU's
own temperature**, instead of the BIOS smart-fan curve that can only read the
motherboard PCIE temperature probe.

The V620 is a passively cooled datacenter card; a blower on a 3D-printed shroud
provides its only cooling, wired to the board's **PUMP_FAN1** header.

## Why a kernel driver swap is needed

The board is an **MSI MAG B550 Tomahawk Max** → Super-I/O chip **Nuvoton
NCT6687D**. Linux's *in-tree* `nct6683` driver binds it **read-only**: every
`pwmN` is `-r--r--r--` with no `pwmN_enable`, so nothing in the OS can set a fan
speed. The fix is the out-of-tree **`nct6687`** driver
([Fred78290/nct6687d](https://github.com/Fred78290/nct6687d)), installed via
DKMS, which exposes **writable** `pwmN` / `pwmN_enable`. `install.sh` blacklists
`nct6683`, loads `nct6687` at boot, and DKMS rebuilds it on kernel upgrades.

`PUMP_FAN1` is **pwm channel 2** on this board (verified empirically: driving
`pwm2` moved only `fan2`'s RPM).

## Control logic

- Curve is driven by the **edge** temperature (the stable "GPU temp"); the
  **hottest** of the hotspot sensors (**junction + mem**) forces 100% as a
  safety override (with hysteresis).
- The fan **never stops** — `MIN_PWM_RAW` is a hard floor, because the blower is
  the card's only cooling. (It does not stall at the floor; the 9733 12V blower
  still holds ~750 RPM at 12.5% and does not stall even at 10%.)
- Default profile is **Quiet**: `edge ≤35 °C → 12.5%`, linear ramp, `edge ≥88 °C
  → 100%`; `junction|mem ≥90 °C → 100%`. Tune in `/etc/gpu-fan-control.env`.
- **Fail toward cooling.** Every sensor present at startup (edge *and* each of
  `HOTSPOT_TEMP_LABELS`) is then required: if **any one** disappears the daemon
  forces 100% — a surviving sensor can't mask the loss of another. Missing a
  configured sensor *at startup* is fatal (run degraded silently is exactly what
  we avoid).
- **Blower tach watchdog.** The blower is the card's only cooling, so its RPM is
  watched: if it reads below `FAN_MIN_RPM` while airflow is commanded
  (`FAN_FAIL_GRACE` polls), the daemon forces 100% and logs `CRITICAL`. Every PWM
  write is **read back**; persistent write failures (`WRITE_FAIL_GRACE`) escalate
  the same way, since control is lost even if the fan still reads some RPM. Set
  `FAN_FAIL_ACTION=poweroff` to power the host off when control can't be restored.
  The tach watchdog auto-disables for fans without a tachometer.
- **Failsafe:** on any stop or crash the service restores a **verified** safe
  state — it hands `PUMP_FAN1` back to the BIOS/SIO auto curve (`pwmN_enable=2`)
  and, only if that can't be confirmed, forces a verified manual 100%; it never
  leaves the blower at the idle floor. Via the script's EXIT trap and the unit's
  `ExecStopPost`. Independently, amdgpu hardware throttles at 100 °C and
  emergency-shuts at ~105 °C.

## Files

| File | Installed to | Purpose |
|------|--------------|---------|
| `gpu-fan-control.sh`      | `/usr/local/sbin/gpu-fan-control`        | the control daemon |
| `gpu-fan-control.env`     | `/etc/gpu-fan-control.env`               | tunable curve / mapping |
| `gpu-fan-control.service` | `/etc/systemd/system/...`                | systemd unit |
| `install.sh`              | —                                        | one-shot installer (driver + service) |

The daemon resolves both hwmon chips by **name** (`amdgpu`, `nct6687`) each
boot, because the `hwmonN` numbers are not stable.

## Install

Run on the Proxmox host as root (idempotent):

```bash
./pro-v620/fan-control/install.sh
```

The installer pins the driver to a reviewed **full commit SHA** (it is built and
loaded into the kernel as root). To move to a newer driver — e.g. if a future
kernel fails to build the pinned commit — review the upstream diff and pin its
SHA: `NCT6687D_REF=<40-char-sha> ./pro-v620/fan-control/install.sh`. A moving ref
like `master` is rejected unless you set `NCT6687D_ALLOW_UNPINNED=1`, in which case
the driver is **rebuilt on every run** (and the resolved commit SHA is recorded).

## Operate

```bash
systemctl status gpu-fan-control
journalctl -u gpu-fan-control -f          # watch edge/junction -> pwm decisions

# live state of the blower channel (resolve nct6687 hwmon first)
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nct6687 ] && echo $h; done)
echo "enable=$(cat $H/pwm2_enable) pwm=$(cat $H/pwm2) rpm=$(cat $H/fan2_input)"

# retune
sensors                                    # or edit /etc/gpu-fan-control.env
systemctl restart gpu-fan-control
```

## Uninstall

```bash
systemctl disable --now gpu-fan-control
rm -f /usr/local/sbin/gpu-fan-control /etc/gpu-fan-control.env \
      /etc/systemd/system/gpu-fan-control.service
systemctl daemon-reload
# (optional) revert to the in-tree read-only driver / BIOS-only fan control:
rm -f /etc/modprobe.d/nct6687.conf /etc/modules-load.d/nct6687.conf
dkms remove nct6687d/1 --all
```

## Troubleshooting

- **`nct6687 hwmon not found` at start** — module not loaded; `modprobe nct6687`
  and check `dmesg | grep nct6687`. The driver only binds NCT6687D-class chips.
- **PWM not writable** — the in-tree `nct6683` won the bind. Confirm
  `/etc/modprobe.d/nct6687.conf` blacklists it, then
  `modprobe -r nct6683 && modprobe nct6687`.
- **Blower at full speed unexpectedly** — junction ≥ 90 °C (override), or the
  GPU sensor is unreadable (the daemon fails toward 100%); check
  `journalctl -u gpu-fan-control`.
- **Wrong fan moves** — the blower isn't on PUMP_FAN1 / pwm2; set
  `FAN_PWM_CHANNEL` in the env file (identify by driving each `pwmN` and watching
  which `fanN_input` changes).
