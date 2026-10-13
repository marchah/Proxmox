#!/usr/bin/env bash
# Install a pinned llama.cpp Vulkan release into a container beside the builds it already
# has, for a build A/B. Runs on the Proxmox HOST as root.
#
#   VMID=123 ./install-llamacpp-release.sh                       # the TAG and SHA256 below
#   VMID=123 TAG=<tag> SHA256=<asset digest> ./install-llamacpp-release.sh
#
# The release unpacks to /opt/llamacpp/llama-<tag>/. The script changes nothing else: not
# /opt/llamacpp/current, not any env file. A sweep cell or an env file picks the build with
# LLAMACPP_DIR. It prints the build's --version, which names its commit.
set -Eeuo pipefail

VMID="${VMID:-123}"
# Bump TAG and SHA256 together. The SHA-256 is the release asset's digest on
# https://github.com/ggml-org/llama.cpp/releases (asset llama-<tag>-bin-ubuntu-vulkan-x64.tar.gz).
readonly DEFAULT_TAG="b11583"
readonly DEFAULT_SHA256="2c331fa6fc874c7757a96df2c0b2ad8856ec258841278fbb45eaab9b5c053332"
TAG="${TAG:-$DEFAULT_TAG}"
SHA256="${SHA256:-$DEFAULT_SHA256}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

check_args() {
  [ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
  [[ "$TAG" =~ ^b[0-9]+$ ]] || die "TAG must look like b11583"
  [[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "SHA256 must be 64 hex digits"
  if [ "$TAG" != "$DEFAULT_TAG" ] && [ "$SHA256" = "$DEFAULT_SHA256" ]; then
    die "TAG ${TAG} needs its own SHA256"
  fi
  pct status "$VMID" | grep -q running || die "CT ${VMID} is not running"
}

install_release() {
  local url="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-bin-ubuntu-vulkan-x64.tar.gz"
  log "installing llama.cpp ${TAG} into CT ${VMID}"
  pct exec "$VMID" -- bash -s -- "$TAG" "$url" "$SHA256" <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
tag="$1" url="$2" sha="$3"
dir="/opt/llamacpp/llama-${tag}"
if [ -x "${dir}/llama-server" ]; then
  echo "${dir} is already installed"
else
  tarball="$(mktemp)"
  trap 'rm -f "$tarball"' EXIT
  curl --fail --show-error --silent --location --output "$tarball" "$url"
  printf '%s  %s\n' "$sha" "$tarball" | sha256sum --check -
  tar -xzf "$tarball" -C /opt/llamacpp
fi
[ -x "${dir}/llama-server" ] || { echo "no llama-server in ${dir}" >&2; exit 1; }
LD_LIBRARY_PATH="$dir" "${dir}/llama-server" --version 2>&1 | grep -E '^(version|built)'
CONTAINER_SCRIPT
}

main() {
  check_args
  install_release
  log "done: LLAMACPP_DIR=/opt/llamacpp/llama-${TAG}"
}

main "$@"
