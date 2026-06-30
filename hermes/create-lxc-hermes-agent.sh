#!/usr/bin/env bash

set -Eeuo pipefail

# Create a persistent unprivileged Debian LXC running NousResearch's Hermes Agent
# (https://hermes-agent.nousresearch.com/) as the homelab's agent. It points at the
# CT 120 LLM runtime's OpenAI-compatible API (no Nous Portal login) and runs a single
# `hermes gateway run` service that serves BOTH the messaging gateway AND Hermes's own
# OpenAI-compatible API server on port 8642.
#
# Unlike the GPU runtime scripts, this consumes an API rather than driving hardware, so
# it is the bench-runner's sibling (unprivileged, auto-discovers CT 120). It is meant to
# be installed once and left running, so it is deliberately lean: one install+configure
# pass, one systemd service, no extra in-container helper commands.
#
# Run this script on the Proxmox host as root.

VMID="${VMID:-121}"
LXC_HOSTNAME="${LXC_HOSTNAME:-hermes}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
# Hermes installs its own uv/Python 3.11 + Node 22 + (optionally) Playwright Chromium,
# so the rootfs is far heavier than the bench-runner's. 30 GB leaves headroom for the
# Chromium download plus growing sessions/memories/logs under /root/.hermes.
ROOT_SIZE_GB="${ROOT_SIZE_GB:-30}"
MEMORY_MB="${MEMORY_MB:-8192}"
SWAP_MB="${SWAP_MB:-2048}"
CORES="${CORES:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
PASSWORD="${PASSWORD:-}"
START_ON_BOOT="${START_ON_BOOT:-1}"
START_AFTER_CREATE="${START_AFTER_CREATE:-1}"

# --- Target LLM runtime (CT 120) ---
TARGET_LXC_VMID="${TARGET_LXC_VMID:-120}"
TARGET_BASE_URL="${TARGET_BASE_URL:-}"          # empty → discover CT 120's IP
# CT 120 serves its model under this --alias (see pro-v620/create-lxc-...sh MODEL_ALIAS);
# /v1/models reports it and OpenAI requests must set "model" to it. Override if it changes.
MODEL_IDENTIFIER="${MODEL_IDENTIFIER:-qwen3.6-35b-a3b}"
# CT 120 runs --ctx-size 262144 with --parallel 4, i.e. 65536 tokens per slot. Matching
# that here keeps one Hermes request inside one slot (a larger value would let a request
# exceed a slot and get truncated). Concurrent Hermes subagents + external API clients all
# draw from CT 120's 4 slots; on CT 120, `llamacpp-reload <ctx> <parallel>` is the lever.
MODEL_CONTEXT_LENGTH="${MODEL_CONTEXT_LENGTH:-65536}"

# --- Hermes version ---
# "latest" installs main HEAD (no --branch). Set to a git tag (e.g. v0.17.0) to pin a
# release for reproducibility. Tracking latest is a deliberate deviation from this repo's
# "pin a tarball + verify SHA-256" idiom — the upstream install.sh URL can't be SHA-pinned.
HERMES_VERSION="${HERMES_VERSION:-latest}"

# --- Hermes OpenAI-compatible API server ---
# The API server gives FULL access to Hermes's toolset, INCLUDING terminal commands, so a
# bearer key is mandatory even on loopback. Empty → auto-generate and print it once.
API_SERVER_KEY="${API_SERVER_KEY:-}"
API_SERVER_PORT="${API_SERVER_PORT:-8642}"

# --- Browser automation (Playwright Chromium) ---
INSTALL_BROWSER="${INSTALL_BROWSER:-1}"         # 1 → installer runs `playwright install --with-deps chromium`

# --- Optional messaging gateway token ---
# Empty (default) → the gateway starts with no platforms; configure them post-provision
# with `pct exec <vmid> -- hermes gateway setup`. Supply a token to wire Telegram at boot.
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"

