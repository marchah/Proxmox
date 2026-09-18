#!/usr/bin/env bash
# Everything except MTP, in one pass. Runs on the Proxmox HOST from this directory.
#
# Ordering is deliberate: MTP speculation is tested LAST and separately, because its gain
# should be largely independent of placement — so find the best placement first, then add
# speculation on top of it, rather than sweeping a two-dimensional space.
#
# Baseline to beat: -ncmoe 20, 2 cards, threads 32 = 11.7 t/s at a 31-token prompt.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
BASE="${BASE:-/root/qwen38-flash-next/tune-$(date -u +%Y%m%dT%H%M%SZ)}"
COMMON=(REPS=1 DEPTHS=0 N_PREDICT=160)

run() {  # run <label> <env assignments...>
  local label="$1"; shift
  echo
  echo "######## ${label} ########"
  env "${COMMON[@]}" "$@" OUT_DIR="${BASE}/${label}" ./placement-sweep.sh 2>&1 \
    | grep -E "^==> (===|healthy|GPU1|tensor-split|⚠️)" || true
}

# AXIS 1 — threads. STREAM measured 8 threads saturating four channels (80.3 GB/s) and 32
# being WORSE (74.8); the CPU expert FFN is memory-bound GEMV, so the inherited 32 (from
# qwen3.6, which had NO CPU-side work) may be contention rather than throughput.
for th in 8 16 24 48; do run "threads-${th}" NCMOE_LIST=20 THREADS="${th}"; done

# AXIS 2 — finer ncmoe at the spill edge. 15 was the fastest cell measured (13.0 t/s) but
# spilled 2.2 GiB to GTT; 16-18 may avoid the spill and beat it outright.
run "ncmoe-fine" NCMOE_LIST="14 16 17 18" THREADS=32

# AXIS 3 — ubatch/batch. Inherited 4096/1024 from a fully GPU-resident model; a hybrid
# placement has completely different tradeoffs and this was never varied.
for ub in 256 512 2048; do run "ubatch-${ub}" NCMOE_LIST=20 THREADS=32 UBATCH="${ub}"; done
run "batch1024-ub256" NCMOE_LIST=20 THREADS=32 BATCH=1024 UBATCH=256

# AXIS 4 — buy VRAM back cheaply and spend it on a lower ncmoe. q8_0 KV frees ~0.8 GiB and
# the projector on CPU frees ~1.1 GiB; together ~2 ncmoe steps.
run "kv-q8"          NCMOE_LIST=20 THREADS=32 KV_TYPE=q8_0
run "mmproj-cpu"     NCMOE_LIST=20 THREADS=32 MMPROJ_CPU=true
run "kv-q8-mmproj-cpu-ncmoe16" NCMOE_LIST=16 THREADS=32 KV_TYPE=q8_0 MMPROJ_CPU=true

# AXIS 5 — 🔴 CPU ONLY. The real question is not speed, it is that BOTH cards come free for
# other models. -ncmoe 48 already showed the GPUs holding just 9.2 GiB and still doing
# 8.6 t/s, so the last 9.2 GiB may be worth very little. Threads matter far more here, since
# attention and the output head move to the CPU too.
for th in 16 32 64; do run "cpuonly-threads-${th}" CPU_ONLY=true NCMOE_LIST=48 THREADS="${th}"; done

# AXIS 6 — an undocumented env var from llama.cpp #28623's description. Free to try.
run "ple-resident" NCMOE_LIST=20 THREADS=32 PLE_RESIDENT=1

echo
echo "################ SUMMARY ################"
python3 - "${BASE}" <<'PYSUM'
import glob, json, os, statistics, sys
base = sys.argv[1]
rows = []
for d in sorted(glob.glob(os.path.join(base, "*/"))):
    man = os.path.join(d, "manifest.json")
    mf = json.load(open(man)) if os.path.exists(man) else {}
    for f in sorted(glob.glob(os.path.join(d, "ncmoe*.json"))):
        try:
            j = json.load(open(f))
        except Exception:
            continue
        pl = j.get("placement") or {}
        dec = [v["decode_tps_median"] for v in (j.get("summary") or {}).values()
               if v.get("decode_tps_median")]
        if not dec:
            continue
        rows.append((round(statistics.median(dec), 2), os.path.basename(d.rstrip("/")),
                     pl.get("n_cpu_moe"), pl.get("vram_total_mib", 0),
                     max(pl.get("gpu1_gtt_mib", 0), pl.get("gpu2_gtt_mib", 0)),
                     bool(pl.get("possible_gtt_spill")), bool(j.get("any_degenerate"))))
rows.sort(reverse=True)
print("%-32s %-6s %9s %8s %-6s %-6s %s" % ("config", "ncmoe", "vram MiB", "gtt MiB", "spill", "degen", "decode t/s"))
for t, label, n, vram, gtt, spill, degen in rows:
    print("%-32s %-6s %9d %8d %-6s %-6s %6.2f" % (label, n, vram, gtt, spill, degen, t))
print()
print("baseline for reference: ncmoe 20 / 2 cards / threads 32 = 11.7 t/s")
PYSUM
echo
echo "results: ${BASE}"
