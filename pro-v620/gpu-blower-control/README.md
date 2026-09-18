# gpu-blower-control

Drives each V620's 9733 blower from that card's **amdgpu** temperature, by writing BMC fan
duty over **in-band IPMI**. Host-side service, not in an LXC.

## Why this exists

The BMC has **no GPU temperature sensor**. Its own fan tables can only ever react to CPU,
board and DIMM temps, so they can never cool a passive datacenter card. This closes that loop.

The BMC manages CPU, board and DIMM cooling. Inspect its sensors with
`ipmitool sdr type Temperature` and `ipmitool sdr type Fan`. Unpopulated DIMM
channels report `No Reading`.

This controller uses IPMI on the ROMED8-2T. Its control law ramps with GPU edge
temperature and overrides to full speed on high junction/memory temperatures,
with hysteresis. The older [fan-control](../fan-control/README.md) service uses
B550-specific `nct6687` sysfs.

## Install

```sh
./install.sh          # needs ipmitool and /dev/ipmi0
```

## Fan pairing

| Blower | Card |
| --- | --- |
| FAN4 | `0000:83:00.0` (top) |
| FAN5 | `0000:03:00.0` (bottom) |

Verify the physical pairing after rewiring: change one blower's duty and confirm
that blower responds. PCI bus order does not identify the fan header. Reversed
pairing ramps the idle card's blower while the loaded card gets minimum duty.

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

The BMC enforces `Fan_PWM_Min = 20`; the env uses that minimum.

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
