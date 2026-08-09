#!/usr/bin/env bash
# Deploy the token-usage collector into the Hermes Agent LXC (CT 121).
#
# Run INSIDE CT 121 as root. Idempotent — safe to re-run; re-running redeploys the
# current repo version of the scripts and units but KEEPS an existing
# /etc/token-usage.env and never touches the accumulated ledger.
#
# What it does, in order:
#   1. token-usage-collect / token-usage-report -> /usr/local/bin   (0755)
#   2. token-usage.env                          -> /etc             (0644, kept if present)
#   3. service + timer                          -> /etc/systemd/system (enable --now)
#   4. one immediate collection so the baseline exists straight away
#
# The first run only records a baseline — llama.cpp's counters are cumulative
# since ITS process start, and tokens produced before the collector existed are
# not attributed to any day. Real numbers begin accruing from the second tick.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BIN_DIR=/usr/local/bin
readonly UNIT_DIR=/etc/systemd/system
readonly ENV_FILE=/etc/token-usage.env
readonly UNIT=token-usage-collect

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_root()    { [ "$(id -u)" -eq 0 ] || die "run as root inside CT 121"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

install_scripts() {
  log "collector + report -> $BIN_DIR"
  install -d "$BIN_DIR"
  install -m 0755 "$SCRIPT_DIR/token-usage-collect.py" "$BIN_DIR/token-usage-collect"
  install -m 0755 "$SCRIPT_DIR/token-usage-report.py"  "$BIN_DIR/token-usage-report"
}

install_env() {
  if [ -f "$ENV_FILE" ]; then
    log "keeping existing $ENV_FILE (compare against token-usage.env for new knobs)"
  else
    log "token-usage.env -> $ENV_FILE"
    install -m 0644 "$SCRIPT_DIR/token-usage.env" "$ENV_FILE"
  fi
}

install_ledger_dir() {
  # shellcheck disable=SC1090  # runtime path, not resolvable at lint time
  . "$ENV_FILE"
  local dir="${TOKEN_USAGE_DIR:-/root/.hermes/token-usage}"
  log "ledger directory -> $dir"
  install -d -m 0755 "$dir"
  case "$dir" in
    /root/.hermes/*) ;;
    *) warn "TOKEN_USAGE_DIR is outside /root/.hermes — add it to ReadWritePaths= in $UNIT.service or the unit will fail 226/NAMESPACE" ;;
  esac
}

install_units() {
  log "systemd units -> $UNIT_DIR"
  install -m 0644 "$SCRIPT_DIR/$UNIT.service" "$UNIT_DIR/$UNIT.service"
  install -m 0644 "$SCRIPT_DIR/$UNIT.timer"   "$UNIT_DIR/$UNIT.timer"
  systemctl daemon-reload
  systemctl enable --now "$UNIT.timer"
}

seed_baseline() {
  log "priming the baseline (first run records a cursor, no tokens attributed)"
  # A failure here is not fatal: the model server may simply be down right now,
  # and the timer will establish the baseline on its next tick.
  systemctl start "$UNIT.service" || warn "initial collection failed — the timer will retry"
}

verify() {
  log "verification"
  systemctl --no-pager --lines=0 status "$UNIT.timer" || true
  # shellcheck disable=SC1090  # runtime path, not resolvable at lint time
  . "$ENV_FILE"
  local dir="${TOKEN_USAGE_DIR:-/root/.hermes/token-usage}"
  if [ -f "$dir/state.json" ]; then
    log "ledger present: $dir/state.json"
    token-usage-report --days 1 || true
  else
    warn "no ledger yet at $dir/state.json — check: journalctl -u $UNIT.service -n 20"
  fi
}

main() {
  require_root
  require_command systemctl
  require_command python3
  install_scripts
  install_env
  install_ledger_dir
  install_units
  seed_baseline
  verify
  log "done. next: systemctl list-timers $UNIT.timer"
}

main "$@"
