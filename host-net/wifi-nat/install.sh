#!/usr/bin/env bash
#
# Turn the Proxmox host into a WiFi-uplink NAT gateway, so it can run with NO
# ethernet: the onboard WiFi (wlo1, MediaTek MT7921K) becomes the routed WAN and
# vmbr0 becomes an internal private LAN that the LXCs sit behind (NAT + DNS/DHCP
# + inbound port-forwards). Run on the Proxmox host as root. Idempotent.
#
# A WiFi STA can only present one MAC to the AP (802.11), so wlo1 CANNOT be
# bridged into vmbr0 — the containers must be NAT'd behind the host instead.
#
# This is deliberately STAGED because it re-points the interface your SSH rides
# on. Run the steps in order, ideally while still on ethernet and with console
# access available:
#
#   ./install.sh              # STAGE: install pkgs + render all config (no network change)
#   ./install.sh --test-wifi  # bring wlo1 up as a SECONDARY uplink and prove egress
#   ./install.sh --cutover    # arm auto-rollback, flip vmbr0 -> NAT, start services
#   ./install.sh --confirm    # (after re-connecting) cancel the rollback = make it permanent
#   ./install.sh --revert     # restore the original ethernet-bridge config
#   ./install.sh --status     # show link / leases / routes / nft table
#
# The cutover arms a self-rollback (systemd-run timer) that restores the backed-up
# /etc/network/interfaces after ROLLBACK_MINUTES unless you run --confirm — so a
# bad flip un-does itself instead of stranding a headless box. Physical console is
# the ultimate fallback. See README.md.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Rendered system-file locations.
readonly WPA_DIR="/etc/wpa_supplicant"
readonly DHCLIENT_UNIT="/etc/systemd/system/dhclient@.service"
readonly WIFINAT_UNIT="/etc/systemd/system/wifinat.service"
readonly NFT_FILE="/etc/nftables.d/wifinat.nft"
readonly DNSMASQ_CONF="/etc/dnsmasq.d/wifinat.conf"
readonly SYSCTL_FILE="/etc/sysctl.d/99-wifinat.conf"
readonly REGDOM_FILE="/etc/modprobe.d/cfg80211.conf"
readonly ROLLBACK_BIN="/usr/local/sbin/wifi-nat-rollback"
readonly INTERFACES="/etc/network/interfaces"
readonly STATE_DIR="/var/lib/wifi-nat"
readonly BACKUP_PTR="${STATE_DIR}/interfaces-backup-path"
# Prior-state snapshot, so --revert / rollback restore rather than guess.
readonly PRIOR_DIR="${STATE_DIR}/prior"
readonly STASH_DIR="${PRIOR_DIR}/blobs"
readonly MANIFEST="${PRIOR_DIR}/manifest"
readonly SENTINEL="${PRIOR_DIR}/.captured"
readonly PRIOR_IPF="${PRIOR_DIR}/ip_forward"
readonly PRIOR_DNS_PRE="${PRIOR_DIR}/dnsmasq-preinstalled"
readonly PRIOR_DNS_EN="${PRIOR_DIR}/dnsmasq-enabled"
readonly PRIOR_DNS_ACT="${PRIOR_DIR}/dnsmasq-active"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (on the Proxmox host)"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# ---- prior-state capture (so --revert / rollback restore, never guess) -------

# Snapshot the host state we are about to change — ONCE, before the first mutation.
record_prior() {
  install -d -m 0700 "$PRIOR_DIR"
  [ -e "$SENTINEL" ] && { log "prior state already recorded ($PRIOR_DIR)"; return; }
  sysctl -n net.ipv4.ip_forward 2>/dev/null > "$PRIOR_IPF" || echo 0 > "$PRIOR_IPF"
  if dpkg -s dnsmasq >/dev/null 2>&1; then
    printf 'yes\n' > "$PRIOR_DNS_PRE"
    systemctl is-enabled dnsmasq 2>/dev/null > "$PRIOR_DNS_EN" || true
    systemctl is-active  dnsmasq 2>/dev/null > "$PRIOR_DNS_ACT" || true
  else
    printf 'no\n' > "$PRIOR_DNS_PRE"
  fi
  : > "$MANIFEST"
  touch "$SENTINEL"
  log "recorded prior host state -> $PRIOR_DIR"
}

