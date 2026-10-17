#!/usr/bin/env bash
# Install Project Maya (github.com/mw00/project-maya) for GLM-5.3-Flash into CT 123, beside the
# llama.cpp and Strata servers. Idempotent: every step is skipped when it is already done.
# Runs on the Proxmox HOST as root, from this directory.
#
#   VMID=123 ./install.sh
#
# Steps: the Maya source at the env file's commit with its pinned llama.cpp; a Python venv;
# the HIP engine for gfx1030 with the AMD guide's tests; llama.cpp built for the CPU at the
# control's release, with Maya's logits dumper, for the quality gate; the packs of UD-Q4_K_XL
# and (once maya-l-download.sh has verified it) Maya-L; the env file, launcher and a disabled
# unit. ROCm comes from ../strata/install.sh, which installs the same package.
#
# This only installs. It does not pass /dev/kfd into the container or stop another server:
# ../glm53-flash/ct123-test-host.sh does that, reversibly. The build runs at nice 19.
set -Eeuo pipefail

VMID="${VMID:-123}"
ENV_FILE="${ENV_FILE:-maya-glm53f.env}"
# Parallel compile jobs. Strata holds ~75 GiB of CT 123's 120 GiB while it serves, and a HIP
# compile job can take several GiB: more jobs risk the container's OOM killer.
JOBS="${JOBS:-4}"

# llama.cpp's UD-Q4_K_XL shards, linked into Maya's model folder, and Maya-L's folder.
UD_SRC=/models/hf/glm-5.3-flash
UD_DIR=/models/maya/ud-q4_k_xl
ML_DIR=/models/maya/Maya-L

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[ "$(pct status "$VMID" | awk '{print $2}')" = "running" ] || die "CT ${VMID} is not running"
for f in "$ENV_FILE" maya-serve-glm53f maya-l-download.sh; do
  [ -f "$f" ] || die "missing ${f}; run from this directory"
done
# shellcheck disable=SC1090  # the env file chosen above
. "./${ENV_FILE}"

# Values every container step reads.
ctenv=(env MAYA_RELEASE="$MAYA_RELEASE" MAYA_COMMIT="$MAYA_COMMIT" MAYA_GGML_COMMIT="$MAYA_GGML_COMMIT"
  MAYA_HOME="$MAYA_HOME" MAYA_GGML_DIR="$MAYA_GGML_DIR" MAYA_VENV="$MAYA_VENV"
  ROCM_PACKAGE="$ROCM_PACKAGE" ROCM_VERSION="$ROCM_VERSION" ROCM_ROOT="$ROCM_ROOT"
  GATE_LLAMACPP_TAG="$GATE_LLAMACPP_TAG" GATE_LLAMACPP_DIR="$GATE_LLAMACPP_DIR"
  UD_SRC="$UD_SRC" UD_DIR="$UD_DIR" ML_DIR="$ML_DIR" JOBS="$JOBS")

check_rocm() {
  log "ROCm ${ROCM_VERSION} (${ROCM_PACKAGE})"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
have="$(dpkg-query -W -f='${Version}' "$ROCM_PACKAGE" 2>/dev/null || true)"
[ "$have" = "$ROCM_VERSION" ] || { echo "FATAL: ${ROCM_PACKAGE} is '${have:-absent}', want ${ROCM_VERSION}; run ../strata/install.sh first" >&2; exit 1; }
[ -d "$ROCM_ROOT/lib" ] || { echo "FATAL: ${ROCM_ROOT}/lib missing" >&2; exit 1; }
echo "present"
CONTAINER_SCRIPT
}

