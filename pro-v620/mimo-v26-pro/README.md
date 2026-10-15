# MiMo-V2.6-Pro-RL on Radeon Pro V620

MiMo-V2.6-Pro-RL (`mimo2`, MIT) is Xiaomi's 1.02T-total, 42B-active MoE with vision and
audio encoders. It is not deployed. At 4-bit it fills nearly all of the host's RAM, and the
[test records](#test-records) measure it on this box as a baseline for hardware changes.

## Model

From the checkpoint's `config.json` and model card, and the GGUF conversion log:

- 70 layers. Ten use full attention (0, 7, 15, 23, 31, 39, 47, 55, 62, 69); the other 60
  use a 128-token sliding window with attention sinks. Only the ten hold a per-token KV
  cache: 8 KV heads, K 192 and V 128 wide, so 50 KiB per token at f16 and 3.1 GiB at 64k.
- Layer 0 has a dense FFN. Layers 1–69 have 384 routed experts, 8 active, with a sigmoid
  router and no shared expert.
- The MTP head is a separate GGUF of three layers, stored as blocks 70–72. A DFlash drafter
  is published beside it.
- Native context 1,048,576 tokens.
- The checkpoint stores the routed experts as MXFP4 (block 32) and the rest as FP8 e4m3,
  except the attention output projections, which are BF16.

The chat template thinks unless `enable_thinking` is false, and then prefills an empty
`<think></think>`. It reads no `reasoning_effort`. The model's `generation_config.json`
sets temperature 1.0 and top-p 0.95.

## Files

[`ggml-org/MiMo-V2.6-Pro-RL-GGUF`](https://huggingface.co/ggml-org/MiMo-V2.6-Pro-RL-GGUF)
revision `5f387f52` (2026-10-02, the upload), the llama.cpp project's own conversion:

| File | Size |
| --- | ---: |
| `MiMo-V2.6-Pro-RL-MXFP4-0000{1..7}-of-00007.gguf` | 554.21 GB |
| `mtp-MiMo-V2.6-Pro-RL-Q8_0.gguf` | 4.05 GB |
| `mtp-MiMo-V2.6-Pro-RL-Q4_0.gguf` | 2.15 GB |

The first shard holds metadata only. In the MXFP4 tensors:

- The routed experts keep their native MXFP4: 7,344 MiB per layer (gate, up and down at
  2,448 MiB each), 494.9 GiB over the 69 layers.
- Everything else is Q8_0 or F32 and takes 21.3 GiB:
  - attention at 271 MiB per layer, 18.5 GiB in all;
  - the output head and the token embedding at 950 MiB each;
  - layer 0's dense FFN at 306 MiB, and the routers at 9 MiB per layer.

Other files measured against this host:

- **Q4_K_M** (DevQuasar, 575.4 GiB) re-quantizes the MXFP4 experts. It is larger than the
  host's RAM and both cards together (503.6 + 60.0 GiB).
- **Q2_K** (ggml-org, 390.0 GiB) keeps the down projections at MXFP4 and quantizes gate and
  up to Q2_K.
- AesSedai's 2.0–3.5 bpw files quantize the MOPD checkpoint, not RL.

The vision and audio projector (`mmproj`) is not downloaded; the tests are text-only.

## Fit on this host

The host has 503.6 GiB of RAM (`MemTotal`) and two cards of 30,704 MiB. The non-expert
weights go on the cards, except the token embedding, which stays in RAM. Each expert
layer moved to the cards costs 7.17 GiB of VRAM and frees the same in RAM:

| `-ncmoe` | Expert layers on the cards | Experts in RAM | Weights on the cards |
| ---: | ---: | ---: | ---: |
| 70 | 0 | 494.9 GiB | 20.4 GiB |
| 68 | 2 | 480.5 GiB | 34.7 GiB |
| 67 | 3 | 473.3 GiB | 41.9 GiB |
| 66 | 4 | 466.2 GiB | 49.1 GiB |

- KV cache, compute buffers and margins share the cards' remaining VRAM.
- One card is left out: every expert layer would be in RAM (495.8 GiB with the
  embedding), leaving the host under 8 GiB. CPU only is left out too: 516.2 GiB of weights.
- The RAM experts stay in the page cache (`auto`, mmap). `dio` pins them as GTT, which
  amdgpu caps at half of RAM (251.8 GiB).
- An expert page the kernel drops is read back from the store in the middle of a request.
  The VRAM checks do not see that. `page-in-sampler.sh` logs the store's reads and CT
  123's memory, and `page-in-summary.py` reports them per sweep cell.

## Test setup

The test record runs MiMo in CT 123 on both cards, in place of Flash-Next. Run from this
directory on the Proxmox host as root:

```bash
VMID=123 ./install.sh --download     # env, launcher, unit; download and verify 9 files
pct exec 123 -- journalctl -u mimo-dl --no-pager -n 20
cd ../glm53-flash
TEST_MODEL=mimo TEST_CPUSET=0-47 ./ct123-test-host.sh two-card   # CT 120 stopped first
./ct123-test-host.sh restore         # Flash-Next back on GPU 2; CT 120's autostart restored
```

- `install.sh` installs the `llamacpp-mimo` unit without enabling it. The unit conflicts
  with `llamacpp-qwen38fn`, `llamacpp-glm53f` and `llamacpp`, so starting it stops whichever
  one runs.
- `TEST_MODEL=mimo` sets CT 123's memory to 488 GiB, which leaves the host 15.5 GiB with
  every other guest shut down. `restore` retires every test unit and puts back the limits
  from before the first test.
- `mimo.env` is the configuration the baseline record starts from: `-ncmoe 67`, split
  `66,4`, `auto`, batch and micro-batch 4096, 32 pinned threads, f16 KV, 65,536 tokens in
  two slots.
- The sweep in [`../qwen38-flash-next/`](../qwen38-flash-next/README.md#benchmark-tools)
  drives it with `UNIT=llamacpp-mimo N_BLOCKS=70`.
- MTP runs as `--spec-type draft-mtp --spec-draft-n-max N -md <mtp GGUF>`.

## llama.cpp support

- Architecture `mimo2`; V2.6 conversion #29257, merged 2026-09-22. MTP draft support
  #26228; fused-QKV tensor split with uneven K/V heads #29294; DFlash #29650. b11505 and
  b11583 contain all of them.
- #29650 was tested on CUDA. DFlash on Vulkan is untested here.

## Test records

Plans and results of each test campaign, per [TEST-RECORDS.md](../TEST-RECORDS.md).

| Date | Build | Backend | Record | Status |
| --- | --- | --- | --- | --- |
| 2026-10-15 | b11583 | Vulkan, Mesa 26.2.4 | [Baseline speed on two V620s and 512 GB of DDR4](runs/2026-10-15-baseline.md) | planned |

## Local validation

```bash
shellcheck -S warning ./*.sh ./llamacpp-serve-mimo
python3 -m py_compile page-in-summary.py
../glm53-flash/ct123-test-host-test.sh
```
