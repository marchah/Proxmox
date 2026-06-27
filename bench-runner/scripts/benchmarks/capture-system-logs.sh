#!/usr/bin/env bash

set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: capture-system-logs.sh <run-dir> <phase>\n' >&2
  exit 2
fi

readonly RUN_DIR="$1"
readonly PHASE="$2"
readonly OUT_DIR="${RUN_DIR}/system-logs/${PHASE}"

mkdir -p "${OUT_DIR}"

run_capture() {
  local label="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"${OUT_DIR}/${label}.log" 2>&1 || true
}

date -Is >"${OUT_DIR}/timestamp.txt" 2>&1 || true
run_capture uname uname -a
run_capture uptime uptime
run_capture disk-free df -h

if command -v lscpu >/dev/null 2>&1; then
  run_capture lscpu lscpu
fi
if command -v free >/dev/null 2>&1; then
  run_capture free free -h
fi
if command -v lsblk >/dev/null 2>&1; then
  run_capture lsblk lsblk -o NAME,MODEL,SIZE,TYPE,FSTYPE,MOUNTPOINTS
fi
if command -v lspci >/dev/null 2>&1; then
  run_capture lspci lspci -nn
fi
if command -v sensors >/dev/null 2>&1; then
  run_capture sensors sensors
fi
if command -v rocm-smi >/dev/null 2>&1; then
  run_capture rocm-smi rocm-smi --showallinfo
fi
if command -v nvidia-smi >/dev/null 2>&1; then
  run_capture nvidia-smi nvidia-smi -q
fi
if command -v dmesg >/dev/null 2>&1; then
  run_capture dmesg-tail sh -c 'dmesg -T 2>/dev/null | tail -n 300'
fi
if command -v journalctl >/dev/null 2>&1; then
  run_capture journal-kernel-tail journalctl -k -n 300 --no-pager
fi
