# GLM-5.3-Flash on Radeon Pro V620

GLM-5.3-Flash (`glm5-next`, MIT) is a 320B-total, 18B-active MoE with a vision encoder.
It is not deployed. The [test records](#test-records) measure it on this box.

## Model

From the checkpoint's `config.json` and the GGUF headers:

- 45 layers plus one MTP layer, stored as GGUF block 45. 34 layers use KDA linear
  attention, with a fixed-size state per sequence. The other 11 (3, 7, …, 43) use DSA:
  NoPE MLA (`kv_lora_rank` 512) with an indexer that keeps the top 2,048 pools of four
  tokens. Only those 11 hold a per-token KV cache.
- Manifold-constrained hyper-connections (mHC) with four streams.
- Layers 0–2 have a dense FFN. Layers 3–44 have 288 routed experts, 8 active, plus one
  shared expert. The MTP layer has the same MoE.
- Native context 1,048,576 tokens.

The chat template opens `<think>` on every assistant turn and has no switch to disable it.
`reasoning_effort` accepts `low`, `high` and `max`; anything else becomes `max`. The
model's `generation_config.json` sets temperature 1.0 and top-p 0.95.

## Files

[`unsloth/GLM-5.3-Flash-GGUF`](https://huggingface.co/unsloth/GLM-5.3-Flash-GGUF) revision
`a38483c8` (2026-10-05, "Update shards due to upstream changes"):

| File | Size |
| --- | ---: |
| `UD-Q4_K_XL/GLM-5.3-Flash-UD-Q4_K_XL-0000{1..6}-of-00006.gguf` | 199.70 GB |
| `mmproj-F16.gguf` | 1.13 GB |

The first shard holds metadata only. In the UD-Q4_K_XL tensors:

- Routed experts take 189.86 GB: 4.379 GB per MoE layer (gate and up Q4_K, down Q5_K),
  except layer 11 at 5.304 GB and layers 12 and 44 at 4.700 GB. The MTP layer's experts
  are 4.379 GB of that.
- Everything else is Q8_0 or F32 and takes 9.84 GB, including the token embedding and
  output head at 674 MB each and the shared experts at 27 MB per layer.
- The MTP layer is in the main GGUF. No separate head file is needed.

## Test setup

The test record runs GLM in CT 123, on GPU 2 or on both cards, in place of Flash-Next.
Run from this directory on the Proxmox host as root:

```bash
VMID=123 ./install.sh --download     # env, launcher, reload helper, unit; verify the model
pct exec 123 -- journalctl -u glm53f-dl --no-pager -n 20
./ct123-test-host.sh one-card        # Flash-Next disabled; CT 123 at 240 GiB and 48 cores
./ct123-test-host.sh two-card        # also GPU 1; CT 120 must be stopped
VMID=123 ENV_FILE=glm53f-bench.env ./install.sh   # after one-card: the best configuration
./ct123-test-host.sh restore         # Flash-Next back on GPU 2; CT 120's autostart restored
./ct123-test-host.sh status
VMID=123 ./install-llamacpp-release.sh   # another pinned release beside b11505, for a build A/B
```

- `install.sh` installs the `llamacpp-glm53f` unit without enabling it. The unit conflicts
  with `llamacpp-qwen38fn` and `llamacpp`, so starting it stops either one.
- `ct123-test-host.sh` keeps CT 120 from autostarting onto GPU 1 while CT 123 holds it,
  and points the thermal watchdog's map at the unit that owns each card. It never starts
  CT 120. `TEST_MODEL=mimo` sets CT 123 up for
  [MiMo-V2.6-Pro-RL](../mimo-v26-pro/README.md#test-setup) instead. `restore` retires
  either model's unit.
- **CPUs:** Proxmox gives a container a random set of `cores` CPUs at every start, and CPU
  n and n+32 share one of the 7532's 32 cores.
  - At 48 CPUs that can leave cores out. CT 123's start on 2026-10-13 covered 30 of 32.
  - `TEST_CPUSET=0-47 ./ct123-test-host.sh one-card` fixes the set to all 32 cores, plus
    16 second threads.
  - A run without `TEST_CPUSET`, and `restore`, give the choice back to Proxmox.
  - `status` shows the set and the cores it covers.
- `glm53f.env` starts with every routed expert in host RAM (`-ncmoe 46`), which fits one
  card.
- `glm53f-bench.env` is the best configuration from the configurations record, at one 64k
  slot: `-ncmoe 46`, `dio`, batch and micro-batch 4096, 32 threads, f16 KV and MTP at
  n-max 2. With `llamacpp-glm53f` started, `make bench GPU=2 MODEL=glm53f` runs the usage
  batch on it from the Mac; `ct123-test-host.sh restore` puts Flash-Next back. The sweep in [`../qwen38-flash-next/`](../qwen38-flash-next/README.md#benchmark-tools)
  drives it with `UNIT=llamacpp-glm53f N_BLOCKS=46`.
- `glm53f-long.env` holds the winners of the long-tasks record's stages 1–4 (#106):
  - b11583 and `GGML_OP_OFFLOAD_MIN_BATCH=512`;
  - `-ncmoe 45` at micro-batch 2048;
  - MTP n-max 2 at p-min 0.2;
  - 32 threads pinned to CPUs 0–31, which needs `TEST_CPUSET=0-47`.

  `glm53f-bench-b11583.env` is `glm53f-bench.env` on b11583, that record's stage 5
  control.
- `MODEL_VK_VISIBLE_DEVICES` limits the cards llama-server sees (`GGML_VK_VISIBLE_DEVICES`,
  by vulkaninfo's index). The launcher exports it only when set: an empty value hides
  every card.
- `install-llamacpp-release.sh` unpacks a pinned Vulkan release to
  `/opt/llamacpp/llama-<tag>/` after checking its SHA-256. It leaves
  `/opt/llamacpp/current` and every env file alone, so a sweep cell picks the build with
  `ENV="LLAMACPP_DIR=..."`.
- The env file's variables reach llama-server, because the launcher sources it with
  `set -a`. `GGML_OP_OFFLOAD_MIN_BATCH` (default 32) is the batch size from which Vulkan
  computes RAM-resident experts on the card; it must never be set empty, which reads as 0.

## llama.cpp support

- Architecture: #27773, merged 2026-09-30. MTP: #29928, merged 2026-10-07. b11505
  contains both.
- #27773 notes that several sequences need `--kv-unified`. Two slots worked without it on
  b11505 ([test record](runs/2026-10-10-configurations.md#stage-1-screen--2026-10-10-21232220-et)).
- Open issues, checked 2026-10-10:
  - #30204: with `--spec-type draft-mtp` on Vulkan, every request that contains an image
    fails with HTTP 500.
  - #29950: the prompt-processing compute buffer grows with context × micro-batch.
  - #28433: the MTP draft context is sized from the total context.
  - #30093: `--spec-type draft-dflash` aborts on the first request, because glm5-next does
    not provide the target-layer inputs the drafter reads.

## Test records

Plans and results of each test campaign, per [TEST-RECORDS.md](../TEST-RECORDS.md).

| Date | Build | Backend | Record | Status |
| --- | --- | --- | --- | --- |
| 2026-10-10 | b11505 | Vulkan, Mesa 26.2.4 | [The fastest configuration on one card, two cards and CPU only](runs/2026-10-10-configurations.md) | done |
| 2026-10-12 | b11505 | Vulkan, Mesa 26.2.4 | [The full benchmark batch on the best configuration](runs/2026-10-12-bench.md) | done |
| 2026-10-13 | b11505 | Vulkan, Mesa 26.2.4 | [The batch's ingestion notes and brief VRAM rises](runs/2026-10-13-findings.md) | done |
| 2026-10-13 | b11505, b11583 | Vulkan, Mesa 26.2.4 | [Tuning one 64k slot for long tasks (#106)](runs/2026-10-13-long-tasks.md) | running |

## Local validation

```bash
shellcheck -S warning ./*.sh ./llamacpp-serve-glm53f ./llamacpp-glm53f-reload
./ct123-test-host-test.sh     # ct123-test-host.sh against a mocked host
```
