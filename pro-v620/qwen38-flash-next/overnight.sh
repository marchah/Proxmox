#!/usr/bin/env bash
# Unattended overnight pipeline. Proxmox HOST, root. Survives without supervision.
#
# DESIGN RULE: every stage is failure-isolated. A stage that dies must not stall the night,
# so each is wrapped, timed out, and appends its outcome to RESULTS regardless. Partial
# results beat a stalled queue.
#
# Stage order and why:
#   1 governor  — pick the winner, then MAKE IT PERSISTENT. Everything downstream is
#                 invalid at 1500 MHz, and cpu-powersave.service re-pins powersave on boot.
#   2 reval     — re-measure the placement curve + threads + the three placement extremes
#                 at full clock, because every earlier number was taken downclocked.
#   3 mtp       — build llama.cpp PR #28097, which already contains #27836's three
#                 NextN/MTP commits rebased AND the draft-head-only (unsloth) GGUF layout
#                 that the downloaded drafter actually uses. Then pick the drafter layout
#                 by measurement and sweep --spec-draft-n-max, against a no-speculation
#                 control on that same binary. This is the only lever left that attacks
#                 the ~43 ms fixed floor, by amortising it across accepted tokens.
#   4 parallel  — amortise the same floor across STREAMS instead. Re-sweeps --threads inside
#                 it, because concurrency changes which term dominates.
#   5 splits    — GGML_SCHED_DEBUG graph-split count, to quantify the floor for an upstream report.
#   6 restore   — put the box back: governor persistent, CT 121 up, CT 123 left stopped.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

CT=120; ENVF=/etc/llamacpp-qwen38fn.env
RUN="${RUN:-/root/qwen38-flash-next/overnight-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$RUN"
RESULTS="${RUN}/RESULTS.md"
LOG="${RUN}/pipeline.log"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n########## %s  %s\n' "$(date -u +%FT%TZ)" "$*"; }
note() { printf '%s\n' "$*" >>"$RESULTS"; }

# 🔴 stage() lives in stagelib.sh because `timeout <shell function>` exits 127 instantly.
# That collapsed this whole pipeline once: all six stages "failed" in 2 seconds and the
# failure-isolation meant to protect the night was what hid it.
# shellcheck source=stagelib.sh
. ./stagelib.sh

