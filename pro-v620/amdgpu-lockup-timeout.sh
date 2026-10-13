#!/usr/bin/env bash
#
# Raise amdgpu's GPU job timeout for compute jobs on the Proxmox host. Run on the host as
# root; idempotent. amdgpu reads lockup_timeout when it loads, so the value applies after
# the next reboot.
#
# The default is 2,000 ms on every ring. A job that runs longer counts as a hang: the kernel
# resets the ring and Vulkan returns ErrorDeviceLost. GLM-5.3-Flash at micro-batch 4096 ran a
# compute job longer than that on prompts past about 65k tokens
# (glm53-flash/runs/2026-10-10-configurations.md, stage 5a; llama.cpp #26447). Only the
# compute timeout is raised: GFX, SDMA and video keep the default, so a hang there is still
# caught at 2 s.
set -Eeuo pipefail

# ---- config -------------------------------------------------------------------------------
# GFX,Compute,SDMA,Video in ms (amdgpu's format; a single value applies to all four).
readonly LOCKUP_TIMEOUT="${LOCKUP_TIMEOUT:-2000,10000,2000,2000}"
readonly MODPROBE_PATH="/etc/modprobe.d/amdgpu-lockup-timeout.conf"
readonly PARAM_PATH="/sys/module/amdgpu/parameters/lockup_timeout"

# ---- helpers ------------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (on the Proxmox host)"; }

validate() {
  [[ "$LOCKUP_TIMEOUT" =~ ^-?[0-9]+(,-?[0-9]+){0,3}$ ]] \
    || die "LOCKUP_TIMEOUT must be one to four comma-separated integers in ms, got '${LOCKUP_TIMEOUT}'"
}

write_option() {
  local want="options amdgpu lockup_timeout=${LOCKUP_TIMEOUT}"
  if [ -f "$MODPROBE_PATH" ] && grep -qxF "$want" "$MODPROBE_PATH"; then
    log "already set in ${MODPROBE_PATH}: ${want}"
    return 0
  fi
  log "writing ${MODPROBE_PATH}: ${want}"
  {
    printf '# GPU job timeout in ms, GFX,Compute,SDMA,Video. Managed by\n'
    printf '# pro-v620/amdgpu-lockup-timeout.sh; amdgpu reads it at load, so reboot to apply.\n'
    printf '%s\n' "$want"
  } > "$MODPROBE_PATH"
}

# Rebuilt every run, as the undervolt installer does, so that an initramfs carrying amdgpu
# also carries the option, and a previous failed rebuild does not go unnoticed.
rebuild_initramfs() {
  log "rebuilding the initramfs"
  update-initramfs -u -k all >/dev/null 2>&1 || update-initramfs -u \
    || die "update-initramfs failed; run 'update-initramfs -u' by hand to see the error"
}

report() {
  local loaded
  loaded="$(cat "$PARAM_PATH" 2>/dev/null || true)"
  if [ "$loaded" = "$LOCKUP_TIMEOUT" ]; then
    log "amdgpu is running with lockup_timeout=${loaded}"
  else
    log "amdgpu is running with lockup_timeout='${loaded}' (empty = the 2,000 ms default); reboot to apply ${LOCKUP_TIMEOUT}"
  fi
}

main() {
  require_root
  validate
  write_option
  rebuild_initramfs
  report
}

main "$@"
