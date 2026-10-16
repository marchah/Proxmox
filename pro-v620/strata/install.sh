#!/usr/bin/env bash
# Install the Strata engine (github.com/Niko1221/Strata) for Qwen3.8-Flash-Next into CT 123,
# beside its llama.cpp server. Idempotent: every step is skipped when it is already done.
# Runs on the Proxmox HOST as root, from this directory.
#
#   VMID=123 ./install.sh
#
# Steps: ROCm userspace for gfx1030 from AMD's apt repository (the kernel driver stays the
# host's amdgpu) and build tools; the Strata source at the env file's commit with its pinned
# llama.cpp; a Python venv; the HIP engine for gfx1030 with its tests; the UD-Q4_K_XL pack;
# the MTP draft layer (about 5 GB of BF16 tensors from Qwen/Qwen3.8-Flash-Next); the env
# file, launcher, reload helper and a disabled unit.
#
# This only installs. It does not pass /dev/kfd into the container, stop llama.cpp or start
# Strata: ./use-engine.sh does that, reversibly. The llama.cpp server keeps serving
# throughout; the build runs at nice 19.
set -Eeuo pipefail

VMID="${VMID:-123}"
ENV_FILE="${ENV_FILE:-strata-qwen38fn.env}"
# Parallel compile jobs. llama.cpp with dio holds ~82 GiB of CT 123's 120 GiB, and a HIP
# compile job can take several GiB: more jobs risk the container's OOM killer.
JOBS="${JOBS:-4}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[ "$(pct status "$VMID" | awk '{print $2}')" = "running" ] || die "CT ${VMID} is not running"
for f in "$ENV_FILE" strata-serve-qwen38fn strata-qwen38fn-reload; do
  [ -f "$f" ] || die "missing ${f}; run from this directory"
done
# shellcheck disable=SC1090  # the env file chosen above
. "./${ENV_FILE}"

# Values every container step reads.
ctenv=(env STRATA_RELEASE="$STRATA_RELEASE" STRATA_COMMIT="$STRATA_COMMIT"
  STRATA_GGML_COMMIT="$STRATA_GGML_COMMIT" STRATA_HOME="$STRATA_HOME"
  STRATA_GGML_DIR="$STRATA_GGML_DIR" STRATA_VENV="$STRATA_VENV" ROCM_PACKAGE="$ROCM_PACKAGE"
  ROCM_VERSION="$ROCM_VERSION" ROCM_ROOT="$ROCM_ROOT" MODEL_GGUF="$MODEL_GGUF"
  MODEL_PACK="$MODEL_PACK" MODEL_MTP_SRC="$MODEL_MTP_SRC" MODEL_MTP="$MODEL_MTP" JOBS="$JOBS")

install_rocm() {
  log "ROCm ${ROCM_VERSION} (${ROCM_PACKAGE}) and build tools"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
tools=(build-essential cmake ninja-build git curl ca-certificates gnupg python3-venv python3-dev)
if [ "$(dpkg-query -W -f='${Version}' "$ROCM_PACKAGE" 2>/dev/null || true)" = "$ROCM_VERSION" ] \
    && dpkg -s "${tools[@]}" >/dev/null 2>&1; then
  echo "already installed"
  exit 0
fi
apt-get update -q
apt-get install -y -q --no-install-recommends "${tools[@]}"
install -d -m 0755 /etc/apt/keyrings
[ -s /etc/apt/keyrings/amdrocm.gpg ] \
  || curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg
cat >/etc/apt/sources.list.d/amdrocm-stable.sources <<'SRC'
X-Repo-Id: amdrocm-stable
Types: deb
URIs: https://stable.repo.amd.com/rocm/core/packages/ubuntu2404/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/amdrocm.gpg
Enabled: yes
SRC
apt-get update -q
# The llama.cpp server in this container runs on Vulkan through the held Mesa build. Refuse a
# ROCm install that would replace Mesa, libdrm or the Vulkan loader under it.
plan="$(apt-get install -s --no-install-recommends "${ROCM_PACKAGE}=${ROCM_VERSION}" | awk '/^Inst /{print $2}')"
if printf '%s\n' "$plan" | grep -E '^(mesa|libdrm|libvulkan|libgl|libegl|libgbm)'; then
  echo "FATAL: installing ${ROCM_PACKAGE} would change the packages above, which llama.cpp's Vulkan uses" >&2
  exit 1
fi
apt-get install -y -q --no-install-recommends "${ROCM_PACKAGE}=${ROCM_VERSION}"
# Its dependencies are pinned to the same version by the package itself.
apt-mark hold "$ROCM_PACKAGE" >/dev/null
[ -d "$ROCM_ROOT/lib" ] || { echo "FATAL: ${ROCM_ROOT}/lib missing after the install" >&2; ls -d /opt/rocm* >&2; exit 1; }
CONTAINER_SCRIPT
}

