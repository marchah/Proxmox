# Running models bigger than VRAM on the RX 6700 XT (background-card findings)

> Status: **research / not yet implemented.** No provisioning script exists for this yet — see
> "Next steps". Captured 2026-06-29 while the V620 (CT 120) is the production runtime.

## Goal being evaluated

Reuse the retired **RX 6700 XT (12 GiB, Navi 22 / gfx1031)** as a *dedicated, second* GPU for
**background / non-interactive** LLM tasks — running models **larger than its 12 GiB VRAM**, with
hours-per-answer being acceptable, fully isolated from the interactive agent on the V620 (CT 120).
The card would go in a **PCIe 3.0** slot and is **not yet physically installed**.

The trigger was [AirLLM](https://github.com/lyogavin/airllm) ("70B on a 4 GB GPU"). The conclusion
below is that AirLLM is the wrong tool here and **llama.cpp's own offload features already do the
job better**, on the Vulkan stack this homelab already runs.

## Why not AirLLM

- **Backend mismatch.** AirLLM is PyTorch-based: CUDA, Apple MLX, or CPU. No ROCm, no Vulkan. The
  PyTorch *Vulkan* backend is a **deprecated, mobile-only** path (~24 ops, no attention — can't run
  a transformer; requires a source build + TorchScript `optimize_for_mobile`). So on an AMD card
  AirLLM means **ROCm**, which on the 6700 XT (gfx1031) is unofficial (needs
  `HSA_OVERRIDE_GFX_VERSION=10.3.0`, has a known 6.4.3+ SIGSEGV regression) and — per our V620
  PoC — faults in an LXC, working only in a passthrough VM.
- **Speed.** AirLLM re-reads every layer's weights from disk on **every token, unconditionally**
  (VRAM footprint ≈ one layer). Measured real-world: ~0.7 tok/s on NVMe + dedicated GPU, ~0.07
  tok/s on Apple, ~5.3 s/token in batch — i.e. **sub-1 tok/s**.
- **Stale.** AirLLM's last substantive capability work is ~2024–2025; it has no tagged releases.
  During that window llama.cpp shipped a more sophisticated version of the same idea.

## The actual tool: llama.cpp offload + mmap

llama.cpp (the engine already used on the V620, over Vulkan, which works fine on gfx1031) runs
models larger than VRAM — and larger than RAM — with no new backend:

- **`-ngl N` / `--n-cpu-moe N` / `-ot`** — keep as much as fits resident on the GPU; for MoE,
  `--n-cpu-moe N` keeps the experts of the first N layers in CPU RAM and ships only the **active**
  experts to the GPU per token (exploits MoE sparsity).
- **`mmap` (default)** — the GGUF is memory-mapped; weights that don't fit VRAM+RAM are paged from
  disk on demand.

### llama.cpp vs AirLLM — the mechanism difference

| | AirLLM | llama.cpp (offload + mmap) |
|---|---|---|
| Weight location | per-layer shards on disk | GPU layers resident in VRAM; CPU layers in RAM (mmap) |
| Per token | read every layer disk→GPU, compute, **free**, repeat | resident layers run in place; **no disk** unless model > VRAM+RAM |
| Disk I/O | **every token, unconditional** | only the genuine overflow, cold pages only |
| MoE | streams all layers | streams only the **active** experts (`--n-cpu-moe`) |
| Quantization | fp16 (2× the disk) | GGUF Q4/Q5 |

**Crux:** AirLLM re-reads from disk every token regardless of memory; llama.cpp keeps everything
that fits resident across VRAM→RAM and only touches disk for true overflow.

## Does offloading hurt accuracy?

**No.** Offload placement (`-ngl`/`--n-cpu-moe`/mmap) decides *where a weight physically sits*
(VRAM / RAM / disk page); the **same weights and the same math** run either way — llama.cpp just
dispatches that tensor to the CPU backend instead of the GPU backend. Output is numerically
identical bar negligible floating-point-ordering differences. **It costs speed, not quality.**
Accuracy is governed by **quantization** (Q5_K_XL here), an independent axis you choose freely and
which offloading does not change.

## Simulation result (V620 emulating a 12 GiB / 10 GiB 6700 XT)

To measure the offload path **without installing the card**, CT 120 (V620) was temporarily
reconfigured to emulate a constrained box, then fully restored:

- RAM capped to **10 GiB** (`pct set 120 -memory 10240 -swap 0`).
- VRAM constrained to **~11.8 GiB** via `--n-cpu-moe 24` (the rest of the ~27 GiB model spills to
  CPU; CPU side ~15 GiB > the 10 GiB cap, so ~5–6 GiB genuinely pages from disk — the real spill
  regime).
- Model: `Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf` (MoE, ~3B active), `--ctx-size 16384 --parallel 1`.

| Scenario | Decode tok/s | Prefill tok/s | Notes |
|---|---|---|---|
| Cold (first request) | **17.5** | 3.7 | experts paged from disk; 51-tok prompt ≈ 14 s |
| Warm, repeated prompt | **~22** | 15–18 | best case — active experts cached |
| Warm, varied prompts | **14–18** | 8–13 | realistic — expert working set churns |
| *Reference: full-VRAM, single stream* | *~53* | — | all experts on GPU |

Offloading ~half the experts to CPU+disk costs roughly **60–70% of decode throughput** → landing
at **~14–22 tok/s**. Prefill / cold latency takes the larger hit.

### Read these as an OPTIMISTIC upper bound for the real 6700 XT

1. **The V620 flatters it.** Full Navi 21 (~72 CU, ~512 GB/s) vs the 6700 XT's Navi 22 (~40 CU,
   ~384 GB/s) — ~1.5–1.8× compute / ~1.3× bandwidth — and the V620 is on PCIe 4.0 vs the planned
   3.0 (~half the bus bandwidth for the per-token CPU↔GPU expert copies). Expect the real card
   nearer **~10–15 tok/s warm**, slower cold.
2. **This is a 3B-active MoE — the favorable case.** A big-active MoE (e.g. Qwen3-235B-A22B,
   ~22B active) does ~7× the per-token compute *and* spills far more to disk → substantially
   slower. A huge **dense** model (e.g. 405B) has no sparsity at all → disk-bound, glacial.
3. **Cold prefill is the real pain** (3.7 tok/s here) — long-context background jobs will have slow
   first tokens.

**Bottom line:** the "don't let VRAM cap what I run" goal is achievable on the 6700 XT via
llama.cpp MoE-offload, at background-appropriate speeds — **for MoE models**. It is *not* a good
path for giant dense models.

## Next steps (when the hardware is in)

1. Physically install the 6700 XT (PCIe 3.0), confirm Proxmox sees both GPUs (`lspci`, a second
   render node `/dev/dri/renderD129` alongside the V620's `renderD128`), PSU headroom.
2. Pick the concrete oversized **MoE** model + quant for the chosen background workload.
3. Add a dedicated `rx-6700-xt/create-lxc-llamacpp-<model>.sh` (a new script per the repo's
   one-script-per-GPU/model/role convention) that passes through the 6700 XT's render node and
   launches `llama-server` with `-ngl 99 --n-cpu-moe N` (+ `-ot` if needed) tuned to ~12 GiB VRAM,
   isolated from CT 120.
4. Benchmark with the existing bench-runner / `make bench` suite.
