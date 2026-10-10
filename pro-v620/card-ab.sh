#!/usr/bin/env bash
# Per-card A/B of the two V620s: llama-bench on the same model, build and flags, from one
# container that holds both cards. Runs on the Proxmox HOST as root.
#
#   ./qwen38-flash-next/ct120-cutover.sh to-qwen38fn     # CT 120 takes both cards
#   VMID=120 ./qwen38-flash-next/thermal-guard.sh         # another shell
#   VMID=120 ./card-ab.sh
#
# Rounds alternate which card runs first, so thermal drift cannot favour one. While each
# bench runs, both cards' clock, power, junction temperature and VRAM are sampled every
# second; the card whose VRAM rose is the one the bench ran on, whatever its Vulkan index.
set -Eeuo pipefail

VMID="${VMID:-120}"
ROUNDS="${ROUNDS:-3}"
REPS="${REPS:-3}"
MODEL="${MODEL:-/models/hf/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf}"
LLAMACPP_DIR="${LLAMACPP_DIR:-/opt/llamacpp/llama-b11505}"
# The production -b 4096 does not fit llama-bench on this card (RADV out of memory).
COMMON=(-m "$MODEL" -ngl 99 -fa 1 -b 2048 -ub 1024 -r "$REPS" -o json)
# Each entry is one llama-bench invocation: prefill and decode at three depths, then a
# long prefill. The prior board's A/B measured the same tests.
TESTS=("-p 512 -n 128 -d 0,8192,32768" "-p 4096 -n 0 -d 0")
UNPINNED="${UNPINNED:-false}"
TRIP_FILE="${TRIP_FILE:-/root/qwen38-flash-next/THERMAL_TRIP}"
OUT_DIR="${OUT_DIR:-/root/card-ab/run-$(date -u +%Y%m%dT%H%M%SZ)}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
cd "$(dirname "$(readlink -f "$0")")"
[ -x ./capture-env.sh ] || die "capture-env.sh not found or not executable"
[ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; check cooling, then remove it"

HARNESS_COMMIT=""
d="$PWD"
while [ "$d" != "/" ]; do
  if [ -f "$d/HARNESS_COMMIT" ]; then HARNESS_COMMIT="$(head -1 "$d/HARNESS_COMMIT")"; break; fi
  d="$(dirname "$d")"
done
if [ -z "$HARNESS_COMMIT" ]; then
  [ "$UNPINNED" = "true" ] || die "no HARNESS_COMMIT: stage with push-harness.sh, or set UNPINNED=true for a run no record will cite"
  HARNESS_COMMIT="unpinned"
fi

[ "$(pct status "$VMID" 2>/dev/null)" = "status: running" ] || die "CT ${VMID} is not running"
mapfile -t CARDS < <(pct config "$VMID" | grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' \
                     | sed 's/^pci-//' | sort -u)
[ "${#CARDS[@]}" -eq 2 ] || die "CT ${VMID} must hold both cards (has ${#CARDS[@]})"
pct exec "$VMID" -- test -f "$MODEL" || die "${MODEL} not found in CT ${VMID}"
pct exec "$VMID" -- test -x "${LLAMACPP_DIR}/llama-bench" || die "no llama-bench in ${LLAMACPP_DIR}"
mkdir -p "$OUT_DIR"

# llama-bench needs the cards to itself. Stop the container's servers and start again on
# exit only those that were running.
was_active=()
for unit in llamacpp llamacpp-qwen38fn; do
  if pct exec "$VMID" -- systemctl is-active --quiet "$unit"; then
    was_active+=("$unit")
    pct exec "$VMID" -- systemctl stop "$unit"
  fi
done
SAMPLER_PID=""
cleanup() {
  [ -z "$SAMPLER_PID" ] || kill "$SAMPLER_PID" 2>/dev/null || true
  if [ -e "$TRIP_FILE" ]; then
    log "thermal trip recorded: leaving ${was_active[*]:-no service} stopped"
  else
    for unit in "${was_active[@]}"; do pct exec "$VMID" -- systemctl start "$unit" || true; done
  fi
}
trap cleanup EXIT

./capture-env.sh "$VMID" "${was_active[0]:-llamacpp}" >"${OUT_DIR}/environment.json" \
  || die "capture-env.sh failed for CT ${VMID}"
cat >"${OUT_DIR}/manifest.json" <<JSON
{"when": "$(date -u +%FT%TZ)", "harness_commit": "${HARNESS_COMMIT}", "vmid": ${VMID},
 "model": "${MODEL}", "llamacpp_dir": "${LLAMACPP_DIR}", "rounds": ${ROUNDS}, "reps": ${REPS},
 "common": "${COMMON[*]}", "cards": "${CARDS[*]}"}
JSON

hw() { local h; for h in "/sys/bus/pci/devices/$1"/hwmon/hwmon*; do echo "$h"; return; done; }
# ts, card, sclk MHz, mclk MHz, power W, junction °C, VRAM MiB, GPU busy % (-1: unreadable)
sampler() {
  while :; do
    local now card h
    now="$(date +%s)"
    for card in "${CARDS[@]}"; do
      h="$(hw "$card")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$card" \
        "$(( $(cat "$h/freq1_input" 2>/dev/null || echo 0) / 1000000 ))" \
        "$(( $(cat "$h/freq2_input" 2>/dev/null || echo 0) / 1000000 ))" \
        "$(( $(cat "$h/power1_average" 2>/dev/null || echo 0) / 1000000 ))" \
        "$(( $(cat "$h/temp2_input" 2>/dev/null || echo 0) / 1000 ))" \
        "$(( $(cat "/sys/bus/pci/devices/${card}/mem_info_vram_used" 2>/dev/null || echo 0) / 1048576 ))" \
        "$(cat "/sys/bus/pci/devices/${card}/gpu_busy_percent" 2>/dev/null || echo -1)"
    done
    sleep 1
  done
}

log "CT ${VMID}, cards ${CARDS[*]}, harness ${HARNESS_COMMIT:0:12}; ${ROUNDS} rounds -> ${OUT_DIR}"
for round in $(seq 1 "$ROUNDS"); do
  if [ $((round % 2)) -eq 1 ]; then order=(0 1); else order=(1 0); fi
  for dev in "${order[@]}"; do
    for t in "${!TESTS[@]}"; do
      [ ! -e "$TRIP_FILE" ] || die "thermal trip during the run: see ${TRIP_FILE}"
      tag="r${round}-Vulkan${dev}-t${t}"
      log "${tag}: ${TESTS[$t]}"
      sampler >"${OUT_DIR}/${tag}.tsv" &
      SAMPLER_PID=$!
      read -r -a extra <<<"${TESTS[$t]}"
      pct exec "$VMID" -- env LD_LIBRARY_PATH="$LLAMACPP_DIR" \
        "${LLAMACPP_DIR}/llama-bench" "${COMMON[@]}" -dev "Vulkan${dev}" "${extra[@]}" \
        >"${OUT_DIR}/${tag}.json" 2>"${OUT_DIR}/${tag}.log" \
        || log "🔴 ${tag} failed (see ${tag}.log)"
      kill "$SAMPLER_PID" 2>/dev/null || true
      wait "$SAMPLER_PID" 2>/dev/null || true
      SAMPLER_PID=""
    done
  done
done

python3 - "$OUT_DIR" >"${OUT_DIR}/SUMMARY.md" <<'PY'
import json, pathlib, statistics as st, sys
d = pathlib.Path(sys.argv[1])
res, tel = {}, {}
for f in sorted(d.glob("r*-Vulkan*-t*.json")):
    tag = f.stem
    rows = [l.split("\t") for l in (d / (tag + ".tsv")).read_text().splitlines() if l.count("\t") == 7]
    base = {}
    for r in rows:
        base.setdefault(r[1], int(r[6]))
    peak = {c: max(int(r[6]) for r in rows if r[1] == c) for c in base}
    # The card this bench ran on: the one whose VRAM rose.
    card = max(base, key=lambda c: peak[c] - base[c]) if base else "?"
    busy = [r for r in rows if r[1] == card and int(r[6]) - base[card] > 1024]
    t = tel.setdefault(card, {"sclk": [], "mclk": [], "w": [], "tj": [], "busy": []})
    for r in busy:
        t["sclk"].append(int(r[2])); t["mclk"].append(int(r[3])); t["w"].append(int(r[4])); t["tj"].append(int(r[5]))
        if int(r[7]) >= 0:
            t["busy"].append(int(r[7]))
    try:
        data = json.loads(f.read_text() or "[]")
    except json.JSONDecodeError:
        data = []
    for b in data:
        test = ("pp%d" % b["n_prompt"]) if b["n_prompt"] else ("tg%d" % b["n_gen"])
        if b.get("n_depth"):
            test += " @d%d" % b["n_depth"]
        res.setdefault(test, {}).setdefault(card, []).append(b["avg_ts"])
cards = sorted(tel)
print("# Per-card llama-bench A/B\n")
print("Each value is the median over rounds of llama-bench's mean t/s; the range is min–max.\n")
print("| test | " + " | ".join("`%s`" % c for c in cards) + " | %s |" % (
    "`%s` vs `%s`" % (cards[1][5:], cards[0][5:]) if len(cards) == 2 else "difference"))
print("|---|" + "---:|" * (len(cards) + 1))
def fmt(xs):
    return "%.1f (%.1f–%.1f)" % (st.median(xs), min(xs), max(xs)) if xs else "—"
for test in sorted(res, key=lambda k: (k.startswith("tg"), int(k.split()[0][2:]),
                                       int(k.split("@d")[1]) if "@d" in k else 0)):
    xs = [res[test].get(c, []) for c in cards]
    delta = "%+.1f%%" % (100 * (st.median(xs[1]) / st.median(xs[0]) - 1)) if len(cards) == 2 and all(xs) else "—"
    print("| %s | %s | %s |" % (test, " | ".join(fmt(x) for x in xs), delta))
print("\n| card | median GPU busy % | median sclk, MHz | median mclk, MHz | median power, W | max junction, °C | samples |")
print("|---|---:|---:|---:|---:|---:|---:|")
for c in cards:
    t = tel[c]
    if t["sclk"]:
        print("| `%s` | %s | %d | %d | %d | %d | %d |" % (c, "%d" % st.median(t["busy"]) if t["busy"] else "—",
              st.median(t["sclk"]), st.median(t["mclk"]),
              st.median(t["w"]), max(t["tj"]), len(t["sclk"])))
PY
log "done — ${OUT_DIR}/SUMMARY.md"