# Record a managed file BEFORE we (over)write it: copy the original if it existed,
# else note we created it — so --revert restores originals and removes only files
# we introduced. Idempotent; no-op until record_prior has run.
stash_file() {
  local f="$1" key
  [ -e "$SENTINEL" ] || return 0
  grep -qxF "existed $f" "$MANIFEST" 2>/dev/null && return 0
  grep -qxF "created $f" "$MANIFEST" 2>/dev/null && return 0
  install -d -m 0700 "$STASH_DIR"
  if [ -e "$f" ]; then
    key="$(printf '%s' "$f" | tr '/' '_')"
    cp -a "$f" "$STASH_DIR/$key"
    printf 'existed %s\n' "$f" >> "$MANIFEST"
  else
    printf 'created %s\n' "$f" >> "$MANIFEST"
  fi
}

# ---- config -----------------------------------------------------------------

# Load the (tracked) tunables and, when requested, the (gitignored) WiFi secrets.
# wifi-nat.env is sourced as BASH (arrays allowed) — it is NOT a systemd
# EnvironmentFile, unlike the pro-v620 .env files.
load_config() {
  local need_secrets="${1:-0}"
  [ -f "$SCRIPT_DIR/wifi-nat.env" ] || die "missing $SCRIPT_DIR/wifi-nat.env"
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/wifi-nat.env"
  : "${WAN_IF:?WAN_IF unset}" "${LAN_IF:?LAN_IF unset}" "${LAN_ADDR:?}" "${LAN_PREFIX:?}" "${LAN_SUBNET:?}"
  : "${DHCP_RANGE_START:?}" "${DHCP_RANGE_END:?}" "${DHCP_LEASE:?}" "${COUNTRY:?}"
  : "${ROLLBACK_MINUTES:?}" "${TEST_PING_IP:?}"
  UPSTREAM_DNS="${UPSTREAM_DNS:-8.8.8.8 1.1.1.1}"
  RESERVATIONS=("${RESERVATIONS[@]:-}")
  PORT_FORWARDS=("${PORT_FORWARDS[@]:-}")
  readonly WPA_CONF="${WPA_DIR}/wpa_supplicant-${WAN_IF}.conf"

  if [ "$need_secrets" = "1" ]; then
    [ -f "$SCRIPT_DIR/wifi-nat.secrets.env" ] \
      || die "missing $SCRIPT_DIR/wifi-nat.secrets.env — copy wifi-nat.secrets.env.example and fill in your SSID/passphrase"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/wifi-nat.secrets.env"
    : "${WIFI_SSID:?WIFI_SSID unset in secrets}" "${WIFI_PSK:?WIFI_PSK unset in secrets}"
  fi
}

require_online() {
  ip route show default | grep -q '^default' \
    || die "no default route — run the STAGE step while the host is still on ethernet (apt needs internet)"
  ping -c1 -W2 "$TEST_PING_IP" >/dev/null 2>&1 \
    || die "cannot reach $TEST_PING_IP — the STAGE step needs a working uplink (run it on ethernet)"
}

# ---- render (idempotent writers) --------------------------------------------

install_packages() {
  # isc-dhcp-client (deprecated but still packaged in Trixie) provides the
  # /usr/sbin/dhclient the rendered dhclient@.service and the test path use.
  local pkgs=(wpasupplicant iw dnsmasq wireless-regdb isc-dhcp-client)
  if dpkg -s "${pkgs[@]}" >/dev/null 2>&1; then
    log "packages already present: ${pkgs[*]}"
  else
    log "installing: ${pkgs[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || die "apt install failed"
  fi
  require_command dhclient
  # We manage dnsmasq's lifecycle (it must not start until vmbr0 is renumbered to
  # $LAN_ADDR, or it fails to bind listen-address). Installing the pkg auto-starts
  # it, so stop+disable now; --cutover starts it after the flip. If dnsmasq was
  # ALREADY in use before this run, record_prior captured its state and --revert
  # restores it — warn so the takeover isn't a surprise.
  if [ "$(cat "$PRIOR_DNS_PRE" 2>/dev/null || echo no)" = "yes" ] && [ "$(cat "$PRIOR_DNS_ACT" 2>/dev/null || true)" = "active" ]; then
    warn "dnsmasq was already running — wifinat will take it over (prior state recorded; --revert restores it)"
  fi
  systemctl disable --now dnsmasq >/dev/null 2>&1 || true
}

