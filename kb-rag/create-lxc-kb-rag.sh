#!/usr/bin/env bash

set -Eeuo pipefail

# Create an unprivileged Debian LXC that indexes the CognitiveStack Markdown knowledge base
# and serves hybrid (keyword + semantic) search to every agent on the server over one
# endpoint — REST and MCP-over-HTTP. See kb-rag/SPEC.md for the full design.
#
# Markdown-in-git stays the single source of truth; this container holds only a derived,
# rebuildable index (sqlite-vec + FTS5), so the rootfs uses backup=0 and a wipe + reindex
# reconstructs everything. Embeddings run on CPU (fastembed/ONNX) — no GPU, no load on CT 120.
#
# It syncs the KB with a read-only deploy key and reindexes on a 10-minute timer.
#
# Run this script on the Proxmox host as root.

VMID="${VMID:-140}"
LXC_HOSTNAME="${LXC_HOSTNAME:-kb-rag}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
# venv + ONNX model cache (~130 MB) + git checkout + sqlite index. All rebuildable.
ROOT_SIZE_GB="${ROOT_SIZE_GB:-12}"
MEMORY_MB="${MEMORY_MB:-4096}"
SWAP_MB="${SWAP_MB:-1024}"
CORES="${CORES:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
PASSWORD="${PASSWORD:-}"
START_ON_BOOT="${START_ON_BOOT:-1}"

# --- Knowledge-base source (git; read-only) ---
KB_REPO_URL="${KB_REPO_URL:-git@github.com:marchah/CognitiveStack.git}"
KB_BRANCH="${KB_BRANCH:-main}"
# Path to a read-only GitHub DEPLOY KEY (private key) for the KB repo, on the Proxmox host.
# Create one: `ssh-keygen -t ed25519 -f ./cognitivestack-deploy -N ''` then add the .pub as a
# read-only deploy key on the CognitiveStack repo (Settings -> Deploy keys). REQUIRED.
DEPLOY_KEY_FILE="${DEPLOY_KEY_FILE:-}"

# --- Embedding model (CPU, fastembed/ONNX) ---
# Changing EMBED_MODEL or EMBED_DIM later requires `kb-reindex --full` (vector dim must match).
EMBED_MODEL="${EMBED_MODEL:-BAAI/bge-small-en-v1.5}"
EMBED_DIM="${EMBED_DIM:-384}"

# --- API server ---
# The search API is read-only knowledge, but still gated: a bearer key is required on every
# endpoint except /health. Empty -> auto-generate and print it once.
API_KEY="${API_KEY:-}"
API_PORT="${API_PORT:-8770}"

# --- Reindex cadence ---
REINDEX_INTERVAL="${REINDEX_INTERVAL:-10min}"

# --- Pinned Python deps (validated together; bump deliberately) ---
KB_PIP_PACKAGES="${KB_PIP_PACKAGES:-fastembed==0.8.0 sqlite-vec==0.1.9 pathspec==1.1.1 PyYAML==6.0.3 fastapi==0.139.0 uvicorn[standard]==0.49.0 mcp==1.28.1 pydantic==2.13.4}"

# --- Standalone (wget | bash) install: where to fetch app/ from when there is no checkout ---
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/marchah/Proxmox/main/kb-rag}"

# ⚠️ Dual-mode install: app files are shipped from a local checkout (tar+push) OR, standalone,
# downloaded one-by-one from REPO_RAW_BASE using THIS list. When you add/rename a file under
# kb-rag/app/, add it here too or the standalone path ships an incomplete service.
APP_FILES=(chunker.py config.py embedder.py store.py reindex.py server.py index.config.yaml)

usage() {
  cat <<'USAGE'
Create an unprivileged Debian LXC that indexes CognitiveStack and serves hybrid search
(REST + MCP-over-HTTP) to all agents. Markdown-in-git stays the source of truth.

Run this script on the Proxmox host as root. A read-only deploy key is REQUIRED.

Useful overrides:
  DEPLOY_KEY_FILE=./cognitivestack-deploy ./create-lxc-kb-rag.sh   # REQUIRED
  VMID=140 LXC_HOSTNAME=kb-rag ./create-lxc-kb-rag.sh
  KB_REPO_URL=git@github.com:you/KB.git KB_BRANCH=main ./create-lxc-kb-rag.sh
  EMBED_MODEL=BAAI/bge-m3 EMBED_DIM=1024 MEMORY_MB=8192 ./create-lxc-kb-rag.sh
  API_KEY=my-secret ./create-lxc-kb-rag.sh        # else auto-generated and printed
  API_PORT=8770 REINDEX_INTERVAL=10min ./create-lxc-kb-rag.sh

After it is up:
  pct exec 140 -- kb-reindex          # pull + reindex now
  pct exec 140 -- kb-reindex --full   # rebuild from scratch (after a model change)
  pct exec 140 -- kb-stats            # index commit, model, chunk count
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "run this script as root on the Proxmox host"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_deploy_key() {
  [[ -n ${DEPLOY_KEY_FILE} ]] || die "DEPLOY_KEY_FILE is required (a read-only deploy key for ${KB_REPO_URL})"
  [[ -r ${DEPLOY_KEY_FILE} ]] || die "cannot read DEPLOY_KEY_FILE: ${DEPLOY_KEY_FILE}"
}

resolve_template() {
  if [[ -n ${TEMPLATE} ]]; then
    return
  fi

  log "Resolving latest Debian 12 LXC template"
  TEMPLATE="$(
    pveam available --section system \
      | awk '/debian-12-standard_[^[:space:]]+_amd64\.tar\.zst/ {print $2}' \
      | sort -V \
      | tail -n 1
  )"

  [[ -n ${TEMPLATE} ]] || die "could not find a Debian 12 LXC template via pveam"
}

