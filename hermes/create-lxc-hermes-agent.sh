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

# --- Target LLM runtime (CT 120) ---
TARGET_LXC_VMID="${TARGET_LXC_VMID:-120}"
# CT 120's hostname. When the containers share a resolver that knows this name (e.g. the
# host WiFi-NAT setup's dnsmasq maps it to CT 120's reserved IP), it survives CT 120
# address changes — so it is PREFERRED over a discovered IP, which goes stale if CT 120's
# address ever changes (as happened on the ethernet→WiFi cutover). Verified from inside
# the Hermes container at provision time; falls back to the discovered IP if it doesn't
# resolve there.
TARGET_HOSTNAME="${TARGET_HOSTNAME:-llamacpp}"
TARGET_BASE_URL="${TARGET_BASE_URL:-}"          # empty → prefer TARGET_HOSTNAME, fall back to CT 120's IP
TARGET_BASE_URL_FALLBACK=""                     # set by discover_target_base_url (CT 120's discovered IP URL)
# CT 120 serves its model under this --alias (see pro-v620/create-lxc-...sh MODEL_ALIAS);
# /v1/models reports it and OpenAI requests must set "model" to it. Override if it changes.
MODEL_IDENTIFIER="${MODEL_IDENTIFIER:-qwen3.6-35b-a3b}"
# CT 120 runs --ctx-size 262144 with --parallel 2, i.e. 131072 tokens per slot. We keep
# this at 65536 (half a slot) on purpose: it caps a Hermes request's PROMPT to ~half the
# slot, leaving the rest free for the model's reasoning+answer output. qwen3.6 is a thinking
# model served with no output cap, so filling a whole slot with prompt starves the response
# and trips "Thinking Budget Exhausted" (the model spends every remaining token on <think>).
# Concurrent Hermes subagents + external API clients all draw from CT 120's 2 slots; on
# CT 120, `llamacpp-reload <ctx> <parallel>` is the lever.
MODEL_CONTEXT_LENGTH="${MODEL_CONTEXT_LENGTH:-65536}"
# Main model-call timeout (seconds), written as providers.custom.request_timeout_seconds. CT 120's
# --parallel 2 means a 3rd concurrent request QUEUES (llama-server queues, doesn't reject); without
# an explicit value the OpenAI SDK default (read=600s) would fire on a >10-min queue wait. 1800s
# (30 min) absorbs that. The provider key MUST be `custom` — that's the resolved agent.provider for
# this bare-custom llamacpp endpoint (a mismatched key silently falls back to the 600s default).
MODEL_REQUEST_TIMEOUT_SECONDS="${MODEL_REQUEST_TIMEOUT_SECONDS:-1800}"

# --- Hermes version (pinned + checksum-verified by default) ---
# The install is pinned to an immutable git tag: the container fetches scripts/install.sh
# from that tag's raw URL, verifies its SHA-256 against HERMES_INSTALLER_SHA256, then runs
# it with `--branch <tag>` so the checked-out code matches the verified installer. This
# follows the repo's "pin a tag + verify SHA-256" idiom and stops a mutated upstream
# installer from running as root. Bump BOTH together from
# https://github.com/NousResearch/hermes-agent/releases — use the GIT TAG (e.g. v2026.6.19),
# NOT the "v0.17.0" marketing title shown on the release page (that is not a valid git ref).
# Recompute the checksum after bumping the tag:
#   curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/<tag>/scripts/install.sh | sha256sum
# Set HERMES_VERSION=latest to instead stream the mutable upstream installer (tracks main
# HEAD) — UNVERIFIED: no checksum, no pin. For testing only.
HERMES_VERSION="${HERMES_VERSION:-v2026.6.19}"
HERMES_INSTALLER_SHA256="${HERMES_INSTALLER_SHA256:-dbd9d555ed4ac67bd1fc71ba6a39b410cf2af0ebcfd8f4889e086af78c9ddcaa}"

# --- Hermes OpenAI-compatible API server ---
# The API server gives FULL access to Hermes's toolset, INCLUDING terminal commands, so a
# bearer key is mandatory even on loopback. Empty → auto-generate and print it once.
API_SERVER_KEY="${API_SERVER_KEY:-}"
API_SERVER_PORT="${API_SERVER_PORT:-8642}"

