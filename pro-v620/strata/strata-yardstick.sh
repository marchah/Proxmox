#!/usr/bin/env bash
# Strata's quality yardstick on CT 123, run on the host with strata-qwen38fn stopped; starts it
# again on exit. LABEL names the outputs in /models/strata/quality/ (default stage1).
#
# - run: teacher-forced perplexity with the experts on the CPU (upstream's method), then with
#   the experts in the VRAM cache (--gpu-experts auto);
# - prompt: the prompt path's next-token logits with STRATA_HIP_PROMPT_F16 off and on;
# - compare and pcompare: the two runs against each other, and FP16 against the default path.
#
# The engine runs get the server's last config and its env file, so the STRATA_* switches reach
# them. The comparisons read only files and run without systemd-run, whose --pipe output does
# not survive pct exec.
set -Eeuo pipefail
LABEL="${LABEL:-stage1}"
Q=/models/strata/quality
CFG=/var/lib/strata-qwen38fn/config.json
STRATA_HOME=/opt/strata/strata-v0.1.44.1
PY=/opt/strata/venv/bin/python

restart() { pct exec 123 -- systemctl start strata-qwen38fn || true; echo "==> strata-qwen38fn restarted"; }
trap restart EXIT

yq() {
  pct exec 123 -- systemd-run --wait --pipe --collect -q \
    -p User=llamacpp -p SupplementaryGroups=render -p LimitMEMLOCK=infinity \
    -p EnvironmentFile=/etc/strata-qwen38fn.env \
    -p WorkingDirectory="${STRATA_HOME}" \
    "${PY}" tools/quant_quality.py "$@"
}

yc() {
  pct exec 123 -- runuser -u llamacpp -- env -C "${STRATA_HOME}" "${PY}" tools/quant_quality.py "$@"
}

pct exec 123 -- systemctl stop strata-qwen38fn
pct exec 123 -- install -d -o llamacpp -g llamacpp "$Q"
pct exec 123 -- install -o llamacpp -g llamacpp -m 644 "$CFG" "$Q/${LABEL}-config.json"
CFG="$Q/${LABEL}-config.json"

echo "==> $(date -u +%FT%TZ) run, experts on the CPU (the gate)"
yq run --config "$CFG" --out "$Q/${LABEL}-cpu.tsv"
echo "==> $(date -u +%FT%TZ) run, experts in the VRAM cache (--gpu-experts auto)"
yq run --config "$CFG" --out "$Q/${LABEL}-gpu.tsv" --gpu-experts auto
echo "==> $(date -u +%FT%TZ) prompt path, default (STRATA_HIP_PROMPT_F16=0)"
yq prompt --config "$CFG" --out "$Q/${LABEL}-prompt-default" --env STRATA_HIP_PROMPT_F16=0
echo "==> $(date -u +%FT%TZ) prompt path, STRATA_HIP_PROMPT_F16=1"
yq prompt --config "$CFG" --out "$Q/${LABEL}-prompt-f16" --env STRATA_HIP_PROMPT_F16=1
echo "==> $(date -u +%FT%TZ) compare"
yc compare "$Q/${LABEL}-cpu.tsv" "$Q/${LABEL}-cpu.tsv" "$Q/${LABEL}-gpu.tsv" --segments \
  --json "$Q/${LABEL}-compare.json"
echo "==> pcompare"
yc pcompare "$Q/${LABEL}-prompt-default" "$Q/${LABEL}-prompt-f16"
echo "==> $(date -u +%FT%TZ) done"
