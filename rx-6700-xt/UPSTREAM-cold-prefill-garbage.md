# Bug report: garbage output on cold prefill ≥ ~7k tokens (Vulkan/RADV, Navi 22)

Ready-to-submit write-up for the cold-prefill correctness cliff documented in
`README.md`. File against **llama.cpp** (Vulkan backend) — and/or **LM Studio**,
since that's how it's observed here (LM Studio bundles the llama.cpp runtime).

- llama.cpp: https://github.com/ggml-org/llama.cpp/issues
- LM Studio: https://github.com/lmstudio-ai/lmstudio-bug-tracker/issues

---

## Title

Vulkan (RADV/Navi 22): large *cold* prefill (≳7k tokens) produces all-`?` garbage output; corruption is sticky until reload

## Summary

On a Radeon RX 6700 XT (Navi 22 / gfx1031) via the Vulkan backend, a single
**cold** prompt (one not served from the prefix cache) whose prefill exceeds
~7k tokens makes the model emit pure garbage — long runs of the `?` replacement
character — instead of text. It is **probabilistic** near the threshold and
**deterministic** above it:

| Cold prefill (≈ tokens) | Garbage runs |
| ---: | ---: |
| 6,656 | 0 / 4 |
| 7,168 | 1 / 4 |
| 7,680 | 2 / 4 |
| 8,192 | 4 / 4 |

Once a request trips it, **every subsequent request returns garbage** — even a
1-token "Hello" — until the model is unloaded/reloaded. It is **not** thermal,
**not** out-of-memory, and **does not** occur when the same long prompt is served
from the prefix cache (which skips the cold prefill compute). `temperature=0`, so
this is not sampling noise.

## Environment

- **GPU:** AMD Radeon RX 6700 XT, Navi 22 (gfx1031, RDNA2), 12 GiB — PCI `1002:73df`
- **Driver:** RADV, Mesa `25.2.8-0ubuntu0.24.04.2`, Vulkan API `1.4.318`, kernel `amdgpu`
- **Kernel / OS:** `7.0.12-1-pve` (Proxmox), inside an Ubuntu 24.04 LXC with `/dev/dri` (renderD128) passthrough
- **Runtime:** `llama.cpp-linux-x86_64-vulkan-avx2@2.22.0` (LM Studio's bundled engine; LM Studio CLI commit `6041ae0`)
- **Model:** Qwen3.5-9B, `Q4_K_M` GGUF
- **Load config:** `--gpu max` (full offload), `--context-length 64000`, `--parallel 4`
- VRAM in use during inference ≈ 7.2 GiB of 12 GiB; junction temp ≤ ~95–103 °C (well under throttle); >14 GiB host RAM free.

## Steps to reproduce

1. Serve the model on the Vulkan backend with a context window large enough to
   hold the prompt (here 64k), exposing the OpenAI-compatible API.
2. Send a **single, unique** (uncached) chat completion whose prompt is ~8k
   tokens. A simple way to guarantee a cold prefill is a unique nonce followed by
   filler:

   ```bash
   python3 - <<'PY'
   import json, urllib.request
   n = 8192                      # prompt ~ n tokens
   prompt = "nonce-%d-zq " % n + ("token " * n)
   body = json.dumps({
       "model": "qwen3.5-9b",
       "messages": [{"role": "user", "content": prompt}],
       "max_tokens": 16, "temperature": 0,
   }).encode()
   req = urllib.request.Request("http://localhost:1234/v1/chat/completions",
                                data=body, headers={"Content-Type": "application/json"})
   print(json.load(urllib.request.urlopen(req, timeout=180))["choices"][0]["message"]["content"])
   PY
   ```

3. Observe the output. At ~8k it is reliably `???????????????…`. Repeat at 6656,
   7168, 7680, 8192 (reloading the model between each, since corruption is sticky)
   to see the probabilistic onset.
4. After a garbage response, send a trivial prompt ("Capital of France?"). It also
   returns garbage — the model stays corrupted until reloaded (`lms unload --all`
   then `lms load …`).

## Expected vs actual

- **Expected:** coherent text for any prompt that fits the context window,
  regardless of whether it hit the prefix cache.
- **Actual:** prefill ≳7k tokens (cold) yields all-`?` output; the runtime then
  serves garbage to all later requests until reloaded.

## What it is not

- **Not thermal:** junction peaked ~95 °C during the failing requests (throttle/
  warn line is 105 °C).
- **Not OOM / VRAM exhaustion:** ~7.2 GiB of 12 GiB VRAM used; >14 GiB host RAM
  free; no allocation errors logged. The 64k context is configured and shorter
  prompts in the same session work.
- **Not prefix-cache-related in the bad direction:** the opposite — a *cached*
  long prompt (repeated identical content) is served fine because the cold prefill
  compute is skipped. The bug needs an actual large cold prefill.
- **Not sampling:** `temperature=0`.

## Notes / suspected cause

- Output is the literal `?` replacement character, consistent with the decode
  step receiving invalid/NaN logits — i.e. numerical corruption during the large
  prefill matmul/attention on this Vulkan backend, rather than a tokenizer issue.
- Probabilistic onset (~7k) hardening to deterministic (~8k) suggests a
  size/occupancy-dependent compute path (large batched prefill) on RADV/Navi 22.
- Stickiness suggests the corrupted state persists in the KV cache / a shared
  buffer for the loaded model instance.

## Things worth trying to narrow it (for maintainers / others hitting this)

- A non-Vulkan backend on the same GPU (ROCm/HIP build) to isolate RADV vs
  llama.cpp-generic.
- A newer/older llama.cpp Vulkan runtime than `2.22.0`.
- A different Mesa/RADV version.
- Smaller `--context-length` and/or different flash-attention / batch settings.
- Another Q4_K_M model to rule out model-specific weights.
