# Speculative decoding A/B on CT 120

Compares speculative decoding against CT 120's plain serving configuration on CT 120's own
card. The result is the shipped configuration: the model's MTP head, drafting 3
tokens, with q8_0 KV so it fits at 262k context. The same Unsloth UD-Q5_K_XL quant
is used with its MTP head kept.

| File | Role |
| --- | --- |
| `run-ab.sh` | Host driver. Stops `llamacpp`, loads each arm as a transient `llamacpp-ab` unit with the production flags plus the arm's, runs the probe, rotates arm order every repetition and restores production on exit. |
| `spec-probe.py` | One measurement pass inside CT 120; one JSONL row per request. |
| `summarize.py` | Markdown tables from the JSONL: decode, c2 total, deep prefill, acceptance and correctness. |

Run it with `qwen38-flash-next/thermal-guard.sh` active as `spec-ab-guard`. The
production watchdog stops `llamacpp`, not the transient unit. Hermes has no model for
the whole run, about 85 minutes for 6 arms × 3 repetitions.

## Measurements — 2026-09-22

Setup:
- **Build and hardware:** llama.cpp `b11018` Vulkan, one V620 (`0000:03:00.0`, −100 mV, blower), `schedutil`.
- **Server flags:** `-c 262144 --parallel 2 -fa on -b 4096 -ub 1024 --reasoning off --cache-ram 0`.
- **Requests:** 512 output tokens with `cache_prompt: false`. `greedy` uses temperature 0; `default` uses the GGUF's sampling (temp 1.0, top-k 20, top-p 0.95), which is what Hermes gets.
- **Deep cells:** depth comes from a repository-text corpus (934,953 bytes, commit `3805b42`).
- **Figures:** median over 3 interleaved repetitions, with the min–max range in brackets.

Arms:

| Arm | Model | Extra flags |
| --- | --- | --- |
| `base` | MTP-less UD-Q5_K_XL (the former production file) | none |
| `base-q8` | same | `-ctk q8_0 -ctv q8_0` |
| `mtp-nN-q8` | MTP UD-Q5_K_XL | q8_0 KV, `--spec-type draft-mtp --spec-draft-n-max N` |
| `dflash-n6-q8` | MTP-less UD-Q5_K_XL | q8_0 KV and drafter KV, `--spec-type draft-dflash`, z-lab DFlash (v1) drafter Q8_0, n-max 6 |

Decode t/s:

| Cell | base | base-q8 | mtp-n2-q8 | **mtp-n3-q8** | mtp-n4-q8 | dflash-n6-q8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| code, greedy | 77.4 | 76.2 | 112.1 | **115.5** | 115.6 | 112.8 |
| code, default | 78.1 | 76.9 | 108.5 | **116.5** | 113.1 | 112.6 |
| prose, greedy | 77.8 | 76.6 | 102.6 | **101.3** | 95.5 | 96.0 |
| prose, default | 78.2 | 76.9 | 97.5 | **91.7** | 90.8 | 77.1 |
| JSON, greedy | 78.5 | 77.2 | 122.8 | **134.8** | 143.5 | 174.9 |
| JSON, default | 78.5 | 77.2 | 122.3 | **135.8** | 144.8 | 170.7 |
| tool call, greedy | 77.4 | 76.0 | 119.0 | **136.7** | 123.2 | 118.8 |
| 16k depth, default | 71.4 | 72.7 | 99.7 | **99.0** | 97.1 | 83.1 |
| 48k depth, default | 64.3 | 67.6 | 86.5 | **86.9** | 84.2 | 67.6 |

Two concurrent streams, total t/s:

| Cell | base | base-q8 | mtp-n2-q8 | **mtp-n3-q8** | mtp-n4-q8 | dflash-n6-q8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| code | 115.2 | 114.3 | 135.6 | **139.5** | 84.3 | 64.4 |
| prose | 114.6 | 113.6 | 119.3 | **117.3** | 66.2 | 51.2 |
| JSON | 114.8 | 113.8 | 147.4 | **158.8** | 97.2 | 89.4 |

Prefill t/s:

| Depth | base | base-q8 | mtp-n2-q8 | **mtp-n3-q8** | mtp-n4-q8 | dflash-n6-q8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 16k | 1019.9 | 1521.4 | 1354.3 | **1346.3** | 1340.4 | 1303.0 |
| 48k | 526.6 | 1084.7 | 920.0 | **916.8** | 918.1 | 994.4 |

Memory after a request (MiB; 30,704 exposed): `base` 30,567 VRAM / 290 GTT; `base-q8`
28,256 / 290; MTP arms ~30,030 / ~650; `dflash-n6-q8` 30,130 / 2,836.

Reading:
- **Draft length 3 is the best overall.** Draft length 2 is marginally ahead on prose. Draft length 4, and DFlash more so, lose badly with two concurrent streams: at two slots the verify batches compete.
- **DFlash is rejected.** Its drafter KV grows with `-c` because this build does not use the drafter's sliding window, so it still spills 2.8 GiB into GTT at 262k even with q8_0 drafter KV. It is fastest only on short single-stream JSON.
- **f16 KV cannot host MTP at 262k.** A smoke load spilled 2.0 GiB into GTT and decoded at 59.9 t/s on the code prompt, against 78 without speculation. At 147k (2×73,728) f16 fits and decodes at 128–138 t/s. q8_0 KV is what makes MTP fit at full context.
- **Plain q8_0 KV doubled 48k prefill** (527 → 1,085 t/s) and changed decode by about ±2%. The prefill gain was not isolated further. MTP gives back about 15% of that prefill, but still ends +32% at 16k and +74% at 48k over `base`.
- **Acceptance** over all cells, sampled and deep ones included, was 79% (n2), 72% (n3), 64% (n4) and 46% (DFlash). For a greedy code prompt, n3 accepts 94%.

Correctness:
- Every arm returned a valid `get_weather` call on all 3 repetitions. No cell repeated itself (distinct 4-gram ratio ≥ 0.5), and no think tags appeared.
- Each arm's greedy output was identical across its 3 repetitions. JSON output was identical across all arms.
- Code and prose diverge at near-tie wording. Plain q8_0 differs from f16 from character 55 of the code answer ("TTL support" vs "TTL (Time-To-Live)"). MTP differs from plain q8_0 from character 430 of code and 626 of prose ("_CacheEntry" vs "CacheEntry", "Delivery Driver" vs "Driver"). The KV-type change moves output more than speculation does.
