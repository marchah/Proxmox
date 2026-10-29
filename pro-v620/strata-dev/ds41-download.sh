#!/usr/bin/env bash
# Download + verify antirez/deepseek-v4.1-flash-gguf's Q2 (IQ2_XXS gate/up + Q2_K down
# experts, native FP8 Engram; 340.6 GiB) into the shared model store, pinned to revision
# dd8a266f (2026-09-12). It is the September V4.1; DeepSeek-V4.1-Flash-1017 has the same
# config, code and tensor index (../strata/DEEPSEEK-V4.1-PLAN.md), so this file serves
# development until a 1017 build in the same format exists.
#
# Runs on the Proxmox HOST, where the store is /mnt/models/store; CT 124 reads it at
# /models/hf/deepseek-v4.1-flash read-only. Resumable and idempotent: re-run to continue.
# A file with a matching .verified stamp is skipped; a complete file without one is only
# hashed.
#
#   systemd-run --unit=ds41-dl --collect ./ds41-download.sh
#
# The retry loop sits outside curl so `-C -` re-reads the resume offset on every attempt,
# and --http1.1 avoids the HF CDN's dropped HTTP/2 streams (see ../qwen38-flash-next/qwen38fn-download.sh).
set -Eeuo pipefail

REPO=antirez/deepseek-v4.1-flash-gguf
REVISION=dd8a266f7145edc19e2334b46e19b6821f221dc7
DEST="${DEST:-/mnt/models/store/hf/deepseek-v4.1-flash}"
# The store's owner: UID 1000 in the privileged CTs 120 and 123.
OWNER="${OWNER:-1000:1000}"
BASE="https://huggingface.co/${REPO}/resolve/${REVISION}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-40}"

MANIFEST=$(cat <<'EOF'
1ce6a8f8806205c13330d7ca287bd198331dc5ca35ccc5d8a9a92a188a6f6f42 DeepSeek-V4.1-Flash-Q2.gguf 365713686528
EOF
)

log() { printf '%s  %s\n' "$(date -u +%FT%TZ)" "$*"; }

mkdir -p "$DEST"
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

chown -R "$OWNER" "$DEST"
log "DONE  all files verified in ${DEST}"
