# `gpu-ab-bench/` — two-GPU A/B harness for the pair of Radeon Pro V620s

**Host-side. NOT shipped into any LXC** (every script needs `pct` and reads host `/sys`). Same
placement rationale as `fan-control/`, `undervolt/` and `gpu-thermal-watchdog/`, but this is a
**one-shot investigation harness, not a service** — no `install.sh`, no systemd unit. Copy the
directory to the Proxmox host and run it:

```bash
scp -r pro-v620/gpu-ab-bench root@pve:/root/
ssh pve 'BENCH_DIR=/root/gpu-ab-bench bash /root/gpu-ab-bench/run-ab.sh'
```

Every script honours `BENCH_DIR` (default `/root/gpu-ab-bench`) for its working/output directory.
Results are plain JSON/JSONL so they diff and archive cleanly, matching `bench-runner/`'s data model.

## Why this exists

`bench-runner/` (CT 200) benchmarks the *served endpoint* over the OpenAI API. It cannot answer
"are these two identical cards actually equivalent?", because it has no GPU passthrough and speaks
only to whichever container owns a card. This harness compares the **cards** directly, with
`llama-bench` inside each card's own container, and it found that they are **not** equivalent —
see the two-slot benchmark in the root `CLAUDE.md`.

## The scripts

| script | runs on | what it does |
| --- | --- | --- |
| `sample-gpus.py` | host | Samples **both** cards + the PWM-hub fan channel to JSONL (temps, power, sclk/mclk, busy%, VRAM, GTT, PCIe link). Reads amdgpu by **PCI address**, never `cardN`. |
| `thermal-guard.sh` | host | Kills `llama-bench` if either card's junction crosses `LIMIT` (default 100 °C). **Required** — see the watchdog warning below. |
| `run-ab.sh` | host | The core A/B on `qwen3.6-35b-a3b`: prefill 512/4096, decode 128, decode at depth 8k/32k, plus a 32k-prefill thermal soak. 3 interleaved rounds. |
| `run-q38.sh` | host | Same treatment for the dense `Qwen3.8-27B`, driven from one container via `--device`. |
| `analyze.py` | host | Joins `llama-bench` results with the per-phase slice of the telemetry and prints the A/B summary. |
| `ct123-dual-gpu.sh` | host | Temporarily gives CT 123 **both** cards so one container can benchmark either via `--device`. `add` / `revert` / `status`. ⚠️ see below. |
| `spec-sweep.sh` | host | Speculative-decoding sweep: MTP + DFlash × GPUs × n-max, each combination in its own server start. `SMOKE=1` runs one config first; `GPU_LIST="Vulkan0:gpu2"` sweeps one card only (no dual-GPU setup needed, leaves CT 120 serving). |
| `spec-probe.py` | **in CT** | Fires a fixed prompt set at a `llama-server` and reports decode tok/s + draft acceptance, **plus a unique-8-gram ratio per prompt** so a repetition-collapse artifact is visible in `results.jsonl` itself (`uniq_8gram_min`, `any_degenerate`). Pushed in automatically by `spec-sweep.sh`. |
| `spec-probe-text.py` | **in CT** | Same prompts but **saves the generated text** and scores a unique-8-gram ratio. This is the degeneracy gate. |
| `merge-row.py` | host | Merges one probe result file into `results.jsonl`. |
| `kv-quant-test.sh` | host | A/B the KV cache type at fixed context, then at 2× context — isolates "quantised KV is slower" from "long context is slower". Hashes the output, which is how it caught q8_0 silently returning nothing. |
| `kv-probe.py` | **in CT** | One fixed request; reports decode/prefill tok/s, MTP acceptance and a content hash. |
| `ctx-ceiling-test.sh` | host | Finds the real context ceiling by loading successive ctx sizes and watching **GTT as closely as VRAM** — on RADV an over-commit spills silently rather than failing, so a successful load is not proof. |
| `mmproj-offload-test.sh` | host | Projector on GPU vs on CPU (`--no-mmproj-offload`): VRAM freed against image-encode latency, at two resolutions plus a text-only control. |
| `mmproj-probe.py` | **in CT** | Times text-only and image requests with `cache_prompt: false`, and flags a `prompt_n` too small to be a real image. |
| `vision-test.py` | **in CT** | Asserts a multimodal server can actually SEE: generates a 256×256 PNG of a blue circle (pure-python encoder, no Pillow) and requires the reply to name both colour and shape. Exits non-zero on failure. |

## Method — what makes the numbers trustworthy

