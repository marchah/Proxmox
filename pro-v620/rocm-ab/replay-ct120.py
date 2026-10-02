#!/usr/bin/env python3
"""Replay CT 120's real requests (MTP era) under the measured ROCm/Vulkan ratios. Runs in CT 120:

    journalctl -u llamacpp -o short-iso --since 2026-09-22T21:21:00 > /tmp/llj.txt
    python3 replay-ct120.py /tmp/llj.txt 2026-09-22T21:21

Per request the journal gives: new prompt tokens + prefill ms, generated tokens + decode ms,
and the final context size. ROCm time = prefill_ms / pp_ratio(depth) + decode_ms / tg_ratio(depth),
with ratios (ROCm/Vulkan, both MTP n3, production-capable ubatch) interpolated in depth.
pp ratios are averages over a cold 0→depth prefill, which understates ROCm's edge for an
incremental prefill deep in context, so this leans in Vulkan's favour.
"""
import re, sys, bisect, collections

def interp(pts, x):
    xs = [p[0] for p in pts]; i = bisect.bisect(xs, x)
    if i == 0: return pts[0][1]
    if i == len(pts): return pts[-1][1]
    (x0, y0), (x1, y1) = pts[i - 1], pts[i]
    return y0 + (y1 - y0) * (x - x0) / (x1 - x0)

# From Phase 3 (d0, llama-bench) and Phase 4 (deep cells, mtp-n3); held beyond 48k.
PP = [(0, 1529.2 / 1662.6), (16000, 1308.1 / 1291.1), (48000, 1058.2 / 863.4)]
TG = [(0, 102.6 / 110.3), (16000, 89.3 / 98.7), (48000, 76.0 / 82.5)]

since = sys.argv[2]
# Task ids restart at 0 with every server process, so key each request by the process id the
# journal prints ("llamacpp-serve[PID]:") as well; a window spanning restarts would otherwise
# let a later request overwrite an earlier one with the same id.
tasks = collections.defaultdict(dict)
for line in open(sys.argv[1], errors="replace"):
    if line[:19] < since: continue
    pid = re.search(r"\[(\d+)\]: ", line)
    pid = pid.group(1) if pid else "?"
    m = re.search(r"task (\d+) \| prompt eval time =\s+([\d.]+) ms /\s+(\d+) tokens", line)
    if m: tasks[pid, m.group(1)].update(pp_ms=float(m.group(2)), pp_n=int(m.group(3)), day=line[:10]); continue
    m = re.search(r"task (\d+) \|\s+eval time =\s+([\d.]+) ms /\s+(\d+) tokens", line)
    if m: tasks[pid, m.group(1)].update(tg_ms=float(m.group(2)), tg_n=int(m.group(3))); continue
    m = re.search(r"task (\d+) \| stop processing: n_tokens = (\d+)", line)
    if m: tasks[pid, m.group(1)].update(ctx=int(m.group(2)))

vk = rc = pp_ms = tg_ms = pp_n = tg_n = 0.0; n = 0; buckets = collections.defaultdict(lambda: [0, 0.0, 0.0])
for t in tasks.values():
    if not all(k in t for k in ("pp_ms", "tg_ms", "ctx")): continue
    end_pp = t["ctx"] - t["tg_n"]; mid_tg = t["ctx"] - t["tg_n"] / 2
    v = t["pp_ms"] + t["tg_ms"]
    r = t["pp_ms"] / interp(PP, end_pp) + t["tg_ms"] / interp(TG, mid_tg)
    vk += v; rc += r; pp_ms += t["pp_ms"]; tg_ms += t["tg_ms"]; pp_n += t["pp_n"]; tg_n += t["tg_n"]; n += 1
    b = "0-8k" if t["ctx"] < 8000 else "8-32k" if t["ctx"] < 32000 else "32-64k" if t["ctx"] < 64000 else "64k+"
    buckets[b][0] += 1; buckets[b][1] += v; buckets[b][2] += r

print(f"requests since {since}: {n}")
print(f"tokens: {pp_n/1e6:.1f}M prefilled, {tg_n/1e6:.2f}M generated (prefill/decode ratio {pp_n/tg_n:.1f})")
print(f"GPU time on Vulkan (measured): {vk/3.6e6:.1f} h  = prefill {pp_ms/3.6e6:.1f} h + decode {tg_ms/3.6e6:.1f} h")
print(f"same requests on ROCm (estimated): {rc/3.6e6:.1f} h  -> ROCm {100*(rc/vk-1):+.1f}%")
print("\nby final context:  requests   Vulkan h   ROCm h   ROCm vs Vulkan")
for b in ("0-8k", "8-32k", "32-64k", "64k+"):
    if b in buckets:
        c, v, r = buckets[b]; print(f"  {b:7s}       {c:6d}   {v/3.6e6:8.2f}   {r/3.6e6:6.2f}   {100*(r/v-1):+6.1f}%")
