# B550 GPU fan control

Reference service for the MSI MAG B550 Tomahawk Max's NCT6687D controller.
The ROMED8-2T uses [gpu-blower-control](../gpu-blower-control/README.md).

One systemd instance controls one fan channel, using GPU temperatures and
PCI-address matching. The B550 hub profile drives two 9733 blowers on PUMP_FAN1
(`pwm2`) and tracks the hotter card. Its PCI addresses and header assignments
belong to that board.

PUMP_FAN1 was the verified PWM output for externally powered fans; the tested
SYS_FAN headers used DC mode. Confirm duty changes affect the fan, since a tach
reading alone does not prove control. The hub returns only one blower's tach.
Each blower needs 12 V / 1.5 A, so verify the hub's per-port rating.

The two-blower setup measured 62/73 °C junction at 51% duty under simultaneous
load on 2026-08-22. The printed blower mount is
[Thingiverse 7296707](https://www.thingiverse.com/thing:7296707).

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

- Curve driven by the **edge** temperature (the **hottest** edge across all cooled GPUs
  when one fan cools several); the **hottest** of the hotspot sensors (**junction + mem**,
  across all cooled GPUs) forces 100% as a safety override (with hysteresis).
- The fan **never stops** — `MIN_PWM_RAW` is a hard floor (the fans are the cards' only
  cooling). The current **9733 blower** floor is **12% (pwm 32, ~1000 RPM)**, verified by
  cold-start: from a dead stop, pwm 32 spins the fan up to ~980 RPM, so the floor sits above
  the cold-start threshold. (Prior per-cooler floors — NF-F12 shroud 50%, Arctic 22% — live in
  the reference env files and the *Measured thermals* notes above.)
- Current **hub** profile (`/etc/gpu-fan-control-hub.env`): `edge ≤45 °C → 12%`, ramp,
  `edge ≥88 °C → 100%`; `junction|mem ≥90 °C → 100%` (resume at 87 °C).
- ⚠️ **The curve follows EDGE temperature, not junction** — a common source of confusion when
  predicting fan behaviour, since junction runs well above edge. Integer math:
  `pct = PWM_MIN_PCT + (edge − EDGE_MIN_C) × (100 − PWM_MIN_PCT) / (EDGE_MAX_C − EDGE_MIN_C)`,
  then `raw = pct × 255 / 100`, floored at `MIN_PWM_RAW`. Verified against the daemon:
  predicted pwm 142 at edge 62 °C, daemon commanded 142.
- `EDGE_MIN_C` was raised **35 → 45** on 2026-08-22 after A/B load tests. Real workloads here
  are bursty and live in the 40-55 °C edge band, where the old floor had the fan already spun
  to 2000-2450 RPM; at 45 it holds ~1000 RPM to 45 °C. Cost at sustained dual-card full load
  was **+3 °C on the hotter card for −230 RPM** (GPU 2: 70 → 73 °C, fan 57% → 51%). The effect
  is self-limiting — a warmer card sits further up the curve. `EDGE_MIN_C=50` was considered
  and declined: another ~200 RPM for another ~2-3 °C is a diminishing return.
- **Fail toward cooling.** Every sensor present at startup (edge *and* each of
  `HOTSPOT_TEMP_LABELS`) is then required: if any disappears the daemon forces 100%.
  Likewise, every GPU in an explicit `GPU_PCI_ADDRESS` list is a **required set**, re-checked
  every poll: if any listed card is missing/unbound the daemon forces 100% and logs
  `CRITICAL` (the shared fan cools all listed cards, so an untracked one must not be left
  following only the present card). Missing a configured *sensor* on a present card at
  startup is fatal.
- **Tach watchdog.** If the fan reads below `FAN_MIN_RPM` while airflow is
  commanded, the daemon forces 100% and logs `CRITICAL`; every PWM write is read
  back and persistent write failures escalate the same way. ⚠️ With the hub, the tach
  only reflects the blower in its **RED port** — the other card's fan is invisible here, so
  this watchdog protects one card, not both. `gpu-thermal-watchdog` covers the other (and the
  amdgpu 100 °C throttle / ~105 °C cutout is the hardware backstop).
- **Failsafe:** on any stop/crash the instance hands its channel back to the
  BIOS/SIO auto curve (`pwmN_enable=2`), or a verified manual 100% if that can't be
  confirmed — never the idle floor. Via the EXIT trap and the unit's `ExecStopPost`.
  Independently, amdgpu throttles at 100 °C and emergency-shuts at ~105 °C.

## Files

| File | Installed to | Purpose |
|------|--------------|---------|
| `gpu-fan-control.sh`          | `/usr/local/sbin/gpu-fan-control`            | the control daemon (GPU(s) pinned via `GPU_PCI_ADDRESS`) |
| `gpu-fan-control@.service`    | `/etc/systemd/system/gpu-fan-control@.service` | systemd **template** (one instance per cooler) |
| `gpu-fan-control-hub.env`     | `/etc/gpu-fan-control-hub.env`               | **current**: both blowers via the hub on PUMP_FAN1 (curve + PCI/channel pins) |
| `gpu-fan-control-gpu1.env`, `gpu-fan-control-gpu2.env` | (not installed) | per-card instances, staged for if the SYS_FAN headers ever become PWM-capable |
| `gpu-fan-control-shroud.env`, `gpu-fan-control-blower.env`, `gpu-fan-control-arctic.env` | (not installed) | retired coolers, kept in-repo for reference |
| `install.sh`                  | —                                            | one-shot installer (driver + the `INSTANCES` cooler(s)) |

The daemon resolves the `nct6687` chip by **name** and each GPU by **PCI address**
every boot (the `hwmonN`/`cardN` numbers are not stable).

## Install

Run on the Proxmox host as root (idempotent — sets up the driver and the cooler
instance(s) in `INSTANCES` (`hub` for the B550 setup), and retires any stale/older ones):

```bash
./pro-v620/fan-control/install.sh
```

The installer pins the nct6687 driver to a reviewed **full commit SHA** (it is
built and loaded into the kernel as root). To bump it, review the upstream diff and
pin its SHA: `NCT6687D_REF=<40-char-sha> ./pro-v620/fan-control/install.sh`. A
moving ref like `master` is rejected unless `NCT6687D_ALLOW_UNPINNED=1`.

## Operate

```bash
systemctl status gpu-fan-control@hub
journalctl -u gpu-fan-control@hub -f        # watch edge(max of both GPUs) -> pwm decisions

# live state of the blowers (resolve nct6687 hwmon first)
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat $h/name)" = nct6687 ] && echo $h; done)
echo "hub (2x 9733, PUMP_FAN1): pwm=$(cat $H/pwm2) rpm=$(cat $H/fan2_input)"
# NB: fan2 is the hub's RED port only — the other blower has no tach anywhere.

# confirm control is REAL (not just a healthy tach): the fan must actually stop
echo 1 > $H/pwm2_enable; echo 0 > $H/pwm2; sleep 7; cat $H/fan2_input   # expect 0
systemctl restart gpu-fan-control@hub                                   # hand it back

# retune the curve
$EDITOR /etc/gpu-fan-control-hub.env
systemctl restart gpu-fan-control@hub
```

## Uninstall

```bash
systemctl disable --now gpu-fan-control@hub
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
- **Fan stuck at 100% and ignoring every duty, tach reading fine** — the PWM signal is not
  reaching it. Almost always the header: only `PUMP_FAN1` drives pin 4 on this board (see the
  DC-mode warning at the top). Do **not** start replacing fans, cables or hubs before you have
  driven the channel to 0 and confirmed the fan does not stop.
- **Wrong fan / wrong card** — each instance is pinned by `GPU_PCI_ADDRESS` +
  `FAN_PWM_CHANNEL`; identify a channel by driving each `pwmN` and watching which
  `fanN_input` responds.
