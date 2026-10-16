#!/usr/bin/env bash
# Install the MiMo-V2.6-Pro-RL serve config into a container. Idempotent: re-run freely.
# Runs on the Proxmox HOST as root, from this directory.
#
#   VMID=123 ./install.sh              # env + launcher + unit; nothing started
#   VMID=123 ./install.sh --download   # also start/resume the download and verification
#
# The unit is installed but not enabled. It conflicts with the container's other model
# units, so starting it stops Flash-Next (or GLM, or Qwen3.6) rather than loading a second
# model beside it. TEST_MODEL=mimo ../glm53-flash/ct123-test-host.sh sets CT 123 up for the test.
set -Eeuo pipefail

VMID="${VMID:-123}"
ENV_FILE="${ENV_FILE:-mimo.env}"
DO_DOWNLOAD=false
[ "${1:-}" = "--download" ] && DO_DOWNLOAD=true

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[ "$(pct status "$VMID" | awk '{print $2}')" = "running" ] || die "CT ${VMID} is not running"
for f in "$ENV_FILE" llamacpp-serve-mimo mimo-download.sh; do
  [ -f "$f" ] || die "missing ${f}; run from this directory"
done

log "pushing /etc/llamacpp-mimo.env (from ${ENV_FILE})"
pct push "$VMID" "$ENV_FILE" /etc/llamacpp-mimo.env --perms 0644

log "pushing /usr/local/bin/llamacpp-serve-mimo"
pct push "$VMID" llamacpp-serve-mimo /usr/local/bin/llamacpp-serve-mimo --perms 0755

log "pushing /usr/local/bin/mimo-download.sh"
pct push "$VMID" mimo-download.sh /usr/local/bin/mimo-download.sh --perms 0755

log "installing the systemd unit"
pct exec "$VMID" -- bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
install -d -o llamacpp -g llamacpp /models/hf/mimo-v2.6-pro-rl

cat >/etc/systemd/system/llamacpp-mimo.service <<'UNIT'
[Unit]
Description=llama.cpp llama-server (MiMo-V2.6-Pro-RL, mimo2)
After=network-online.target
Wants=network-online.target
# One model per card and per port: starting this stops the others, and the reverse.
Conflicts=llamacpp.service llamacpp-qwen38fn.service llamacpp-glm53f.service

[Service]
Type=simple
User=llamacpp
Group=llamacpp
Environment=HOME=/home/llamacpp
ExecStart=/usr/local/bin/llamacpp-serve-mimo
Restart=on-failure
RestartSec=15
# ~554 GB from the NVMe store; a cold load reads all of it before it serves.
TimeoutStartSec=3600
# The CPU-resident experts must stay resident; paging them turns decode into disk reads.
MemorySwapMax=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
echo "unit installed (not enabled)"
CONTAINER_SCRIPT

if [ "$DO_DOWNLOAD" = "true" ]; then
  if pct exec "$VMID" -- systemctl is-active --quiet mimo-dl 2>/dev/null; then
    log "download already running; leaving it alone"
  else
    log "starting/resuming the download and verification (systemd unit mimo-dl)"
    pct exec "$VMID" -- systemd-run --unit=mimo-dl --collect \
      --description="MiMo-V2.6-Pro-RL GGUF download" \
      /usr/local/bin/mimo-download.sh
  fi
fi

echo
log "state"
# shellcheck disable=SC2016  # must expand INSIDE the container, not here
pct exec "$VMID" -- bash -lc '
  echo "  env:    $(test -f /etc/llamacpp-mimo.env && echo ok || echo MISSING)"
  echo "  serve:  $(test -x /usr/local/bin/llamacpp-serve-mimo && echo ok || echo MISSING)"
  echo "  unit:   $(systemctl is-enabled llamacpp-mimo 2>&1 | head -1)"
  d=/models/hf/mimo-v2.6-pro-rl
  echo "  model:  $(ls "$d"/*.verified 2>/dev/null | wc -l)/9 verified (7 shards + 2 MTP heads)"
  echo "  dl:     $(systemctl is-active mimo-dl 2>&1 | head -1)"'
