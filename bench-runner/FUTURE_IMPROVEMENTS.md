# Future Benchmark Improvements

These are useful ideas that are intentionally not required for the first
server-side benchmark workflow.

## Power And Energy

- Add wall-power logging from a smart plug or UPS.
- Record idle watts, benchmark watts, watt-hours, joules/request, and joules
  per 1k generated tokens.
- Keep GPU-reported power as a secondary metric because it excludes CPU,
  memory, disks, fans, and PSU losses.

## Better Token Accounting

- Add model-specific tokenizer counting when practical.
- Store API-reported tokens, tokenizer tokens, estimated tokens, character
  counts, and word counts side by side.
- Use tokenizer counts for final throughput comparisons once the tokenizer path
  is stable.

## External Benchmark Tools

- Add NVIDIA GenAI-Perf only if NVIDIA/Triton or NVIDIA-serving experiments
  become part of the lab.
- Add vLLM benchmark runs only when vLLM is an actual serving runtime.
- Add broader `lm-evaluation-harness` task groups after the local API baseline
  is stable.

## Deeper Quality Evaluation

- Build a private holdout promptset from real homelab tasks.
- Add deterministic checks for structured output, command plans, refusal
  behavior, and required facts.
- Add manual or model-judge rubrics only after deterministic checks are in
  place.

## Visualization

- Add a small static HTML report that plots TTFT, latency, throughput,
  temperature, memory, and GPU utilization from JSONL files.
- Keep this optional; JSON and Markdown remain the source of truth.

## Automation

- Add scheduled baseline runs after the server is stable.
- Add regression alerts when SLO status changes from pass to warn/fail.
- Add automatic comparison against the latest run with the same profile.
