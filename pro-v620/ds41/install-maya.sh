#!/usr/bin/env bash
# Install Project Maya (github.com/mw00/project-maya) for DeepSeek-V4.1-Flash-1017 into CT 127
# ds41-maya, on the UD-Q4_K_XL file CT 125 serves. Runs on the Proxmox HOST as root, from this
# directory, after create-lxc-ds41-engine.sh maya. Idempotent: Maya's own setup skips what is done.
#
#   ./install-maya.sh
#
# Steps: Maya's source at MAYA_COMMIT and llama.cpp at the commit Maya pins; a folder of links to
# the store's UD-Q4_K_XL shards (Maya writes its pack inside the model's folder, and the store is
# read-only in the container); then Maya's own setup, run without questions and without starting:
# the HIP engine (maya-ds4) for gfx1030, the pack, DeepSeek's DSpark drafter and vision tower
# (downloaded from DeepSeek's checkpoint at the revision Maya pins), and the config. Last, a
# disabled unit that starts that config on :1234.
#
# It needs no GPU: Maya's setup reads the cards from the kernel's KFD topology in sysfs, which
# lists both V620s in any container; --gpu 0 keeps it to one card, and every V620 is the same
# size. ds41-host.sh take 127 gives the container GPU 2 for a run. The build and the setup run at
# nice 19 on the CPUs CT 125 serves from.
set -Eeuo pipefail

VMID="${VMID:-127}"
AGENT_USER="${AGENT_USER:-agent}"
# A release and the commit its tag names, moved together.
MAYA_RELEASE="${MAYA_RELEASE:-v1.1.65}"
MAYA_COMMIT="${MAYA_COMMIT:-c81fab6c9d63cf69b928f92460e0a662b28aa9ec}"
# The llama.cpp commit Maya builds ggml from (setup.py's LLAMA_CPP_COMMIT at MAYA_COMMIT).
MAYA_GGML_COMMIT="${MAYA_GGML_COMMIT:-3cf03257f219afbe7334045ff7c6a06ac68c627d}"
MAYA_ROOT="${MAYA_ROOT:-/opt/maya-ds4}"
MAYA_HOME="${MAYA_HOME:-${MAYA_ROOT}/maya-${MAYA_RELEASE}}"
MAYA_GGML_DIR="${MAYA_GGML_DIR:-${MAYA_ROOT}/llama.cpp-${MAYA_GGML_COMMIT:0:8}}"
# The store's UD-Q4_K_XL (checked by size and SHA-256 when it was downloaded: UD-Q4_K_XL.verified).
UD_SRC="${UD_SRC:-/models/hf/deepseek-v4.1-flash-1017-ud-q4_k_xl/UD-Q4_K_XL}"
# Maya's models folder, writable: the links to the shards, the pack, the drafter and the tower.
MODELS="${MODELS:-/models-dev/maya-ds4}"
UD_DIR="${UD_DIR:-${MODELS}/DeepSeek-V4.1-Flash-1017-GGUF/UD-Q4_K_XL}"
# CT 125 serves a 262,144-token context with DSpark on and the vision tower.
CONTEXT="${CONTEXT:-262144}"
PORT="${PORT:-1234}"
UNIT="${UNIT:-maya-deepseek}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[ "$(pct status "$VMID" 2>/dev/null | awk '{print $2}')" = running ] || die "CT ${VMID} is not running"

ctenv=(env MAYA_RELEASE="$MAYA_RELEASE" MAYA_COMMIT="$MAYA_COMMIT" MAYA_GGML_COMMIT="$MAYA_GGML_COMMIT"
  MAYA_ROOT="$MAYA_ROOT" MAYA_HOME="$MAYA_HOME" MAYA_GGML_DIR="$MAYA_GGML_DIR" UD_SRC="$UD_SRC" MODELS="$MODELS"
  UD_DIR="$UD_DIR" CONTEXT="$CONTEXT" PORT="$PORT" UNIT="$UNIT" AGENT_USER="$AGENT_USER")

check_rocm() {
  log "ROCm for gfx1030"
  pct exec "$VMID" -- bash -lc 'echo "ROCM_PATH=${ROCM_PATH:-unset}"; test -d "${ROCM_PATH:-/nonexistent}/lib" && test -x "${ROCM_PATH}/lib/llvm/bin/clang++"' \
    || die "CT ${VMID} has no ROCm on its login paths; run create-lxc-ds41-engine.sh maya first"
}

