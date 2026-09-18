#!/usr/bin/env bash
# Build llama.cpp (Vulkan) in the disposable Ubuntu 24.04 builder, CT 201.
#
# 🔴 WHY A SEPARATE BUILD CONTAINER: CT 120 is Ubuntu 24.04 (glibc 2.39) and the Proxmox host
# is Debian 13 (glibc 2.41). A binary built on the HOST will NOT run in CT 120 — glibc is only
# forward compatible. Build on 2.39 and the result runs in CT 120 AND on the host, which is
# also what makes the LXC-passthrough A/B possible with one binary.
#
# Builds TWO trees so the #28699 comparison has a real control: an identically-configured
# baseline at the same tag, and the same tree with the PR applied. Comparing a self-built
# patched binary against the official release tarball would confound the patch with build flags.
set -Eeuo pipefail

# Vulkan build deps on Ubuntu 24.04: libvulkan-dev, glslc, AND spirv-headers — the last one
# is easy to miss, and its absence fails at cmake configure with a find_package error for
# "SPIRV-Headers" rather than anything mentioning Vulkan.
TAG="${TAG:-b11018}"
PR="${PR:-28699}"
SRC=/root/llama.cpp
OUT=/root/builds

mkdir -p "$OUT"
if [ ! -d "$SRC/.git" ]; then
  # -q matters: the clone's per-file progress is ~100 kB of carriage-return spam
  git clone -q --filter=blob:none https://github.com/ggml-org/llama.cpp "$SRC"
fi
cd "$SRC"
git fetch --tags --quiet origin
git fetch --quiet origin "pull/${PR}/head:pr-${PR}" || { echo "FATAL: cannot fetch PR ${PR}"; exit 1; }

build() {  # build <label> <git-ref> [extra cherry-pick ref]
  local label="$1" ref="$2" pick="${3:-}"
  echo
  echo "======== building ${label} ========"
  git checkout --quiet --force "$ref"
  git clean -qfd
  if [ -n "$pick" ]; then
    echo "  cherry-picking ${pick}"
    git -c user.email=b@local -c user.name=builder cherry-pick "$pick" 2>&1 | tail -3 || {
      echo "  FATAL: cherry-pick failed (PR does not apply cleanly to ${ref})"; return 1; }
  fi
  git log --oneline -2 | sed 's/^/  /'
  rm -rf build
  cmake -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_VULKAN=ON -DGGML_NATIVE=ON \
    -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    >/dev/null
  cmake --build build -j "$(nproc)" 2>&1 | tail -4
  local dest="${OUT}/${label}"
  rm -rf "$dest"; mkdir -p "$dest"
  # flat layout, matching the release tarballs CT 120 already uses
  find build/bin -maxdepth 1 -type f -exec cp {} "$dest/" \; 2>/dev/null || true
  find build -name "*.so*" -exec cp -P {} "$dest/" \; 2>/dev/null || true
  chmod +x "$dest"/llama-* 2>/dev/null || true
  echo "  -> ${dest} ($(du -sh "$dest" | cut -f1))"
  LD_LIBRARY_PATH="$dest" "$dest/llama-server" --version 2>&1 | head -1 | sed 's/^/  /'
  # the whole point: confirm the arch and the PR's own kill switch are present
  grep -rlq qwen4exp "$dest" && echo "  qwen4exp: present" || echo "  qwen4exp: ABSENT"
  if [ -n "$pick" ]; then
    grep -rlq LLAMA_QSA_NO_POOLED_CACHE "$dest" \
      && echo "  LLAMA_QSA_NO_POOLED_CACHE kill switch: present (PR applied)" \
      || echo "  🔴 kill switch ABSENT — the PR may not have taken"
  fi
}

build "${TAG}-baseline" "$TAG"
build "${TAG}-pr${PR}"  "$TAG" "pr-${PR}"

echo
echo "======== built ========"
ls -1 "$OUT"