usage() {
  cat <<'USAGE'
Create a persistent unprivileged Debian LXC running NousResearch's Hermes Agent.

It points at the CT 120 LLM runtime (OpenAI-compatible API) and runs a single
`hermes gateway run` service = messaging gateway + OpenAI-compatible API server (port 8642).

Run this script on the Proxmox host as root.

Useful overrides:
  VMID=121 LXC_HOSTNAME=hermes ./create-lxc-hermes-agent.sh
  TARGET_LXC_VMID=120 ./create-lxc-hermes-agent.sh
  TARGET_BASE_URL=http://192.168.1.50:1234/v1 ./create-lxc-hermes-agent.sh
  MODEL_IDENTIFIER=qwen3.6-35b-a3b ./create-lxc-hermes-agent.sh
  HERMES_VERSION=v0.17.0 ./create-lxc-hermes-agent.sh   # pin a release instead of latest
  INSTALL_BROWSER=0 ./create-lxc-hermes-agent.sh        # skip Playwright Chromium (leaner)
  API_SERVER_KEY=my-secret ./create-lxc-hermes-agent.sh # else auto-generated and printed
  TELEGRAM_BOT_TOKEN=123:abc ./create-lxc-hermes-agent.sh

After it is up, add/adjust messaging platforms without re-provisioning:
  pct exec 121 -- hermes gateway setup
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

discover_target_base_url() {
  local target_ip

  if [[ -n ${TARGET_BASE_URL} ]]; then
    return
  fi

  if pct status "${TARGET_LXC_VMID}" >/dev/null 2>&1; then
    target_ip="$(pct exec "${TARGET_LXC_VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n ${target_ip} ]]; then
      TARGET_BASE_URL="http://${target_ip}:1234/v1"
      return
    fi
  fi

  # Fallback to a DNS name if CT 120 is not running at provision time. The base_url can be
  # re-pointed later by editing /root/.hermes/config.yaml and restarting hermes.service.
  TARGET_BASE_URL="http://llamacpp:1234/v1"
  cat >&2 <<WARN

============================================================
WARNING: could not reach CT ${TARGET_LXC_VMID} to discover its IP.
TARGET_BASE_URL defaulted to ${TARGET_BASE_URL}. If that DNS name does
not resolve, Hermes will not reach the model until you fix it:
  - Start CT ${TARGET_LXC_VMID}, then edit /root/.hermes/config.yaml
    (model.base_url) on CT ${VMID} and: systemctl restart hermes
  - Or re-run with TARGET_BASE_URL=http://<ip>:1234/v1
============================================================

WARN
}

maybe_generate_api_key() {
  if [[ -z ${API_SERVER_KEY} ]]; then
    API_SERVER_KEY="$(openssl rand -hex 16)"
  fi
}

create_container() {
  local ostemplate
  local rootfs
  local net0
  local -a create_args

  ostemplate="$(template_ref)"
  rootfs="${ROOT_STORAGE}:${ROOT_SIZE_GB}"
  net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth"

  log "Creating Hermes Agent LXC ${VMID} (${LXC_HOSTNAME})"

  # nesting=1 lets headless Chromium (Playwright) set up its sandbox inside an
  # unprivileged container; keyctl=1 matches the bench-runner sibling.
  create_args=(
    "${VMID}"
    "${ostemplate}"
    --hostname "${LXC_HOSTNAME}"
    --cores "${CORES}"
    --memory "${MEMORY_MB}"
    --swap "${SWAP_MB}"
    --rootfs "${rootfs}"
    --net0 "${net0}"
    --features "nesting=1,keyctl=1"
    --unprivileged 1
    --onboot "${START_ON_BOOT}"
    --ostype debian
  )

  if [[ -n ${PASSWORD} ]]; then
    create_args+=(--password "${PASSWORD}")
  fi

  pct create "${create_args[@]}"
}