# --- Browser automation (Playwright Chromium) ---
INSTALL_BROWSER="${INSTALL_BROWSER:-1}"         # 1 → Playwright Chromium + the readability extractor (trafilatura) used by the KB-ingestion skill

# --- Messaging gateway platforms ---
# Not pre-wired here: the gateway starts with no platforms. Add Telegram/Discord/Slack/…
# after provisioning with `pct exec <vmid> -- hermes gateway setup`, which also walks you
# through the per-platform user allowlist (without one, Hermes denies all incoming users).

usage() {
  cat <<'USAGE'
Create a persistent unprivileged Debian LXC running NousResearch's Hermes Agent.

It points at the CT 120 LLM runtime (OpenAI-compatible API) and runs a single
`hermes gateway run` service = messaging gateway + OpenAI-compatible API server (port 8642).

Run this script on the Proxmox host as root.

Useful overrides:
  VMID=121 LXC_HOSTNAME=hermes ./create-lxc-hermes-agent.sh
  TARGET_LXC_VMID=120 ./create-lxc-hermes-agent.sh
  TARGET_HOSTNAME=llamacpp ./create-lxc-hermes-agent.sh   # CT 120's name; preferred over its IP (survives address changes)
  TARGET_BASE_URL=http://<ct120-ip>:1234/v1 ./create-lxc-hermes-agent.sh  # pin an exact endpoint (skips discovery)
  MODEL_IDENTIFIER=qwen3.6-35b-a3b ./create-lxc-hermes-agent.sh
  HERMES_VERSION=v2026.6.19 ./create-lxc-hermes-agent.sh  # pin a different release (GIT TAG, not the v0.x.y title)
  HERMES_VERSION=latest ./create-lxc-hermes-agent.sh      # track main HEAD, UNVERIFIED (no checksum/pin)
  INSTALL_BROWSER=0 ./create-lxc-hermes-agent.sh        # skip Playwright Chromium + readability extractor (leaner)
  API_SERVER_KEY=my-secret ./create-lxc-hermes-agent.sh # else auto-generated and printed

After it is up, add messaging platforms (Telegram/Discord/Slack/…) without re-provisioning:
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

  # Explicit override always wins; no fallback needed.
  if [[ -n ${TARGET_BASE_URL} ]]; then
    TARGET_BASE_URL_FALLBACK=""
    return
  fi

  # PREFER the stable hostname. We can't tell here whether it resolves from the (not-yet-
  # created) Hermes container's view, so we also capture CT 120's current IP as a fallback
  # the container itself will use only if the hostname doesn't resolve there. This avoids
  # baking in an IP that goes stale when CT 120's address changes (e.g. a network move).
  TARGET_BASE_URL="http://${TARGET_HOSTNAME}:1234/v1"
  TARGET_BASE_URL_FALLBACK=""
  if pct status "${TARGET_LXC_VMID}" >/dev/null 2>&1; then
    target_ip="$(pct exec "${TARGET_LXC_VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n ${target_ip} ]] && TARGET_BASE_URL_FALLBACK="http://${target_ip}:1234/v1"
  fi

  if [[ -z ${TARGET_BASE_URL_FALLBACK} ]]; then
    cat >&2 <<WARN

============================================================
NOTE: could not reach CT ${TARGET_LXC_VMID} to capture a fallback IP.
Hermes will be pointed at ${TARGET_BASE_URL}. If that name does not
resolve from CT ${VMID}, fix it after CT ${TARGET_LXC_VMID} is up:
  - edit /root/.hermes/config.yaml (model.base_url) on CT ${VMID}
    and: systemctl restart hermes
  - or re-run with TARGET_BASE_URL=http://<ip>:1234/v1
============================================================

WARN
  fi
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