render_regdomain() {
  # Host boots at regdom 00 (world) with no regulatory.db → 5 GHz is locked.
  # wireless-regdb (installed above) + country=US in the wpa conf is what actually
  # unlocks US 5 GHz; this modprobe hint is the persistent belt-and-braces.
  local want="options cfg80211 ieee80211_regdom=${COUNTRY}"
  if [ -f "$REGDOM_FILE" ] && grep -qxF "$want" "$REGDOM_FILE"; then
    log "regdomain modprobe option already set ($REGDOM_FILE)"
  else
    stash_file "$REGDOM_FILE"
    log "setting WiFi regulatory domain -> $COUNTRY ($REGDOM_FILE)"
    printf '# Managed by host-net/wifi-nat/install.sh — unlock %s WiFi channels.\n%s\n' "$COUNTRY" "$want" > "$REGDOM_FILE"
  fi
}

render_wpa() {
  install -d -m 0755 "$WPA_DIR"
  stash_file "$WPA_CONF"
  log "rendering $WPA_CONF (0600) for SSID '$WIFI_SSID'"
  # Feed the passphrase on STDIN (not argv) so it never appears in ps/proc; take
  # only the hashed psk (skip wpa_passphrase's plaintext #psk= line) and build the
  # network block ourselves.
  local psk_hash
  psk_hash="$(printf '%s\n' "$WIFI_PSK" | wpa_passphrase "$WIFI_SSID" | awk -F= '/^[[:space:]]*psk=/{print $2; exit}')" || true
  [ -n "$psk_hash" ] || die "wpa_passphrase produced no psk (passphrase must be 8-63 chars; check SSID/passphrase)"
  {
    printf 'ctrl_interface=/run/wpa_supplicant\nctrl_interface_group=0\nupdate_config=1\ncountry=%s\n\n' "$COUNTRY"
    printf 'network={\n\tssid="%s"\n\tpsk=%s\n\tkey_mgmt=WPA-PSK WPA-PSK-SHA256\n\tscan_ssid=1\n}\n' "$WIFI_SSID" "$psk_hash"
  } > "$WPA_CONF"
  chmod 0600 "$WPA_CONF"
}