install_source() {
  log "Strata ${STRATA_RELEASE} (${STRATA_COMMIT:0:12}) and llama.cpp ${STRATA_GGML_COMMIT:0:12}"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
# The release tag must still name the commit the env file pins.
tag="$(git ls-remote https://github.com/Niko1221/Strata.git "refs/tags/${STRATA_RELEASE}^{}" | cut -f1)"
[ "$tag" = "$STRATA_COMMIT" ] || { echo "FATAL: ${STRATA_RELEASE} is ${tag:-missing}, the env file pins ${STRATA_COMMIT}" >&2; exit 1; }
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
checkout "$STRATA_HOME" https://github.com/Niko1221/Strata.git "$STRATA_COMMIT"
checkout "$STRATA_GGML_DIR" https://github.com/ggml-org/llama.cpp.git "$STRATA_GGML_COMMIT"
CONTAINER_SCRIPT
}

install_venv() {
  log "Python venv ${STRATA_VENV}"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
stamp="${STRATA_VENV}/REQUIREMENTS_SHA256"
want="$(sha256sum "${STRATA_HOME}/requirements.txt" | cut -d' ' -f1)"
if [ -x "${STRATA_VENV}/bin/python" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
  echo "requirements already installed"
  exit 0
fi
[ -x "${STRATA_VENV}/bin/python" ] || python3 -m venv "$STRATA_VENV"
"${STRATA_VENV}/bin/pip" install -q --disable-pip-version-check -r "${STRATA_HOME}/requirements.txt"
echo "$want" >"$stamp"
CONTAINER_SCRIPT
}

build_engine() {
  log "HIP engine for gfx1030 (${JOBS} jobs at nice 19; 20-40 min the first time)"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
b="${STRATA_HOME}/build-hip"
if [ -x "$b/strata" ] && [ -x "$b/strata-device" ] && [ "$(cat "$b/BUILT_COMMIT" 2>/dev/null)" = "$STRATA_COMMIT" ]; then
  echo "engine already built at ${STRATA_COMMIT:0:12}"
  exit 0
fi
# setup.py's build_engine_hip, with the tests built for the validation steps in README.md.
clang="$(ls "$ROCM_ROOT"/llvm/bin/clang++ "$ROCM_ROOT"/lib/llvm/bin/clang++ 2>/dev/null | head -1 || true)"
bitcode="$(ls -d "$ROCM_ROOT"/lib/llvm/amdgcn/bitcode "$ROCM_ROOT"/amdgcn/bitcode 2>/dev/null | head -1 || true)"
[ -n "$clang" ] && [ -n "$bitcode" ] || { echo "FATAL: no clang++ or device bitcode under ${ROCM_ROOT}" >&2; exit 1; }
export HIP_PLATFORM=amd HIP_COMPILER=clang HIP_RUNTIME=rocclr ROCM_PATH="$ROCM_ROOT" HIP_PATH="$ROCM_ROOT"
llvm_bin="$(dirname "$clang")"
export PATH="${ROCM_ROOT}/bin:${llvm_bin}:${PATH}" LD_LIBRARY_PATH="${ROCM_ROOT}/lib"
cmake -S "$STRATA_HOME" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DSTRATA_ENABLE_HIP=ON -DSTRATA_ENABLE_CUDA=OFF -DSTRATA_BUILD_TESTS=ON -DSTRATA_PREFILL_MMQ=ON \
  -DCMAKE_HIP_ARCHITECTURES=gfx1030 -DCMAKE_HIP_COMPILER="$clang" -DCMAKE_HIP_COMPILER_ROCM_ROOT="$ROCM_ROOT" \
  -DCMAKE_PREFIX_PATH="$ROCM_ROOT" -DCMAKE_HIP_FLAGS="--rocm-path=${ROCM_ROOT} --rocm-device-lib-path=${bitcode}" \
  -DSTRATA_GGML_DIR="$STRATA_GGML_DIR"
nice -n 19 cmake --build "$b" -j "$JOBS"
[ -x "$b/strata" ] && [ -x "$b/strata-device" ] || { echo "FATAL: the build produced no strata / strata-device" >&2; exit 1; }
echo "$STRATA_COMMIT" >"$b/BUILT_COMMIT"
sha256sum "$b/strata" "$b/strata-device"
CONTAINER_SCRIPT
}

prepare_model() {
  log "UD-Q4_K_XL pack and MTP draft layer under /models/strata"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
install -d -o llamacpp -g llamacpp /models/strata /models/strata/packs "$MODEL_MTP_SRC"
py() { runuser -u llamacpp -- "${STRATA_VENV}/bin/python" "$@"; }
cd "$STRATA_HOME"
if [ -f "${MODEL_PACK}/native_experts.txt" ] && [ -f "${MODEL_PACK}/tokenizer/vocab.json" ]; then
  echo "pack present: ${MODEL_PACK}"
else
  # Shard 1 holds only metadata: the pack is the dense side (~1.4 GB) and the tokenizer; the
  # experts are read from the GGUF shards in place. --compat-bf16 rounds the file's Q8_0
  # hyper-connection projections to the BF16 the engine reads (docs/UNSLOTH_Q4.md).
  py tools/iq_pack.py --gguf "$MODEL_GGUF" --out "$MODEL_PACK" --compat-bf16
fi
if [ -f "${MODEL_MTP}/experts.bin" ] && [ -f "${MODEL_MTP}/draft_vocab.bin" ]; then
  echo "MTP draft layer present: ${MODEL_MTP}"
else
  # setup.py's steps: the mtp.* tensors by HTTP range reads at the pinned checkpoint revision,
  # checked against their SHA-256s, packed with Q2_0 experts, and setup's default token subset.
  py tools/mtp_fetch.py fetch --out "$MODEL_MTP_SRC"
  py tools/mtp_fetch.py verify --out "$MODEL_MTP_SRC"
  py tools/mtp_pack.py --src "$MODEL_MTP_SRC" --experts q2_0 --out "${MODEL_MTP_SRC}/mtp-q2_0.gguf"
  py tools/mtp_rt.py --gguf "${MODEL_MTP_SRC}/mtp-q2_0.gguf" --out "$MODEL_MTP"
  runuser -u llamacpp -- cp "${STRATA_HOME}/data/draft_vocab.bin" "${MODEL_MTP}/draft_vocab.bin"
fi
CONTAINER_SCRIPT
}

install_serve_files() {
  log "env file, launcher, reload helper and unit"
  pct push "$VMID" "$ENV_FILE" /etc/strata-qwen38fn.env --perms 0644
  pct push "$VMID" strata-serve-qwen38fn /usr/local/bin/strata-serve-qwen38fn --perms 0755
  pct push "$VMID" strata-qwen38fn-reload /usr/local/bin/strata-qwen38fn-reload --perms 0755
  pct exec "$VMID" -- bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
cat >/etc/systemd/system/strata-qwen38fn.service <<'UNIT'
[Unit]
Description=Strata server (Qwen3.8-Flash-Next UD-Q4_K_XL, HIP)
After=network-online.target
Wants=network-online.target
# One model server per card and port: starting either engine stops the other.
Conflicts=llamacpp-qwen38fn.service

[Service]
Type=simple
User=llamacpp
Group=llamacpp
SupplementaryGroups=render video
Environment=HOME=/home/llamacpp
ExecStart=/usr/local/bin/strata-serve-qwen38fn
Restart=on-failure
RestartSec=15
TimeoutStartSec=1800
TimeoutStopSec=120
# The expert arena (77 GB) is page-locked for the GPU.
LimitMEMLOCK=infinity
# The experts and the n-gram table must stay resident.
MemorySwapMax=0
RuntimeDirectory=strata-qwen38fn
LogsDirectory=strata-qwen38fn
LogsDirectoryMode=0755

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
echo "unit installed ($(systemctl is-enabled strata-qwen38fn 2>&1 | head -1))"
CONTAINER_SCRIPT
}

show_state() {
  echo
  log "state"
  pct exec "$VMID" -- "${ctenv[@]}" bash -s <<'CONTAINER_SCRIPT'
ok() { if eval "$2" >/dev/null 2>&1; then echo "  $1: ok"; else echo "  $1: MISSING"; fi; }
echo "  rocm:    $(dpkg-query -W -f='${Package}=${Version}' "$ROCM_PACKAGE" 2>/dev/null || echo MISSING)"
echo "  engine:  $(cat "${STRATA_HOME}/build-hip/BUILT_COMMIT" 2>/dev/null || echo 'not built')"
ok "pack   " "test -f '${MODEL_PACK}/native_experts.txt'"
ok "mtp    " "test -f '${MODEL_MTP}/experts.bin'"
ok "kfd    " "test -c /dev/kfd"
echo "  units:   llamacpp-qwen38fn $(systemctl is-active llamacpp-qwen38fn)/$(systemctl is-enabled llamacpp-qwen38fn 2>&1 | head -1)," \
  "strata-qwen38fn $(systemctl is-active strata-qwen38fn)/$(systemctl is-enabled strata-qwen38fn 2>&1 | head -1)"
CONTAINER_SCRIPT
  echo
  echo "Next: README.md, Validation; ./use-engine.sh strata switches CT ${VMID} to Strata."
}

main() {
  install_rocm
  install_source
  install_venv
  build_engine
  prepare_model
  install_serve_files
  show_state
}

main "$@"