install_and_configure() {
  log "Installing Hermes Agent (${HERMES_VERSION}) and configuring the service"

  # The API-server bearer key is the only secret and must NOT travel through argv or the
  # environment (both are visible in `ps` / `/proc` on the host and in the container). Push
  # it as a mode-600 raw-value file; the container reads it with `$(cat)` — NOT `source`, so
  # the value is never interpreted as shell — and then deletes it. The host copy is removed
  # as soon as it is pushed. Everything else below is non-secret and stays as positional args.
  local secret_file
  secret_file="$(mktemp)" || return 1
  chmod 600 "${secret_file}"
  printf '%s' "${API_SERVER_KEY}" >"${secret_file}"

  if ! pct push "${VMID}" "${secret_file}" /root/.hermes-provision-secret --perms 0600; then
    rm -f "${secret_file}"
    return 1
  fi
  rm -f "${secret_file}"   # host copy no longer needed; the container has its own

  local rc=0
  pct exec "${VMID}" -- bash -s -- \
    "${HERMES_VERSION}" \
    "${HERMES_INSTALLER_SHA256}" \
    "${INSTALL_BROWSER}" \
    "${TARGET_BASE_URL}" \
    "${MODEL_IDENTIFIER}" \
    "${MODEL_CONTEXT_LENGTH}" \
    "${API_SERVER_PORT}" \
    "${TARGET_BASE_URL_FALLBACK}" \
    "${MODEL_REQUEST_TIMEOUT_SECONDS}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

HERMES_VERSION="$1"
HERMES_INSTALLER_SHA256="$2"
INSTALL_BROWSER="$3"
TARGET_BASE_URL="$4"
MODEL_IDENTIFIER="$5"
MODEL_CONTEXT_LENGTH="$6"
API_SERVER_PORT="$7"
TARGET_BASE_URL_FALLBACK="$8"   # discovered IP URL; used only if TARGET_BASE_URL doesn't resolve here
MODEL_REQUEST_TIMEOUT_SECONDS="$9"

# The API key was pushed as a mode-600 raw-value file (kept out of argv/env so it never
# appears in `ps`). Read it with command substitution — NOT `source` — so its contents are
# never interpreted as shell, then delete it before doing anything else.
SECRET_FILE=/root/.hermes-provision-secret
API_SERVER_KEY="$(cat "${SECRET_FILE}")"
rm -f "${SECRET_FILE}"

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
apt-get install -y ca-certificates curl git build-essential python3 jq

# 2. Install Hermes — pinned + checksum-verified by default. Fetch scripts/install.sh from
# the pinned git tag's raw URL (immutable), verify its SHA-256, then run it with
# `--branch <tag>` so the checked-out code matches the verified installer. This stops a
# mutated upstream installer from running as root. HERMES_VERSION=latest opts out: it
# streams the mutable upstream installer (no checksum, no pin) — for testing only.
installer="$(mktemp)"
if [[ "${HERMES_VERSION}" == "latest" ]]; then
  printf 'warning: HERMES_VERSION=latest — installing UNPINNED main HEAD with NO checksum verification\n' >&2
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "${installer}"
else
  curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_VERSION}/scripts/install.sh" -o "${installer}"
  if [[ -z "${HERMES_INSTALLER_SHA256}" ]]; then
    printf 'error: HERMES_INSTALLER_SHA256 is empty; refusing to run an unverified pinned installer\n' >&2
    exit 1
  fi
  if ! printf '%s  %s\n' "${HERMES_INSTALLER_SHA256}" "${installer}" | sha256sum -c - >/dev/null 2>&1; then
    printf 'error: installer SHA-256 mismatch for tag %s\n' "${HERMES_VERSION}" >&2
    printf '  expected: %s\n' "${HERMES_INSTALLER_SHA256}" >&2
    printf '  actual:   %s\n' "$(sha256sum "${installer}" | awk '{print $1}')" >&2
    exit 1
  fi
fi

# --non-interactive is mandatory (no TTY under `pct exec`); --skip-setup skips the config
# wizard because we write config.yaml/.env ourselves below. --branch <tag> pins the
# checkout (git clone --branch accepts tags and detaches HEAD at the tagged commit).
install_args=(--non-interactive --skip-setup)
if [[ "${HERMES_VERSION}" != "latest" ]]; then
  install_args+=(--branch "${HERMES_VERSION}")
fi
if [[ "${INSTALL_BROWSER}" != "1" ]]; then
  install_args+=(--skip-browser)
fi
bash "${installer}" "${install_args[@]}"
rm -f "${installer}"

command -v hermes >/dev/null 2>&1 || [[ -x /usr/local/bin/hermes ]] \
  || { printf 'error: hermes CLI not found after install\n' >&2; exit 1; }
