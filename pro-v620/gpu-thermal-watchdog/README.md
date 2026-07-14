# GPU thermal watchdog (Radeon Pro V620)

A host-side systemd daemon that is the **last-resort over-temp protection** for the
two Radeon Pro V620s. It gracefully stops the LLM server if a card gets dangerously
hot, so the GPU cools **before** the hardware has to reset itself.

Runs on the **Proxmox host** as root (not in an LXC) — it reads amdgpu hwmon temps
and stops an LXC service via `pct`.

## Why it exists — where it sits in the thermal stack

The V620 already protects itself in hardware; this daemon fills the gap between those
two protections:

| Layer | Junction / Mem | What happens |
|---|---|---|
| `gpu-fan-control@shroud` | 90 °C hotspot | forces the shroud fan to 100% (cooling) |
| **GPU throttle** (hardware) | **100 °C / 98 °C** | clocks drop to shed heat — keeps running, just slower. *Normal; this daemon does NOT act on it.* |
| **→ this watchdog** | **102 °C / 101 °C** | gracefully **stops the LLM server** to remove the load |
| **GPU emergency** (hardware) | **105 °C / 103 °C** | amdgpu forces a **MODE1 reset** — crashes/corrupts whatever was running (ungraceful) |

The 102 °C trip is deliberately **above** the 100 °C throttle (a little throttling is
fine) and **below** the 105 °C emergency — the last graceful chance before the reset.

In the normal **split** config both GPUs sit ~59 °C, so this never fires. It only
matters for a sustained **solo full-load** on a single card (which the NF-F12 shroud
cannot hold below the low-90s °C — see [`../fan-control/README.md`](../fan-control/README.md)).

## Behaviour

- Watches `junction` + `mem` on every configured V620 every `POLL_SECS` (default 2 s).
- On a trip: stops `llamacpp` in CT 120 (`pct exec 120 -- systemctl stop llamacpp`),
  logs `CRITICAL`, and keeps the stop asserted while hot (idempotent).
- **Leaves the server stopped** after cooling (default). Reaching the trip means
  cooling could not keep up, so a human should confirm it is safe before restarting.
  Set `AUTO_RESUME=true` to auto-restart once the card drops below `RESUME_C`.
- **Fails safe toward NOT acting on missing data**: stopping the model is disruptive,
  so an unreadable sensor is logged and skipped rather than treated as an over-temp.
  The 105 °C hardware emergency remains the final backstop if a sensor truly dies.
- **Never silently watches fewer cards than configured**: the expected PCI set is
  re-resolved **every poll**, so a card that is missing at startup, binds late, or
  disappears and returns (e.g. an amdgpu reset) is watched the moment it appears. A
  partial set does **not** abort the daemon (that would remove the only graceful
  protection) — it watches what's present and logs a loud `WARN` naming the missing
  address until the full set is back. Only a *totally* absent GPU stack (0 present at
  startup) is fatal.

## Install

```bash
# on the Proxmox host, as root
./install.sh
```

Idempotent. Installs the daemon to `/usr/local/sbin/gpu-thermal-watchdog`, the config
to `/etc/gpu-thermal-watchdog.env` (existing config left untouched), and the unit to
`/etc/systemd/system/gpu-thermal-watchdog.service`; then enables + restarts it.

## Verify / operate

```bash
systemctl status gpu-thermal-watchdog
journalctl -u gpu-thermal-watchdog -f          # watch it live
```

## Tuning (`/etc/gpu-thermal-watchdog.env`)

| Var | Default | Meaning |
|---|---|---|
| `GPU_PCI_ADDRESS` | `0000:2d:00.0,0000:06:00.0` | V620s to watch (comma list; empty = all amdgpu) |
| `TRIP_JUNCTION_C` | `102` | junction trip (°C) |
| `TRIP_MEM_C` | `101` | mem trip (°C) |
| `RESUME_C` | `95` | re-arm / auto-resume below this (°C) |
| `POLL_SECS` | `2` | poll interval |
| `WATCHDOG_ACTION` | `stop` | `stop` the LLM service, or `warn` (log only — for testing) |
| `LLM_CT_VMID` / `LLM_SERVICE` | `120` / `llamacpp` | the LXC + service to stop |
| `PROTECT_CMD` / `RESUME_CMD` | *(empty)* | override the stop/start command (run via `bash -c`) |
| `AUTO_RESUME` | `false` | restart the service once cooled instead of leaving it down |

After editing: `systemctl restart gpu-thermal-watchdog`.

### Testing it without cooking a card

Point the trip below the current temp and log-only, so it exercises the whole detect
→ trip path without stopping anything:

```bash
systemctl set-environment WATCHDOG_ACTION=warn   # (or edit the env file)
# temporarily set TRIP_JUNCTION_C=30 in the env, restart, watch the journal, then revert
```