render_dhclient_unit() {
  stash_file "$DHCLIENT_UNIT"
  log "rendering $DHCLIENT_UNIT"
  cat > "$DHCLIENT_UNIT" <<EOF
[Unit]
Description=DHCPv4 client on %i (WiFi WAN uplink)
Documentation=https://github.com/Marchah/Proxmox/tree/main/host-net/wifi-nat
Wants=wpa_supplicant@%i.service
After=wpa_supplicant@%i.service
BindsTo=sys-subsystem-net-devices-%i.device

[Service]
Type=simple
ExecStartPre=/usr/sbin/iw reg set ${COUNTRY}
ExecStart=/usr/sbin/dhclient -4 -d -v %i
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

render_dnsmasq() {
  stash_file "$DNSMASQ_CONF"
  log "rendering $DNSMASQ_CONF (LAN DHCP+DNS on $LAN_IF)"
  {
    printf '# Managed by host-net/wifi-nat/install.sh. Serves DHCP+DNS to the LXCs on\n'
    printf '# %s only; never answers on the WiFi WAN side.\n' "$LAN_IF"
    printf 'interface=%s\nbind-interfaces\nexcept-interface=%s\nexcept-interface=lo\nlisten-address=%s\n' \
      "$LAN_IF" "$WAN_IF" "$LAN_ADDR"
    printf 'no-resolv\n'
    local up; for up in $UPSTREAM_DNS; do printf 'server=%s\n' "$up"; done
    printf 'domain=lan\nlocal=/lan/\n'
    printf 'dhcp-range=%s,%s,%s\n' "$DHCP_RANGE_START" "$DHCP_RANGE_END" "$DHCP_LEASE"
    printf 'dhcp-option=option:router,%s\n' "$LAN_ADDR"
    printf 'dhcp-option=option:dns-server,%s\n' "$LAN_ADDR"
    local r mac ip name
    for r in "${RESERVATIONS[@]}"; do
      [ -n "$r" ] || continue
      read -r mac ip name <<<"$r"
      printf 'dhcp-host=%s,%s,%s\n' "$mac" "$ip" "$name"
    done
  } > "$DNSMASQ_CONF"
}

render_nftables() {
  install -d -m 0755 "$(dirname "$NFT_FILE")"
  stash_file "$NFT_FILE"; stash_file "$WIFINAT_UNIT"; stash_file "$SYSCTL_FILE"
  log "rendering $NFT_FILE (masquerade + port-forwards)"
  {
    printf '#!/usr/sbin/nft -f\n'
    printf '# Managed by host-net/wifi-nat/install.sh. Self-contained table — the\n'
    printf '# proxmox-firewall only ever flushes its own tables, so this survives.\n'
    printf 'table ip wifinat {\n'
    printf '\tchain prerouting {\n\t\ttype nat hook prerouting priority dstnat; policy accept;\n'
    local pf proto ext dip dport
    for pf in "${PORT_FORWARDS[@]}"; do
      [ -n "$pf" ] || continue
      read -r proto ext dip dport <<<"$pf"
      printf '\t\tiifname "%s" %s dport %s dnat to %s:%s\n' "$WAN_IF" "$proto" "$ext" "$dip" "$dport"
    done
    printf '\t}\n'
    printf '\tchain postrouting {\n\t\ttype nat hook postrouting priority srcnat; policy accept;\n'
    printf '\t\tip saddr %s oifname "%s" masquerade\n\t}\n' "$LAN_SUBNET" "$WAN_IF"
    printf '\tchain forward {\n\t\ttype filter hook forward priority filter; policy accept;\n'
    printf '\t\tct state established,related accept\n'
    printf '\t\tiifname "%s" oifname "%s" accept\n' "$LAN_IF" "$WAN_IF"
    printf '\t\tiifname "%s" oifname "%s" ct state new,established,related accept\n' "$WAN_IF" "$LAN_IF"
    printf '\t}\n}\n'
  } > "$NFT_FILE"

  log "rendering $WIFINAT_UNIT + $SYSCTL_FILE"
  cat > "$WIFINAT_UNIT" <<EOF
[Unit]
Description=WiFi NAT/port-forward (nftables table ip wifinat)
Documentation=https://github.com/Marchah/Proxmox/tree/main/host-net/wifi-nat
After=network-online.target proxmox-firewall.service nftables.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# add-then-delete makes a re-load idempotent (delete errors if absent).
ExecStartPre=-/usr/sbin/nft add table ip wifinat
ExecStartPre=-/usr/sbin/nft delete table ip wifinat
ExecStart=/usr/sbin/nft -f ${NFT_FILE}
ExecStop=-/usr/sbin/nft delete table ip wifinat

[Install]
WantedBy=multi-user.target
EOF
  printf '# Managed by host-net/wifi-nat/install.sh — routing needs forwarding.\nnet.ipv4.ip_forward=1\n' > "$SYSCTL_FILE"
}

# Render the full teardown used by BOTH the auto-rollback timer and `--revert`, so
# there is ONE correct "undo". Self-contained (all paths baked in) so it runs with
# no repo checkout. NOT tracked in the manifest — else it would delete itself.
render_teardown() {
  log "rendering $ROLLBACK_BIN"
  cat > "$ROLLBACK_BIN" <<EOF
#!/usr/bin/env bash
# Restore the pre-cutover network AND make sure the WiFi/NAT stack does not return
# on reboot. Order matters: restore files + interfaces first, then bring a prior
# dnsmasq back (it may bind the ethernet address, which must exist by then).
set -uo pipefail

# 1. Disable (not merely stop) the cutover units so nothing returns on reboot.
systemctl disable --now wifinat dnsmasq dhclient@${WAN_IF} wpa_supplicant@${WAN_IF} 2>/dev/null || true
/usr/sbin/nft delete table ip wifinat 2>/dev/null || true

# 2. Restore the ethernet interfaces config from the backup.
BK="\$(cat ${BACKUP_PTR} 2>/dev/null || true)"
if [ -n "\$BK" ] && [ -f "\$BK" ]; then cp -a "\$BK" ${INTERFACES}; fi

# 3. Restore every managed file: put back originals we overwrote, remove only files
#    we created. This also removes our dnsmasq/nft/unit/sysctl drop-ins.
if [ -f "${MANIFEST}" ]; then
  while read -r st f; do
    [ -n "\$f" ] || continue
    if [ "\$st" = existed ]; then
      key="\$(printf '%s' "\$f" | tr '/' '_')"
      [ -e "${STASH_DIR}/\$key" ] && cp -a "${STASH_DIR}/\$key" "\$f"
    elif [ "\$st" = created ]; then
      rm -f "\$f"
    fi
  done < "${MANIFEST}"
fi
rm -f ${SYSCTL_FILE}   # belt-and-braces if the manifest is missing

# 4. Restore forwarding to its pre-cutover value.
pf="\$(cat ${PRIOR_IPF} 2>/dev/null || echo 0)"
sysctl -w net.ipv4.ip_forward="\$pf" >/dev/null 2>&1 || true

# 5. Reload units + interfaces BEFORE restoring dnsmasq.
systemctl daemon-reload 2>/dev/null || true
ifreload -a || true

# 6. Restore a PRE-EXISTING dnsmasq to its prior state (files were put back in #3).
if [ "\$(cat ${PRIOR_DNS_PRE} 2>/dev/null || echo no)" = yes ]; then
  if [ "\$(cat ${PRIOR_DNS_EN} 2>/dev/null || true)" = enabled ]; then systemctl enable dnsmasq >/dev/null 2>&1 || true; fi
  if [ "\$(cat ${PRIOR_DNS_ACT} 2>/dev/null || true)" = active ]; then systemctl start dnsmasq >/dev/null 2>&1 || true; fi
fi

logger -t wifi-nat "teardown executed (restored \${BK:-<none>}, ip_forward=\$pf)"
EOF
  chmod 0755 "$ROLLBACK_BIN"
}

backup_interfaces() {
  install -d -m 0755 "$STATE_DIR"
  if [ -f "$BACKUP_PTR" ] && [ -f "$(cat "$BACKUP_PTR")" ]; then
    log "interfaces backup already recorded: $(cat "$BACKUP_PTR")"
    return
  fi
  local ts bk; ts="$(date +%Y%m%d-%H%M%S)"; bk="/root/interfaces.bak.${ts}"
  cp -a "$INTERFACES" "$bk"
  printf '%s\n' "$bk" > "$BACKUP_PTR"
  log "backed up $INTERFACES -> $bk"
}

# Surgically replace only the vmbr0 stanza; leave everything else untouched.
rewrite_vmbr0() {
  local tmpblk tmpout
  tmpblk="$(mktemp)"; tmpout="$(mktemp)"
  cat > "$tmpblk" <<EOF
auto ${LAN_IF}
iface ${LAN_IF} inet static
	address ${LAN_ADDR}/${LAN_PREFIX}
	bridge-ports none
	bridge-stp off
	bridge-fd 0
EOF
  awk -v blockfile="$tmpblk" -v ifn="$LAN_IF" '
    $0 ~ "^auto " ifn "[ \t]*$" { next }
    $0 ~ "^iface " ifn "[ \t]" { while ((getline l < blockfile) > 0) print l; close(blockfile); inblk=1; next }
    inblk==1 { if ($0 ~ /^[ \t]/) next; inblk=0 }
    { print }
  ' "$INTERFACES" > "$tmpout"
  grep -q "address ${LAN_ADDR}/${LAN_PREFIX}" "$tmpout" || { rm -f "$tmpblk" "$tmpout"; die "vmbr0 rewrite produced no $LAN_ADDR — aborting flip"; }
  grep -q "gateway " "$tmpout" && { rm -f "$tmpblk" "$tmpout"; die "rewritten interfaces still has a gateway line — aborting flip"; }
  install -m 0644 "$tmpout" "$INTERFACES"
  rm -f "$tmpblk" "$tmpout"
  log "rewrote $LAN_IF stanza -> ${LAN_ADDR}/${LAN_PREFIX}, bridge-ports none, no gateway"
}

# ---- WAN bring-up helpers ---------------------------------------------------

wan_associate() {  # start wpa + wait for association
  require_command wpa_supplicant
  rfkill unblock wifi 2>/dev/null || true
  ip link set "$WAN_IF" up 2>/dev/null || true
  iw reg set "$COUNTRY" 2>/dev/null || true
  systemctl start "wpa_supplicant@${WAN_IF}.service" || die "wpa_supplicant@${WAN_IF} failed to start"
  local _
  for _ in $(seq 1 20); do
    iw dev "$WAN_IF" link 2>/dev/null | grep -q 'Connected to' && { log "associated: $(iw dev "$WAN_IF" link | awk '/SSID/{print $2}')"; return 0; }
    sleep 1
  done
  die "wlo1 did not associate to '$WIFI_SSID' in 20s — check SSID/passphrase and signal (journalctl -u wpa_supplicant@${WAN_IF})"
}

wan_egress_ok() {  # prove traffic actually leaves via $WAN_IF (SO_BINDTODEVICE)
  ping -I "$WAN_IF" -c3 -W2 "$TEST_PING_IP" >/dev/null 2>&1
}

# EXIT-trap handler for the pre-commit window: undo the TRANSIENT gate state (a
# started wpa + a test lease) and cancel any partially-armed rollback timer. Nothing
# persistent is created before the rollback is armed, so this fully restores the box.
cutover_cleanup() {
  systemctl stop net-rollback.timer 2>/dev/null || true
  systemctl reset-failed net-rollback.timer net-rollback.service 2>/dev/null || true
  dhclient -r "$WAN_IF" >/dev/null 2>&1 || true
  systemctl stop "wpa_supplicant@${WAN_IF}.service" 2>/dev/null || true
}

# Every check must hold for a healthy cutover. Prints each failure; returns nonzero
# if ANY fail. This is the gate --confirm must pass before it cancels the rollback.
verify_health() {
  local bad=0 u
  # Runtime state.
  ip -4 addr show "$LAN_IF" 2>/dev/null | grep -q "inet ${LAN_ADDR}/" || { warn "health: $LAN_IF is not ${LAN_ADDR}"; bad=1; }
  ip route show default 2>/dev/null | grep -q "dev ${WAN_IF}" || { warn "health: default route not via $WAN_IF"; bad=1; }
  wan_egress_ok || { warn "health: no egress via $WAN_IF (ping $TEST_PING_IP)"; bad=1; }
  nft list table ip wifinat >/dev/null 2>&1 || { warn "health: nft table ip wifinat missing"; bad=1; }
  systemctl is-active --quiet dnsmasq || { warn "health: dnsmasq not active"; bad=1; }
  # Reboot-persistence: all four units must be ENABLED, or connectivity is lost on
  # the next reboot even though it looks fine right now.
  for u in "wpa_supplicant@${WAN_IF}" "dhclient@${WAN_IF}" wifinat dnsmasq; do
    systemctl is-enabled --quiet "$u" || { warn "health: $u not enabled (won't survive reboot)"; bad=1; }
  done
  return "$bad"
}

# ---- commands ---------------------------------------------------------------

cmd_stage() {
  require_root
  load_config 1
  require_online
  require_command wpa_passphrase
  record_prior
  install_packages
  render_regdomain
  render_wpa
  render_dhclient_unit
  render_dnsmasq
  render_nftables
  render_teardown
  backup_interfaces
  systemctl daemon-reload
  log "STAGE complete — routing unchanged (dnsmasq stopped; prior state saved for --revert)."
  log "Next: ./install.sh --test-wifi   (verify WiFi works before the cutover)"
}

cmd_test_wifi() {
  require_root
  load_config
  [ -f "$WPA_CONF" ] || die "$WPA_CONF missing — run ./install.sh (stage) first"
  require_command dhclient
  log "bringing $WAN_IF up as a SECONDARY uplink (ethernet stays primary)"
  wan_associate
  # One-shot lease at a HIGH metric so it can't steal the ethernet default route
  # while we test; egress is forced onto $WAN_IF via ping -I regardless.
  dhclient -1 -e IF_METRIC=1000 "$WAN_IF" >/dev/null 2>&1 || warn "dhclient returned non-zero (may still have a lease)"
  ip -4 addr show "$WAN_IF" | grep -q 'inet ' || die "$WAN_IF got no IPv4 lease — is the SSID a 2.4/5 GHz network the card can join?"
  log "$WAN_IF lease: $(ip -4 -br addr show "$WAN_IF" | awk '{print $3}')"
  if wan_egress_ok; then
    log "EGRESS OK via $WAN_IF (ping $TEST_PING_IP). WiFi path is good."
  else
    dhclient -r "$WAN_IF" >/dev/null 2>&1 || true
    systemctl stop "wpa_supplicant@${WAN_IF}.service" 2>/dev/null || true
    die "no egress via $WAN_IF — DO NOT cut over. Check AP/band/regdomain (see README)."
  fi
  # Leave the box exactly as before the test: release the test lease + drop assoc.
  dhclient -r "$WAN_IF" >/dev/null 2>&1 || true
  systemctl stop "wpa_supplicant@${WAN_IF}.service" 2>/dev/null || true
  log "test lease released, $WAN_IF idle again. Ready for: ./install.sh --cutover"
}

cmd_cutover() {
  require_root
  load_config
  [ -f "$WPA_CONF" ] || die "$WPA_CONF missing — run ./install.sh (stage) first"
  [ -f "$BACKUP_PTR" ] || die "no interfaces backup recorded — run ./install.sh (stage) first"
  grep -q "address ${LAN_ADDR}/${LAN_PREFIX}" "$INTERFACES" && die "already cut over ($LAN_IF is $LAN_ADDR). Use --revert to undo."
  require_command dhclient

  # --- GATE: prove WiFi egress with only TRANSIENT changes. An EXIT trap undoes
  # that transient state on ANY abort before we arm the rollback, so every failure
  # path here is genuinely "nothing persistent changed" (incl. wan_associate's die). ---
  trap 'cutover_cleanup' EXIT
  log "verifying the WiFi path before committing (transient; ethernet stays primary)"
  wan_associate
  # High-metric one-shot lease so it can't steal the ethernet default; egress is
  # forced onto $WAN_IF via ping -I regardless.
  dhclient -1 -e IF_METRIC=1000 "$WAN_IF" >/dev/null 2>&1 || warn "dhclient returned non-zero (may still have a lease)"
  ip -4 addr show "$WAN_IF" | grep -q 'inet ' || die "$WAN_IF got no lease — ABORTED (nothing changed)"
  wan_egress_ok || die "no egress via $WAN_IF — ABORTED (nothing changed). Check AP/band/regdomain."
  dhclient -r "$WAN_IF" >/dev/null 2>&1 || true   # drop the test lease before committing
  log "WiFi egress OK — committing."

  # --- ARM the auto-rollback BEFORE any persistent change. If it can't be armed the
  # EXIT trap undoes the transient gate state, so "nothing changed" stays true. ---
  systemctl stop net-rollback.timer 2>/dev/null || true
  systemctl reset-failed net-rollback.timer net-rollback.service 2>/dev/null || true
  if [ "${WIFI_NAT_NO_ROLLBACK:-0}" = "1" ]; then
    warn "WIFI_NAT_NO_ROLLBACK=1 — proceeding with NO auto-rollback (be sure you have console access)"
  else
    log "arming self-rollback: restores the old config in ${ROLLBACK_MINUTES} min unless you run --confirm"
    systemd-run --on-active="${ROLLBACK_MINUTES}min" --unit=net-rollback "$ROLLBACK_BIN" \
      || die "failed to arm the rollback timer — ABORTED (nothing changed). Fix systemd-run, or set WIFI_NAT_NO_ROLLBACK=1."
    systemctl is-active --quiet net-rollback.timer \
      || die "rollback timer did not come up — ABORTED (nothing changed)."
    log "rollback armed (net-rollback.timer active)."
  fi
  trap - EXIT   # committed from here — the armed rollback (or --revert) is the safety net

  # --- COMMIT: enable persistently, forward, flip, start services. Past this point
  # the armed rollback (or --revert) is the safety net; we warn rather than die. ---
  warn "FLIPPING NOW. If your SSH drops, reconnect to the host's WiFi IP and run:  ./install.sh --confirm"
  warn "(keep the ethernet cable plugged in until you've confirmed, so the rollback route still works)"
  systemctl enable --now "wpa_supplicant@${WAN_IF}.service" >/dev/null 2>&1 || warn "could not enable wpa_supplicant@${WAN_IF} (won't survive reboot)"
  systemctl enable "dhclient@${WAN_IF}.service" >/dev/null 2>&1 || warn "could not enable dhclient@${WAN_IF} (won't survive reboot)"
  systemctl restart "dhclient@${WAN_IF}.service" || warn "dhclient@${WAN_IF} restart failed"
  local _; for _ in $(seq 1 15); do ip -4 addr show "$WAN_IF" | grep -q 'inet ' && break; sleep 1; done
  sysctl --system >/dev/null 2>&1 || true
  rewrite_vmbr0
  ifreload -a || warn "ifreload returned non-zero — check 'ip a' / console"
  systemctl enable --now wifinat dnsmasq >/dev/null 2>&1 || warn "wifinat/dnsmasq did not enable/start cleanly — check status"

  log "post-flip health check:"
  ip route show default || true
  if verify_health; then
    log "HEALTHY. Reconnect if needed, then LOCK IT IN:  ./install.sh --confirm"
  else
    warn "UNHEALTHY — do NOT --confirm (it will refuse). Fix the above, or let the rollback auto-revert in ${ROLLBACK_MINUTES} min."
  fi
  warn "Reboot the CTs to pick up their 10.10.10.x leases:  for c in 120 121 200; do pct reboot \$c; done"
}

cmd_confirm() {
  require_root
  load_config
  # Refuse to cancel the safety net unless the cutover is actually healthy — this is
  # what prevents a broken network from being made permanent.
  verify_health || die "health checks FAILED — refusing to cancel the rollback. Fix the issues above, or let the timer auto-revert, then re-run --confirm once healthy."
  systemctl stop net-rollback.timer 2>/dev/null || true
  systemctl reset-failed net-rollback.timer net-rollback.service 2>/dev/null || true
  log "healthy + confirmed — rollback cancelled, WiFi NAT is now permanent."
  log "Set a DHCP reservation on your router for the ${WAN_IF} MAC so 'ssh pve' keeps a stable IP."
}

cmd_revert() {
  require_root
  load_config
  log "reverting to the ethernet-bridge config"
  systemctl stop net-rollback.timer 2>/dev/null || true
  systemctl reset-failed net-rollback.timer net-rollback.service 2>/dev/null || true
  [ -f "$BACKUP_PTR" ] || warn "no interfaces backup recorded — manual restore may be needed (vmbr0: bridge-ports nic0, static 192.168.1.50/24, gateway 192.168.1.1)"

  # Run the SAME comprehensive teardown the auto-rollback uses (disable units,
  # restore interfaces + managed files, restore forwarding, daemon-reload, ifreload,
  # then restore a pre-existing dnsmasq — in that order).
  if [ -x "$ROLLBACK_BIN" ]; then
    "$ROLLBACK_BIN"
  else
    warn "$ROLLBACK_BIN missing — inline fallback"
    systemctl disable --now wifinat dnsmasq "dhclient@${WAN_IF}.service" "wpa_supplicant@${WAN_IF}.service" >/dev/null 2>&1 || true
    nft delete table ip wifinat 2>/dev/null || true
    if [ -f "$BACKUP_PTR" ] && [ -f "$(cat "$BACKUP_PTR")" ]; then cp -a "$(cat "$BACKUP_PTR")" "$INTERFACES"; fi
    systemctl daemon-reload; ifreload -a || warn "ifreload returned non-zero — check console"
  fi
  rm -f "$ROLLBACK_BIN"   # our launcher (kept out of the manifest to avoid self-deletion)

  # Clear the ACTIVE transaction state so a later stage/revert starts fresh and can
  # never restore this now-obsolete snapshot. Timestamped /root backups are kept.
  rm -f "$SENTINEL" "$MANIFEST" "$BACKUP_PTR" "$PRIOR_IPF" "$PRIOR_DNS_PRE" "$PRIOR_DNS_EN" "$PRIOR_DNS_ACT"
  rm -rf "$STASH_DIR"

  log "reverted and cleared transaction state (archived /root/interfaces.bak.* kept)."
  log "Reboot the CTs to re-pull LAN DHCP:  for c in 120 121 200; do pct reboot \$c; done"
}

cmd_status() {
  load_config
  echo "== $WAN_IF (WAN) =="; iw dev "$WAN_IF" link 2>/dev/null || true; ip -4 -br addr show "$WAN_IF" 2>/dev/null || true
  echo "== routes =="; ip route 2>/dev/null || true
  echo "== $LAN_IF (LAN) =="; ip -4 -br addr show "$LAN_IF" 2>/dev/null || true
  echo "== nft table ip wifinat =="; nft list table ip wifinat 2>/dev/null || echo "(not loaded)"
  echo "== dnsmasq leases =="; cat /var/lib/misc/dnsmasq.leases 2>/dev/null || echo "(none)"
  echo "== units =="; systemctl is-active "wpa_supplicant@${WAN_IF}" "dhclient@${WAN_IF}" dnsmasq wifinat net-rollback.timer 2>/dev/null || true
}

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  case "${1:-stage}" in
    stage|"")     cmd_stage ;;
    --test-wifi)  cmd_test_wifi ;;
    --cutover)    cmd_cutover ;;
    --confirm)    cmd_confirm ;;
    --revert)     cmd_revert ;;
    --status)     cmd_status ;;
    -h|--help)    usage ;;
    *)            die "unknown argument: $1 (try --help)" ;;
  esac
}

main "$@"
