#!/usr/bin/env bash

set -Eeuo pipefail

# Create an unprivileged Debian LXC that runs MealDeal (github.com/marchah/mealdeal): a
# self-hosted grocery-deal tracker. One Node process serves the built SPA, the GraphQL API
# at /graphql, and (once IMAP is configured) the ingest cron in-process.
#
# The app ships a Dockerfile, but this homelab runs no Docker: the build steps are replayed
# natively here (pinned Node + pnpm), which is why NODE_/PNPM_ versions and the build
# pipeline below must be kept in step with mealdeal's own Dockerfile.
#
# Deploy model — release directories + a `current` symlink (the llama.cpp `current` idiom):
#   /opt/mealdeal/repo            git clone; the build workspace
#   /opt/mealdeal/releases/<sha>  a built, production-pruned release
#   /opt/mealdeal/current   ->    the release systemd runs
#   /var/lib/mealdeal/            SQLite DB — a SEPARATE backup=1 volume (see below)
# `mealdeal-update` builds a new release and only flips the symlink once the new release
# answers /graphql, so a bad upstream commit cannot take the service down: it rolls back.
#
# Backup split: /var/lib/mealdeal is a small mount point with backup=1 (mount points default
# to backup=0) holding the ONE thing that cannot be rebuilt — the deal database. Node,
# node_modules and the built releases are all reproducible from git. A container's ROOTFS
# cannot be excluded from vzdump (PVE rejects backup= on rootfs), so keep backups lean with
# `vzdump 110 --exclude-path /opt/mealdeal` rather than a rootfs flag.
#
# Extraction runs against the homelab's own LLM runtime (CT 120, llamacpp:1234) — no cloud
# API key. IMAP credentials are NOT baked in: provision leaves ingest disabled and prints
# the two lines to fill in, or pass IMAP_USER=/IMAP_PASSWORD= to arm it immediately.
#
# Run this script on the Proxmox host as root.

# --- Container config (override any via VAR=value) ---------------------------
# CT 110: the 100-119 infra/services range. MealDeal is an app, not an AI container —
# it only *consumes* CT 120's API (same relationship Hermes has).
VMID="${VMID:-110}"
LXC_HOSTNAME="${LXC_HOSTNAME:-mealdeal}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-}"
ROOT_STORAGE="${ROOT_STORAGE:-local-lvm}"
# Node toolchain + a full dev node_modules for the build + KEEP_RELEASES pruned releases.
ROOT_SIZE_GB="${ROOT_SIZE_GB:-20}"
# The Vite/tsup build is the memory peak, not the server (which idles well under 512 MB).
MEMORY_MB="${MEMORY_MB:-4096}"
SWAP_MB="${SWAP_MB:-2048}"
CORES="${CORES:-4}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONFIG="${IP_CONFIG:-dhcp}"
# Fixed MAC so the dnsmasq reservation (10.10.10.110 mealdeal) is deterministic and the
# :4000 port-forward keeps pointing at this container across reboots.
MAC="${MAC:-BC:24:11:C0:DE:10}"
PASSWORD="${PASSWORD:-}"
START_ON_BOOT="${START_ON_BOOT:-1}"

# Separate volume for the SQLite database, so the deal data can be backed up and restored on
# its own. Set DATA_SIZE_GB=0 to keep the DB on the rootfs instead.
DATA_STORAGE="${DATA_STORAGE:-${ROOT_STORAGE}}"
DATA_SIZE_GB="${DATA_SIZE_GB:-4}"
DATA_DIR="${DATA_DIR:-/var/lib/mealdeal}"

# --- App source --------------------------------------------------------------
APP_REPO_URL="${APP_REPO_URL:-https://github.com/marchah/mealdeal.git}"
APP_BRANCH="${APP_BRANCH:-main}"
APP_PORT="${APP_PORT:-4000}"
# Built releases retained for rollback (the live one always counts as one of them).
KEEP_RELEASES="${KEEP_RELEASES:-3}"

# --- Pinned toolchain -------------------------------------------------------
# Official prebuilt linux-x64 tarball, verified by SHA-256 (no NodeSource `curl | bash`;
# matches the repo's llama.cpp/Node pinning). Bump VERSION + SHA256 together from
# https://nodejs.org/dist/<VERSION>/SHASUMS256.txt (the node-<VERSION>-linux-x64.tar.xz line).
NODE_VERSION="${NODE_VERSION:-v26.5.0}"
NODE_SHA256="${NODE_SHA256:-9f619528f1db5ddc41dccf54211066fb42228d69a156733c69cb9d6cc92e358c}"
# MUST match mealdeal's package.json "packageManager" field.
PNPM_VERSION="${PNPM_VERSION:-11.13.1}"