install_source() {
  log "Maya ${MAYA_RELEASE} (${MAYA_COMMIT:0:12}), llama.cpp ${MAYA_GGML_COMMIT:0:12} and ${GATE_LLAMACPP_TAG}"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
# The release tag must still name the commit the env file pins.
tag="$(git ls-remote https://github.com/mw00/project-maya.git "refs/tags/${MAYA_RELEASE}" | cut -f1)"
[ "$tag" = "$MAYA_COMMIT" ] || { echo "FATAL: ${MAYA_RELEASE} is ${tag:-missing}, the env file pins ${MAYA_COMMIT}" >&2; exit 1; }
gate="$(git ls-remote https://github.com/ggml-org/llama.cpp.git "refs/tags/${GATE_LLAMACPP_TAG}" | cut -f1)"
[ -n "$gate" ] || { echo "FATAL: llama.cpp has no tag ${GATE_LLAMACPP_TAG}" >&2; exit 1; }
checkout() {   # <dir> <url> <commit>: a shallow checkout of exactly that commit
  local dir="$1" url="$2" commit="$3"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ]; then
    echo "${dir} at ${commit:0:12}"
    return
  fi
  [ ! -e "$dir/.git" ] || { echo "FATAL: ${dir} is at another commit; move it aside" >&2; exit 1; }
  install -d -m 0755 "$dir"
  git init -q "$dir"
  git -C "$dir" fetch -q --depth 1 "$url" "$commit"
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || { echo "FATAL: ${dir} is not at ${commit}" >&2; exit 1; }
}
checkout "$MAYA_HOME" https://github.com/mw00/project-maya.git "$MAYA_COMMIT"
checkout "$MAYA_GGML_DIR" https://github.com/ggml-org/llama.cpp.git "$MAYA_GGML_COMMIT"
checkout "$GATE_LLAMACPP_DIR" https://github.com/ggml-org/llama.cpp.git "$gate"
CONTAINER_SCRIPT
}

install_venv() {
  log "Python venv ${MAYA_VENV}"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
# setup.py's PY_PACKAGES without cmake and ninja, which the container has; Maya pins no versions,
# so the venv records what pip installed.
pkgs=(numpy jinja2 regex pyyaml tqdm requests pillow psutil)
stamp="${MAYA_VENV}/PACKAGES"
if [ -x "${MAYA_VENV}/bin/python" ] && [ "$(head -1 "$stamp" 2>/dev/null)" = "${pkgs[*]}" ]; then
  echo "packages already installed"
  exit 0
fi
[ -x "${MAYA_VENV}/bin/python" ] || python3 -m venv "$MAYA_VENV"
"${MAYA_VENV}/bin/pip" install -q --disable-pip-version-check "${pkgs[@]}"
{ echo "${pkgs[*]}"; "${MAYA_VENV}/bin/pip" freeze; } >"$stamp"
CONTAINER_SCRIPT
}

