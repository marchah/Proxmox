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
4. Set a **DHCP reservation on your router** for the `wlo1` MAC
   (`50:c2:e8:95:42:ff`) so the host keeps a stable IP. If the new-site LAN is
   `192.168.1.0/24`, reserve `192.168.1.50` so `ssh pve` and the tooling keep
   working unchanged; otherwise update `~/.ssh/config` after the move.

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
./install.sh --confirm    # Cancel the auto-rollback = make the change permanent.
for c in 120 121 200; do pct reboot $c; done   # CTs pick up their 10.10.10.x leases.
```

If you do **not** run `--confirm`, the cutover **auto-reverts** after
`ROLLBACK_MINUTES` (default 10) via a `systemd-run` timer that restores the
backed-up `/etc/network/interfaces`. Keep the ethernet cable plugged in during the
cutover so that rollback route still works.

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

Restores the original ethernet-bridge `/etc/network/interfaces` from the backup,
stops/disables the WiFi + NAT + dnsmasq services, removes the `wifinat` nftables
table, and turns forwarding back off. **Config only — no data touched, and the
containers need no per-CT change** (they stay `ip=dhcp` and simply pull a
`192.168.1.x` LAN lease again). The interfaces backup in `/root/interfaces.bak.*`
is kept.

`./install.sh --status` prints the WiFi link, leases, routes, and nft table at any
time.

## What it installs / changes

| Path | Purpose |
|---|---|
| pkgs `wpasupplicant iw dnsmasq wireless-regdb` | WiFi client, DHCP/DNS, 5 GHz regdb |
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
- Add Plex's `10.10.10.x` to `PORT_FORWARDS` (`tcp 32400 …`) once it's deployed.
