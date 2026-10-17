#!/usr/bin/env bash
# Download + verify Project Maya's Maya-L quant of GLM-5.3-Flash (4 shards, 156.3 GB) into
# /models/maya/Maya-L/, pinned to peasantsmith/GLM-5.3-Flash-Maya-GGUF revision f16ee4ba
# (2026-10-09). The SHA-256s are the ones maya.py publishes at Maya v1.1.15. Maya writes its
# pack into the same folder (the engine finds the GGUF files at <pack>/..).
#
# Resumable and idempotent: re-run to continue. A file with a matching .verified stamp is
# skipped; a complete file without one is only hashed.
#
# The retry loop sits outside curl so `-C -` re-reads the resume offset on every attempt,
# and --http1.1 avoids the HF CDN's dropped HTTP/2 streams (see qwen38fn-download.sh).
set -Eeuo pipefail

REPO=peasantsmith/GLM-5.3-Flash-Maya-GGUF
REVISION=f16ee4ba50d8fd2bb726ea1862ca6ca14ba188da
DEST="${DEST:-/models/maya/Maya-L}"
BASE="https://huggingface.co/${REPO}/resolve/${REVISION}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-40}"

MANIFEST=$(cat <<'EOF'
c41aeaf3a3e0022150b7c355e7f4df6c92ba68c4794e3e827e02e56b54886b9e Maya-L/GLM-5.3-Flash-Maya-L-IQ3_S-00001-of-00004.gguf 47718550176
351d59366afb7be7dfc3fb7af91281f7ccf00760b17dc45f82090325a7b34f64 Maya-L/GLM-5.3-Flash-Maya-L-IQ3_S-00002-of-00004.gguf 47957222464
3685962fdfeaf130b74f98d3ce703ee33d818aa9991725932cb305b7c48db8af Maya-L/GLM-5.3-Flash-Maya-L-IQ3_S-00003-of-00004.gguf 47305387552
1af62cd72de6460c85369d988abbb790d6ec3a97507df51faf9bf32aa2b600d0 Maya-L/GLM-5.3-Flash-Maya-L-IQ3_S-00004-of-00004.gguf 13338053216
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

chown -R llamacpp:llamacpp "$DEST"
log "DONE  all files verified in ${DEST}"