build_engine() {
  log "HIP engine for gfx1030 (${JOBS} jobs at nice 19)"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
b="${MAYA_HOME}/build"
if [ -x "$b/strata" ] && [ -x "$b/strata-device" ] && [ "$(cat "$b/BUILT_COMMIT" 2>/dev/null)" = "$MAYA_COMMIT" ]; then
  echo "engine already built at ${MAYA_COMMIT:0:12}"
  exit 0
fi
# maya.py's compile_engine_hip, with the tests on for the AMD guide's checks.
clang="$(ls "$ROCM_ROOT"/llvm/bin/clang++ "$ROCM_ROOT"/lib/llvm/bin/clang++ 2>/dev/null | head -1 || true)"
bitcode="$(ls -d "$ROCM_ROOT"/lib/llvm/amdgcn/bitcode "$ROCM_ROOT"/amdgcn/bitcode 2>/dev/null | head -1 || true)"
[ -n "$clang" ] && [ -n "$bitcode" ] || { echo "FATAL: no clang++ or device bitcode under ${ROCM_ROOT}" >&2; exit 1; }
export HIP_PLATFORM=amd HIP_COMPILER=clang HIP_RUNTIME=rocclr ROCM_PATH="$ROCM_ROOT" HIP_PATH="$ROCM_ROOT"
export PATH="${ROCM_ROOT}/bin:$(dirname "$clang"):${PATH}" LD_LIBRARY_PATH="${ROCM_ROOT}/lib"
cmake -S "$MAYA_HOME" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSTRATA_ENABLE_HIP=ON -DSTRATA_ENABLE_CUDA=OFF -DSTRATA_PREFILL_MMQ=ON -DSTRATA_NATIVE_EXPERTS=ON \
  -DSTRATA_BUILD_TESTS=ON -DCMAKE_HIP_ARCHITECTURES=gfx1030 -DCMAKE_HIP_COMPILER="$clang" \
  -DCMAKE_HIP_COMPILER_ROCM_ROOT="$ROCM_ROOT" -DCMAKE_PREFIX_PATH="$ROCM_ROOT" \
  -DCMAKE_HIP_FLAGS="--rocm-path=${ROCM_ROOT} --rocm-device-lib-path=${bitcode}" -DSTRATA_GGML_DIR="$MAYA_GGML_DIR"
nice -n 19 cmake --build "$b" -j "$JOBS" --target strata strata-device
[ -x "$b/strata" ] && [ -x "$b/strata-device" ] || { echo "FATAL: the build produced no strata / strata-device" >&2; exit 1; }
# The AMD guide's test targets (docs/AMD_MAYA.md, Validation). A target this build does not
# define, or one that fails for gfx1030, is reported and skipped: the engine above is what runs.
for t in glm_hc_parity glm_kda_parity glm_ffn_parity glm_dsa_parity glm_layer_parity glm_model_test \
         hip_intrinsics hip_glm_handoff hip_glm_prefill_attention hip_handoff hip_expert_cache_staging \
         iq1_s_parity; do
  nice -n 19 cmake --build "$b" -j "$JOBS" --target "$t" >"$b/test-build-${t}.log" 2>&1 \
    && echo "test target ${t}: built" || echo "test target ${t}: NOT built (see ${b}/test-build-${t}.log)"
done
echo "$MAYA_COMMIT" >"$b/BUILT_COMMIT"
sha256sum "$b/strata" "$b/strata-device"
CONTAINER_SCRIPT
}

build_gate_tools() {
  log "llama.cpp ${GATE_LLAMACPP_TAG} for the CPU and Maya's llm_logits_dump"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
src="$GATE_LLAMACPP_DIR"
b="${src}/build-cpu"
dump="${src}/llm_logits_dump"
if [ -x "$dump" ] && [ -x "$b/bin/llama-tokenize" ] && [ "$(cat "$dump.SOURCE" 2>/dev/null)" = "$MAYA_COMMIT" ]; then
  echo "gate tools already built"
  exit 0
fi
cmake -S "$src" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DGGML_VULKAN=OFF -DGGML_HIP=OFF -DGGML_NATIVE=ON -DLLAMA_CURL=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
nice -n 19 cmake --build "$b" -j "$JOBS" --target llama llama-tokenize
# Maya's tool, built out of tree against that build (its header lists the command).
nice -n 19 g++ -O2 -std=c++17 -I "$src/include" -I "$src/ggml/include" "${MAYA_HOME}/tools/llm_logits_dump.cpp" \
  -o "$dump" -L "$b/bin" -Wl,-rpath,"$b/bin" -lllama -lggml -lggml-base -lggml-cpu -lm -pthread
echo "$MAYA_COMMIT" >"$dump.SOURCE"
"$b/bin/llama-tokenize" --help >/dev/null 2>&1 || true
ls -l "$dump" "$b/bin/llama-tokenize"
CONTAINER_SCRIPT
}

