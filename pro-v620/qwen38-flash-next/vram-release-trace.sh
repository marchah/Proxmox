#!/usr/bin/env bash
# Trace the kernel's VRAM allocations and frees, with the task behind each one, to see when
# memory a process freed returns to the card. Runs on the Proxmox HOST as root, beside
# vram-residency-sampler.py:
#
#   systemd-run --unit=vram-release-trace --collect "$PWD/vram-release-trace.sh" /root/trace.txt
#   systemctl stop vram-release-trace
#   ./vram-release-trace.sh --check     # define the probes, then remove them; traces nothing
#
# OUTPUT gets one tracefs line per event, each with the task (comm-pid) that ran it:
#   vram_new      the VRAM manager allocating for a buffer (amdgpu_vram_mgr_new): man, bo, size
#   vram_new_ret  its return value: 0, or an error such as -ENOSPC (-28) when VRAM is full
#   vram_del      the VRAM manager freeing a buffer's VRAM (amdgpu_vram_mgr_del): man, bo, size
#   gem_free      the last reference to a buffer object dropped (amdgpu_gem_object_free): bo, size
#   release_notify  the driver's release hook (amdgpu_bo_release_notify), which can queue a
#                 wipe of the buffer's VRAM before TTM frees it: bo, size
#   vram_fill, vram_clear  the driver filling or clearing a buffer's VRAM on the GPU
#                 (amdgpu_fill_buffer, amdgpu_ttm_clear_buffer): bo, size
#   amdgpu_bo_create, amdgpu_bo_move  the driver's own tracepoints, for placements; they
#                 print hashed pointers, so match them to the lines above by time and size
# `man` is a card's VRAM manager, one address per card; `bo` is the buffer's raw address,
# the same in all three probes. Timestamps are CLOCK_MONOTONIC seconds; a `sync <epoch>`
# marker every SYNC_SECONDS pairs them with the wall clock. Buffers under MIN_MIB are left
# out; `vram_new_ret` lines carry no size and are all kept. On exit the script removes its
# probes and its tracefs instance, and it exits non-zero if OUTPUT cannot be written or the
# reader stops early.
set -Eeuo pipefail

MIN_MIB="${MIN_MIB:-16}"
SYNC_SECONDS="${SYNC_SECONDS:-10}"
BUFFER_KB="${BUFFER_KB:-16384}"
TRACEFS=/sys/kernel/tracing
INSTANCE="${TRACEFS}/instances/vram-release"
GROUP=vramtrace
PROBES=(
  "f:${GROUP}/vram_new amdgpu_vram_mgr_new man=man:x64 bo=tbo:x64 size=tbo->base.size:u64"
  "f:${GROUP}/vram_new_ret amdgpu_vram_mgr_new%return ret=\$retval:s32"
  "f:${GROUP}/vram_del amdgpu_vram_mgr_del man=man:x64 bo=res->bo:x64 size=res->size:u64"
  "f:${GROUP}/gem_free amdgpu_gem_object_free bo=gobj:x64 size=gobj->size:u64"
  "f:${GROUP}/release_notify amdgpu_bo_release_notify bo=bo:x64 size=bo->base.size:u64"
  "f:${GROUP}/vram_fill amdgpu_fill_buffer bo=bo:x64 size=bo->tbo.base.size:u64"
  "f:${GROUP}/vram_clear amdgpu_ttm_clear_buffer bo=bo:x64 size=bo->tbo.base.size:u64"
)
SIZED_PROBES=(vram_new vram_del gem_free release_notify vram_fill vram_clear)

reader_pid=""

die() { echo "ERROR: $*" >&2; exit 1; }

probe_name() { local name="${1%% *}"; echo "${name#f:}"; }

remove_probes() {
  local probe
  for probe in "${PROBES[@]}"; do
    echo "-:$(probe_name "$probe")" >>"${TRACEFS}/dynamic_events" 2>/dev/null || true
  done
}

add_probes() {
  local probe
  remove_probes
  for probe in "${PROBES[@]}"; do
    echo "$probe" >>"${TRACEFS}/dynamic_events" || die "the kernel refused: ${probe}"
  done
}

cleanup() {
  if [ -d "$INSTANCE" ]; then
    echo 0 >"${INSTANCE}/tracing_on" 2>/dev/null || true
    # Let the reader drain what is already buffered.
    sleep 1
  fi
  if [ -n "$reader_pid" ]; then
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
  fi
  if [ -d "$INSTANCE" ]; then
    echo 0 >"${INSTANCE}/events/enable" 2>/dev/null || true
    rmdir "$INSTANCE" 2>/dev/null || echo "WARNING: could not remove ${INSTANCE}" >&2
  fi
  remove_probes
}

start_instance() {
  local min_bytes=$((MIN_MIB * 1024 * 1024)) probe
  mkdir "$INSTANCE"
  echo 0 >"${INSTANCE}/tracing_on"
  echo mono >"${INSTANCE}/trace_clock"
  echo "$BUFFER_KB" >"${INSTANCE}/buffer_size_kb"
  for probe in "${SIZED_PROBES[@]}"; do
    echo "size >= ${min_bytes}" >"${INSTANCE}/events/${GROUP}/${probe}/filter"
  done
  echo 1 >"${INSTANCE}/events/${GROUP}/enable"
  echo "pages >= $((min_bytes / 4096))" >"${INSTANCE}/events/amdgpu/amdgpu_bo_create/filter"
  echo 1 >"${INSTANCE}/events/amdgpu/amdgpu_bo_create/enable"
  echo "bo_size >= ${min_bytes}" >"${INSTANCE}/events/amdgpu/amdgpu_bo_move/filter"
  echo 1 >"${INSTANCE}/events/amdgpu/amdgpu_bo_move/enable"
}

main() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
  [ -w "${TRACEFS}/dynamic_events" ] || die "no writable tracefs at ${TRACEFS}"
  [ -d "$INSTANCE" ] && die "${INSTANCE} exists: a trace is running, or a previous one did not clean up"

  if [ "${1:-}" = "--check" ]; then
    trap remove_probes EXIT
    add_probes
    grep "^f:${GROUP}/" "${TRACEFS}/dynamic_events"
    return 0
  fi
  local output="${1:?usage: vram-release-trace.sh OUTPUT | --check}"
  : >>"$output" || die "cannot write ${output}"

  trap cleanup EXIT
  trap 'exit 0' INT TERM
  add_probes
  start_instance
  cat "${INSTANCE}/trace_pipe" >>"$output" &
  reader_pid=$!
  echo 1 >"${INSTANCE}/tracing_on"
  while :; do
    kill -0 "$reader_pid" 2>/dev/null || die "the trace reader stopped; ${output} is incomplete"
    echo "sync $(date +%s.%N)" >"${INSTANCE}/trace_marker"
    sleep "$SYNC_SECONDS" &
    wait $!
  done
}

main "$@"
