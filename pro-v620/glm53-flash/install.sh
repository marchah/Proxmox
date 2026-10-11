#!/usr/bin/env bash
# Install the GLM-5.3-Flash serve config into a container. Idempotent: re-run freely.
# Runs on the Proxmox HOST as root, from this directory.
#
#   VMID=123 ./install.sh              # env + launcher + reload helper + unit; nothing started
#   VMID=123 ./install.sh --download   # also start/resume the download and verification
#
# The unit is installed but not enabled. It conflicts with the container's other model
# units, so starting it stops Flash-Next (or Qwen3.6) on the same card rather than
# loading a second model beside it. ./ct123-test-host.sh sets CT 123 up for the test.
set -Eeuo pipefail

VMID="${VMID:-123}"
ENV_FILE="${ENV_FILE:-glm53f.env}"
DO_DOWNLOAD=false
[ "${1:-}" = "--download" ] && DO_DOWNLOAD=true

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[ "$(pct status "$VMID" | awk '{print $2}')" = "running" ] || die "CT ${VMID} is not running"
for f in "$ENV_FILE" llamacpp-serve-glm53f llamacpp-glm53f-reload glm53f-download.sh; do
  [ -f "$f" ] || die "missing ${f}; run from this directory"
done

log "pushing /etc/llamacpp-glm53f.env (from ${ENV_FILE})"
pct push "$VMID" "$ENV_FILE" /etc/llamacpp-glm53f.env --perms 0644

log "pushing /usr/local/bin/llamacpp-serve-glm53f"
pct push "$VMID" llamacpp-serve-glm53f /usr/local/bin/llamacpp-serve-glm53f --perms 0755

log "pushing /usr/local/bin/llamacpp-glm53f-reload"
pct push "$VMID" llamacpp-glm53f-reload /usr/local/bin/llamacpp-glm53f-reload --perms 0755

log "pushing /usr/local/bin/glm53f-download.sh"
pct push "$VMID" glm53f-download.sh /usr/local/bin/glm53f-download.sh --perms 0755

log "installing the systemd unit"
pct exec "$VMID" -- bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
install -d -o llamacpp -g llamacpp /models/hf/glm-5.3-flash

cat >/etc/systemd/system/llamacpp-glm53f.service <<'UNIT'
[Unit]
Description=llama.cpp llama-server (GLM-5.3-Flash, glm5-next)
After=network-online.target
Wants=network-online.target
# One model per card and per port: starting this stops the others, and the reverse.
Conflicts=llamacpp.service llamacpp-qwen38fn.service

[Service]
Type=simple
User=llamacpp
Group=llamacpp
Environment=HOME=/home/llamacpp
ExecStart=/usr/local/bin/llamacpp-serve-glm53f
Restart=on-failure
RestartSec=15
# ~200 GB from the NVMe store; a cold dio load pins ~190 GB before it serves.
TimeoutStartSec=1800
# The CPU-resident experts must stay resident; paging them turns decode into disk reads.
MemorySwapMax=0

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
echo "unit installed (not enabled)"
CONTAINER_SCRIPT

if [ "$DO_DOWNLOAD" = "true" ]; then
  if pct exec "$VMID" -- systemctl is-active --quiet glm53f-dl 2>/dev/null; then
    log "download already running; leaving it alone"
  else
    log "starting/resuming the download and verification (systemd unit glm53f-dl)"
    pct exec "$VMID" -- systemd-run --unit=glm53f-dl --collect \
      --description="GLM-5.3-Flash GGUF download" \
      /usr/local/bin/glm53f-download.sh
  fi
fi

echo
log "state"
# shellcheck disable=SC2016  # must expand INSIDE the container, not here
pct exec "$VMID" -- bash -lc '
  echo "  env:    $(test -f /etc/llamacpp-glm53f.env && echo ok || echo MISSING)"
  echo "  serve:  $(test -x /usr/local/bin/llamacpp-serve-glm53f && echo ok || echo MISSING)"
  echo "  reload: $(test -x /usr/local/bin/llamacpp-glm53f-reload && echo ok || echo MISSING)"
  echo "  unit:   $(systemctl is-enabled llamacpp-glm53f 2>&1 | head -1)"
  d=/models/hf/glm-5.3-flash
  echo "  model:  $(ls "$d"/GLM-5.3-Flash-*.verified "$d"/mmproj-*.verified 2>/dev/null | wc -l)/7 verified (6 shards + projector)"
  echo "  dl:     $(systemctl is-active glm53f-dl 2>&1 | head -1)"'
