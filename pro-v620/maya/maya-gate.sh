#!/usr/bin/env bash
# The quality gate of the Maya test record (stage 1): Maya's next-token distributions against
# llama.cpp's on the same GGUF and tokens. Runs on the Proxmox HOST as root, from a harness
# staged with ../push-harness.sh, with CT 123 in a Maya test setup
# (../glm53-flash/ct123-test-host.sh) and maya-glm53f started once, so its config exists.
#
#   ./maya-gate.sh                                   # UD-Q4_K_XL
#   LABEL=maya-l PACK=/models/maya/Maya-L/pack \
#     MODEL=/models/maya/Maya-L/GLM-5.3-Flash-Maya-L-IQ3_S-00001-of-00004.gguf \
#     ALSO_REF=ud ./maya-gate.sh                     # Maya-L, also scored against UD-Q4_K_XL's reference
#
# Steps (maya-gate.py has each one's detail), outputs in /models/maya/gate/ in CT 123:
# - the texts: eight of this repository's READMEs, PER tokens of each (default 512), one sequence;
# - the reference: llama.cpp on the CPU over the sequence, kept as top-64 log-probs per position
#   after the first CTX tokens (default 64); reused only when its manifest matches the model's
#   shards, the dumper build, the tokens and CTX (maya-gate.py check-ref);
# - Maya's score of the same positions on GPU 2, and the verdict against the plan's thresholds.
#
# Both servers stay stopped: the gate needs the card and the RAM. thermal-guard.sh writes
# TRIP_FILE on a trip; the gate will not start with it present and checks it before each step.
set -Eeuo pipefail

VMID="${VMID:-123}"
LABEL="${LABEL:-ud}"
PACK="${PACK:-/models/maya/ud-q4_k_xl/pack}"
MODEL="${MODEL:-/models/hf/glm-5.3-flash/GLM-5.3-Flash-UD-Q4_K_XL-00001-of-00006.gguf}"
ALSO_REF="${ALSO_REF:-}"
PER="${PER:-512}"
CTX="${CTX:-64}"
TRIP_FILE="${TRIP_FILE:-/root/qwen38-flash-next/THERMAL_TRIP}"
HOST_OUT="${HOST_OUT:-/root/glm53-flash/maya-gate-${LABEL}-$(date -u +%Y%m%dT%H%M%SZ)}"

readonly G=/models/maya/gate
readonly CFG=/var/lib/maya-glm53f/config.json
readonly PY=/opt/maya/venv/bin/python
readonly LLAMA=/opt/maya/llama.cpp-b11583
readonly TEXTS=(../README.md ../TEST-RECORDS.md ../strata/README.md ../glm53-flash/README.md
  ../qwen38-flash-next/README.md ../mimo-v26-pro/README.md ../gpu-thermal-watchdog/README.md
  ../undervolt/README.md)

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '==> %s %s\n' "$(date -u +%FT%TZ)" "$*"; }
no_trip() { [ ! -e "$TRIP_FILE" ] || die "thermal trip recorded in ${TRIP_FILE}; check cooling, then remove it"; }
in_ct() { pct exec "$VMID" -- "$@"; }
gate() { no_trip; in_ct "$PY" "$G/maya-gate.py" "$@"; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
[[ "$LABEL" =~ ^[a-z0-9-]+$ ]] || die "LABEL must be lower-case letters, digits and dashes"
cd "$(dirname "$(readlink -f "$0")")"
[ -f maya-gate.py ] || die "maya-gate.py not found beside this script"
no_trip
in_ct test -f "$CFG" || die "no ${CFG}: start maya-glm53f once so its launcher writes the config"
in_ct test -f "$PACK/native_experts.txt" || die "no pack at ${PACK}"
in_ct test -f "$MODEL" || die "no model at ${MODEL}"
in_ct test -x "$LLAMA/llm_logits_dump" || die "no ${LLAMA}/llm_logits_dump; run install.sh"

log "stopping the model servers: the gate needs GPU 2 and the RAM"
in_ct systemctl stop maya-glm53f llamacpp-glm53f 2>/dev/null || true
in_ct install -d -o llamacpp -g llamacpp "$G" "$G/texts"
pct push "$VMID" maya-gate.py "$G/maya-gate.py" --perms 0755
i=0
for t in "${TEXTS[@]}"; do
  i=$((i + 1))
  pct push "$VMID" "$t" "$G/texts/$(printf '%02d' "$i")-$(basename "$(dirname "$t")")-$(basename "$t")" --perms 0644
done
mkdir -p "$HOST_OUT"

log "tokens: ${PER} of each of ${#TEXTS[@]} texts, with ${MODEL##*/}'s tokenizer"
gate tokens --tokenize "$LLAMA/build-cpu/bin/llama-tokenize" --model "$MODEL" --texts "$G/texts" \
  --per "$PER" --out "$G/${LABEL}-tokens.json"

if gate check-ref --ref "$G/${LABEL}-ref" --model "$MODEL" --dump "$LLAMA/llm_logits_dump" \
  --tokens "$G/${LABEL}-tokens.json" --ctx "$CTX"; then
  log "reference reused: $G/${LABEL}-ref.json"
else
  log "reference: llama.cpp ${LLAMA##*/} on the CPU, one token at a time"
  gate reference --dump "$LLAMA/llm_logits_dump" --model "$MODEL" --tokens "$G/${LABEL}-tokens.json" \
    --ctx "$CTX" --out "$G/${LABEL}-ref"
fi

log "Maya's score on GPU 2"
in_ct chmod a+r "$G/${LABEL}-ref.topk"
gate score --config "$CFG" --pack "$PACK" --tokens "$G/${LABEL}-tokens.json" --ctx "$CTX" \
  --topk "$G/${LABEL}-ref.topk" --out "$G/${LABEL}-maya"
rc=0
gate verdict --ref "$G/${LABEL}-ref.json" --score "$G/${LABEL}-maya.json" | tee "$HOST_OUT/verdict.json" || rc=$?

if [ -n "$ALSO_REF" ]; then
  # The same tokens and CTX are required: the comparison is position by position.
  gate check-ref --ref "$G/${ALSO_REF}-ref" --tokens "$G/${LABEL}-tokens.json" --ctx "$CTX" \
    || die "${ALSO_REF}'s reference does not match ${LABEL}'s tokens and CTX; no cross comparison"
  log "Maya on ${LABEL} against ${ALSO_REF}'s llama.cpp reference (quoted, not gated)"
  gate score --config "$CFG" --pack "$PACK" --tokens "$G/${LABEL}-tokens.json" --ctx "$CTX" \
    --topk "$G/${ALSO_REF}-ref.topk" --out "$G/${LABEL}-maya-vs-${ALSO_REF}"
fi

for f in $(in_ct bash -c "cd '$G' && ls ${LABEL}-*.json ${LABEL}-*.out ${LABEL}-*.err ${LABEL}-ref.dump.log 2>/dev/null"); do
  pct pull "$VMID" "$G/$f" "$HOST_OUT/$f"
done
log "done (verdict exit ${rc}) — ${HOST_OUT}"
exit "$rc"
