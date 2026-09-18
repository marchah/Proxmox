# gpu-blower-control

Drives each V620's 9733 blower from that card's **amdgpu** temperature, by writing BMC fan
duty over **in-band IPMI**. Host-side service, not in an LXC.

## Why this exists

The BMC has **no GPU temperature sensor**. Its own fan tables can only ever react to CPU,
board and DIMM temps, so they can never cool a passive datacenter card. This closes that loop.

### What the BMC *does* cover, so you don't build a second service for it

The GPU is the **only** thermal gap on this board. The BMC monitors the CPU, the board and
**every memory channel**, and its own fan tables act on them — so there is deliberately no
CPU or RAM equivalent of this service, and none is needed.

```sh
ipmitool sdr type Temperature      # CPU Temp, MB Temp, Card Side Temp, Onboard LAN Temp,
                                   # and TEMP_CPU1_DDR4A .. TEMP_CPU1_DDR4H (one per channel)
ipmitool sdr type Fan              # FAN1..FAN5
```

⚠️ **An unpopulated channel reports `No Reading`** — which is the easiest way to see which
slots are filled without opening the case. Do **not** use `dmidecode` for that: ASRock's
firmware labels every slot `Locator: DIMM 0`, so the field is worthless here.

Baseline measured **2026-09-17** under the qwen4exp placement sweep, with **4 of 8 channels
populated (C, D, G, H)**. ✅ That placement is **correct and deliberate** — chosen from the
board documentation and validated by the owner's own tests, all four running at
`Configured Memory Speed: 3200 MT/s`. Don't "fix" it, and don't second-guess it from generic
one-per-quadrant advice.

| sensor | reading |
| --- | ---: |
| `TEMP_CPU1_DDR4C` / `D` / `G` / `H` | 47 / 48 / 45 / **50 °C** |
| `TEMP_CPU1_DDR4A` / `B` / `E` / `F` | *empty — No Reading* |
| `CPU Temp` | 41 °C |
| `FAN1`–`FAN5` | 1200 / 1400 / 1400 / 1700 / 2400 RPM |

DDR4 RDIMMs throttle near 85 °C, so that is ~35 °C of headroom, and the BMC exposes **no
upper threshold** on the DIMM sensors. The ~4 °C spread between the hottest (H) and coolest
(G) channel is airflow position, not a fault.
⚠️ Expect **+5–10 °C when the remaining four sticks land**: A/B/E/F currently act as airflow
gaps, and filling them both adds heat sources and restricts flow.

✅ **Flat DIMM temps are a useful independent check on whether a workload is genuinely
memory-bandwidth-bound.** They did not move while CPU utilisation swung 2% → 50% during the
sweep — corroborating, from a completely different sensor, that the hybrid qwen4exp placement
is latency-bound rather than saturating the ~92 GB/s the sizing note assumes.

It replaces [`../fan-control/`](../fan-control/) on the ROMED8-2T. That service writes
`nct6687` PWM sysfs — a Super I/O chip **no server board has**. The *control law is identical*
(linear ramp on edge temp + hotspot override on the hottest of junction/mem, with hysteresis);
only the transport changed.

## Install

```sh
./install.sh          # needs ipmitool and /dev/ipmi0
```

## 🔴 Verify the PCI ↔ fan pairing before trusting it

**Do not infer which blower cools which card from PCI bus order.** On this build it is the
reverse: `FAN4` cools `0000:83:00.0` (top card), `FAN5` cools `0000:03:00.0` (bottom).

Getting this backwards is nearly undiagnosable from temperatures alone — each card's blower
ramps in response to the *other* card's heat, so the loaded card gets minimum duty while its
idle neighbour runs at full. Both cards then appear to "fail to cool" identically, and every
other hypothesis (shroud, case airflow, undervolt, PCIe link) tests clean.

**The test that settles it — starve one blower under load:**

```sh
systemctl stop gpu-blower-control
# FAN4 -> 20%, FAN5 -> 100% (positions 4 and 5 of the 16-byte duty table)
ipmitool raw 0x3a 0xd6 0x14 0x14 0x14 0x14 0x64 0x14 0x14 0x1e 0x1e 0x1e 0x1e 0x1e 0x1e 0x1e 0x1e 0x1e
# now load ONE card and watch its edge temp
```

If the card **stays cool while its supposed blower is starved**, the pairing is swapped.
Measured here: 47 °C with FAN4 at 20% versus 94 °C with FAN4 at 100% — a 47 °C swing that
points unambiguously the wrong way.

## BMC fan command set (ASRock Rack, in-band `/dev/ipmi0`)

| Command | Payload | Meaning |
| --- | --- | --- |
| `0x3a 0xd9` | read 16 | mode per fan: `00`=Default `01`=Manual `02`=Customized |
| `0x3a 0xd8` | write 16 | set modes |
| `0x3a 0xd7` | read 16 | manual duty table |
| `0x3a 0xd6` | write 16 | set manual duty |
| `0x3a 0xda` | read 16 | currently applied duty |

⚠️ **Values must carry `0x` prefixes.** Passing bare hex from a shell variable returns
`rsp=0xc7 Request data length invalid`, which reads like a wrong payload length and is not.

⚠️ The BMC enforces `Fan_PWM_Min = 20`, so the B550-era `PWM_MIN_PCT=12` floor is unreachable
here; the env uses 20.

The service claims **only** its two fans — it reads the existing mode table and preserves every
other fan's mode, so the BMC keeps managing the CPU and case fans through its own table.

## Fail-safe

Deliberately the **opposite** of `gpu-thermal-watchdog`: stopping a model is disruptive, so that
service skips a missing sensor. Here a missing sensor means a card is being cooled blind, so:

- any unreadable temp, missing hwmon or failed IPMI write → **100%**
- `ExecStopPost` forces 100%, so a clean stop or reboot leaves the blowers at full
- `Restart=always`; verified against `kill -9`

⚠️ An **unclean** power loss leaves whatever duty was last written. The next boot idles there
until the service starts — safe with cold cards, but worth knowing.

⚠️ **With the host powered off the BMC stops all fans**, including these. That is fine (the cards
are cold) but means the blowers are not a standby-power safety net.

## Measured

Sustained MoE load, one card, `-100 mV` undervolt, correct pairing:

| | |
| --- | ---: |
| Steady edge / junction | **55 °C / 62 °C** |
| Power | stable 130–140 W, no throttling |
| Blower duty | ~35% (2900 RPM of ~5000 max) |

With the pairing swapped the same load settled at 94 °C / 100 °C, at 100% duty, throttling
171 → 132 W.
