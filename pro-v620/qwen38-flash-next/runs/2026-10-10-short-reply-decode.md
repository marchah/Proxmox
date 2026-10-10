# Qwen3.8-Flash-Next: short-reply decode with `dio` and the MTP head

Plan committed 2026-10-10 · Run 2026-10-10 · Status: planned

## Question

The [prefill-slowdown record](2026-10-10-prefill-slowdown.md)'s full batch at `-ncmoe 37`
with `dio` and the MTP head failed the owner's keep rule at two points, both 32-token
replies:
- the input-length sweep's 512-token point: median decode 11.1 t/s against 14.0 (−20.2%);
- llama-benchy's 512-token prompt after 4,096 tokens of context: 11.2 against 13.4 (−16.0%).

Requests within one point decoded at 7.6–14.3 t/s. Is the loss at these points larger
than the spread between repeated runs?

## What answers it

For each configuration and point: the median decode rate of each rep, and the median over
all reps (24 requests per input-length point, 9 llama-benchy runs per point).

- The loss at a point **holds** when `h37`'s median over all reps is lower than `dep`'s by
  more than the rep-to-rep spread (highest minus lowest rep median) of either
  configuration. Otherwise it is within the spread.
- Each result is also read against the keep rule's limit: a median decode more than 10%
  lower.
- Per request: drafted and accepted tokens and the decode time; from the residency
  sampler, VRAM-requested memory outside VRAM, card power and core clock during the
  decode.

This record does not change the prefill-slowdown record's verdict. Whether to deploy is
the owner's decision.

## Configurations

| Cell | Configuration |
| --- | --- |
| `dep` | Deployed: `-ncmoe 34`, `auto` load mode, no head |
| `h37` | The prefill-slowdown record's stage 3: `-ncmoe 37`, `--load-mode dio`, Q4_K_M head at n-max 3 (`--spec-type draft-mtp --model-draft /models/hf/qwen3.8-flash-next/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf --spec-draft-ngl all --spec-draft-n-max 3`) |

Both: CT 123, one 64k slot, q8_0 KV, 16 threads, 4096/1024, projector on CPU, b11505.

- **Left out:** two cards and CPU only (the owner keeps Flash-Next on one card; the question
  is about these two configurations). `dio` at `-ncmoe 37` without the head would separate
  the head from the placement; the owner asked for the two points against the deployed
  configuration.

## Controls

- `dep` is the non-speculative control, the configuration both batches were judged
  against.
- The points run with the batch's own commands and prompts, after a reload, as in the
  batch. Each item also runs the point that preceded it in the batch: the input-length
  sweep's 128-token point, and llama-benchy's 512-token prompt without context.
- Reps interleave as `dep h37 h37 dep dep h37`, so a drift over the run falls on both.

## Method

Code at the plan's commit; the playbook pushes the suite, stops on uncommitted benchmark
code and records the commit and `capture-env.sh`'s capture in each run's `versions.json`.
`LLAMA_BENCHY_PP`, `LLAMA_BENCHY_TG` and `LLAMA_BENCHY_DEPTH`, added with this plan, set
llama-benchy's sizes and keep the rest of its default command line.

```bash
# Host: stage the harness, start the residency sampler for the whole run
./pro-v620/push-harness.sh          # Mac; prints /root/harness/<sha12>
H=/root/harness/<sha12>/pro-v620/qwen38-flash-next
systemd-run --unit=vram-residency --collect /usr/bin/python3 $H/vram-residency-sampler.py \
  --pci 0000:83:00.0 --output /root/qwen38-flash-next/residency-short-reply.jsonl

# Host: the two env files, from the deployed one
pct exec 123 -- cp -p /etc/llamacpp-qwen38fn.env /etc/llamacpp-qwen38fn.env.dep
pct exec 123 -- sh -c 'sed \
  -e "s/^MODEL_CPU_MOE=.*/MODEL_CPU_MOE=\"37\"/" \
  -e "s/^MODEL_LOAD_MODE=.*/MODEL_LOAD_MODE=\"dio\"/" \
  -e "s|^EXTRA_ARGS=.*|EXTRA_ARGS=\"--device Vulkan0 --spec-type draft-mtp --model-draft /models/hf/qwen3.8-flash-next/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf --spec-draft-ngl all --spec-draft-n-max 3\"|" \
  /etc/llamacpp-qwen38fn.env.dep > /etc/llamacpp-qwen38fn.env.h37'

# Per rep, in the order dep h37 h37 dep dep h37
pct exec 123 -- cp /etc/llamacpp-qwen38fn.env.<cell> /etc/llamacpp-qwen38fn.env
pct exec 123 -- systemctl restart llamacpp-qwen38fn
ansible-playbook ansible/benchmark.yml -e @<main checkout>/ansible/secrets.yml -e gpu=2 \
  -e runtime=llamacpp -e allow_dirty=false -e suite=short -e '{"regression_benchmarks": [
    "llm-bench-sweep input-length --points 128 512 --output-tokens 32",
    "RUN_OPENAI_DIRECT=false LLAMA_BENCHY_PP=512 LLAMA_BENCHY_TG=32 LLAMA_BENCHY_DEPTH=\"0 4096\" llm-bench-baseline"]}'

# Host, after the last rep (also if a rep fails)
pct exec 123 -- cp -p /etc/llamacpp-qwen38fn.env.dep /etc/llamacpp-qwen38fn.env
pct exec 123 -- systemctl restart llamacpp-qwen38fn
systemctl stop vram-residency
```

- `h37`'s env file must differ from `dep`'s in exactly the three lines the stage 3 batch
  changed; this is checked before the first rep.
- Before each rep, a request checks the cell: draft tokens in its `timings` for `h37`, none
  for `dep`.
- `residency-summary.py` cannot window decodes; the per-request decode windows are read
  from the request records (start, first token, end) against the sampler's lines.
- Expected duration: about 12 minutes per rep, 1 h 15 min in all.
- Raw data: `pro-v620/results/llamacpp-gpu2/parallel-1/<run>/` on the Mac, two folders per
  rep; residency samples in `/root/qwen38-flash-next/residency-short-reply.jsonl` on the
  host.

## Safety

- Every guest the run does not use stays shut down: CT 120 `llamacpp`, CT 121 `hermes`,
  CT 140 `kb-rag`, VM 300 `docker-host` and CT 201. CT 123 and CT 200 run for it; each
  rep's playbook shuts CT 200 down at its end. Starting any other guest waits for the
  owner's go-ahead.
- `gpu-thermal-watchdog` stops `llamacpp-qwen38fn` at 102 °C junction or 101 °C memory.
  The longest prompt is 4,608 tokens.
- The deployed env file is restored after the run, also if a rep fails.

## Environment

Intended: as in the [prefill-slowdown record](2026-10-10-prefill-slowdown.md#environment).
Replaced by the run's capture.

---

## Results

## Deviations

## Conclusion