- **Interleaved, alternating rounds.** `run-ab.sh` alternates which card goes first each round, so
  thermal drift cannot favour whichever ran first. Measured variance came out under **0.1 %**.
- **Every control verified, not assumed.** Before trusting a card-vs-card delta, confirm: the GGUF
  hash matches on both containers *and* upstream (`sha256sum` vs HF's `x-linked-etag`); the
  `llama-server --version` build matches; `pp_od_clk_voltage` shows the same undervolt on both; and
  `power1_cap` matches. The two containers have **separate `/models` disks**, so identical file
  names prove nothing.
- **Placement is proven, never assumed.** With two identical cards, `--device Vulkan0/Vulkan1` gives
  no hint which physical card you got. Map it with `vulkaninfo`'s `pciBus` and then confirm from the
  host that the expected card's `mem_info_vram_used` actually rose. `spec-sweep.sh` records a
  `placed_on` field for exactly this.

## ⚠️ Warnings, all learned the hard way

- **`ct123-dual-gpu.sh add` MUST be reverted before production comes back up.** While added, CT 123
  can see GPU 1, and its llama-swap config passes no device selector — it would take Vulkan device
  0, which may be CT 120's card. The script stops and disables llama-swap on `add` and re-enables it
  on `revert`, and backs up `123.conf` both ways. Always finish with `revert`.
- **`gpu-thermal-watchdog` CANNOT protect this harness.** It stops the container's model *service*,
  which is a no-op against a `llama-bench` or hand-started `llama-server` — leaving the 105 °C
  hardware MODE1 reset as the only backstop. **Always run `thermal-guard.sh` alongside.** (In
  practice, with a blower per card, nothing came close: the hottest workload peaked at 73/74 °C
  junction with the fan under 50 %. The guard never fired. Run it anyway.)
- **Never trust a speculative tok/s win without an output-sanity check.** A raw-throughput sweep said
  `--spec-draft-n-max 6` was the optimum for both drafters on both cards. It is not: at n-max 6 two
  of three prompts collapsed into **repetition** (unique-8-gram ratio 0.04 and 0.01), which drafts
  almost perfectly and inflates both acceptance *and* tok/s. On the one prompt that stayed coherent,
  n-max 6 was **slower** than n-max 2. Non-monotonic acceptance is the tell. Use
  `spec-probe-text.py` to gate every result.
  - Corollary: **run a no-speculation control.** Greedy decoding at temp 0 degenerates on its own —
    one prompt repeated even with speculation fully off — so degeneracy must be *attributed*, not
    assumed to be the drafter's fault.
  - ⚠️ **The `dflash` arm's GGUFs were DELETED on 2026-08-22** (Qwen3.6-27B and its DFlash head,
    retired from llama-swap). `spec-sweep.sh` now **loudly skips** a config whose files are missing
    rather than failing mid-run — a sweep covering fewer arms than you assume reads as "no
    difference found" when it never actually ran. The arm is kept in `CONFIGS` because it produced
    the controlled b10361 → b10587 comparison and the shape is worth documenting. ⚠️ The DFlash
    head is **not re-downloadable** (provenance never established, matched no published repo);
    its sha256 is `c37b84724fa58cc5c6b545d8b96f8617a8c3bd7f018bf608feef4d3460e0575e` if it ever
    surfaces. `dflash-kquant.gguf` (muse-glimmer's drafter) survives, so DFlash coverage is not
    lost entirely.
  - Corollary: **"lossless at temp 0" does not hold on b10361.** Outputs were byte-identical across
    both GPUs at n-max ≤ 3 and at baseline, but **diverged at n ≥ 4**, so cross-config tok/s at
    n ≥ 4 compares different work. Hash the outputs and only compare cells that match.
- **`current_link_speed` / `current_link_width` lie** on this host — both report `16.0 GT/s x16` for
  *both* cards. Ground truth is the starred line of `pp_dpm_pcie`. `sample-gpus.py` records the
  misleading pair, so read it as "what the kernel claims", not as the link state.
- **The host has 31 GB of RAM and each model is ~20–27 GB**, so alternating between two different
  models thrashes the page cache and every load is disk-bound. Order sweeps **target-outer** to keep
  one file hot; model load times are therefore a *disk* measurement, not a PCIe one.

## Two harness traps that silently emptied whole runs

Both cost a full sweep before being spotted, and both fail **quietly** — the servers were healthy
and the benchmark "completed":

1. **A `while`/`until` loop returns the status of the last command executed in its body.** A
   health-wait loop ending in `[ $i -gt TIMEOUT ] && { ...; return 1; }` returns **1** on success,
   because the final guard evaluates false. Every run was recorded as "unhealthy" while every server
   had in fact loaded and was listening. Always `return 0` explicitly after such a loop.
2. **`python3 - args <<'HEREDOC'` consumes stdin for the *program*.** Piping data into it as well
   means `sys.stdin.read()` returns empty — the interpreter already ate it. That is why
   `merge-row.py` is a real file taking a path argument instead of an inline heredoc.

Corollary: **smoke-test the harness on one configuration before launching a long matrix.**
`SMOKE=1 bash spec-sweep.sh` exists for that.

Also: `pkill -f 'llama-server.*--port 5999'` from an interactive `ssh pve '...'` one-liner matches
**the ssh command line itself** and kills your own session (exit 255). Bracket a character —
`pkill -f 'llama-serve[r].*--port 5999'` — or run it from a script file.

## ⚠️ Hash the output, or a quality failure reads as a win

`kv-quant-test.sh` exists because of a specific trap. Quantising the KV cache to q8_0 on
`Qwen3.8-27B` costs **zero** throughput — it is marginally *faster*, even at 2× context — so a
speed-only comparison scores it a free win. It is not: with reasoning enabled the quantised cache
perturbs the logits enough that the model never emits its end-of-thinking token, reasons to the
cap, and returns **empty content**. The tell was the content hash `e3b0c44298fc…`, which is the
sha256 of the empty string.

With `reasoning_effort: "none"` the same config is byte-identical to f16 at twice the context and
9 % faster. So the result is a *coupled* choice, not a ranking — and only hashing the output
distinguishes the two cases. The same habit caught the n-max-6 repetition collapse.

⚠️ Do not size context from the GGUF metadata formula
(`2 × n_layer × n_head_kv × head_dim × bytes_per_element`). For this model it predicts 260
KiB/token at f16 and matches a figure recorded elsewhere, but it over-predicts what this card
actually allocates by ~3.5×. Measured from VRAM deltas: **~42 KiB/token q8_0, ~72 KiB/token f16**.

## Verifying vision, when a model has it

A server started without `--mmproj` answers `image input is not supported` **and the caller keeps
going** — that is how a documented 3-hour agent run reasoned about screenshots it never received.
So a multimodal entry needs a test whose answer you can check:

```bash
pct push 123 vision-test.py /root/vision-test.py --perms 755
pct exec 123 -- python3 /root/vision-test.py http://127.0.0.1:8080 qwen3.8-27b-mtp
```

⚠️ **A vision test whose answer you cannot verify is not a test.** The blue-circle image has
unambiguous ground truth, so the assertion can genuinely fail; "the model said something
plausible about an image" cannot.

Measured on CT 123 (b10587, Vulkan, ctx 65536) when enabling it on `qwen3.8-27b-mtp`: **+1.11 GiB
VRAM**, GTT unchanged (no spill), text-only decode 32.2 → 32.0 tok/s with **byte-identical output**
— i.e. the projector is free when no image is sent, and **MTP speculation stays active on image
requests** (6/6 accepted). VRAM is the binding constraint, not compatibility; `--mmproj-device none`
trades image-encode latency for zero VRAM if headroom runs out.

## Output layout

```
$BENCH_DIR/
  telemetry.jsonl            # both cards + fan, one JSON object per sample
  phases.jsonl               # {phase, gpu, args, start, end, rc} — slices the telemetry per phase
  <phase>.<gpu>.json         # llama-bench -o json
  <phase>.<gpu>.err
  guard.log                  # only exists if thermal-guard.sh fired
  spec/results.jsonl         # one row per speculative config, incl. placed_on + output hashes
  spec/<tag>.serverlog       # llama-server log for that config
```

## Linting

`shellcheck` is the repo's expected linter. All five shell scripts here are **clean at full
strictness** (no `-S` filter, so info and style findings included) as of 2026-08-22:

```bash
brew install shellcheck          # macOS
shellcheck pro-v620/gpu-ab-bench/*.sh
```

⚠️ Beware a false negative when checking whether it is installed: `cd somewhere && which shellcheck
&& ... || echo "not installed"` reports "not installed" if the **`cd`** fails, because the failure
short-circuits the whole `&&` chain into the `||` branch. That misreport cost a round of review here.

Raw telemetry and results are **deliberately not committed** (a 3.3 h session is ~3.5 MB of JSONL,
and `.gitignore` already excludes `results/`). Keep the scripts here; archive the data with the run.