prepare_packs() {
  log "packs under /models/maya"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
install -d -o llamacpp -g llamacpp /models/maya "$UD_DIR"
# The engine reads the GGUF shards from the pack's parent folder, so UD-Q4_K_XL's six shards
# are linked into a folder of Maya's own: the pack stays out of llama.cpp's folder.
for s in "$UD_SRC"/GLM-5.3-Flash-UD-Q4_K_XL-0000?-of-00006.gguf; do
  [ -f "${s}.verified" ] || { echo "FATAL: ${s} is not verified" >&2; exit 1; }
  ln -sfn "$s" "$UD_DIR/$(basename "$s")"
done
pack() {   # <folder> <first shard>: maya.py pack_step's command
  local dir="$1" first="$2"
  if [ -f "$dir/pack/native_experts.txt" ] && [ -f "$dir/pack/tokenizer/vocab.json" ]; then
    echo "pack present: ${dir}/pack"
    return
  fi
  runuser -u llamacpp -- env STRATA_GGUF_PY="${MAYA_GGML_DIR}/gguf-py" "${MAYA_VENV}/bin/python" \
    "${MAYA_HOME}/tools/iq_pack.py" --gguf "$first" --out "$dir/pack" --compat-bf16
  for f in index.txt native_experts.txt dense.bin tokenizer/vocab.json tokenizer/merges.txt; do
    [ -e "$dir/pack/$f" ] || { echo "FATAL: the pack builder did not write ${dir}/pack/${f}" >&2; exit 1; }
  done
  echo "pack: ${dir}/pack"
}
cd "$MAYA_HOME"
pack "$UD_DIR" "$UD_DIR/GLM-5.3-Flash-UD-Q4_K_XL-00001-of-00006.gguf"
if [ "$(ls "$ML_DIR"/*.verified 2>/dev/null | wc -l)" -eq 4 ]; then
  pack "$ML_DIR" "$ML_DIR/GLM-5.3-Flash-Maya-L-IQ3_S-00001-of-00004.gguf"
else
  echo "Maya-L not verified yet (maya-l-download.sh); its pack waits for a re-run"
fi
CONTAINER_SCRIPT
}

install_serve_files() {
  log "env file, launcher, download script and unit"
  pct push "$VMID" "$ENV_FILE" /etc/maya-glm53f.env --perms 0644
  pct push "$VMID" maya-serve-glm53f /usr/local/bin/maya-serve-glm53f --perms 0755
  pct push "$VMID" maya-l-download.sh /usr/local/bin/maya-l-download.sh --perms 0755
  pct exec "$VMID" -- bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
cat >/etc/systemd/system/maya-glm53f.service <<'UNIT'
[Unit]
Description=Project Maya server (GLM-5.3-Flash, HIP)
After=network-online.target
Wants=network-online.target
# One model server per card and port: starting any of these stops the others, and they stop it.
Conflicts=llamacpp.service llamacpp-qwen38fn.service strata-qwen38fn.service llamacpp-glm53f.service

[Service]
Type=simple
User=llamacpp
Group=llamacpp
SupplementaryGroups=render video
Environment=HOME=/home/llamacpp
ExecStart=/usr/local/bin/maya-serve-glm53f
Restart=on-failure
RestartSec=15
TimeoutStartSec=1800
TimeoutStopSec=120
# The RAM tier is page-locked for the GPU.
LimitMEMLOCK=infinity
MemorySwapMax=0
StateDirectory=maya-glm53f
LogsDirectory=maya-glm53f
LogsDirectoryMode=0755

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
echo "unit installed ($(systemctl is-enabled maya-glm53f 2>&1 | head -1))"
CONTAINER_SCRIPT
}

show_state() {
  echo
  log "state"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
ok() { if eval "$2" >/dev/null 2>&1; then echo "  $1: ok"; else echo "  $1: MISSING"; fi; }
echo "  engine:  $(cat "${MAYA_HOME}/build/BUILT_COMMIT" 2>/dev/null || echo 'not built')"
ok "ud pack" "test -f '${UD_DIR}/pack/native_experts.txt'"
ok "L pack " "test -f '${ML_DIR}/pack/native_experts.txt'"
ok "dumper " "test -x '${GATE_LLAMACPP_DIR}/llm_logits_dump'"
ok "kfd    " "test -c /dev/kfd"
for u in maya-glm53f llamacpp-glm53f strata-qwen38fn llamacpp-qwen38fn; do
  echo "  ${u}: $(systemctl is-active "$u" 2>&1 | head -1)/$(systemctl is-enabled "$u" 2>&1 | head -1)"
done
CONTAINER_SCRIPT
}

main() {
  check_rocm
  install_source
  install_venv
  build_engine
  build_gate_tools
  prepare_packs
  install_serve_files
  show_state
}

main "$@"
