#!/usr/bin/env bash
# Inside the test VM, root, after guest-setup.sh. Adds the ROCm 10.0 runtime the llama.cpp
# ROCm build links against (libamdhip64.so.7, librocblas.so.5, libhipblas.so.3), for gfx1030
# only. Userspace only: the kernel driver is already amdgpu-dkms, and Mesa stays held at the
# production build, so the Vulkan setup in the same VM is unchanged.
set -Eeuo pipefail

ROCM="${ROCM:-10.0.0-4}"
HIP_LIB="${HIP_LIB:-/opt/rocm-ab/llama-b11018-rocm/libggml-hip.so}"
# ROCm 10 installs here and registers nothing with ld.so. Only the ROCm setup gets this path
# (run-phase.sh), so the Vulkan setup in the same VM loads exactly what it did before.
ROCM_LIB=/opt/rocm/core-10.0/lib
export DEBIAN_FRONTEND=noninteractive

install -d -m 0755 /etc/apt/keyrings
[ -s /etc/apt/keyrings/amdrocm.gpg ] \
  || curl -fsSL https://stable.repo.amd.com/rocm/gpg/packages.gpg | gpg --dearmor -o /etc/apt/keyrings/amdrocm.gpg
cat > /etc/apt/sources.list.d/amdrocm-stable.sources <<'SRC'
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
apt-get install -y -q --no-install-recommends "amdrocm-runtime10.0=${ROCM}" "amdrocm-blas10.0-gfx1030=${ROCM}"
apt-mark hold amdrocm-runtime10.0 amdrocm-blas10.0-gfx1030 >/dev/null

# Every library the llama.cpp ROCm build needs must resolve from the system paths.
missing=$(LD_LIBRARY_PATH="$(dirname "$HIP_LIB"):${ROCM_LIB}" ldd "$HIP_LIB" | grep "not found" || true)
if [ -n "$missing" ]; then echo "FATAL: unresolved libraries:"; echo "$missing"; exit 1; fi

echo "rocm: $(dpkg-query -W -f='${Package}=${Version} ' 'amdrocm-runtime10.0' 'amdrocm-blas10.0-gfx1030')"
echo "mesa: $(dpkg-query -W -f='${Version}' mesa-vulkan-drivers) (held)"
LD_LIBRARY_PATH="$(dirname "$HIP_LIB"):${ROCM_LIB}" ldd "$HIP_LIB" | grep -E "amdhip|rocblas|hipblas"
