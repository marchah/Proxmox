#!/usr/bin/env bash
#
# Install the GPU thermal watchdog on the Proxmox host — last-resort over-temp
# protection for the Radeon Pro V620(s). If either card's junction/mem crosses the
# trip temp (default 102C junction / 101C mem), it gracefully stops the LLM server
# (llama.cpp in CT 120) so the card cools before the 105C hardware emergency reset.
#
# Run on the Proxmox host as root. Idempotent — safe to re-run.
#
# What it does, in order:
#   1. Install the gpu-thermal-watchdog daemon -> /usr/local/sbin.
#   2. Install its env file -> /etc/gpu-thermal-watchdog.env (existing left as-is).
#   3. Install the systemd unit -> /etc/systemd/system.
#   4. Enable, then RESTART the service (so a re-run activates the new version),
#      and verify it is active.
#
# No kernel module or build toolchain is needed (unlike the fan controller): the
# watchdog only READS amdgpu hwmon temps and stops an LXC service via pct.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly SBIN_PATH="/usr/local/sbin/gpu-thermal-watchdog"
readonly UNIT_PATH="/etc/systemd/system/gpu-thermal-watchdog.service"
readonly ENV_PATH="/etc/gpu-thermal-watchdog.env"
readonly UNIT="gpu-thermal-watchdog.service"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (on the Proxmox host)"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

install_service() {
  log "installing daemon -> $SBIN_PATH"
  install -m 0755 "$SCRIPT_DIR/gpu-thermal-watchdog.sh" "$SBIN_PATH"

  if [ -f "$ENV_PATH" ]; then
    warn "$ENV_PATH exists — leaving your settings untouched (delete it to reset to defaults)"
  else
    log "installing config -> $ENV_PATH"
    install -m 0644 "$SCRIPT_DIR/gpu-thermal-watchdog.env" "$ENV_PATH"
  fi

  log "installing unit -> $UNIT_PATH"
  install -m 0644 "$SCRIPT_DIR/gpu-thermal-watchdog.service" "$UNIT_PATH"
  systemctl daemon-reload
}

enable_service() {
  log "enabling + (re)starting: $UNIT"
  systemctl enable "$UNIT" >/dev/null 2>&1 || die "failed to enable $UNIT"
  # restart (not enable --now): on a re-run --now leaves the OLD process running,
  # so an installed fix would not take effect until reboot/manual restart.
  systemctl restart "$UNIT"
  sleep 3
  systemctl is-active --quiet "$UNIT" \
    || die "$UNIT failed to start — see: journalctl -u $UNIT -n 30"
  log "active. Recent log:"
  journalctl -u "$UNIT" -n 6 -o cat || true
}

main() {
  require_root
  require_command pct
  install_service
  enable_service
  log "done. Tune /etc/gpu-thermal-watchdog.env, then: systemctl restart $UNIT"
}

main "$@"