# --- Model endpoint (CT 120, by dnsmasq name — not a hard-coded IP) ---------
TARGET_HOSTNAME="${TARGET_HOSTNAME:-llamacpp}"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://${TARGET_HOSTNAME}:1234/v1}"
OPENAI_MODEL="${OPENAI_MODEL:-qwen3.6-35b-a3b}"
OPENAI_API_KEY="${OPENAI_API_KEY:-not-needed}"

# --- IMAP mailbox to ingest -------------------------------------------------
# Leave USER/PASSWORD empty (the default) and provisioning writes the env file with
# INGEST_INLINE=0: the web app + API come up clean and ingest stays off until you fill
# in /etc/mealdeal.env. Pass both to arm ingest at provision time instead.
IMAP_HOST="${IMAP_HOST:-imap.gmail.com}"
IMAP_PORT="${IMAP_PORT:-993}"
IMAP_SECURE="${IMAP_SECURE:-true}"
IMAP_USER="${IMAP_USER:-}"
IMAP_PASSWORD="${IMAP_PASSWORD:-}"
IMAP_MAILBOX="${IMAP_MAILBOX:-INBOX}"

# --- Ingest ------------------------------------------------------------------
INGEST_CRON="${INGEST_CRON:-*/30 * * * *}"
INGEST_BATCH="${INGEST_BATCH:-25}"
# Bearer token guarding POST /internal/ingest (the manual trigger). Empty -> generated.
INGEST_TOKEN="${INGEST_TOKEN:-}"
# Optional: keep each ingested email's canonical Markdown for offline extractor work.
INGEST_ARCHIVE_DIR="${INGEST_ARCHIVE_DIR:-}"

# --- Geocoding / location ---------------------------------------------------
# The public Nominatim default is capped at ~4 req/min and receives any merchant address
# the newsletters state; point this at a self-hosted geocoder to keep addresses internal.
GEOCODER_BASE_URL="${GEOCODER_BASE_URL:-https://nominatim.openstreetmap.org}"
GEOCODER_USER_AGENT="${GEOCODER_USER_AGENT:-MealDeal/0.1 (+https://github.com/marchah/mealdeal)}"
# Optional five-digit US ZIP for near-me features.
USER_LOCATION="${USER_LOCATION:-}"

