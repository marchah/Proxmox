# host-net/wifi-nat — Proxmox host WiFi uplink + NAT gateway

Run the Proxmox host with **no ethernet**: the onboard WiFi (`wlo1`, MediaTek
MT7921K) becomes the routed **WAN**, and `vmbr0` becomes an **internal private
LAN** that the LXCs sit behind (NAT + DHCP/DNS + inbound port-forwards).

A WiFi client (STA) can only present one MAC to the AP (802.11), so `wlo1`
**cannot be bridged** into `vmbr0` — the containers are NAT'd behind the host
instead. This is the software / no-extra-hardware path. (A mesh node in AP mode
is the zero-host-change alternative — it keeps the LXCs on the real LAN with no
NAT — if you'd rather not touch the host's networking at all.)

Runs on the **Proxmox host as root**, following the `pro-v620/` service idiom
(idempotent `install.sh` + `.env` + rendered systemd/config).

```
Spectrum WiFi ──STA──▶ wlo1 (WAN: wpa_supplicant@wlo1 + dhclient@wlo1, DHCP)   ← default route
                              │  nftables table ip wifinat: masquerade + DNAT
                              ▼
                       vmbr0 (LAN: static 10.10.10.1/24, bridge-ports none)
                              │  dnsmasq: DHCP 10.10.10.50–.199 + reservations, DNS
                    CT120 .120   CT121 .121   CT200 .200   (stay ip=dhcp; get 10.10.10.x)
```

## Before you start

1. `cp wifi-nat.secrets.env.example wifi-nat.secrets.env` and fill in your
   **SSID + passphrase** (target a 2.4/5 GHz SSID — 6E client mode is fragile).
2. Review `wifi-nat.env` (subnet, DHCP range, reservations, port-forwards).
3. Have **physical console access** available for the cutover — it's the ultimate
   fallback if the WiFi flip goes wrong.
