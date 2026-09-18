#!/usr/bin/env bash
# Install the Qwen3.8-Flash-Next serve config into CT 120. Idempotent — re-run freely.
# Runs on the Proxmox HOST as root, from this directory.
#
#   ./install.sh                # env + serve script + unit, download NOT started
#   ./install.sh --download     # also start/resume the 112 GB GGUF download
#
# Two deployments use this, and they differ only in the env file:
#
#   VMID=120                                  ./install.sh   # two cards, -ncmoe 16 (qwen38fn.env)
#   VMID=123 ENV_FILE=qwen38fn-gpu2.env       ./install.sh   # ONE card, -ncmoe 34
#
# This only installs. It does not attach a GPU, change the container's limits, or stop
# the qwen3.6 server — ./ct120-cutover.sh does all of that, reversibly.
set -Eeuo pipefail

VMID="${VMID:-120}"
# Which config to push. qwen38fn.env is the two-card CT 120 shape; qwen38fn-gpu2.env is the
# single-card CT 123 shape. Separate files rather than flags, because this repo keeps
# GPU/model/engine assumptions narrow and explicit instead of parameterising one launcher.
ENV_FILE="${ENV_FILE:-qwen38fn.env}"
DO_DOWNLOAD=false
[ "${1:-}" = "--download" ] && DO_DOWNLOAD=true

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[ "$(pct status "$VMID" | awk '{print $2}')" = "running" ] || die "CT ${VMID} is not running"
for f in "$ENV_FILE" llamacpp-serve-qwen38fn qwen38fn-download.sh; do
  [ -f "$f" ] || die "missing ${f} — run from this directory"
done

log "pushing /etc/llamacpp-qwen38fn.env (from ${ENV_FILE})"
pct push "$VMID" "$ENV_FILE" /etc/llamacpp-qwen38fn.env --perms 0644

log "pushing /usr/local/bin/llamacpp-serve-qwen38fn"
pct push "$VMID" llamacpp-serve-qwen38fn /usr/local/bin/llamacpp-serve-qwen38fn --perms 0755

log "pushing /usr/local/bin/qwen38fn-download.sh"
pct push "$VMID" qwen38fn-download.sh /usr/local/bin/qwen38fn-download.sh --perms 0755

log "installing the systemd unit"
pct exec "$VMID" -- bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
install -d -o llamacpp -g llamacpp /models/hf/qwen3.8-flash-next

cat >/etc/systemd/system/llamacpp-qwen38fn.service <<'UNIT'
[Unit]
Description=llama.cpp llama-server (Qwen3.8-Flash-Next, qwen4exp) on two Radeon Pro V620
After=network-online.target
Wants=network-online.target
# Never both at once: they would fight over the same port and the same cards.
Conflicts=llamacpp.service

[Service]
Type=simple
User=llamacpp
Group=llamacpp
Environment=HOME=/home/llamacpp
ExecStart=/usr/local/bin/llamacpp-serve-qwen38fn
Restart=on-failure
RestartSec=15
# A 111 GB model plus ~28.7 GB of PLE rows is slow to fault in on a SATA SSD the first
# time. Without this systemd would kill the load as a startup failure.
TimeoutStartSec=1800
# The PLE table and the CPU-side experts must stay resident: paging them back from the
# 860 EVO turns a bandwidth measurement into a disk measurement.
MemorySwapMax=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
echo "unit installed (not enabled — cutover does that)"
CONTAINER_SCRIPT

if [ "$DO_DOWNLOAD" = "true" ]; then
  if pct exec "$VMID" -- systemctl is-active --quiet qwen38fn-dl 2>/dev/null; then
    log "download already running — leaving it alone"
  else
    log "starting/resuming the GGUF download (systemd unit qwen38fn-dl)"
    pct exec "$VMID" -- systemd-run --unit=qwen38fn-dl --collect \
      --description="Qwen3.8-Flash-Next GGUF download" \
      /usr/local/bin/qwen38fn-download.sh
  fi
fi

echo
log "state"
# shellcheck disable=SC2016  # must expand INSIDE the container, not here
pct exec "$VMID" -- bash -lc '
  echo "  env:    $(test -f /etc/llamacpp-qwen38fn.env && echo ok || echo MISSING)"
  echo "  serve:  $(test -x /usr/local/bin/llamacpp-serve-qwen38fn && echo ok || echo MISSING)"
  echo "  unit:   $(systemctl is-enabled llamacpp-qwen38fn 2>&1 | head -1)"
  echo "  shards: $(ls /models/hf/qwen3.8-flash-next/*.verified 2>/dev/null | wc -l)/5 verified"
  echo "  dl:     $(systemctl is-active qwen38fn-dl 2>&1 | head -1)"'
echo
echo "Next: ./ct120-cutover.sh to-qwen38fn   (once all 5 files are verified)"