template_ref() {
  printf '%s:vztmpl/%s\n' "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

download_template_if_missing() {
  local template_path="/var/lib/vz/template/cache/${TEMPLATE}"

  if [[ -f ${template_path} ]]; then
    return
  fi

  log "Downloading LXC template ${TEMPLATE}"
  pveam update
  pveam download "${TEMPLATE_STORAGE}" "${TEMPLATE}"
}

assert_vmid_available() {
  if pct status "${VMID}" >/dev/null 2>&1; then
    die "VMID ${VMID} already exists (destroy the existing CT ${VMID} or set VMID=)"
  fi
}

maybe_generate_api_key() {
  if [[ -z ${API_KEY} ]]; then
    API_KEY="$(openssl rand -hex 16)"
  fi
}

create_container() {
  local ostemplate rootfs net0
  local -a create_args

  ostemplate="$(template_ref)"
  rootfs="${ROOT_STORAGE}:${ROOT_SIZE_GB}"
  net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth"

  log "Creating kb-rag LXC ${VMID} (${LXC_HOSTNAME})"

  create_args=(
    "${VMID}"
    "${ostemplate}"
    --hostname "${LXC_HOSTNAME}"
    --cores "${CORES}"
    --memory "${MEMORY_MB}"
    --swap "${SWAP_MB}"
    --rootfs "${rootfs}"
    --net0 "${net0}"
    --unprivileged 1
    --onboot "${START_ON_BOOT}"
    --ostype debian
  )

  if [[ -n ${PASSWORD} ]]; then
    create_args+=(--password "${PASSWORD}")
  fi

  pct create "${create_args[@]}"

  pct set "${VMID}" --tags kb-rag >/dev/null 2>&1 || true

  # Index/model cache are rebuildable — keep the rootfs out of backups (repo convention).
  # Append backup=0 to the ACTUAL allocated volume line (same size => no resize).
  local rootfs_line
  rootfs_line="$(pct config "${VMID}" | sed -n 's/^rootfs: //p')"
  if [[ -n ${rootfs_line} && ${rootfs_line} != *backup=* ]]; then
    pct set "${VMID}" --rootfs "${rootfs_line},backup=0" >/dev/null 2>&1 || true
  fi
}

start_container() {
  log "Starting LXC ${VMID}"
  pct start "${VMID}"
}

wait_for_container() {
  log "Waiting for container startup"
  for _ in {1..60}; do
    if pct exec "${VMID}" -- test -d /run/systemd/system >/dev/null 2>&1; then
      return
    fi
    sleep 2
  done

  die "container did not become ready in time"
}

push_secret_file() {
  # $1 = local source, $2 = container destination. mode-600, never through argv/env.
  local src="$1" dst="$2" tmp
  tmp="$(mktemp)" || return 1
  chmod 600 "${tmp}"
  cat "${src}" >"${tmp}"
  if ! pct push "${VMID}" "${tmp}" "${dst}" --perms 0600; then
    rm -f "${tmp}"
    return 1
  fi
  rm -f "${tmp}"
}

install_and_configure() {
  local script_dir app_dir have_local=0 tarball secret_key
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  app_dir="${script_dir}/app"

  log "Pushing secrets (deploy key + API key)"
  push_secret_file "${DEPLOY_KEY_FILE}" /root/.kb-deploy-key || die "failed to push deploy key"
  secret_key="$(mktemp)"; chmod 600 "${secret_key}"; printf '%s' "${API_KEY}" >"${secret_key}"
  push_secret_file "${secret_key}" /root/.kb-api-key || { rm -f "${secret_key}"; die "failed to push API key"; }
  rm -f "${secret_key}"

  if [[ -d ${app_dir} ]]; then
    have_local=1
    log "Shipping app/ from local checkout"
    tarball="$(mktemp)"
    tar -C "${script_dir}" -czf "${tarball}" app
    pct push "${VMID}" "${tarball}" /root/kb-rag-app.tar.gz --perms 0600 || { rm -f "${tarball}"; die "failed to push app tarball"; }
    rm -f "${tarball}"
  else
    log "No local checkout — container will download app/ from ${REPO_RAW_BASE}"
  fi

  log "Installing kb-rag and configuring services"
  local rc=0
  pct exec "${VMID}" -- bash -s -- \
    "${have_local}" \
    "${REPO_RAW_BASE}" \
    "${API_PORT}" \
    "${EMBED_MODEL}" \
    "${EMBED_DIM}" \
    "${KB_REPO_URL}" \
    "${KB_BRANCH}" \
    "${REINDEX_INTERVAL}" \
    "${KB_PIP_PACKAGES}" \
    "${APP_FILES[*]}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

HAVE_LOCAL="$1"
REPO_RAW_BASE="$2"
API_PORT="$3"
EMBED_MODEL="$4"
EMBED_DIM="$5"
KB_REPO_URL="$6"
KB_BRANCH="$7"
REINDEX_INTERVAL="$8"
PIP_PACKAGES="$9"
APP_FILES="${10}"

export DEBIAN_FRONTEND=noninteractive

# 1. Read pushed secrets (mode-600, kept out of argv/env). Install the deploy key; delete the
#    provision copies. Read the API key with command substitution (never `source`).
install -d -m 700 /root/.ssh
mv /root/.kb-deploy-key /root/.ssh/kb-rag-deploy
chmod 600 /root/.ssh/kb-rag-deploy
API_KEY="$(cat /root/.kb-api-key)"
rm -f /root/.kb-api-key

# 2. Base packages. sqlite-vec + fastembed ship prebuilt amd64 wheels; build-essential is a
#    safety net only. python3-venv gives us an isolated interpreter.
apt-get update
apt-get install -y ca-certificates curl git python3 python3-venv python3-pip build-essential

# 3. venv + pinned deps.
python3 -m venv /opt/kb-rag/venv
/opt/kb-rag/venv/bin/pip install --upgrade pip >/dev/null
# shellcheck disable=SC2086
/opt/kb-rag/venv/bin/pip install ${PIP_PACKAGES}

# 4. Deploy app/. Local checkout -> extract the pushed tarball; standalone -> download each file.
install -d -m 755 /opt/kb-rag/app /opt/kb-rag/data
if [[ "${HAVE_LOCAL}" == "1" ]]; then
  tar -C /opt/kb-rag -xzf /root/kb-rag-app.tar.gz
  rm -f /root/kb-rag-app.tar.gz
else
  for f in ${APP_FILES}; do
    curl -fsSL "${REPO_RAW_BASE}/app/${f}" -o "/opt/kb-rag/app/${f}" \
      || { echo "error: failed to download app/${f}" >&2; exit 1; }
  done
fi

# 5. Runtime env (systemd + wrappers source this). Process env wins over index.config.yaml,
#    so these override the shipped defaults. GIT_SSH_COMMAND pins the read-only deploy key.
cat >/etc/kb-rag.env <<ENV
KB_API_KEY=${API_KEY}
KB_API_PORT=${API_PORT}
KB_REPO_URL=${KB_REPO_URL}
KB_BRANCH=${KB_BRANCH}
KB_REPO_DIR=/opt/kb-rag/data/repo
KB_DB_PATH=/opt/kb-rag/data/kb.sqlite
KB_EMBED_MODEL=${EMBED_MODEL}
KB_EMBED_DIM=${EMBED_DIM}
GIT_SSH_COMMAND="ssh -i /root/.ssh/kb-rag-deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
ENV
chmod 600 /etc/kb-rag.env

# 6. Wrapper commands.
cat >/usr/local/bin/kb-reindex <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a; . /etc/kb-rag.env; set +a
exec /opt/kb-rag/venv/bin/python /opt/kb-rag/app/reindex.py "$@"
SH
cat >/usr/local/bin/kb-stats <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
set -a; . /etc/kb-rag.env; set +a
exec /opt/kb-rag/venv/bin/python - <<'PY'
import json, sys
sys.path.insert(0, "/opt/kb-rag/app")
from config import load_config
from store import Store
cfg = load_config()
print(json.dumps(Store(cfg["db_path"], cfg["embed_dim"]).stats(), indent=2))
PY
SH
chmod +x /usr/local/bin/kb-reindex /usr/local/bin/kb-stats

# 7. Initial index: clone the KB (deploy key) + build from scratch. This also warms the ONNX
#    model cache. Fail loudly if it doesn't produce chunks.
set -a; . /etc/kb-rag.env; set +a
kb-reindex --full

# 8. systemd: the API server + a reindex timer.
cat >/etc/systemd/system/kb-rag.service <<'SERVICE'
[Unit]
Description=kb-rag knowledge-base search API (REST + MCP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/kb-rag.env
WorkingDirectory=/opt/kb-rag/app
ExecStart=/opt/kb-rag/venv/bin/uvicorn server:app --host 0.0.0.0 --port ${KB_API_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

cat >/etc/systemd/system/kb-reindex.service <<'SERVICE'
[Unit]
Description=kb-rag reindex (git pull + incremental embed)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kb-reindex
SERVICE

cat >/etc/systemd/system/kb-reindex.timer <<TIMER
[Unit]
Description=kb-rag periodic reindex

[Timer]
OnBootSec=2min
OnUnitActiveSec=${REINDEX_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now kb-rag.service
systemctl enable --now kb-reindex.timer

# 9. Confirm the API is up AND the index is non-empty (don't report success over a dead
#    service or an empty index). Poll ~120s.
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then
    count="$(curl -fsS -H "Authorization: Bearer ${API_KEY}" \
      "http://127.0.0.1:${API_PORT}/v1/stats" 2>/dev/null \
      | sed -n 's/.*"chunk_count"[: ]*\([0-9]*\).*/\1/p')"
    if [[ -n "${count}" && "${count}" -gt 0 ]]; then
      printf 'kb-rag is up on port %s with %s chunks indexed\n' "${API_PORT}" "${count}"
      exit 0
    fi
  fi
  sleep 2
done

printf 'error: kb-rag did not become healthy with a non-empty index within ~120s\n' >&2
systemctl status kb-rag.service --no-pager --full >&2 || true
journalctl -u kb-rag.service --no-pager -n 80 >&2 || true
exit 1
CONTAINER_SCRIPT
  rc=$?

  # Best-effort cleanup of any provision leftovers.
  pct exec "${VMID}" -- rm -f /root/.kb-api-key /root/kb-rag-app.tar.gz >/dev/null 2>&1 || true

  return "${rc}"
}

print_summary() {
  local ip
  ip="$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

  log "Done"
  printf 'kb-rag LXC: %s (%s)\n' "${VMID}" "${LXC_HOSTNAME}"
  if [[ -n ${ip} ]]; then
    printf 'REST:  http://%s:%s/v1/search   MCP: http://%s:%s/mcp/\n' "${ip}" "${API_PORT}" "${ip}" "${API_PORT}"
    printf 'By name (dnsmasq): http://%s:%s/v1  (from other containers)\n' "${LXC_HOSTNAME}" "${API_PORT}"
  else
    printf 'Endpoint: check container IP, port %s\n' "${API_PORT}"
  fi
  printf 'API key (bearer, save this — shown once): %s\n' "${API_KEY}"
  printf 'Model target: %s (served as "%s")\n' "${KB_REPO_URL}" "${EMBED_MODEL}"
  printf '\nNext steps:\n'
  printf '  Search:            curl -s http://%s:%s/v1/search -H "Authorization: Bearer <key>" -H "content-type: application/json" -d '\''{"query":"..."}'\''\n' "${LXC_HOSTNAME}" "${API_PORT}"
  printf '  Reindex now:       pct exec %s -- kb-reindex\n' "${VMID}"
  printf '  Index stats:       pct exec %s -- kb-stats\n' "${VMID}"
  printf '  Wire into Hermes:  register MCP server http://%s:%s/mcp/ (Bearer <key>)\n' "${LXC_HOSTNAME}" "${API_PORT}"
}

main() {
  if [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
    usage
    exit 0
  fi

  require_root
  require_command pct
  require_command pveam
  require_command openssl
  require_deploy_key
  assert_vmid_available
  resolve_template
  download_template_if_missing
  maybe_generate_api_key
  create_container
  start_container
  wait_for_container
  if ! install_and_configure; then
    printf '\n' >&2
    log "kb-rag provisioning FAILED on CT ${VMID}."
    printf 'The container exists but the service/index is not healthy. Inspect it with:\n' >&2
    printf '  pct exec %s -- systemctl status kb-rag\n' "${VMID}" >&2
    printf '  pct exec %s -- journalctl -u kb-rag -n 100 --no-pager\n' "${VMID}" >&2
    printf '  pct exec %s -- kb-reindex --full   # re-run the index build\n' "${VMID}" >&2
    printf 'API bearer key (save it; only shown here): %s\n' "${API_KEY}" >&2
    exit 1
  fi
  print_summary
}

main "$@"
