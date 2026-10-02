#!/usr/bin/env bash
# Stage everything the Vulkan/ROCm A/B needs on the Proxmox HOST, root. Touches no guest.
#
# - a temporary thin volume holding both test models, copied out of the CTs that own them
#   and sha256-checked against their sources
# - the b11018 Vulkan and ROCm release tarballs, checked against the release digests
# - the Ubuntu 24.04 cloud image for the test VM, and wikitext-2 for the perplexity gate
#
# Undo with: umount "$MNT" && lvremove -y "pve/${LV}"
set -Eeuo pipefail

ROOT="${ROOT:-/root/rocm-ab}"
LV="${LV:-rocm-ab-models}"; LV_SIZE="${LV_SIZE:-50G}"
MNT="${MNT:-/mnt/rocm-ab-models}"
TAG=b11018
VULKAN_SHA256=d5ae7502b5a312788df5a74bb47df00b97fdaa45c763f00c7f8909cd7cd6e105
ROCM_SHA256=6658e965da8ce88e3f8879a7b5ae2b54b54553ed1bc8e42fd8f273661446dcd4
# <ct>|<path in ct>
MODELS=(
  "120|/models/hf/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
  "123|/models/hf/Qwen3.8-27B-UD-Q5_K_XL.gguf"
)
IMG_URL=https://cloud-images.ubuntu.com/noble/current
WIKI_URL=https://huggingface.co/datasets/ggml-org/ci/resolve/main/wikitext-2-raw-v1.zip

say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
mkdir -p "$ROOT/dl"

if ! mountpoint -q "$MNT"; then
  if ! lvs "pve/${LV}" >/dev/null 2>&1; then
    say "creating thin volume pve/${LV} (${LV_SIZE})"
    lvcreate -q -V "$LV_SIZE" -T pve/data -n "$LV"
    mkfs.ext4 -q -L rocm-ab "/dev/pve/${LV}"
  fi
  mkdir -p "$MNT"; mount "/dev/pve/${LV}" "$MNT"
fi

for m in "${MODELS[@]}"; do
  ct=${m%%|*}; src=${m#*|}; dst="${MNT}/$(basename "$src")"
  if [ ! -s "${dst}.sha256" ]; then
    say "copying CT ${ct}:${src}"
    pct pull "$ct" "$src" "$dst"
    s_src=$(pct exec "$ct" -- sha256sum "$src" | cut -d' ' -f1)
    s_dst=$(sha256sum "$dst" | cut -d' ' -f1)
    [ "$s_src" = "$s_dst" ] || { say "FATAL: sha256 mismatch for ${dst}: ${s_src} vs ${s_dst}"; exit 1; }
    echo "$s_dst  $(basename "$dst")" > "${dst}.sha256"
  fi
  say "model ok: $(cat "${dst}.sha256")"
done

fetch(){ local url=$1 out=$2 sha=$3
  [ -s "$out" ] || curl -fsSL --retry 3 -o "$out" "$url"
  echo "${sha}  ${out}" | sha256sum -c --quiet - || { say "FATAL: sha256 mismatch for ${out}"; exit 1; }
  say "ok: $(basename "$out")"; }
fetch "https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-bin-ubuntu-vulkan-x64.tar.gz" \
  "$ROOT/dl/llama-${TAG}-bin-ubuntu-vulkan-x64.tar.gz" "$VULKAN_SHA256"
fetch "https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-bin-ubuntu-rocm-10.0-x64.tar.gz" \
  "$ROOT/dl/llama-${TAG}-bin-ubuntu-rocm-10.0-x64.tar.gz" "$ROCM_SHA256"

# The cloud image is published with a SHA256SUMS file; record which build was used.
img="$ROOT/dl/noble-server-cloudimg-amd64.img"
curl -fsSL -o "$ROOT/dl/SHA256SUMS" "${IMG_URL}/SHA256SUMS"
img_sha=$(awk '$2 ~ /noble-server-cloudimg-amd64\.img$/ {print $1}' "$ROOT/dl/SHA256SUMS")
fetch "${IMG_URL}/noble-server-cloudimg-amd64.img" "$img" "$img_sha"

if [ ! -s "$ROOT/dl/wiki.test.raw" ]; then
  curl -fsSL --retry 3 -o "$ROOT/dl/wikitext-2-raw-v1.zip" "$WIKI_URL"
  python3 - "$ROOT/dl" <<'PY'
import sys, zipfile, pathlib
d = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(d / "wikitext-2-raw-v1.zip") as z:
    (d / "wiki.test.raw").write_bytes(z.read("wikitext-2-raw/wiki.test.raw"))
PY
fi
say "wiki.test.raw: $(sha256sum "$ROOT/dl/wiki.test.raw" | cut -c1-16) $(wc -c <"$ROOT/dl/wiki.test.raw") bytes"
say "staging done"
