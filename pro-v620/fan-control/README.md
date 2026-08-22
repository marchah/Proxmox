# GPU fan control — Radeon Pro V620 coolers (per-cooler instances)

Host-level (Proxmox) service that drives the V620 cooler fan(s) from the **GPU's own
temperature**, instead of the BIOS smart-fan curve (which can only read a motherboard
temperature probe). The V620s are passively cooled datacenter cards, so their fans are
the **only** cooling.

The service runs **one systemd instance per controllable fan channel**. Current hardware —
**each V620 has its own 9733 radial blower**, and both blowers hang off a single
**SATA-powered PWM hub** that takes its control signal from the **PUMP FAN** header:

| Instance | GPU(s) cooled | Cooler | nct6687 pwm | Idle floor |
|----------|---------------|--------|-------------|------------|
| `gpu-fan-control@hub` | both — `0000:2d:00.0` + `0000:06:00.0` | 2 × 9733 blower (one per card) via an EN-Labs PWMHUB10SMG on PUMP_FAN1 | pwm2 | 12% (pwm 32, ~1000 RPM) |

Each card has its **own** blower, so cooling capacity is per-card; only the **PWM control
signal** is shared through the hub. One signal means one curve, so it tracks the **hottest**
card, and a required sensor missing on **any** of them forces 100%.

An instance pins its GPU(s) by **PCI address** (`GPU_PCI_ADDRESS` — comma-separated when one
channel drives fans on several cards; stable across boots, unlike the `cardN` index) and its
fan by `FAN_PWM_CHANNEL`.

> ### ⚠️ Only PUMP_FAN1 can control an externally-powered fan
>
> The **`SYS_FAN*` headers on this board are in DC (voltage) mode**, so their **pin 4 carries
> no PWM signal**. A fan drawing its 12 V from elsewhere (SATA) ignores pin 2's voltage and
> has nothing on pin 4 to obey — it free-runs at **100% forever**. `PUMP_FAN1` is the only
> header verified to drive pin 4, which is why the hub's control lead lives there.
>
> Verified 2026-08-22 the hard way, across `SYS_FAN1`, `SYS_FAN2` and `SYS_FAN4`, with two
> different blowers, a plain SATA+PWM cable **and** the hub — every combination free-ran at
> 100%. The clincher: a **3-pin** case fan is smoothly speed-controlled on `pwm5`
> (1360→1217→1027→869→695→496→369 RPM, stalling below 18%), and only voltage control can do
> that to a fan with no PWM wire at all.
>
> **There is no software fix.** The driver exposes no `pwm*_mode` attribute (its
> `NCT6687_REG_FAN_CTRL_MODE` is manual-vs-auto, a different thing), upstream documents the
> PWM-vs-DC unit as "configured by firmware", Nuvoton does not publish the NCT6687D register
> map, and this host has no video output to reach BIOS. **CoolerControl / `fancontrol` /
> lm-sensors cannot help either** — they write the same `pwm*` sysfs files this daemon does;
> they do not change hardware mode.
>
> ⚠️ **A tach reading proves NOTHING about control.** A 4-pin fan receiving no PWM signal
> reports RPM perfectly while ignoring every duty change. Mistaking a healthy tach for
> working control cost roughly two weeks of misdiagnosis here — a fan was blamed, a cable
> replaced, a hub bought, then a fan and a hub each wrongly declared dead. **Confirm control
> by driving the channel to 0 and checking the fan actually stops.**
>
> ⚠️ **Monitoring gap:** the hub returns a tach signal from its **RED port only**, so `fan2`
> reports just one of the two blowers. Failure of the other is invisible to the tach
> watchdog; [`gpu-thermal-watchdog/`](../gpu-thermal-watchdog/) is the backstop for that card.
>
> ⚠️ **Per-port current is the spec that matters, and it is usually unstated.** Each blower is
> **12 V / 18 W = 1.5 A**. `SYS_FAN` headers are rated 1 A / 12 W and `PUMP_FAN1` 2-3 A, which
> is why the blowers cannot be header-powered on a SYS_FAN channel at all. Arctic's Case Fan
> Hub is **1 A/port** — too weak. Arctic's Fan Controller and Lian Li's EDGE Hub are
> **USB/software-controlled**, so they are useless for a sysfs curve on headless Proxmox
> regardless of their current rating.

## Measured thermals & 3D-printed mounts (per cooler)

Junction temperature at −100 mV undervolt (the [`undervolt/`](../undervolt/) floor).
**Split** = model split across both cards (each ~half the load); **solo full-load** = the
whole model on one card (~250 W board power). CT 120 is pinned to GPU 1 and CT 123 to GPU 2,
so the realistic worst case is **both cards loaded at once**.

| Cooler | Card(s) | Split (½-load) | Solo / dual full-load | 3D-printed mount |
|--------|---------|----------------|-----------------------|------------------|
| **2 × 9733 blower, one per card** (current) | both | — | **GPU1 62 °C / GPU2 73 °C @ 51% fan** — both loaded at once ✅ | [thingiverse:7296707](https://www.thingiverse.com/thing:7296707) |
| *9733 blower, single card (historical)* | 1 (PCIe-1) | — | ~83 °C @ ~93% fan | as above |
| *NF-F12 iPPC-3000 shroud, both cards (retired 2026-08-15)* | both | ~56–59 °C @ 60% fan | GPU1 ~91 °C / GPU2 ~97 °C @ 100% fan | [printables 1670548](https://www.printables.com/model/1670548-v620-dual-shroud) |
| *2 × Arctic S4028-6K (retired)* | 1 (PCIe-3) | ~70 °C | 106 °C, fan maxed, throttling | [printables 1712035](https://www.printables.com/model/1712035-amd-v340-v520-v620-mi25-mi50-mi60-mi100-mi210-fan) |

**A blower per card resolved the thermal ceiling.** The current setup was load-tested
2026-08-22 with **both cards driven simultaneously for ~6.7 minutes** — the case the shroud
configuration never survived — and settled at **GPU 2 = 73 °C with the fan at only 51%**,
temps flat for the final four minutes, **zero thermal-watchdog trips**. That is ~25 °C better
than the shroud managed *with its fan maxed*, and it leaves **29 °C of margin** to the
watchdog's 102 °C trip plus half the fan's range unused. Sustained saturation on both cards
is comfortable; there is no workload on this box that approaches the cards' limits.

The historical rows are kept because they explain the progression: the low-CFM Arctic pair
could not push static pressure through a passive heatsink at all, and a single 120 mm shroud
fan could hold a *split* load but ran a full load right at its limit. Static pressure per
card is what matters, hence one radial blower each.

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
instance(s) in `INSTANCES` (currently `hub`), and retires any stale/older ones):

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
