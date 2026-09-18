# B550 GPU A/B harness

Reference harness for comparing the two V620s on the prior B550 host. Host
orchestration scripts use that platform's PCI addresses, fan channel, container
services and device ordering. Port those assumptions before using them on the
ROMED8-2T. Current Flash-Next experiments and the matching thermal guard are in
[../qwen38-flash-next/](../qwen38-flash-next/README.md).

The Python probes can be used independently against compatible endpoints.
`bench-runner/` measures served OpenAI APIs; this harness also runs `llama-bench`
inside GPU containers to compare physical devices.

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

## Operating constraints

- `ct123-dual-gpu.sh` manages the retired llama-swap service and B550 device paths.
  Its `add`/`revert` flow is not a cutover procedure for the current CT 123 service.
- The production watchdog stops managed services, not manually launched benchmark
  processes. Run a guard configured for the benchmark's actual host/cards.
- Smoke-test one cell before launching a matrix (`SMOKE=1` for `spec-sweep.sh`).
  Missing model files are skipped; check which configurations actually ran.
- Speculative decoding needs both output-sanity checks and a no-speculation
  control. Degenerate repetition can inflate throughput and draft acceptance.
- Name prompt class, build and drafter with speculative results. Tune n-max for
  each drafter; do not transfer it between heads.
- Use `pp_dpm_pcie` under load to verify link state, and order sweeps by target
  model when page-cache pressure would otherwise dominate reload time.

## KV-cache validation

`kv-quant-test.sh` exists because of a specific trap. Quantising the KV cache to q8_0 on
`Qwen3.8-27B` costs **zero** throughput — it is marginally *faster*, even at 2× context — so a
speed-only comparison scores it a free win. It is not: with reasoning enabled the quantised cache
perturbs the logits enough that the model never emits its end-of-thinking token, reasons to the
cap, and returns **empty content**. The tell was the content hash `e3b0c44298fc…`, which is the
sha256 of the empty string.

With `reasoning_effort: "none"` the same config is byte-identical to f16 at twice the context and
9 % faster. So the result is a *coupled* choice, not a ranking — and only hashing the output
distinguishes the two cases. The same habit caught the n-max-6 repetition collapse.

For a hybrid model, compute KV size using full-attention layers only. Confirm
with VRAM/GTT deltas between context sizes. Qwen3.8-27B measured about
42 KiB/token at q8_0 and 72 KiB/token at f16.

## Verifying vision, when a model has it

Use a known image to verify that the model receives visual input:

```bash
pct push 123 vision-test.py /root/vision-test.py --perms 755
pct exec 123 -- python3 /root/vision-test.py http://127.0.0.1:1234 qwen3.8-flash-next
```

The blue-circle image has a verifiable answer. For timing, disable prompt caching
so repeated requests measure encoding. `--no-mmproj-offload` saves projector VRAM
at a cost to image encoding; text throughput is unaffected in the recorded trials.

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

```bash
shellcheck pro-v620/gpu-ab-bench/*.sh
```

Raw telemetry and results are **deliberately not committed** (a 3.3 h session is ~3.5 MB of JSONL,
and `.gitignore` already excludes `results/`). Keep the scripts here; archive the data with the run.