HERMES_BIN="$(command -v hermes 2>/dev/null || echo /usr/local/bin/hermes)"
"${HERMES_BIN}" --version 2>/dev/null || true

# 2b. Web-ingestion toolchain for the KB skills (part of the browser toolchain, INSTALL_BROWSER=1):
#   - gh (GitHub CLI): the knowledge-ingestion `kb-open-pr` helper uses it to clone/push/open PRs.
#   - trafilatura + readability-lxml in a dedicated /opt/readability venv (off the system and
#     Hermes interpreters): the web-extraction skill's clean-text extractor. The trafilatura CLI
#     goes on PATH; /opt/readability/bin/python exposes the readability fallback.
# Versions pinned (validated together; bump deliberately).
if [[ "${INSTALL_BROWSER}" == "1" ]]; then
  apt-get install -y python3-venv gh
  python3 -m venv /opt/readability
  /opt/readability/bin/pip install --upgrade pip >/dev/null
  # lxml_html_clean is REQUIRED on lxml 6.x: both trafilatura (via justext) and
  # readability-lxml import lxml.html.clean, which moved to this separate package.
  /opt/readability/bin/pip install trafilatura==2.1.0 readability-lxml==0.8.4.1 lxml_html_clean==0.4.5
  ln -sf /opt/readability/bin/trafilatura /usr/local/bin/trafilatura
  # Fail provisioning if either package can't actually run (not just "pip said OK"). Full
  # paths: /usr/local/bin is not on this non-login pct-exec PATH.
  /opt/readability/bin/trafilatura --version >/dev/null 2>&1 \
    || { printf 'error: trafilatura CLI not runnable after install\n' >&2; exit 1; }
  /opt/readability/bin/python -c 'from readability import Document' >/dev/null 2>&1 \
    || { printf 'error: readability-lxml not importable after install\n' >&2; exit 1; }
  command -v gh >/dev/null 2>&1 \
    || { printf 'error: gh (GitHub CLI) not installed — kb-open-pr needs it\n' >&2; exit 1; }
fi

# 3. Point Hermes at the CT 120 runtime (custom OpenAI-compatible endpoint, no key).
# Prefer TARGET_BASE_URL (the stable hostname), but verify it resolves + answers FROM THIS
# container — the correct vantage point (the host/CT 120 resolve names this container may
# not, and vice-versa). Fall back to the discovered IP only if the hostname fails here. If
# curl is somehow unavailable, both tests are simply skipped and we keep the hostname.
install -d -m 700 "${HERMES_HOME}"
EFFECTIVE_BASE_URL="${TARGET_BASE_URL}"
if curl -fsS -m 5 -o /dev/null "${TARGET_BASE_URL}/models" 2>/dev/null; then
  printf 'model provider reachable at %s\n' "${TARGET_BASE_URL}"
elif [[ -n ${TARGET_BASE_URL_FALLBACK} ]] && curl -fsS -m 5 -o /dev/null "${TARGET_BASE_URL_FALLBACK}/models" 2>/dev/null; then
  printf 'note: %s not reachable from this container; using discovered IP %s instead\n' \
    "${TARGET_BASE_URL}" "${TARGET_BASE_URL_FALLBACK}" >&2
  EFFECTIVE_BASE_URL="${TARGET_BASE_URL_FALLBACK}"
else
  printf 'warning: neither %s nor the fallback answered now; writing %s — re-point model.base_url later if the model is unreachable\n' \
    "${TARGET_BASE_URL}" "${TARGET_BASE_URL}" >&2
fi
cat >"${HERMES_HOME}/config.yaml" <<YAML
model:
  default: ${MODEL_IDENTIFIER}
  provider: custom
  base_url: ${EFFECTIVE_BASE_URL}
  api_key: ""
  context_length: ${MODEL_CONTEXT_LENGTH}
providers:
  # Timeout for the main model call. CT 120 runs --parallel 2, so a 3rd concurrent request queues;
  # this keeps a queued request from tripping the OpenAI SDK's 600s default read timeout. The key
  # MUST be `custom` (== the resolved agent.provider for this endpoint).
  custom:
    request_timeout_seconds: ${MODEL_REQUEST_TIMEOUT_SECONDS}
