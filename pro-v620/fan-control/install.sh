#!/usr/bin/env bash
#
# Install GPU-temperature-based fan control for the Radeon Pro V620 blower
# (wired to PUMP_FAN1) on a Proxmox host with an MSI MAG B550 board.
#
# Run on the Proxmox host as root. Idempotent — safe to re-run.
#
# What it does, in order:
#   1. Install kernel headers + DKMS build toolchain (if missing).
#   2. Install the out-of-tree nct6687 hwmon driver via DKMS — the in-tree
#      nct6683 is READ-ONLY on this board, so it cannot set fan PWM. Blacklist
#      nct6683 and load nct6687 at boot.
#   3. Install the gpu-fan-control daemon, its env file, and systemd unit.
#   4. Enable + start the service.
#
# The nct6687 driver is built from an external repository (default
# https://github.com/Fred78290/nct6687d) — the de-facto Linux driver for the
# Nuvoton NCT6687D. Override the source/ref with NCT6687D_REPO / NCT6687D_REF.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Out-of-tree driver source. Pinned to a commit known-good on kernel 7.0.12-1-pve;
# if a future kernel fails to build, retry with NCT6687D_REF=master.
NCT6687D_REPO="${NCT6687D_REPO:-https://github.com/Fred78290/nct6687d}"
NCT6687D_REF="${NCT6687D_REF:-e069fac}"

readonly SBIN_PATH="/usr/local/sbin/gpu-fan-control"
readonly ENV_PATH="/etc/gpu-fan-control.env"
readonly UNIT_PATH="/etc/systemd/system/gpu-fan-control.service"
readonly BLACKLIST_PATH="/etc/modprobe.d/nct6687.conf"
readonly MODLOAD_PATH="/etc/modules-load.d/nct6687.conf"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (on the Proxmox host)"; }

# A writable nct6687 hwmon present means the driver is already in place.
nct6687_writable() {
  local h
  for h in /sys/class/hwmon/hwmon*; do
    [ -r "$h/name" ] || continue
    [ "$(cat "$h/name" 2>/dev/null)" = "nct6687" ] || continue
    [ -w "$h/pwm1_enable" ] && return 0
  done
  return 1
}

ensure_build_deps() {
  local kver headers
  kver="$(uname -r)"
  headers="proxmox-headers-${kver}"
  if dpkg -s dkms git build-essential "$headers" >/dev/null 2>&1; then
    log "build deps already present"
    return
  fi
  log "installing build deps: $headers dkms git build-essential"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$headers" dkms git build-essential \
    || die "failed installing build deps (is '$headers' available for kernel $kver?)"
  [ -d "/usr/src/linux-headers-${kver}" ] || die "kernel headers for $kver still missing after install"
}

ensure_driver() {
  if dkms status 2>/dev/null | grep -q '^nct6687d'; then
    log "nct6687d already registered with DKMS"
  else
    local tmp; tmp="$(mktemp -d)"
    log "cloning $NCT6687D_REPO @ $NCT6687D_REF"
    git clone "$NCT6687D_REPO" "$tmp" >/dev/null 2>&1 || die "git clone failed"
    git -C "$tmp" checkout --quiet "$NCT6687D_REF" || die "checkout $NCT6687D_REF failed"
    log "building + installing nct6687 via DKMS"
    make -C "$tmp" dkms/install || die "DKMS build/install failed"
    rm -rf "$tmp"
  fi

  # Prefer the writable out-of-tree nct6687 over the read-only in-tree nct6683.
  if [ ! -f "$BLACKLIST_PATH" ]; then
    log "blacklisting in-tree nct6683"
    printf '# Use out-of-tree nct6687 (writable PWM) instead of read-only in-tree nct6683\nblacklist nct6683\n' > "$BLACKLIST_PATH"
  fi
  if [ ! -f "$MODLOAD_PATH" ]; then
    log "loading nct6687 at boot"
    printf 'nct6687\n' > "$MODLOAD_PATH"
  fi
  # Swap drivers now (no reboot needed): drop the read-only one, load the writable one.
  modprobe -r nct6683 2>/dev/null || true
  modprobe nct6687 2>/dev/null || true

  nct6687_writable || die "nct6687 present but PWM still not writable — check 'dmesg | grep nct6687' and that the chip is an NCT6687D"
  log "nct6687 writable PWM confirmed"
}

install_service() {
  log "installing daemon -> $SBIN_PATH"
  install -m 0755 "$SCRIPT_DIR/gpu-fan-control.sh" "$SBIN_PATH"

  if [ -f "$ENV_PATH" ]; then
    warn "$ENV_PATH exists — leaving your settings untouched (delete it to reset to defaults)"
  else
    log "installing config -> $ENV_PATH"
    install -m 0644 "$SCRIPT_DIR/gpu-fan-control.env" "$ENV_PATH"
  fi

  log "installing unit -> $UNIT_PATH"
  install -m 0644 "$SCRIPT_DIR/gpu-fan-control.service" "$UNIT_PATH"
  systemctl daemon-reload
}

enable_service() {
  log "enabling + starting gpu-fan-control.service"
  systemctl enable --now gpu-fan-control.service
  sleep 4
  systemctl is-active --quiet gpu-fan-control.service \
    || die "service failed to start — see: journalctl -u gpu-fan-control -n 30"
  log "active. Recent log:"
  journalctl -u gpu-fan-control.service -n 3 -o cat || true
}

main() {
  require_root
  ensure_build_deps
  ensure_driver
  install_service
  enable_service
  log "done. Tune the curve in $ENV_PATH, then: systemctl restart gpu-fan-control"
}

main "$@"