usage() {
  cat <<'USAGE'
Create the MealDeal LXC (CT 110): a self-hosted grocery-deal tracker — one Node process
serving the SPA + GraphQL API + in-process ingest cron, with SQLite on a backed-up volume.

Run this script on the Proxmox host as root.

Useful overrides:
  VMID=110 LXC_HOSTNAME=mealdeal ./create-lxc-mealdeal.sh
  APP_BRANCH=main APP_PORT=4000 ./create-lxc-mealdeal.sh
  IMAP_USER=you@gmail.com IMAP_PASSWORD='app password' ./create-lxc-mealdeal.sh  # arm ingest now
  OPENAI_BASE_URL=http://gpu2:8080/v1 OPENAI_MODEL=qwen3.6-35b-a3b ./create-lxc-mealdeal.sh
  NODE_VERSION=v26.5.0 NODE_SHA256=<linux-x64 sha> PNPM_VERSION=11.13.1 ./create-lxc-mealdeal.sh
  DATA_SIZE_GB=0 ./create-lxc-mealdeal.sh   # keep the DB on the rootfs (no separate volume)
  MEMORY_MB=6144 CORES=6 ./create-lxc-mealdeal.sh

Builds mealdeal from git into /opt/mealdeal/releases/<sha> and points /opt/mealdeal/current
at it. Update later with:  pct exec 110 -- mealdeal-update   (builds, health-checks, and
rolls back on failure). Ingest is DISABLED unless IMAP_USER + IMAP_PASSWORD are supplied.
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

validate_config() {
  # Fail before creating anything, not halfway through a build.
  [[ ${APP_PORT} =~ ^[0-9]+$ ]] || die "APP_PORT must be numeric (got '${APP_PORT}')"
  [[ ${KEEP_RELEASES} =~ ^[0-9]+$ && ${KEEP_RELEASES} -ge 1 ]] \
    || die "KEEP_RELEASES must be an integer >= 1 (got '${KEEP_RELEASES}')"
  [[ ${DATA_SIZE_GB} =~ ^[0-9]+$ ]] || die "DATA_SIZE_GB must be an integer (0 disables the volume)"
  [[ -n ${GEOCODER_USER_AGENT} ]] || die "GEOCODER_USER_AGENT must identify this installation"
  if [[ -n ${USER_LOCATION} && ! ${USER_LOCATION} =~ ^[0-9]{5}$ ]]; then
    die "USER_LOCATION must be a five-digit US ZIP code (got '${USER_LOCATION}')"
  fi
  # Half-configured IMAP silently disables ingest in the app; refuse it loudly here.
  if [[ -n ${IMAP_USER} && -z ${IMAP_PASSWORD} ]] || [[ -z ${IMAP_USER} && -n ${IMAP_PASSWORD} ]]; then
    die "set BOTH IMAP_USER and IMAP_PASSWORD, or neither (ingest starts disabled)"
  fi
}

maybe_generate_ingest_token() {
  if [[ -z ${INGEST_TOKEN} ]]; then
    INGEST_TOKEN="$(openssl rand -hex 16)"
  fi
}

# 1 when ingest should be scheduled in-process at boot (IMAP fully configured).
ingest_inline() {
  if [[ -n ${IMAP_USER} && -n ${IMAP_PASSWORD} ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

create_container() {
  local ostemplate rootfs net0
  local -a create_args

  ostemplate="$(template_ref)"
  rootfs="${ROOT_STORAGE}:${ROOT_SIZE_GB}"
  net0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG},type=veth,hwaddr=${MAC}"

  log "Creating mealdeal LXC ${VMID} (${LXC_HOSTNAME})"

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

  pct set "${VMID}" --tags mealdeal >/dev/null 2>&1 || true

  # NOTE: unlike the other containers here, the rootfs is NOT set backup=0 — a container's
  # root disk cannot be excluded from vzdump at all. PVE rejects the property outright
  # ("rootfs.backup: property is not defined in schema"), so the append-backup=0 idiom used
  # elsewhere in this repo is a silent no-op. Only MOUNT POINTS carry a backup flag.
  # To keep backups lean, exclude the rebuildable tree in the backup job instead:
  #   vzdump 110 --exclude-path /opt/mealdeal
  #
  # The database is the one thing that cannot be rebuilt, so it gets its own mount point with
  # backup=1 — explicitly, because mount points default to backup=0 (the inverse of rootfs).
  # Attached before first start so it is mounted when the service is installed.
  if [[ ${DATA_SIZE_GB} -gt 0 ]]; then
    log "Attaching ${DATA_SIZE_GB}G data volume at ${DATA_DIR} (backup=1)"
    pct set "${VMID}" --mp0 "${DATA_STORAGE}:${DATA_SIZE_GB},mp=${DATA_DIR},backup=1" \
      || die "failed to attach the data volume"
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

# Render /etc/mealdeal.env on the HOST and push it mode-600, so IMAP_PASSWORD and the ingest
# token never travel through argv or the environment of a `pct exec` (visible in ps).
push_env_file() {
  local tmp inline
  inline="$(ingest_inline)"

  tmp="$(mktemp)" || die "mktemp failed"
  chmod 600 "${tmp}"

  cat >"${tmp}" <<ENV
# MealDeal runtime environment — read by mealdeal.service (EnvironmentFile) and the
# mealdeal-* wrappers. Written by mealdeal/create-lxc-mealdeal.sh; safe to hand-edit,
# then: systemctl restart mealdeal
#
# This file holds the IMAP password. Keep it mode 600.

NODE_ENV=production
PORT=${APP_PORT}
# The built SPA that this release serves (follows the release symlink).
WEB_DIR=/opt/mealdeal/current/web
DATABASE_URL=file:${DATA_DIR}/mealdeal.db
# Resolved relative to WorkingDirectory (=/opt/mealdeal/current), per the app's migrator.
MIGRATIONS_DIR=drizzle

# Deal extraction — the homelab's own LLM runtime (CT 120), reached by dnsmasq name.
OPENAI_BASE_URL=${OPENAI_BASE_URL}
OPENAI_API_KEY=${OPENAI_API_KEY}
OPENAI_MODEL=${OPENAI_MODEL}

# Merchant address geocoding.
GEOCODER_BASE_URL=${GEOCODER_BASE_URL}
GEOCODER_USER_AGENT=${GEOCODER_USER_AGENT}

# Mailbox to ingest. IMAP_USER/IMAP_PASSWORD empty => the app disables ingest entirely
# (settings.IMAP is null). Fill both in, set INGEST_INLINE=1, then restart the service.
IMAP_HOST=${IMAP_HOST}
IMAP_PORT=${IMAP_PORT}
IMAP_SECURE=${IMAP_SECURE}
IMAP_USER=${IMAP_USER}
IMAP_PASSWORD=${IMAP_PASSWORD}
IMAP_MAILBOX=${IMAP_MAILBOX}

# INGEST_INLINE=0 disables the in-process scheduler (anything but the string "0" enables it).
INGEST_INLINE=${inline}
INGEST_CRON=${INGEST_CRON}
INGEST_BATCH=${INGEST_BATCH}
INGEST_SOURCE=imap
INGEST_ARCHIVE_DIR=${INGEST_ARCHIVE_DIR}
# Bearer token for the manual trigger: POST /internal/ingest (used by mealdeal-ingest).
INGEST_TOKEN=${INGEST_TOKEN}

# Optional five-digit US ZIP for near-me features.
USER_LOCATION=${USER_LOCATION}
ENV

  log "Pushing /etc/mealdeal.env (mode 600)"
  if ! pct push "${VMID}" "${tmp}" /etc/mealdeal.env --perms 0600; then
    rm -f "${tmp}"
    die "failed to push /etc/mealdeal.env"
  fi
  rm -f "${tmp}"
}

install_and_configure() {
  log "Installing Node ${NODE_VERSION} + pnpm ${PNPM_VERSION}, building mealdeal, wiring systemd"

  pct exec "${VMID}" -- bash -s -- \
    "${APP_REPO_URL}" \
    "${APP_BRANCH}" \
    "${NODE_VERSION}" \
    "${NODE_SHA256}" \
    "${PNPM_VERSION}" \
    "${KEEP_RELEASES}" \
    "${DATA_DIR}" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

APP_REPO_URL="$1"
APP_BRANCH="$2"
NODE_VERSION="$3"
NODE_SHA256="$4"
PNPM_VERSION="$5"
KEEP_RELEASES="$6"
DATA_DIR="$7"

export DEBIAN_FRONTEND=noninteractive

# 1. Base packages. Deliberately NO build-essential/python3: mealdeal's own Dockerfile
#    builds on node:26-slim, which has no compiler, so every dependency resolves to a
#    prebuilt binary. xz-utils unpacks the Node tarball, and libatomic1 is a hard runtime
#    dependency of the official Node linux-x64 build that the Debian LXC template does NOT
#    ship (node:26-slim does) — without it every `node` call dies with
#    "libatomic.so.1: cannot open shared object file".
apt-get update
apt-get install -y ca-certificates curl git xz-utils libatomic1

# 2. Pinned Node from the official tarball, SHA-256 verified. Versioned dir + a `current`
#    symlink (the /opt/llamacpp/current idiom), so a Node bump is a symlink flip.
install -d -m 755 /opt/node
node_tarball="/tmp/node-${NODE_VERSION}-linux-x64.tar.xz"
curl -fsSL -o "${node_tarball}" \
  "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz"
echo "${NODE_SHA256}  ${node_tarball}" | sha256sum -c - \
  || { echo "error: Node tarball SHA-256 mismatch — refusing to install" >&2; exit 1; }
tar -C /opt/node -xJf "${node_tarball}"
rm -f "${node_tarball}"
ln -sfn "/opt/node/node-${NODE_VERSION}-linux-x64" /opt/node/current
for b in node npm npx; do
  ln -sfn "/opt/node/current/bin/${b}" "/usr/local/bin/${b}"
done
# `pct exec` runs a non-login shell whose PATH omits /usr/local/bin (a repo-wide gotcha — see
# CLAUDE.md), and Node's own bin dir is on neither. Put both in reach for the rest of this
# script, so the npm/pnpm calls below do not depend on the caller's PATH.
export PATH="/opt/node/current/bin:/usr/local/bin:${PATH}"
# Node 26 no longer bundles corepack — install the pinned pnpm directly (as the Dockerfile does).
npm install -g "pnpm@${PNPM_VERSION}" >/dev/null
ln -sfn /opt/node/current/bin/pnpm /usr/local/bin/pnpm
node --version
pnpm --version

# 3. Unprivileged service account. The app needs write access to the database directory
#    only; the release tree stays root-owned and read-only to it.
id -u mealdeal >/dev/null 2>&1 || useradd --system --home-dir /nonexistent \
  --shell /usr/sbin/nologin mealdeal
install -d -m 755 /opt/mealdeal /opt/mealdeal/releases
# DATA_DIR is a mount point when a data volume is attached; either way, make it writable
# by the service account (SQLite writes -wal/-shm siblings, so the DIRECTORY must be writable).
install -d -m 750 -o mealdeal -g mealdeal "${DATA_DIR}"

# 4. Deploy knobs the mealdeal-* wrappers read. Non-secret (mode 644); the app's own
#    environment — including the IMAP password — lives in the mode-600 /etc/mealdeal.env.
cat >/etc/mealdeal-deploy.env <<DEPLOY
# Deploy-time configuration for the mealdeal-* wrapper commands. Non-secret.
MEALDEAL_REPO_URL=${APP_REPO_URL}
MEALDEAL_BRANCH=${APP_BRANCH}
MEALDEAL_ROOT=/opt/mealdeal
MEALDEAL_KEEP_RELEASES=${KEEP_RELEASES}
DEPLOY
chmod 644 /etc/mealdeal-deploy.env

# 5. Clone the app. Shallow history is enough — releases are identified by commit sha and
#    `mealdeal-update` fetches what it needs.
if [[ ! -d /opt/mealdeal/repo/.git ]]; then
  git clone --branch "${APP_BRANCH}" "${APP_REPO_URL}" /opt/mealdeal/repo
fi

# 6. Health probe, shared by the service check and the update/rollback paths. The app has no
#    /health route, so probe GraphQL: a `{__typename}` reply proves the HTTP server is up AND
#    the schema built AND startup migrations completed (main() migrates before it listens).
cat >/usr/local/bin/mealdeal-health <<'SH'
#!/usr/bin/env bash
# Exit 0 once the running service answers GraphQL. Usage: mealdeal-health [timeout-seconds]
set -Eeuo pipefail

timeout="${1:-90}"
port="$(sed -n 's/^PORT=//p' /etc/mealdeal.env | tail -n 1)"
port="${port:-4000}"

deadline=$((SECONDS + timeout))
while ((SECONDS < deadline)); do
  if curl -fsS --max-time 5 "http://127.0.0.1:${port}/graphql" \
      -H 'content-type: application/json' \
      -d '{"query":"{__typename}"}' 2>/dev/null | grep -q '"__typename":"Query"'; then
    exit 0
  fi
  sleep 2
done

printf 'mealdeal did not answer GraphQL on port %s within %ss\n' "${port}" "${timeout}" >&2
exit 1
SH

# 7. The update path: build a release, flip the symlink, verify, roll back on failure.
#    Provisioning uses this same script for the FIRST build, so the update path is exercised
#    on day one rather than discovered to be broken on the first upgrade.
cat >/usr/local/bin/mealdeal-update <<'SH'
#!/usr/bin/env bash
# Build and deploy a mealdeal release from git.
#
#   mealdeal-update              fetch the tracked branch; build + deploy if the sha moved
#   mealdeal-update --check      report only; exit 10 if an update is available
#   mealdeal-update --force      rebuild + redeploy even if the sha has not moved
#   mealdeal-update --ref <ref>  deploy a specific branch, tag, or commit
#
# The live release is only replaced once the new one answers GraphQL; otherwise the previous
# release is restored. A failed BUILD never touches the running service at all.
set -Eeuo pipefail

# shellcheck source=/dev/null
. /etc/mealdeal-deploy.env

ROOT="${MEALDEAL_ROOT:-/opt/mealdeal}"
REPO="${ROOT}/repo"
RELEASES="${ROOT}/releases"
CURRENT="${ROOT}/current"
KEEP="${MEALDEAL_KEEP_RELEASES:-3}"

check_only=0
force=0
ref="${MEALDEAL_BRANCH:-main}"
explicit_ref=0

while (($#)); do
  case "$1" in
    --check) check_only=1 ;;
    --force) force=1 ;;
    --ref)
      shift
      [[ -n ${1:-} ]] || { echo "error: --ref needs a value" >&2; exit 2; }
      ref="$1"
      explicit_ref=1
      ;;
    -h | --help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# A bare `pct exec 110 -- mealdeal-update` (and a systemd timer) runs with a PATH that omits
# /usr/local/bin and Node's bin dir — the repo-wide gotcha. Never rely on the caller's PATH.
export PATH="/opt/node/current/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

command -v pnpm >/dev/null 2>&1 || die "pnpm not on PATH"
# pnpm needs HOME for its content-addressed store; a systemd timer or a bare `pct exec`
# can invoke this with HOME unset.
export HOME="${HOME:-/root}"

log "Fetching ${MEALDEAL_REPO_URL:-origin} (${ref})"
git -C "${REPO}" fetch --prune --tags origin

# Resolve the requested ref: a bare branch name resolves against the remote so the tracked
# branch follows upstream, while an explicit tag/sha is honoured as given.
if ((explicit_ref)); then
  target="$(git -C "${REPO}" rev-parse --verify "origin/${ref}^{commit}" 2>/dev/null \
    || git -C "${REPO}" rev-parse --verify "${ref}^{commit}" 2>/dev/null)" \
    || die "cannot resolve ref '${ref}'"
else
  target="$(git -C "${REPO}" rev-parse --verify "origin/${ref}^{commit}" 2>/dev/null)" \
    || die "cannot resolve branch 'origin/${ref}'"
fi
target_short="${target:0:12}"

live=""
if [[ -L ${CURRENT} ]]; then
  live="$(basename "$(readlink -f "${CURRENT}")")"
fi

if [[ ${live} == "${target_short}" ]] && ((!force)); then
  log "Already on ${target_short} ($(git -C "${REPO}" log -1 --format=%s "${target}")) — nothing to do"
  exit 0
fi

if ((check_only)); then
  log "Update available: ${live:-<none>} -> ${target_short}"
  git -C "${REPO}" log --oneline "${live:+${live}..}${target}" 2>/dev/null | sed 's/^/    /' || true
  exit 10
fi

release="${RELEASES}/${target_short}"
# `pnpm deploy` creates its target itself and expects to sit inside the workspace, so stage
# there and rename into the release dir afterwards (same filesystem => instant rename).
# Untracked, and outside the packages/* workspace globs, so no build sees it.
staging="${REPO}/.deploy-staging"

log "Building ${target_short} ($(git -C "${REPO}" log -1 --format=%s "${target}"))"
# --force discards any local scribbles; node_modules is untracked and deliberately kept
# (pnpm reconciles it from the lockfile, which is much faster than a clean install).
git -C "${REPO}" checkout --force --detach "${target}"

# Mirror mealdeal's Dockerfile build, in order: install -> schema -> codegen -> web -> api.
cd "${REPO}"
pnpm install --frozen-lockfile
pnpm --filter @mealdeal/api build-schema
pnpm --filter @mealdeal/web gen
pnpm --filter @mealdeal/web build
pnpm --filter @mealdeal/api build

# Production-pruned deployment (dist + prod node_modules + drizzle migrations), then the
# built SPA alongside it — the same layout the Dockerfile's runtime stage assembles.
rm -rf "${staging}"
pnpm --filter @mealdeal/api deploy --prod --legacy "${staging}"
cp -r "${REPO}/packages/web/dist" "${staging}/web"
[[ -f ${staging}/dist/server.js ]] || die "build produced no dist/server.js"
[[ -d ${staging}/drizzle ]] || die "build produced no drizzle/ migrations directory"
[[ -f ${staging}/web/index.html ]] || die "build produced no web/index.html"

# Work out the rollback target BEFORE disturbing anything on disk.
previous=""
if [[ -n ${live} && ${live} != "${target_short}" && -d ${RELEASES}/${live} ]]; then
  # Normal upgrade: roll back to whatever is running.
  previous="${RELEASES}/${live}"
fi

if [[ -d ${release} ]]; then
  # This sha was already built (a --force rebuild, or redeploying a retained release). Move the
  # old tree ASIDE rather than deleting it: it may be the LIVE one, and deleting a running
  # release's files would leave nothing to fall back to if the new build turns out to be bad.
  rm -rf "${release}.previous"
  mv "${release}" "${release}.previous"
  [[ -n ${previous} ]] || previous="${release}.previous"
fi
mv "${staging}" "${release}"

# Atomic symlink swap (ln -sfn is unlink+symlink; mv -T renames over it in one step).
log "Activating ${target_short}"
ln -sfn "${release}" "${CURRENT}.new"
mv -Tf "${CURRENT}.new" "${CURRENT}"

systemctl restart mealdeal

if /usr/local/bin/mealdeal-health 90; then
  log "Healthy on ${target_short}"
else
  printf 'error: %s failed its health check\n' "${target_short}" >&2
  journalctl -u mealdeal -n 60 --no-pager >&2 || true
  if [[ -n ${previous} ]]; then
    printf '==> Rolling back to %s\n' "$(basename "${previous}")" >&2
    ln -sfn "${previous}" "${CURRENT}.new"
    mv -Tf "${CURRENT}.new" "${CURRENT}"
    systemctl restart mealdeal
    if /usr/local/bin/mealdeal-health 90; then
      printf '==> Rolled back; service healthy on %s\n' "$(basename "${previous}")" >&2
    else
      printf 'error: rollback to %s is ALSO unhealthy — service is down\n' \
        "$(basename "${previous}")" >&2
    fi
  else
    printf 'error: no previous release to roll back to — service is down\n' >&2
  fi
  exit 1
fi

# Prune old releases, newest first, never touching the live one.
live_path="$(readlink -f "${CURRENT}")"
mapfile -t stale < <(
  find "${RELEASES}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -rn | awk '{print $2}' | grep -vxF "${live_path}" | tail -n "+${KEEP}"
)
for dir in "${stale[@]}"; do
  [[ -n ${dir} ]] || continue
  log "Pruning old release $(basename "${dir}")"
  rm -rf "${dir}"
done
SH

# 8. Roll back to a retained release without rebuilding (the fast lane when a deploy looked
#    healthy but misbehaves later).
cat >/usr/local/bin/mealdeal-rollback <<'SH'
#!/usr/bin/env bash
# Activate a previously built release. Usage: mealdeal-rollback [<sha>]
# With no argument, picks the most recent retained release that is not live.
set -Eeuo pipefail

# shellcheck source=/dev/null
. /etc/mealdeal-deploy.env
ROOT="${MEALDEAL_ROOT:-/opt/mealdeal}"
RELEASES="${ROOT}/releases"
CURRENT="${ROOT}/current"

live_path="$(readlink -f "${CURRENT}" 2>/dev/null || true)"

if [[ -n ${1:-} ]]; then
  target="${RELEASES}/$1"
  [[ -d ${target} ]] || { echo "error: no such release: $1" >&2;
    echo "available:" >&2; ls -1 "${RELEASES}" >&2; exit 1; }
else
  target="$(
    find "${RELEASES}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
      | sort -rn | awk '{print $2}' | grep -vxF "${live_path:-/nonexistent}" | head -n 1
  )"
  [[ -n ${target} ]] || { echo "error: no other release retained to roll back to" >&2; exit 1; }
fi

printf '==> Activating %s\n' "$(basename "${target}")"
ln -sfn "${target}" "${CURRENT}.new"
mv -Tf "${CURRENT}.new" "${CURRENT}"
systemctl restart mealdeal
exec /usr/local/bin/mealdeal-health 90
SH

# 9. Status + manual ingest trigger.
cat >/usr/local/bin/mealdeal-status <<'SH'
#!/usr/bin/env bash
# Summarize what is deployed and whether ingest is armed.
set -Eeuo pipefail

# shellcheck source=/dev/null
. /etc/mealdeal-deploy.env
ROOT="${MEALDEAL_ROOT:-/opt/mealdeal}"
port="$(sed -n 's/^PORT=//p' /etc/mealdeal.env | tail -n 1)"; port="${port:-4000}"
db="$(sed -n 's/^DATABASE_URL=file://p' /etc/mealdeal.env | tail -n 1)"
live="$(basename "$(readlink -f "${ROOT}/current" 2>/dev/null || echo none)")"

printf 'release:    %s\n' "${live}"
printf 'commit:     %s\n' \
  "$(git -C "${ROOT}/repo" log -1 --format='%h %s (%cr)' "${live}" 2>/dev/null || echo unknown)"
printf 'branch:     %s\n' "${MEALDEAL_BRANCH:-main}"
printf 'service:    %s\n' "$(systemctl is-active mealdeal 2>/dev/null || true)"
printf 'endpoint:   http://%s:%s  (GraphQL at /graphql)\n' "$(hostname -I | awk '{print $1}')" "${port}"
if /usr/local/bin/mealdeal-health 5 >/dev/null 2>&1; then
  printf 'health:     ok\n'
else
  printf 'health:     FAILING\n'
fi

imap_user="$(sed -n 's/^IMAP_USER=//p' /etc/mealdeal.env | tail -n 1)"
inline="$(sed -n 's/^INGEST_INLINE=//p' /etc/mealdeal.env | tail -n 1)"
if [[ -z ${imap_user} ]]; then
  printf 'ingest:     DISABLED (no IMAP_USER in /etc/mealdeal.env)\n'
elif [[ ${inline} == 0 ]]; then
  printf 'ingest:     configured for %s but INGEST_INLINE=0 (scheduler off)\n' "${imap_user}"
else
  printf 'ingest:     every "%s" as %s\n' \
    "$(sed -n 's/^INGEST_CRON=//p' /etc/mealdeal.env | tail -n 1)" "${imap_user}"
fi

if [[ -n ${db} && -f ${db} ]]; then
  printf 'database:   %s (%s)\n' "${db}" "$(du -h "${db}" | awk '{print $1}')"
else
  printf 'database:   %s (not created yet)\n' "${db:-unset}"
fi
printf 'releases:   %s\n' \
  "$(find "${ROOT}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
SH

cat >/usr/local/bin/mealdeal-ingest <<'SH'
#!/usr/bin/env bash
# Trigger one ingest pass now (token-gated POST /internal/ingest) and print the result.
set -Eeuo pipefail

port="$(sed -n 's/^PORT=//p' /etc/mealdeal.env | tail -n 1)"; port="${port:-4000}"
token="$(sed -n 's/^INGEST_TOKEN=//p' /etc/mealdeal.env | tail -n 1)"
[[ -n ${token} ]] || { echo "error: INGEST_TOKEN is unset in /etc/mealdeal.env" >&2; exit 1; }

curl -fsS --max-time 900 -X POST "http://127.0.0.1:${port}/internal/ingest" \
  -H "x-ingest-token: ${token}" -H 'content-type: application/json'
printf '\n'
SH

chmod +x /usr/local/bin/mealdeal-health /usr/local/bin/mealdeal-update \
  /usr/local/bin/mealdeal-rollback /usr/local/bin/mealdeal-status /usr/local/bin/mealdeal-ingest

# 10. systemd unit. WorkingDirectory is the release symlink (re-resolved on every restart),
#     which is what makes MIGRATIONS_DIR=drizzle and the symlink flip work together.
cat >/etc/systemd/system/mealdeal.service <<'SERVICE'
[Unit]
Description=MealDeal — grocery-deal API + SPA (GraphQL at /graphql)
Documentation=https://github.com/marchah/mealdeal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mealdeal
Group=mealdeal
EnvironmentFile=/etc/mealdeal.env
WorkingDirectory=/opt/mealdeal/current
ExecStart=/usr/local/bin/node dist/server.js
Restart=on-failure
RestartSec=10
# The service only ever writes the database directory; ReadWritePaths is set from the
# DATABASE_URL directory by the installer (see the drop-in below).
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
SERVICE

install -d -m 755 /etc/systemd/system/mealdeal.service.d
cat >/etc/systemd/system/mealdeal.service.d/10-data-dir.conf <<DROPIN
[Service]
ReadWritePaths=${DATA_DIR}
DROPIN

# 11. First build. This runs the real update path, so a green provision proves upgrades work.
#     mealdeal-update restarts the service; enable it first so the restart starts it.
systemctl daemon-reload
systemctl enable mealdeal.service >/dev/null

/usr/local/bin/mealdeal-update --force

# 12. Report loudly if the service is not actually up (a green build is not a green service).
if ! /usr/local/bin/mealdeal-health 30 >/dev/null 2>&1; then
  echo "error: mealdeal built but is not answering GraphQL" >&2
  systemctl status mealdeal.service --no-pager --full >&2 || true
  journalctl -u mealdeal.service --no-pager -n 80 >&2 || true
  exit 1
fi

/usr/local/bin/mealdeal-status
CONTAINER_SCRIPT
}

print_summary() {
  local ip inline
  ip="$(pct exec "${VMID}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  inline="$(ingest_inline)"

  log "Done"
  printf 'mealdeal LXC: %s (%s)\n' "${VMID}" "${LXC_HOSTNAME}"
  if [[ -n ${ip} ]]; then
    printf 'Web + GraphQL: http://%s:%s   (GraphQL at /graphql)\n' "${ip}" "${APP_PORT}"
  fi
  printf 'By name (dnsmasq, from other containers): http://%s:%s\n' "${LXC_HOSTNAME}" "${APP_PORT}"
  printf 'Model endpoint: %s (model "%s")\n' "${OPENAI_BASE_URL}" "${OPENAI_MODEL}"
  printf 'Database: %s/mealdeal.db' "${DATA_DIR}"
  if [[ ${DATA_SIZE_GB} -gt 0 ]]; then
    printf ' (mp0, %sG, backup=1)\n' "${DATA_SIZE_GB}"
  else
    printf ' (on the rootfs)\n'
  fi
  printf 'Ingest trigger token: %s\n' "${INGEST_TOKEN}"

  # The mealdeal-* wrappers live in /usr/local/bin, which a BARE `pct exec` PATH omits — hence
  # the `bash -lc` wrapper on every one of them (repo-wide convention; see CLAUDE.md).
  printf '\nOperate:\n'
  printf "  Status:          pct exec %s -- bash -lc 'mealdeal-status'\n" "${VMID}"
  printf "  Update to main:  pct exec %s -- bash -lc 'mealdeal-update'\n" "${VMID}"
  printf "  Check only:      pct exec %s -- bash -lc 'mealdeal-update --check'\n" "${VMID}"
  printf "  Roll back:       pct exec %s -- bash -lc 'mealdeal-rollback'\n" "${VMID}"
  printf '  Logs:            pct exec %s -- journalctl -u mealdeal -n 100 --no-pager\n' "${VMID}"

  if [[ ${inline} == 0 ]]; then
    printf '\n⚠️  Ingest is DISABLED — no IMAP credentials were supplied. To enable it:\n'
    printf '  1. pct exec %s -- nano /etc/mealdeal.env\n' "${VMID}"
    printf '       IMAP_HOST=%s\n' "${IMAP_HOST}"
    printf '       IMAP_USER=<the mailbox address>\n'
    printf '       IMAP_PASSWORD=<app password, not your account password>\n'
    printf '       INGEST_INLINE=1\n'
    printf '  2. pct exec %s -- systemctl restart mealdeal\n' "${VMID}"
    printf "  3. pct exec %s -- bash -lc 'mealdeal-ingest'   # one pass now; prints the counts\n" "${VMID}"
  else
    printf '\nIngest is ARMED for %s on schedule "%s".\n' "${IMAP_USER}" "${INGEST_CRON}"
    printf "  Run one pass now: pct exec %s -- bash -lc 'mealdeal-ingest'\n" "${VMID}"
  fi

  printf '\nReach it from the LAN by adding to host-net/wifi-nat/wifi-nat.env:\n'
  printf '  RESERVATIONS  += "%s 10.10.10.%s %s"\n' "${MAC}" "${VMID}" "${LXC_HOSTNAME}"
  printf '  PORT_FORWARDS += "tcp %s 10.10.10.%s %s"\n' "${APP_PORT}" "${VMID}" "${APP_PORT}"
  printf '  then: /root/wifi-nat/install.sh --reload-dns && /root/wifi-nat/install.sh --reload-nft\n'
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
  validate_config
  assert_vmid_available
  resolve_template
  download_template_if_missing
  maybe_generate_ingest_token
  create_container
  start_container
  wait_for_container
  push_env_file

  if ! install_and_configure; then
    printf '\n' >&2
    log "mealdeal provisioning FAILED on CT ${VMID}."
    printf 'The container exists but the service is not healthy. Inspect it with:\n' >&2
    printf '  pct exec %s -- systemctl status mealdeal\n' "${VMID}" >&2
    printf '  pct exec %s -- journalctl -u mealdeal -n 100 --no-pager\n' "${VMID}" >&2
    printf '  pct exec %s -- mealdeal-update --force   # re-run the build\n' "${VMID}" >&2
    printf 'Ingest trigger token (save it; only shown here): %s\n' "${INGEST_TOKEN}" >&2
    exit 1
  fi

  print_summary
}

main "$@"
