set -Eeuo pipefail
RUN=/tmp/tstg; rm -rf "$RUN"; mkdir -p "$RUN"; RESULTS="$RUN/R.md"; : >"$RESULTS"
CT=120; BUILDER=201; ENVF=/dev/null
MODELDIR=/models/hf/qwen3.8-flash-next
MTPDIR=/opt/llamacpp/mtp-b11018
DRAFT_PLAIN="$MODELDIR/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf"
DRAFT_SHARED="$MODELDIR/mtp-Qwen3.8-Flash-Next-shared-Q4_K_M.gguf"
export MTP_SKIP_BUILD=true
printf '16 30 q8_0 true\n' >"$RUN/best_split.txt"
printf '16\n' >"$RUN/best_ncmoe.txt"; printf '30\n' >"$RUN/best_c1.txt"
printf 'q8_0 true\n' >"$RUN/best_shape.txt"; printf '16\n' >"$RUN/best_threads.txt"
note() { printf '%s\n' "$*" >>"$RESULTS"; }
say()  { printf '[say] %s\n' "$*"; }
setv() { :; }
ip() { echo 127.0.0.1; }
wait_up() { return 0; }
sleep() { :; }
pct() { case "$*" in *"test -x"*) return 0;; *"--help"*) return 0;; esac; return 0; }
curl() { return 0; }
best_ncmoe() { echo 16; }
mtp_cell() { echo "12.00 45.0"; }
mtp_row()  { echo "  [row $1]"; }
ctx_cell() { echo "  [ctx_cell $*]"; }
split_cell() { echo "  [split_cell $*]"; }
split_headroom() { echo "fits 4000 4000 71 15"; }
for fn in mtp_set_placement s2c_context s3_mtp s2b_split s4_parallel; do
  eval "$(sed -n "/^${fn}() {/,/^}/p" overnight-part2.sh)" || { echo "EXTRACT FAIL $fn"; exit 1; }
done
for fn in s2c_context s3_mtp s2b_split; do
  if ( "$fn" >/dev/null 2>&1 ); then echo "  OK   $fn"; else echo "  🔴 FAIL $fn (rc=$?)"; fi
done