start_container() {
  if [[ ${START_AFTER_CREATE} == 1 ]]; then
    log "Starting LXC ${VMID}"
    pct start "${VMID}"
  fi
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

install_and_configure() {
  log "Installing Hermes Agent (${HERMES_VERSION}) and configuring the service"

  # The bot token is the one secret here; pass it on stdin (not as a positional arg, which
  # would show in the host's `ps` during provisioning). Everything else is non-secret and
  # passed as positional args, bench-runner style.
  pct exec "${VMID}" -- env HERMES_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}" \
    bash -s -- \
    "${HERMES_VERSION}" \
    "${INSTALL_BROWSER}" \
    "${TARGET_BASE_URL}" \
    "${MODEL_IDENTIFIER}" \
    "${MODEL_CONTEXT_LENGTH}" \
    "${API_SERVER_KEY}" \
    "${API_SERVER_PORT}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

HERMES_VERSION="$1"
INSTALL_BROWSER="$2"
TARGET_BASE_URL="$3"
MODEL_IDENTIFIER="$4"
MODEL_CONTEXT_LENGTH="$5"
API_SERVER_KEY="$6"
API_SERVER_PORT="$7"
TELEGRAM_BOT_TOKEN="${HERMES_TELEGRAM_BOT_TOKEN:-}"

export HERMES_HOME=/root/.hermes

# 1. Bootstrap packages the upstream installer needs to run. The installer itself
# installs uv/Python 3.11, Node 22, ripgrep, ffmpeg, and (with browser enabled)
# `playwright install --with-deps chromium` — all of which need root/apt, which is why
# this container installs and runs Hermes as root.
# build-essential + python3 are REQUIRED here: Hermes's `npm install` builds the native
# node-pty module via node-gyp, which needs make/g++/python3. The Debian template ships
# none of them, so without this the installer's npm step fails silently ("npm install
# failed or timed out") and the agent-browser daemon never installs — leaving the browser
# tools unavailable at runtime. (Verified on a real provision.)
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git build-essential python3

# 2. Install Hermes. --non-interactive is mandatory (no TTY under `pct exec`); --skip-setup
# skips the config wizard because we write config.yaml/.env ourselves below.
install_args=(--non-interactive --skip-setup)
if [[ "${HERMES_VERSION}" != "latest" ]]; then
  install_args+=(--branch "${HERMES_VERSION}")
fi
if [[ "${INSTALL_BROWSER}" != "1" ]]; then
  install_args+=(--skip-browser)
fi
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- "${install_args[@]}"

command -v hermes >/dev/null 2>&1 || [[ -x /usr/local/bin/hermes ]] \
  || { printf 'error: hermes CLI not found after install\n' >&2; exit 1; }
HERMES_BIN="$(command -v hermes 2>/dev/null || echo /usr/local/bin/hermes)"
"${HERMES_BIN}" --version 2>/dev/null || true

# 3. Point Hermes at the CT 120 runtime (custom OpenAI-compatible endpoint, no key).
install -d -m 700 "${HERMES_HOME}"
cat >"${HERMES_HOME}/config.yaml" <<YAML
model:
  default: ${MODEL_IDENTIFIER}
  provider: custom
  base_url: ${TARGET_BASE_URL}
  api_key: ""
  context_length: ${MODEL_CONTEXT_LENGTH}
terminal:
  backend: local
YAML

if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
  cat >>"${HERMES_HOME}/config.yaml" <<'YAML'
gateway:
  platforms:
    telegram:
      enabled: true
YAML
fi

# 4. Secrets + API-server enablement live in .env (root-only). The bearer key is required
# even on loopback because the API exposes terminal access.
{
  printf 'API_SERVER_ENABLED=true\n'
  printf 'API_SERVER_KEY=%s\n' "${API_SERVER_KEY}"
  printf 'API_SERVER_HOST=0.0.0.0\n'
  printf 'API_SERVER_PORT=%s\n' "${API_SERVER_PORT}"
  if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "${TELEGRAM_BOT_TOKEN}"
  fi
} >"${HERMES_HOME}/.env"
chmod 600 "${HERMES_HOME}/.env"

# 5. One systemd service: `hermes gateway run` serves the gateway + API server in a single
# foreground process (the same command the official Docker image runs).
cat >/etc/systemd/system/hermes.service <<SERVICE
[Unit]
Description=Hermes Agent (gateway + OpenAI-compatible API server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HERMES_HOME=${HERMES_HOME}
ExecStart=${HERMES_BIN} gateway run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now hermes.service

# 6. Confirm the API server comes up rather than silently reporting success over a dead
# service. /v1/models requires the bearer key even on loopback. A heavy first boot can be
# slow, so on timeout this WARNS (the container + service are installed either way) rather
# than aborting the provision — check `journalctl -u hermes` if it does not answer.
for _ in $(seq 1 60); do
  if curl -fsS -H "Authorization: Bearer ${API_SERVER_KEY}" \
      "http://127.0.0.1:${API_SERVER_PORT}/v1/models" >/dev/null 2>&1; then
    printf 'hermes API server is up on port %s\n' "${API_SERVER_PORT}"
    exit 0
  fi
  sleep 2
done
printf 'warning: hermes API server did not answer /v1/models within ~120s; check `journalctl -u hermes`\n' >&2
CONTAINER_SCRIPT
}

print_summary() {
  local ip
  ip="$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

  log "Done"
  printf 'Hermes Agent LXC: %s (%s)\n' "${VMID}" "${LXC_HOSTNAME}"
  if [[ -n ${ip} ]]; then
    printf 'API endpoint: http://%s:%s/v1 (OpenAI-compatible)\n' "${ip}" "${API_SERVER_PORT}"
  else
    printf 'API endpoint: check container IP, port %s\n' "${API_SERVER_PORT}"
  fi
  printf 'API key (bearer, save this — shown once): %s\n' "${API_SERVER_KEY}"
  printf 'Model target: %s (served as "%s")\n' "${TARGET_BASE_URL}" "${MODEL_IDENTIFIER}"
  printf '\nNext steps:\n'
  printf "  Add messaging platforms:  pct exec %s -- hermes gateway setup\n" "${VMID}"
  printf "  Chat from the host:       pct exec %s -- bash -lc 'hermes chat -q \"hello\"'\n" "${VMID}"
  printf '  Check the service:        pct exec %s -- systemctl status hermes\n' "${VMID}"
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
  assert_vmid_available
  resolve_template
  download_template_if_missing
  discover_target_base_url
  maybe_generate_api_key
  create_container
  start_container
  wait_for_container
  install_and_configure
  print_summary
}

main "$@"