terminal:
  backend: local
  # Run the agent from /root (a neutral home), not its install dir. Hermes auto-loads a project
  # context file (.hermes.md / AGENTS.md / ...) from the working dir on every prompt; without this it
  # falls back to the install dir and pulls its ~70 KB codebase AGENTS.md into every turn's context.
  cwd: /root
YAML

# 3b. Small project-context file for the agent's cwd (/root) — Hermes loads it as `.hermes.md` on
# every prompt now that terminal.cwd=/root, so keep it SHORT. It replaces the giant install-dir
# AGENTS.md that would otherwise be slurped + truncated each turn.
cat >/root/.hermes.md <<'HERMESMD'
# Homelab Hermes agent — quick context

You are the homelab **Hermes agent** on this Proxmox LXC. On every task:

- **Local model:** you run on the CT 120 LLM runtime (see `model.base_url` in `~/.hermes/config.yaml`)
  — a modest context window, so be economical with tokens.
- **Skills** live in `~/.hermes/skills`; prefer them over hand-rolled shell/git.
- **Knowledge base:** if the `knowledge-ingestion` skill is installed, use it to capture things into
  CognitiveStack (it dedups via kb-rag, authors a SCHEMA entry, and opens a PR — never hand-roll
  git/tokens; multiple items in one request → one PR).
- **Web fetch:** if the `web-extraction` skill is installed, use its `kb-fetch.sh <url>` for clean
  text; for GitHub repo metadata use `gh api ... --jq` (never pipe `curl` into `python3`/`sh`).
- **Secrets** live in `~/.hermes/.env` — never print or commit them.
HERMESMD

# 4. Secrets + API-server enablement live in .env (root-only). The bearer key is required
# even on loopback because the API exposes terminal access.
{
  printf 'API_SERVER_ENABLED=true\n'
  printf 'API_SERVER_KEY=%s\n' "${API_SERVER_KEY}"
  printf 'API_SERVER_HOST=0.0.0.0\n'
  printf 'API_SERVER_PORT=%s\n' "${API_SERVER_PORT}"
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
# HOME is set because `gh` (used by the KB-ingestion PR helper) fails on an unset HOME. The KB tokens
# are deliberately NOT loaded into the service env: the ingestion helpers (kb-open-pr.sh / kb-dedup.sh)
# source ${HERMES_HOME}/.env themselves, only when their specific key is needed — so secrets stay
# scoped to those short-lived helper processes (and pick up rotated keys immediately) rather than
# being inherited by every command the agent runs.
Environment=HOME=/root
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
# slow, so we poll for ~120s. On timeout we dump the service status + recent journal and
# exit NONZERO so the host aborts (it must not print "Done" over a dead service).
for _ in $(seq 1 60); do
  if curl -fsS -H "Authorization: Bearer ${API_SERVER_KEY}" \
      "http://127.0.0.1:${API_SERVER_PORT}/v1/models" >/dev/null 2>&1; then
    printf 'hermes API server is up on port %s\n' "${API_SERVER_PORT}"
    exit 0
  fi
  sleep 2
done

printf 'error: hermes API server did not answer /v1/models within ~120s\n' >&2
systemctl status hermes.service --no-pager --full >&2 || true
journalctl -u hermes.service --no-pager -n 80 >&2 || true
exit 1
CONTAINER_SCRIPT
  rc=$?

  # Best-effort: ensure the pushed secret file is gone even if the inner script failed
  # before it could delete itself (e.g. a transfer/startup error). Runs regardless of rc.
  pct exec "${VMID}" -- rm -f /root/.hermes-provision-secret >/dev/null 2>&1 || true

  return "${rc}"
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
  if ! install_and_configure; then
    printf '\n' >&2
    log "Hermes provisioning FAILED: the API server never came up on CT ${VMID}."
    printf 'The container exists but hermes.service is not healthy. Inspect it with:\n' >&2
    printf '  pct exec %s -- systemctl status hermes\n' "${VMID}" >&2
    printf '  pct exec %s -- journalctl -u hermes -n 100 --no-pager\n' "${VMID}" >&2
    printf 'API bearer key (save it; only shown here): %s\n' "${API_SERVER_KEY}" >&2
    exit 1
  fi
  print_summary
}

main "$@"
