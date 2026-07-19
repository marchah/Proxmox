#!/usr/bin/env bash
# Deploy the autonomous-coding-loop / orchestrator config into the Hermes Agent LXC (CT 121).
#
# Run INSIDE CT 121 as root (e.g. `git clone` this repo there, or `pct push` this folder, then
# `./install.sh`). Idempotent — safe to re-run; re-running redeploys the current repo version.
#
# What it does, in order:
#   1. loop helper scripts        -> /usr/local/bin        (0755)
#   2. coder/reviewer profiles + custom loop skills + plugins
#                                 -> /root/.hermes/...     (rsync, no --delete: never removes stock bundles)
#   3. loop-watchdog.env          -> /root/.hermes/        (kept if it already exists)
#   4. the 3 loop systemd timers  -> /etc/systemd/system   (daemon-reload + enable --now)
#   5. enable the two loop plugins
# It NEVER writes /root/.hermes/.env (the secrets file) — see hermes.env.example. It does NOT touch the
# shared /root/.hermes/config.yaml or the stock hermes.service/hermes-dashboard.service (see config-snippets.md).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERMES_HOME=/root/.hermes
readonly BIN_DIR=/usr/local/bin
readonly UNIT_DIR=/etc/systemd/system
readonly TIMERS=(loop-watchdog backlog-tick pr-revise-tick)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_root()    { [ "$(id -u)" -eq 0 ] || die "run as root inside CT 121"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

install_scripts() {
  log "loop helper scripts -> $BIN_DIR"
  install -d "$BIN_DIR"
  install -m 0755 "$SCRIPT_DIR"/bin/* "$BIN_DIR"/
}

install_hermes_home() {
  require_command rsync
  # rsync WITHOUT --delete so we add/update our custom files but never remove the stock Hermes skill
  # bundles, per-profile state, or secret .env files that live alongside them.
  for sub in profiles skills plugins; do
    log "$sub -> $HERMES_HOME/$sub"
    install -d "$HERMES_HOME/$sub"
    rsync -a --exclude '.env' "$SCRIPT_DIR/$sub/" "$HERMES_HOME/$sub/"
  done
  if [ -f "$HERMES_HOME/loop-watchdog.env" ]; then
    warn "$HERMES_HOME/loop-watchdog.env exists — leaving your thresholds untouched (delete it to reset)"
  else
    log "loop-watchdog.env -> $HERMES_HOME"
    install -m 0644 "$SCRIPT_DIR/loop-watchdog.env" "$HERMES_HOME/loop-watchdog.env"
  fi
}

install_timers() {
  log "loop systemd timers -> $UNIT_DIR"
  for t in "${TIMERS[@]}"; do
    install -m 0644 "$SCRIPT_DIR/systemd/$t.service" "$UNIT_DIR/$t.service"
    install -m 0644 "$SCRIPT_DIR/systemd/$t.timer"   "$UNIT_DIR/$t.timer"
  done
  systemctl daemon-reload
  for t in "${TIMERS[@]}"; do systemctl enable --now "$t.timer" >/dev/null; done
}

enable_plugins() {
  command -v hermes >/dev/null 2>&1 || { warn "hermes CLI not on PATH — enable plugins by hand"; return; }
  log "enabling plugins (completion-gate, codex-review)"
  hermes plugins enable completion-gate >/dev/null 2>&1 || warn "enable completion-gate failed (may already be enabled)"
  hermes plugins enable codex-review    >/dev/null 2>&1 || warn "enable codex-review failed (may already be enabled)"
}

main() {
  require_root
  require_command install
  install_scripts
  install_hermes_home
  install_timers
  enable_plugins
  log "done."
  cat <<EOF

Next steps (NOT automated — they touch secrets / shared config the gateway owns):
  1. Set env vars: add the loop vars from $SCRIPT_DIR/hermes.env.example to $HERMES_HOME/.env — the
     MEALDEAL_GITHUB_TOKEN + SLACK_CODING/AUTOMATION/PLANNING_CHANNEL. install.sh NEVER writes $HERMES_HOME/.env.
  2. Merge the loop-relevant blocks from $SCRIPT_DIR/config-snippets.md into $HERMES_HOME/config.yaml
     (kanban.max_in_progress, plugins.enabled, model pointers) if not already present.
  3. Restart the gateway so the plugins + config load:  systemctl restart hermes
Timers now active:  systemctl list-timers 'loop-watchdog*' 'backlog-tick*' 'pr-revise-tick*'
EOF
}

main "$@"