setv() { pct exec "$CT" -- python3 -c '
import json, os, re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
line = key + "=" + json.dumps(val)
src = open(path).read() if os.path.exists(path) else ""
src, n = re.subn(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, src)
if not n: src = src.rstrip("\n") + "\n" + line + "\n"
open(path, "w").write(src)' "$ENVF" "$1" "$2"; }

note "# Overnight run — $(date -u +%FT%TZ)"
note ""
note "Host: EPYC 7532 / ROMED8-2T / 2x Radeon Pro V620 / 251 GiB (4 of 8 channels)."
note "Model: Qwen3.8-Flash-Next UD-Q4_K_XL (111.3 GB), llama.cpp b11018 self-built."
note ""
note "## Stage log"
note ""

# ---------------------------------------------------------------- 1. governor
s1_governor() {
  while pgrep -f "governor-test.sh" >/dev/null 2>&1; do sleep 60; done
  sleep 10
  local gov
  gov=$(python3 - <<'PY'
import glob, json, os, statistics as st
best, bestv = "performance", -1.0
dirs = sorted(glob.glob("/root/qwen38-flash-next/gov-*/"), key=os.path.getmtime)
if dirs:
    for g in ("performance", "schedutil"):
        vals = []
        for f in glob.glob(os.path.join(dirs[-1], g + "-r*.json")):
            try: s = json.load(open(f)).get("summary", {})
            except Exception: continue
            a = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d0/")]
            if a: vals.append(st.median(a))
        if vals:
            m = st.median(vals)
            # schedutil takes ties and anything within 2%: it clocks down when idle and
            # needs no per-service toggle, so it has no silent-failure mode.
            if m > bestv * 1.02 or (g == "schedutil" and m > bestv * 0.98):
                best, bestv = g, m
print(best)
PY
)
  echo "winning governor: ${gov}"
  echo "$gov" >"${RUN}/governor.txt"

  # 🔴 PERSIST IT. cpu-powersave.service re-pins powersave at every boot, so without this
  # the single largest performance factor on the box silently reverts on reboot.
  cp -a /etc/systemd/system/cpu-powersave.service "${RUN}/cpu-powersave.service.orig"
  cat >/etc/systemd/system/cpu-governor.service <<UNIT
[Unit]
Description=Set CPU governor=${gov} (replaces cpu-powersave.service)
Documentation=CognitiveStack personal/hermes memory host-power-saving
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# 🔴 WHY NOT powersave: this host uses acpi-cpufreq, where \`powersave\` PINS every core to
# the minimum 1500 MHz against a 3308 MHz maximum -- it is NOT the dynamic governor it is
# under amd-pstate-epp. Measured 2026-09-17 on Qwen3.8-Flash-Next: -52% decode at short
# prompt, -27% at 8k, and run-to-run spread blowing out from ~1.4% to as much as 36%.
# C-states are innocent and the BIOS levers should stay: pinning cores out of C2 via
# /dev/cpu_dma_latency changed throughput by 0%. Idle cost of this change is ~1.7 W of CPU
# package power, measured with RAPL (/sys/class/powercap/intel-rapl:0/energy_uj).
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "\$g" ] && echo ${gov} > "\$g"; done; exit 0'
ExecStart=/bin/sh -c 'v=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor); [ "\$v" = "${gov}" ] || { echo "FATAL: governor is \$v, wanted ${gov}" >&2; exit 1; }'

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl disable --now cpu-powersave.service 2>/dev/null || true
  systemctl enable --now cpu-governor.service
  local got; got=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
  echo "governor now: ${got}"
  note ""
  note "## Governor"
  note ""
  note "Winner: **${gov}** (now persistent via \`cpu-governor.service\`; \`cpu-powersave.service\` disabled)."
  note ""
  python3 - "$gov" >>"$RESULTS" <<'PY'
import glob, json, os, statistics as st, sys
dirs = sorted(glob.glob("/root/qwen38-flash-next/gov-*/"), key=os.path.getmtime)
print("| governor | d0 t/s | d8000 t/s | n |")
print("| --- | ---: | ---: | ---: |")
if dirs:
    for g in ("performance", "schedutil", "ondemand", "powersave"):
        a, b = [], []
        for f in sorted(glob.glob(os.path.join(dirs[-1], g + "-r*.json"))):
            try: s = json.load(open(f)).get("summary", {})
            except Exception: continue
            x = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d0/")]
            y = [v["decode_tps_median"] for k, v in s.items() if k.startswith("d8000/")]
            if x: a.append(st.median(x))
            if y: b.append(st.median(y))
        if a: print("| `%s` | %.2f | %.2f | %d |" % (g, st.median(a), st.median(b) if b else 0, len(a)))
print()
print("Idle CPU package power (RAPL): performance 54.9 W, schedutil 54.2, ondemand 54.2,")
print("powersave 53.2 — a 1.7 W spread, which is why per-core governor pinning is not worth")
print("building: idle cores are halted in C2 regardless of governor.")
PY
}
stage governor 9000 s1_governor

# ---------------------------------------------------------------- 2. re-validate
s2_reval() { GOV="$(cat "${RUN}/governor.txt" 2>/dev/null || echo performance)" ROUNDS=2 ./revalidate.sh; }
stage revalidate 21600 s2_reval

say "pipeline part 1 done; MTP and parallel stages follow in overnight-part2.sh"
note ""
note "_Part 1 complete. See part 2 for MTP and --parallel._"
