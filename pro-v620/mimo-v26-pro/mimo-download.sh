#!/usr/bin/env bash
# Download + verify ggml-org/MiMo-V2.6-Pro-RL-GGUF MXFP4 (7 shards) and both MTP heads into
# /models/hf/mimo-v2.6-pro-rl/, pinned to repo revision 5f387f52 (2026-10-02, the upload).
# The MTP head is a separate GGUF here; the main shards carry none.
#
# Resumable and idempotent: re-run to continue. A file with a matching .verified stamp is
# skipped; a complete file without one is only hashed.
#
# The retry loop sits outside curl so `-C -` re-reads the resume offset on every attempt,
# and --http1.1 avoids the HF CDN's dropped HTTP/2 streams (see qwen38fn-download.sh).
set -Eeuo pipefail

REPO=ggml-org/MiMo-V2.6-Pro-RL-GGUF
REVISION=5f387f5260fc110678396a3076a140c469b41eaa
DEST="${DEST:-/models/hf/mimo-v2.6-pro-rl}"
BASE="https://huggingface.co/${REPO}/resolve/${REVISION}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-40}"

MANIFEST=$(cat <<'EOF'
4d77de566b7bc5c283b1a5b8b0b73bdfd539d939f72d2a82e231e90323fd1589 MiMo-V2.6-Pro-RL-MXFP4-00001-of-00007.gguf 5948832
85973b1eb0b0bb54a6d7acccf412356b644dad472434557f4460fd1c2ae7c798 MiMo-V2.6-Pro-RL-MXFP4-00002-of-00007.gguf 97542736736
11f22ddfafd936643f208977aa17ed009d48f913aea9e3d47846482b8a4bdf4c MiMo-V2.6-Pro-RL-MXFP4-00003-of-00007.gguf 97542736768
c8ea6e7ea7655f43a3454aaca5d3b22d12f20b4afb48fc468d8c624162de0bf2 MiMo-V2.6-Pro-RL-MXFP4-00004-of-00007.gguf 97542736768
74becd913d58917e19bd3005759d59708845e42ec499a01e82db500ecfe0db56 MiMo-V2.6-Pro-RL-MXFP4-00005-of-00007.gguf 97542736768
d7183ce566d19264f4e1310155f7f9ffc8702906b2ee0b418a81736e67b2c77e MiMo-V2.6-Pro-RL-MXFP4-00006-of-00007.gguf 97542736768
c1219a9dfed8b754146890eb7b818fe86b325ffd5ef1324b7d1e01cdc9627a0f MiMo-V2.6-Pro-RL-MXFP4-00007-of-00007.gguf 66492132032
bc342d88400dccf3c830feba538630816cb5594bcfe36c6fef8561c81a1ef37f mtp-MiMo-V2.6-Pro-RL-Q8_0.gguf 4053914784
741be72c45a9b9c1265f746baf4f124da3d37a4378f262782c732578e55021c1 mtp-MiMo-V2.6-Pro-RL-Q4_0.gguf 2149176480
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
