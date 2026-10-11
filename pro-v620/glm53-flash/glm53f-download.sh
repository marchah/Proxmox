#!/usr/bin/env bash
# Download + verify unsloth/GLM-5.3-Flash-GGUF UD-Q4_K_XL (6 shards) and the F16 vision
# projector into /models/hf/glm-5.3-flash/, pinned to repo revision a38483c8
# (2026-10-05, "Update shards due to upstream changes"). The MTP layer is inside the
# shards; there is no separate head.
#
# Resumable and idempotent: re-run to continue. A file with a matching .verified stamp is
# skipped; a complete file without one is only hashed.
#
# The retry loop sits outside curl so `-C -` re-reads the resume offset on every attempt,
# and --http1.1 avoids the HF CDN's dropped HTTP/2 streams (see qwen38fn-download.sh).
set -Eeuo pipefail

REPO=unsloth/GLM-5.3-Flash-GGUF
REVISION=a38483c8cd5df544f53d70fb281afe97369d5ab6
DEST="${DEST:-/models/hf/glm-5.3-flash}"
BASE="https://huggingface.co/${REPO}/resolve/${REVISION}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-40}"

MANIFEST=$(cat <<'EOF'
b59c030090f012b38213bc8c4f78ce10767f2693d730d0dbcd3dc16a5f69e2bc UD-Q4_K_XL/GLM-5.3-Flash-UD-Q4_K_XL-00001-of-00006.gguf 9429984
d3ecb6ff3957a99878f9a0352676a0913748a431a9a4a1b1ffa5ade9b8947a74 UD-Q4_K_XL/GLM-5.3-Flash-UD-Q4_K_XL-00002-of-00006.gguf 49198039200
328073c004e7c5395b208247feed26089db247b94dd8fa4ab0f2569d86c1d770 UD-Q4_K_XL/GLM-5.3-Flash-UD-Q4_K_XL-00003-of-00006.gguf 49988626304
6803ab7effa6da4a0b02c9c7865952fdd6c5b2e10e53903348da369e90bd13f9 UD-Q4_K_XL/GLM-5.3-Flash-UD-Q4_K_XL-00004-of-00006.gguf 48700701344
852f3df9dacde3d196796f9fe738468e80c8701555ff0a8c30bc010fb8974dd8 UD-Q4_K_XL/GLM-5.3-Flash-UD-Q4_K_XL-00005-of-00006.gguf 49026026752
c6ba510fafc1e12cc0addbc361a329c0c592ab96980098e7e25e107d8faa983e UD-Q4_K_XL/GLM-5.3-Flash-UD-Q4_K_XL-00006-of-00006.gguf 2784497888
922b809664d6a89cc1e40bfeaa63618000edc6651baf4082ce0718a784adf947 mmproj-F16.gguf 1128047296
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
