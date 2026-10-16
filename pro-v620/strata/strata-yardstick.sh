#!/usr/bin/env bash
# Stage 1's quality yardstick on CT 123, with strata-qwen38fn stopped; restarts it on exit.
set -Eeuo pipefail
Q=/models/strata/quality
CFG=/var/lib/strata-qwen38fn/config.json

restart() { pct exec 123 -- systemctl start strata-qwen38fn || true; echo "==> strata-qwen38fn restarted"; }
trap restart EXIT

yq() {
  pct exec 123 -- systemd-run --wait --pipe --collect -q \
    -p User=llamacpp -p SupplementaryGroups=render -p LimitMEMLOCK=infinity \
    -p EnvironmentFile=/etc/strata-qwen38fn.env \
    -p WorkingDirectory=/opt/strata/strata-v0.1.44.1 \
    /opt/strata/venv/bin/python tools/quant_quality.py "$@"
}

pct exec 123 -- systemctl stop strata-qwen38fn
pct exec 123 -- install -d -o llamacpp -g llamacpp "$Q"
pct exec 123 -- cp "$CFG" "$Q/stage1-config.json"
pct exec 123 -- chown llamacpp:llamacpp "$Q/stage1-config.json"
CFG="$Q/stage1-config.json"

echo "==> $(date -u +%FT%TZ) run, experts on the CPU (the gate)"
yq run --config "$CFG" --out "$Q/stage1-cpu.tsv"
echo "==> $(date -u +%FT%TZ) run, experts in the VRAM cache (--gpu-experts auto)"
yq run --config "$CFG" --out "$Q/stage1-gpu.tsv" --gpu-experts auto
echo "==> $(date -u +%FT%TZ) prompt path, default (STRATA_HIP_PROMPT_F16=0)"
yq prompt --config "$CFG" --out "$Q/stage1-prompt-default" --env STRATA_HIP_PROMPT_F16=0
echo "==> $(date -u +%FT%TZ) prompt path, STRATA_HIP_PROMPT_F16=1"
yq prompt --config "$CFG" --out "$Q/stage1-prompt-f16" --env STRATA_HIP_PROMPT_F16=1
echo "==> $(date -u +%FT%TZ) compare"
yq compare "$Q/stage1-cpu.tsv" "$Q/stage1-cpu.tsv" "$Q/stage1-gpu.tsv" --segments --json "$Q/stage1-compare.json"
echo "==> pcompare"
yq pcompare "$Q/stage1-prompt-default" "$Q/stage1-prompt-f16"
echo "==> $(date -u +%FT%TZ) done"
