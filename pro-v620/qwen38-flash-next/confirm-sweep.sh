#!/usr/bin/env bash
# Confirm the tuning matrix's outliers at 3 reps, and compose the two independent wins.
# Runs on the Proxmox HOST from this directory.
#
# The matrix was 1 rep per cell against a ~5% noise floor, so most of it was
# indistinguishable. Only these are worth confirming:
#   * the -ncmoe 15/16/17 cluster (clearly above baseline)
#   * -ncmoe x threads 16, never composed
#   * mmproj-CPU alone at 9.83 t/s, which should have been a no-op on a text benchmark
#   * -ncmoe 48 as the "give the GPUs back" candidate, at its best thread count
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
BASE="${BASE:-/root/qwen38-flash-next/confirm-$(date -u +%Y%m%dT%H%M%SZ)}"

run() { local label="$1"; shift
  echo; echo "######## ${label} ########"
  env REPS=3 DEPTHS="0,8000" N_PREDICT=160 "$@" OUT_DIR="${BASE}/${label}" \
    ./placement-sweep.sh 2>&1 | grep -E "^==> (===|healthy|GPU1|tensor-split|⚠️)" || true
}

# compose the two wins, 3 reps, and include depth since that is where it will actually live
run "ncmoe15-17-threads16" NCMOE_LIST="15 16 17" THREADS=16
run "ncmoe15-17-threads32" NCMOE_LIST="15 16 17" THREADS=32

# the headroom variant: same speed as ncmoe 17 in the matrix but with less VRAM and no spill
run "ncmoe16-q8kv-mmprojcpu-t16" NCMOE_LIST=16 THREADS=16 KV_TYPE=q8_0 MMPROJ_CPU=true

# recheck the suspicious result in isolation
run "mmprojcpu-recheck" NCMOE_LIST=20 THREADS=16 MMPROJ_CPU=true
run "mmproj-gpu-control" NCMOE_LIST=20 THREADS=16

# the "give the GPUs back" candidate at its best thread count
run "ncmoe48-t16" NCMOE_LIST=48 THREADS=16

echo; echo "################ CONFIRMED (3 reps, d0 and d8000) ################"
python3 - "$BASE" <<'PYSUM'
import glob, json, os, statistics, sys
base = sys.argv[1]
rows = []
for d in sorted(glob.glob(os.path.join(base, "*/"))):
    man = os.path.join(d, "manifest.json")
    mf = json.load(open(man)) if os.path.exists(man) else {}
    per = {}
    for f in glob.glob(os.path.join(d, "ncmoe*.json")):
        try: j = json.load(open(f))
        except Exception: continue
        pl = j.get("placement") or {}
        n = pl.get("n_cpu_moe")
        for k, v in (j.get("summary") or {}).items():
            if v.get("decode_tps_median"):
                per.setdefault((n, k.split("/")[0]), []).append(v["decode_tps_median"])
        per.setdefault((n, "_vram"), []).append(pl.get("vram_total_mib", 0))
        per.setdefault((n, "_gtt"), []).append(max(pl.get("gpu1_gtt_mib", 0), pl.get("gpu2_gtt_mib", 0)))
        per.setdefault((n, "_degen"), []).append(bool(j.get("any_degenerate")))
    ns = sorted({k[0] for k in per if k[0] is not None})
    for n in ns:
        d0 = per.get((n, "d0"), []); d8 = per.get((n, "d8000"), [])
        rows.append((statistics.median(d0) if d0 else 0,
                     os.path.basename(d.rstrip("/")), n, mf.get("threads_override") or "?",
                     statistics.median(per.get((n, "_vram"), [0])),
                     max(per.get((n, "_gtt"), [0])),
                     statistics.median(d0) if d0 else 0, statistics.median(d8) if d8 else 0,
                     any(per.get((n, "_degen"), [False]))))
rows.sort(reverse=True)
print("%-32s %-6s %-8s %9s %8s %8s %8s %s" % ("config","ncmoe","threads","vram MiB","gtt MiB","d0 t/s","d8k t/s","degen"))
for _, label, n, th, vram, gtt, d0, d8, dg in rows:
    print("%-32s %-6s %-8s %9d %8d %8.2f %8.2f %s" % (label, n, th, vram, gtt, d0, d8, dg))
print()
print("prior: -ncmoe 20/threads 32 = 11.7 (d0) 10.3 (d8k) | -ncmoe 15 = 13.0 / 10.1 | -ncmoe 48 = 8.6 / 8.2")
PYSUM
echo "results: ${BASE}"