4. Set a **DHCP reservation on your router** for the `wlo1` MAC so the host keeps a
   stable IP — a plain lease can drift on renewal or a router reboot, and with no
   console that means hunting for the box by MAC (`arp -a | grep -i <wlo1-mac>` from
   the LAN). Routers often refuse to move an existing lease, so the simplest path is
   to reserve **whatever IP `wlo1` already has**, then point `ssh pve` / `~/.ssh/config`
   and the `pve` MCP (`PVE_BASE_URL`) at it. (The container `.120/.121` reservations
   are separate — the host's own dnsmasq handles those.)

## Staged rollout (do this while still on ethernet)

```bash
# on the Proxmox host, in this folder:
./install.sh              # STAGE: apt install + render all config + back up interfaces.
                          #        Nothing on the network changes.
./install.sh --test-wifi  # Bring wlo1 up as a SECONDARY uplink and PROVE egress via it.
                          #        GATE: if this fails, stop — nothing destructive has run.
./install.sh --cutover    # Arm auto-rollback, flip vmbr0 -> 10.10.10.1 NAT, start services.
                          #        Your SSH will move to the WiFi IP.
# ...reconnect to the host's WiFi IP...
./install.sh --confirm    # Health-check + cancel the auto-rollback = make it permanent.
for c in 120 121 200; do pct reboot $c; done   # CTs pick up their 10.10.10.x leases.
```

`--cutover` is **transactional**: it first proves WiFi egress with only *transient*
changes (an EXIT trap undoes them on any abort), then arms the rollback timer, and
only *then* makes persistent changes (enable units, `ip_forward`, flip). So if
anything fails before the timer is armed — including a failed WiFi association or a
`systemd-run` failure — it aborts with **nothing persistent changed**. Set
`WIFI_NAT_NO_ROLLBACK=1` only if you're on console and deliberately want no
auto-revert.

`--confirm` runs mandatory health checks — vmbr0 address, default route via `wlo1`,
WiFi egress, nftables table, dnsmasq active, **and `is-enabled` for all four units
(so the setup survives a reboot)** — and **refuses to cancel the rollback if any
fail**, so a broken or non-persistent flip can't be made permanent.

If you do **not** run `--confirm`, the cutover **auto-reverts** after
`ROLLBACK_MINUTES` (default 10): a `systemd-run` timer runs the **same full teardown
as `--revert`** — disables the WiFi/NAT/dnsmasq units, removes the forwarding
drop-in and resets `ip_forward` to its pre-cutover value, restores the backed-up
`/etc/network/interfaces` and every managed file (originals back, our files removed),
and brings a pre-existing dnsmasq back to its prior state (in that order). Keep the
ethernet cable plugged in during the cutover so that rollback route still works.

**Riskiest step:** the `ifreload -a` inside `--cutover` drops the `192.168.1.1`
default route SSH rides on. It's guarded by (1) `wlo1` being kept out of
`/etc/network/interfaces` so `ifreload` can't disturb the WAN, (2) the
`--test-wifi` egress gate, (3) the auto-rollback timer, (4) keeping ethernet
plugged, (5) console access.

## Reverting

```bash
./install.sh --revert
for c in 120 121 200; do pct reboot $c; done
```

Runs the full teardown (the same one the auto-rollback uses): restores the original
ethernet-bridge `/etc/network/interfaces`, disables the WiFi + NAT + dnsmasq
services, removes the `wifinat` nftables table, and restores prior host state from
the snapshot taken at stage time (`/var/lib/wifi-nat/prior/`) — files we overwrote
are put back and only files we created are removed, `ip_forward` returns to its
pre-cutover value, and a pre-existing dnsmasq is restored to its prior state (left
disabled only if we installed it). The teardown **verifies** the restore (interfaces
file matches the backup, `vmbr0` is off the NAT subnet); only on a **confirmed**
teardown does revert then **clear the active transaction state** (snapshot, manifest,
backup pointer) so a future stage/revert starts fresh and can never restore an
obsolete snapshot. If the teardown can't confirm the restore it **keeps** the recovery
state and exits with an error so you can fix and retry. The timestamped
`/root/interfaces.bak.*` archives are always kept. **Config only — no data touched, and
the containers need no per-CT change** (they stay `ip=dhcp` and pull a `192.168.1.x`
LAN lease again).

`./install.sh --status` prints the WiFi link, leases, routes, and nft table at any
time.

## What it installs / changes

| Path | Purpose |
|---|---|
| pkgs `wpasupplicant iw dnsmasq wireless-regdb isc-dhcp-client` | WiFi client, DHCP/DNS, 5 GHz regdb, dhclient |
| `/etc/wpa_supplicant/wpa_supplicant-wlo1.conf` (0600) | WiFi association (`country=US`, hashed PSK) |
| `/etc/systemd/system/dhclient@.service` | DHCP client on the WAN iface (kept out of ifupdown2) |
| `/etc/modprobe.d/cfg80211.conf` | persists the regulatory domain |
| `/etc/dnsmasq.d/wifinat.conf` | LAN DHCP+DNS on `vmbr0` only, with MAC reservations |
| `/etc/nftables.d/wifinat.nft` + `wifinat.service` | `table ip wifinat`: masquerade + port-forwards |
| `/etc/sysctl.d/99-wifinat.conf` | `net.ipv4.ip_forward=1` |
| `/usr/local/sbin/wifi-nat-rollback` | the auto-rollback action |
| `/etc/network/interfaces` (vmbr0 block only) | `10.10.10.1/24`, `bridge-ports none`, no gateway |

The `wifinat` nftables table is self-contained — `proxmox-firewall` only flushes
its own tables, so this coexists. The `forward` chain is `policy accept`; tighten
it (drop + explicit allows) if you want the containers hidden from the rest of the
LAN except the forwarded ports.

## Downstream effects on the rest of the repo

- Containers move to `10.10.10.x`. The provisioning scripts (`ip=dhcp`,
  `bridge=vmbr0`) need **no change**; new CTs auto-join the NAT LAN.
- `bench-runner` auto-discovery of CT120 still resolves internally (CT200 and
  CT120 share `10.10.10.x`); `make bench` over `ssh pve` is unaffected.
- From your Mac / the rest of the LAN, reach the container APIs at the host's WiFi
  IP: `http://<host-ip>:1234/v1/models` (llama.cpp) and `:8642` (Hermes).
- **Hermes (CT121)** stores CT120's endpoint in `/root/.hermes/config.yaml`, so a CT120
  IP change (like this cutover) breaks it with "model provider failed after retries".
  Point `model.base_url` at the stable name `http://llamacpp:1234/v1` (dnsmasq resolves
  it to CT120's reserved IP) and `systemctl restart hermes`. The provisioner now prefers
  that name by default — see [`hermes/`](../../hermes/README.md).
- Add Plex's `10.10.10.x` to `PORT_FORWARDS` (`tcp 32400 …`) once it's deployed.

## Troubleshooting

- **`--test-wifi` won't associate — `journalctl -u wpa_supplicant@wlo1` shows
  `auth_failures` / `CONN_FAILED` even with the correct passphrase:** check the card's
  **antennas are physically connected**. A weak signal (very negative dBm in
  `iw dev wlo1 scan`) drops the WPA handshake and looks exactly like a wrong password.
- **Can't find the host after a cutover:** it's on WiFi at whatever IP the router leased
  `wlo1` (not necessarily what you expected). Locate it by MAC from the LAN:
  `arp -a | grep -i <wlo1-mac>`. If the flip went unhealthy, the auto-rollback restores
  ethernet within `ROLLBACK_MINUTES`; if the box is unreachable and console-less, a
  power-cycle brings it back on the restored config.
- **`ssh pve` fails host-key verification after the IP changes:** the new IP isn't trusted
  yet — `ssh-keygen -R <ip>` then reconnect (accept the key), or `ssh-keyscan <ip> >> ~/.ssh/known_hosts`.
