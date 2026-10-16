#!/usr/bin/env bash
# Log what the NVMe model store reads and how CT 123's memory splits, every INTERVAL seconds,
# so a test can show the RAM-resident experts stayed in the page cache. Under mmap, experts
# the kernel drops are read back from the store in the middle of a request; the VRAM checks
# do not see it. Runs on the Proxmox HOST as root:
#
#   systemd-run --unit=mimo-pagein --collect $PWD/page-in-sampler.sh /root/mimo/pagein-<stage>.tsv
#   ./page-in-summary.py <sweep OUT_DIR> /root/mimo/pagein-<stage>.tsv
#
# Columns: epoch, store reads (MiB, cumulative), major faults (host-wide, cumulative), CT
# memory in use, its page cache and anonymous parts, its limit, and the host's MemAvailable
# and MemFree, all in MiB. MemAvailable counts the experts' page cache as reclaimable, so
# MemFree is the host's margin. A CT restart recreates its cgroup; the CT columns read 0
# until it is back.
set -Eeuo pipefail

OUT="${1:?usage: page-in-sampler.sh <output.tsv>}"
VMID="${VMID:-123}"
INTERVAL="${INTERVAL:-2}"
STORE="${STORE:-/mnt/models}"

dev="$(basename "$(readlink -f "$(findmnt -no SOURCE "$STORE")")")"
stat="/sys/block/${dev}/stat"
[ -r "$stat" ] || { echo "ERROR: no ${stat} for ${STORE}" >&2; exit 1; }
cg="/sys/fs/cgroup/lxc/${VMID}"

printf 'epoch\tstore_read_mib\tpgmajfault\tct_mib\tct_file_mib\tct_anon_mib\tct_max_mib\thost_avail_mib\thost_free_mib\n' >"$OUT"
while :; do
  read -r _ _ sectors _ <"$stat"
  majflt="$(awk '$1 == "pgmajfault" {print $2}' /proc/vmstat)"
  avail="$(awk '$1 == "MemAvailable:" {print int($2 / 1024)}' /proc/meminfo)"
  free="$(awk '$1 == "MemFree:" {print int($2 / 1024)}' /proc/meminfo)"
  cur=0 file=0 anon=0 max=0
  if [ -r "${cg}/memory.current" ]; then
    cur=$(( $(cat "${cg}/memory.current" 2>/dev/null || echo 0) / 1048576 ))
    read -r file anon < <(awk '$1 == "file" { f = $2 } $1 == "anon" { a = $2 }
      END { printf "%d %d\n", f / 1048576, a / 1048576 }' "${cg}/memory.stat" 2>/dev/null || echo "0 0")
    max="$(cat "${cg}/memory.max" 2>/dev/null || echo 0)"
    [ "$max" = max ] && max=0
    max=$(( max / 1048576 ))
  fi
  printf '%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n' "$(date +%s)" $(( sectors / 2048 )) "$majflt" \
    "$cur" "$file" "$anon" "$max" "$avail" "$free" >>"$OUT"
  sleep "$INTERVAL"
done
