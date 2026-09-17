# gpu-blower-control

Drives each V620's 9733 blower from that card's **amdgpu** temperature, by writing BMC fan
duty over **in-band IPMI**. Host-side service, not in an LXC.

## Why this exists

The BMC has **no GPU temperature sensor**. Its own fan tables can only ever react to CPU,
board and DIMM temps, so they can never cool a passive datacenter card. This closes that loop.

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
