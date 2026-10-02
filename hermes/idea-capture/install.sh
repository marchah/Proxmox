#!/usr/bin/env bash
# Deploy the idea-capture plugin into the Hermes Agent LXC (CT 121).
#
# Run INSIDE CT 121 as root. Idempotent — safe to re-run; re-running redeploys the current repo
# version of the plugin. It never writes /root/.hermes/.env: add the variables from
# idea-capture.env.example by hand.
#
# What it does, in order:
#   1. plugin/__init__.py + plugin.yaml -> /root/.hermes/plugins/idea-capture   (0644)
#   2. check that .env defines what the plugin reads (names only, values are never printed)
#   3. hermes plugins enable idea-capture
# It does NOT restart the gateway, which would interrupt in-flight agent turns. Restart it when
# idle: systemctl restart hermes
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERMES_HOME=/root/.hermes
readonly PLUGIN_DIR="$HERMES_HOME/plugins/idea-capture"
readonly REQUIRED_ENV=(PROJECT_PLANNER_URL PROJECT_PLANNER_SLACK_CHANNEL SLACK_ALLOWED_USERS SLACK_BOT_TOKEN)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_root()    { [ "$(id -u)" -eq 0 ] || die "run as root inside CT 121"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (run under bash -lc)"; }

install_plugin() {
  log "plugin -> $PLUGIN_DIR"
  install -d "$PLUGIN_DIR"
  install -m 0644 "$SCRIPT_DIR/plugin/__init__.py" "$SCRIPT_DIR/plugin/plugin.yaml" "$PLUGIN_DIR/"
}

check_env() {
  local missing=() name
  for name in "${REQUIRED_ENV[@]}"; do
    grep -qE "^(export )?${name}=.+" "$HERMES_HOME/.env" 2>/dev/null || missing+=("$name")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "missing from $HERMES_HOME/.env: ${missing[*]} — the plugin stays inert until they are set"
  else
    log ".env defines ${REQUIRED_ENV[*]}"
  fi
}

enable_plugin() {
  log "enabling idea-capture"
  hermes plugins enable idea-capture >/dev/null 2>&1 || warn "enable failed (may already be enabled)"
}

main() {
  require_root
  require_command install
  require_command hermes
  install_plugin
  check_env
  enable_plugin
  log "done. Restart the gateway when idle to load it: systemctl restart hermes"
}

main "$@"
