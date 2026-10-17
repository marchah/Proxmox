# Project Maya for GLM-5.3-Flash on CT 123

[Project Maya](https://github.com/mw00/project-maya) (MIT) is an inference engine built for one
model, GLM-5.3-Flash. Its engine started from [Strata](../strata/README.md)'s and was rewritten for
this model. It splits the routed experts into three tiers: VRAM, page-locked RAM and the SSD. The
VRAM tier follows the conversation, and a CPU lane computes RAM-tier experts while the GPU works.
On two cards it splits the layers, and the second card runs the model's MTP block. On AMD it runs
through HIP (ROCm). RDNA2 (`gfx1030`) is accepted as experimental; the project has not validated
it on a card.

This directory installs Maya into CT 123 beside llama.cpp and Strata, for the GLM-5.3-Flash test
records ([glm53-flash](../glm53-flash/README.md#test-records)). GLM-5.3-Flash is not deployed.

## What is installed

| Part | Where (CT 123) | Pinned by |
| --- | --- | --- |
| ROCm userspace for gfx1030 | `/opt/rocm/core-10.0` | `../strata/install.sh` |
| Maya source and HIP build for gfx1030, with the AMD guide's tests | `/opt/maya/maya-v1.1.15`, `build/` | `MAYA_RELEASE`, `MAYA_COMMIT` |
| llama.cpp (ggml and gguf-py), at Maya's pin | `third_party/llama.cpp` in the source tree | `MAYA_GGML_COMMIT` |
| Python venv with setup.py's packages | `/opt/maya/venv` | none upstream; `PACKAGES` in the venv records them |
| llama.cpp for the CPU and Maya's `llm_logits_dump`, for the quality gate | `/opt/maya/llama.cpp-b11583` | `GATE_LLAMACPP_TAG` |
| UD-Q4_K_XL: links to llama.cpp's shards and Maya's pack | `/models/maya/ud-q4_k_xl/` | the shards' `.verified` stamps |
| Maya-L (156.3 GB) and its pack | `/models/maya/Maya-L/` | `maya-l-download.sh`: revision and SHA-256s |
| Env file, launcher, unit | `/etc/maya-glm53f.env`, `/usr/local/bin/maya-serve-glm53f`, `maya-glm53f.service` | this directory |

```bash
VMID=123 ./install.sh                     # idempotent; the build runs at nice 19
pct exec 123 -- systemd-run --unit=maya-dl --collect /usr/local/bin/maya-l-download.sh
VMID=123 ./install.sh                     # again once Maya-L is verified: writes its pack
```

The engine reads the GGUF shards from its pack's parent folder, so the pack lives beside them.
`/models/maya/ud-q4_k_xl/` links llama.cpp's shards, which keeps the pack out of llama.cpp's
folder. Rebuildable bulk on CT 123's root disk: `/opt/maya`; check its size with
`pct exec 123 -- du -sh /opt/maya`.

`install.sh` patches a copy of `llm_logits_dump.cpp` to read `DUMP_THREADS` (default 32). The
original decodes one token per call on llama.cpp's default 4 threads, which would take hours on
this model.

## Running it

The unit conflicts with the four other model units on the card and port. CT 123 needs
`/dev/kfd` and a DRM cgroup rule narrowed to the bound cards, which the GLM test setup makes:

```bash
cd ../glm53-flash
TEST_CPUSET=0-47 TEST_ENGINE=maya ./ct123-test-host.sh one-card   # or two-card
TEST_ENGINE=llamacpp ./ct123-test-host.sh engine   # hand the cards to llama.cpp's GLM unit, no restart
./ct123-test-host.sh restore                       # Flash-Next back on the engine enabled before
```

`maya-serve-glm53f` writes Maya's JSON config from the env file at every start, as Maya's setup
writes it (`maya.py write_config`), and runs `serve/server.py`. The config is kept at
`/var/lib/maya-glm53f/config.json`; the engine log is `/var/log/maya-glm53f/engine.log`.

## Configuration

| Setting | Value | Source |
| --- | --- | --- |
| Cards | `MODEL_GPUS=0000:83:00.0`, by PCI address | the launcher resolves HIP's numbering at every start; two addresses run a layer split, the first card first, at `MODEL_LAYER_SPLIT` |
| Context | 64k, one request at a time | llama.cpp's one 64k slot |
| Engine arguments | `--expert-cache auto --prefill auto --kv-streaming on`, the shipped expert profile | setup's config |
| HIP settings | 3 GiB VRAM and 16 GiB RAM left free, prompt sub-batch 1024, 4 GiB prompt budget | setup's values for a discrete card of 20 GB or more; no hipBLASLt table exists for gfx1030 |
| RAM tier | `STRATA_GLM_RAM_RESIDENT=1`: every expert outside VRAM pinned in RAM | this box's RAM holds them; nothing is read from the SSD while it answers |
| Prompt reuse | `STRATA_GLM_NO_REUSE=1`: no snapshot of the last prompt, no SSD slots, no checkpoints | every request reads its whole prompt, as the probes' cold rows need; with only slots and checkpoints off, a repeated prompt still read 1 of 24 tokens |
| Reasoning | `reasoning_effort: none` | llama.cpp runs `--reasoning-budget 0`; Maya's default is high |
| Sampling defaults | temperature 1.0, top-p 0.95 | Maya's, the model's generation_config |

On two cards, the engine's split search (`MODEL_LAYER_SPLIT=auto`) prices each card from HIP's
memory clock, which reads 64 GB/s on the V620 against the card's 512 GB/s. It then gives GPU 2
only the dense layers 0–1, with no expert pool and no prompt path, so every prompt runs token by
token. `MODEL_LAYER_SPLIT=24` gives each card 21 MoE layers. Two-card loads at layer 24 stalled
on long prompts ([test record](../glm53-flash/runs/2026-10-16-maya.md#stage-2-arms)).

## Measuring it

- [`../strata/strata-sweep.sh`](../strata/strata-sweep.sh) with `UNIT=maya-glm53f` runs cells
  over this env file. Its base is `maya-glm53f.env`, and the contract uses GLM's efforts.
  `strata-cell.py` reads Maya's start and request lines (`glm fast:`, `glm stat:`,
  `glm spec:`), and a stall or non-finite line fails the cell.
- [`maya-gate.sh`](maya-gate.sh) compares Maya's next-token distributions with llama.cpp's on the
  same GGUF and tokens, and gives the test record's verdict. [`maya-gate.py`](maya-gate.py) has
  each step.
- [`maya-vs-llamacpp.sh`](maya-vs-llamacpp.sh) interleaves llama.cpp's GLM unit and Maya in
  rounds, with the watchdog's map following the engine that runs.

## Differences from llama.cpp that matter to the tooling

- Responses carry llama.cpp's `timings` names (`prompt_n`, `cache_n`, `predicted_per_second`,
  `draft_n`, `draft_n_accepted`).
- Reasoning effort takes `none`, `low`, `high` or `max`, and a caller's effort wins over the
  config's.
- Maya's `strata-device` prints HIP's device 0 only; the launcher counts devices through HIP.

## Validation

```bash
shellcheck -S warning ./*.sh ./maya-serve-glm53f
python3 -m py_compile maya-gate.py
```
