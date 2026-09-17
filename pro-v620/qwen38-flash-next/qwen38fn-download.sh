#!/usr/bin/env bash
# Download + verify unsloth/Qwen3.8-Flash-Next-GGUF UD-Q4_K_XL (4 shards) + the F16
# vision projector into /models/hf/qwen3.8-flash-next/.
#
# Resumable and idempotent: re-run to continue. A file with a matching .verified stamp
# is skipped.
#
# ⚠️ Two curl lessons, both learned the hard way on this 112 GB pull:
#   1. curl's own --retry does NOT re-evaluate `-C -`, so an interrupted transfer
#      restarted from byte 0 and silently discarded 22 GB. The retry loop must be
#      OUTSIDE curl so the resume offset is recomputed per attempt.
#   2. HF's CDN drops long HTTP/2 transfers with "stream was not closed cleanly:
#      CANCEL (err 8)". --http1.1 avoids it.
# --no-progress-meter is not cosmetic either: the meter wrote ~100 kB of carriage-return
# spam per file into the journal.
set -Eeuo pipefail

REPO=unsloth/Qwen3.8-Flash-Next-GGUF
DEST=/models/hf/qwen3.8-flash-next
BASE="https://huggingface.co/${REPO}/resolve/main"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-40}"

MANIFEST=$(cat <<'EOF'
4448186216b3af4cc558bbce2c3213f01608f8f8b2e5267a9767971dd3ec8082 UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf 10946624
3f342f1c1580473f1ee94ddd5b28206e8c07a70fa1a366f59d1d6c922919a6c9 UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00002-of-00004.gguf 49859583136
56758f40269cad5cd9b0d3d6fbae0f40f6d5be6de49e4ab392dbe83157d9cbd3 UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00003-of-00004.gguf 49376141504
753bda48b98ba4f1636134a90a967de1b2d3908a236c026e464777342e53510a UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf 12087983520
1f7b7f0b984cf065c604360c29c8098362ed61b290db0ff12c6f360bb1a8a980 mmproj-F16.gguf 904004000
EOF
)

log() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*"; }

while read -r sha rpath bytes; do
  [ -n "${sha:-}" ] || continue
  name="$(basename "$rpath")"
  out="${DEST}/${name}"
  stamp="${out}.verified"

  if [ -f "$stamp" ]; then log "SKIP  ${name}"; continue; fi

  attempt=0
  while :; do
    have=$( [ -f "$out" ] && stat -c %s "$out" || echo 0 )
    [ "$have" -ge "$bytes" ] && break

    attempt=$((attempt + 1))
    [ "$attempt" -le "$MAX_ATTEMPTS" ] || { log "FAIL  ${name}: gave up after ${MAX_ATTEMPTS} attempts"; exit 1; }
    log "GET   ${name}  attempt ${attempt}  from $(numfmt --to=iec "$have")/$(numfmt --to=iec "$bytes")"

    # -C - resumes from whatever is on disk NOW, because this is a fresh invocation.
    rc=0
    curl --http1.1 --no-progress-meter -fL -C - \
         --connect-timeout 30 --speed-limit 51200 --speed-time 180 \
         -o "$out" "${BASE}/${rpath}" || rc=$?
    [ "$rc" -eq 0 ] && break
    log "WARN  ${name}: curl exit ${rc}; re-resuming in 10s"
    sleep 10
  done

  actual=$(stat -c %s "$out")
  [ "$actual" = "$bytes" ] || { log "FAIL  ${name}: size ${actual} != ${bytes}"; exit 1; }

  log "HASH  ${name}"
  got=$(sha256sum "$out" | cut -d' ' -f1)
  [ "$got" = "$sha" ] || { log "FAIL  ${name}: sha256 mismatch"; exit 1; }
  touch "$stamp"
  log "OK    ${name}"
done <<<"$MANIFEST"

chown -R llamacpp:llamacpp "$DEST"
log "DONE  all files verified in ${DEST}"