install_source() {
  log "Maya ${MAYA_RELEASE} (${MAYA_COMMIT:0:12}) and llama.cpp ${MAYA_GGML_COMMIT:0:12}"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$MAYA_ROOT"
as_agent() { runuser -u "$AGENT_USER" -- "$@"; }
# The release tag must still name the commit pinned here.
tag="$(git ls-remote https://github.com/mw00/project-maya.git "refs/tags/${MAYA_RELEASE}^{}" "refs/tags/${MAYA_RELEASE}" | sort -k2 | tail -1 | cut -f1)"
[ "$tag" = "$MAYA_COMMIT" ] || { echo "FATAL: ${MAYA_RELEASE} is ${tag:-missing}, pinned ${MAYA_COMMIT}" >&2; exit 1; }
checkout() {   # <dir> <url> <commit>: a shallow checkout of exactly that commit, owned by the agent
  local dir="$1" url="$2" commit="$3"
  if [ -d "$dir/.git" ] && [ "$(as_agent git -C "$dir" rev-parse HEAD)" = "$commit" ]; then
    echo "${dir} at ${commit:0:12}"
    return
  fi
  [ ! -e "$dir/.git" ] || { echo "FATAL: ${dir} is at another commit; move it aside" >&2; exit 1; }
  as_agent install -d -m 0755 "$dir"
  as_agent git init -q "$dir"
  as_agent git -C "$dir" fetch -q --depth 1 "$url" "$commit"
  as_agent git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  [ "$(as_agent git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "FATAL: ${dir} is not at ${commit}" >&2; exit 1; }
  echo "${dir} at ${commit:0:12}"
}
checkout "$MAYA_HOME" https://github.com/mw00/project-maya.git "$MAYA_COMMIT"
pin="$(sed -n 's/^LLAMA_CPP_COMMIT = "\([0-9a-f]*\)"$/\1/p' "$MAYA_HOME/setup.py")"
[ "$pin" = "$MAYA_GGML_COMMIT" ] || { echo "FATAL: Maya ${MAYA_RELEASE} pins llama.cpp ${pin:-?}, not ${MAYA_GGML_COMMIT}" >&2; exit 1; }
checkout "$MAYA_GGML_DIR" https://github.com/ggml-org/llama.cpp.git "$MAYA_GGML_COMMIT"
CONTAINER_SCRIPT
}

link_model() {
  log "UD-Q4_K_XL's shards linked into ${UD_DIR}"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
[ -f "$(dirname "$UD_SRC")/UD-Q4_K_XL.verified" ] || { echo "FATAL: ${UD_SRC} is not verified" >&2; exit 1; }
runuser -u "$AGENT_USER" -- install -d -m 0755 "$UD_DIR"
n=0
for s in "$UD_SRC"/DeepSeek-V4.1-Flash-1017-UD-Q4_K_XL-0000?-of-00009.gguf; do
  ln -sfn "$s" "$UD_DIR/$(basename "$s")"
  n=$((n + 1))
done
[ "$n" -eq 9 ] || { echo "FATAL: ${UD_SRC} has ${n} of 9 shards" >&2; exit 1; }
chown -h "$AGENT_USER:$AGENT_USER" "$UD_DIR"/*.gguf
echo "${n} shards, $(du -shL "$UD_DIR" | cut -f1)"
CONTAINER_SCRIPT
}

run_setup() {
  log "Maya's setup: engine, pack, drafter, vision tower, config (at nice 19; the first run compiles for a while)"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
cd "$MAYA_HOME"
# A login shell for ROCm's paths (/etc/profile.d/rocm.sh); the setup's answers on the command line.
runuser -u "$AGENT_USER" -- nice -n 19 bash -lc "cd '$MAYA_HOME' && ./maya.sh --setup --no-start --yes --plain \
  --download-model --backend hip --gpu 0 --model DeepSeek-V4.1-Flash-1017 --ds4-quant gguf-q4 \
  --model-dir '$UD_DIR' --models-dir '$MODELS' --llama-dir '$MAYA_GGML_DIR' --context $CONTEXT \
  --drafting on --host 0.0.0.0 --port $PORT" 2>&1 | tee "$MAYA_ROOT/setup-$(date -u +%Y%m%dT%H%M%SZ).log"
CONTAINER_SCRIPT
}

install_unit() {
  log "unit ${UNIT} (disabled): the installed config on :${PORT}"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
cfg="$(ls -t "$MAYA_HOME"/run-maya-*.sh 2>/dev/null | head -1 || true)"
[ -n "$cfg" ] || { echo "FATAL: the setup wrote no run-maya-*.sh in ${MAYA_HOME}" >&2; exit 1; }
cat >"/etc/systemd/system/${UNIT}.service" <<UNITFILE
[Unit]
Description=Project Maya ${MAYA_RELEASE} (DeepSeek-V4.1-Flash UD-Q4_K_XL, HIP) on :${PORT}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${AGENT_USER}
Group=${AGENT_USER}
SupplementaryGroups=video render
WorkingDirectory=${MAYA_HOME}
Environment=HOME=/home/${AGENT_USER}
# The setup's own start script for its config (ROCm from the login profile)
ExecStart=/bin/bash -lc 'exec ${cfg}'
Restart=on-failure
RestartSec=30
TimeoutStartSec=3600
TimeoutStopSec=180
# The engine page-locks its RAM tier.
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
UNITFILE
systemctl daemon-reload
echo "${UNIT}: $(systemctl is-enabled "$UNIT" 2>&1 | head -1); start script ${cfg}"
CONTAINER_SCRIPT
}

show_state() {
  log "state"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
ok() { if eval "$2" >/dev/null 2>&1; then echo "  $1: ok"; else echo "  $1: MISSING"; fi; }
ok "engine maya-ds4" "test -x '${MAYA_HOME}/build/maya-ds4'"
ok "pack           " "ls -d '${UD_DIR}'/pack* "
ok "drafter        " "ls '${UD_DIR}/../dspark'/* "
ok "kfd            " "test -c /dev/kfd"
ls "$MAYA_HOME"/run-maya-*.sh 2>/dev/null | sed 's/^/  start script: /'
du -sh "$MAYA_ROOT" "$MODELS" 2>/dev/null | sed 's/^/  /'
CONTAINER_SCRIPT
}

main() {
  check_rocm
  install_source
  link_model
  run_setup
  install_unit
  show_state
}

main "$@"
