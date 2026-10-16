# Strata for Qwen3.8-Flash-Next on CT 123

[Strata](https://github.com/Niko1221/Strata) (MIT) is an inference engine built for one model
family, Qwen3.8-Flash-Next. It keeps every routed expert in a page-locked RAM arena and fills
the VRAM left after the dense weights with an expert cache. The cache adapts to the requests,
and the CPU computes the cache misses while the GPU works. The model's own MTP layer drafts
tokens. On AMD it runs through HIP (ROCm), not Vulkan.

This directory installs Strata into CT 123 beside the deployed llama.cpp server
([qwen38-flash-next](../qwen38-flash-next/README.md)), on the same card (`0000:83:00.0`),
port, model name and GGUF files. Only one of the two engines runs at a time. Measurements
are in the test records under [`qwen38-flash-next/runs/`](../qwen38-flash-next/README.md#test-records).

## What is installed

| Part | Where (CT 123) | Pinned by |
| --- | --- | --- |
| ROCm userspace for gfx1030, from AMD's apt repository | `/opt/rocm/core-10.0` | `ROCM_PACKAGE`, `ROCM_VERSION` (held) |
| Strata source and HIP build for gfx1030, with its tests | `/opt/strata/strata-v0.1.44.1`, `build-hip/` | `STRATA_RELEASE`, `STRATA_COMMIT` |
| llama.cpp (ggml and gguf-py), at Strata's pin | `third_party/llama.cpp` in the source tree | `STRATA_GGML_COMMIT` |
| Python venv with Strata's `requirements.txt` | `/opt/strata/venv` | the file's pins |
| Pack of shard 1: dense weights, tokenizer, conversions | `/models/strata/packs/ud-q4_k_xl` | the shard's SHA-256 |
| MTP draft layer | `/models/strata/mtp/rt` | `mtp_fetch.py`'s checkpoint revision and tensor SHA-256s |
| Env file, launcher, reload helper | `/etc/strata-qwen38fn.env`, `/usr/local/bin/strata-serve-qwen38fn`, `/usr/local/bin/strata-qwen38fn-reload` | this directory |
| Unit | `strata-qwen38fn.service`, `Conflicts=llamacpp-qwen38fn.service` | this directory |

The kernel driver is the host's in-tree amdgpu (kernel 7.0.14-pve). The container gets
`/dev/kfd` through Proxmox device passthrough (`devN:`), beside the render node it already
has. ROCm's libraries stay out of `ld.so`'s path, so llama.cpp's Vulkan stack in the same
container is unchanged; `install.sh` refuses a ROCm install that would replace Mesa, libdrm
or the Vulkan loader.

Rebuildable bulk on CT 123's root disk, which the weekly backup includes: `/opt/rocm` and
`/opt/strata`. Check their size with `pct exec 123 -- du -sh /opt/rocm /opt/strata`; the
backup job's `exclude-path` can leave them out.

## Model files

No other quantization is needed. The four UD-Q4_K_XL shards llama.cpp serves have the
SHA-256s of the revision Strata supports (`38bb39e`; head `766911a` is byte-identical).
Strata loads their experts from the shards into its arena at start, with no repacked copy. Strata cannot use Unsloth's separate MTP GGUF heads. It
builds its own draft layer from the 31 `mtp.*` tensors of the BF16 checkpoint
`Qwen/Qwen3.8-Flash-Next` (HTTP range reads, about 5 GB), with Q2_0 experts, as its setup
does.

Other files Strata supports, for reference (its own measurements, on an R9700 32 GB):
- GSQ-RCO IQ3_S, Strata's native format, decodes faster (75/95 against 63/87 t/s for UD-Q4_K_XL
  on story/code) and agrees less with Q8_0: 87.7% against 93.1% of top tokens on Strata's
  yardstick.
- UD-Q5_K_XL is closer to Q8_0 (94.6%), at 57–60/81–83 t/s. Its experts fit this box's RAM.

## Switching engines

```bash
VMID=123 ./install.sh            # idempotent; llama.cpp keeps serving
./use-engine.sh status
./use-engine.sh strata           # adds /dev/kfd if missing (restarts CT 123 once), then Strata
./use-engine.sh llamacpp         # back to the deployed llama.cpp server
```

Each switch changes the running unit, the unit enabled at boot and the thermal watchdog's
map entry for `0000:83:00.0` together, so a reboot and a thermal trip both act on the engine
that holds the card. The first `strata` switch restarts CT 123 to apply `/dev/kfd`.
Switch back to `llamacpp` before running `../qwen38-flash-next/ct120-cutover.sh`: its
rollback writes `123:llamacpp-qwen38fn` into the watchdog map.

`strata-qwen38fn-reload <context> <parallel>` restarts Strata and returns once
`/v1/models` lists the model, the interface of `llamacpp-qwen38fn-reload`. Strata gives each
slot the whole context; llama.cpp splits it across the slots.

## Configuration

`strata-serve-qwen38fn` writes the server's JSON config from the env file at every start
and exports the env file's `STRATA_*` switches to the engine. The starting values:

| Setting | Value | Source |
| --- | --- | --- |
| Experts | every expert in the RAM arena (no `--resident-budget-gib`) | setup.py's rule for Unsloth files when the experts and 16 GiB more fit the RAM |
| Expert cache | `--expert-cache auto`, `--vram-reserve-mib 1024`, the shipped `data/expert-profile.bin` | setup.py; docs/AMD_HIP.md's HIP starting arguments |
| Context, KV | 64k, `--kv int8`, `--kv-resident 32768` | llama.cpp's one 64k slot; setup.py streams KV from 64k |
| Prompt chunks | `--prefill auto` (8,192 tokens) | setup.py |
| Draft | MTP draft layer, `--spec 4 --spec-min-p 0.5` | setup.py |
| CPU expert workers | `--pool-workers 15` | CT 123's 24 CPUs sit on 21 cores; STREAM peaks at 16 threads ([memory bandwidth](../qwen38-flash-next/README.md#host-memory-bandwidth--2026-10-08)) |
| n-gram (PLE) table | `--ple-io direct` from the NVMe store | engine default |
| Memory limit | `--memory-limit-mib 118784` | the engine cannot see CT 123's 120 GiB limit from inside |
| Reasoning | `reasoning_effort: none` | llama.cpp runs `--reasoning off` |
| Sampling defaults | temperature 1.0, top_k 20, top_p 0.95, min_p 0.05 | llama-server's `/props` on CT 123; Strata's own default is greedy |
| RDNA2 switches | `STRATA_HIP_PROMPT_F16=1`, `STRATA_SH_STREAM=1`, `STRATA_HIP_ADAPT_KERNEL_COPY=1` | docs/AMD_HIP.md: FP16 prompt GEMMs, the shared-expert stream, kernel copies for the #884 hang |

## Differences from llama.cpp that matter to the tooling here

- No `/completion`, `/tokenize` or `/detokenize`. The probes run in chat mode
  (`PROBE_CHAT=true`); a `CONTEXT_FILE` needs the pack's tokenizer instead of the server.
- `cache_prompt` is ignored: the conversation cache reuses any matching prefix. A cold
  prefill needs a prompt that differs from every earlier one near its start; check
  `timings.cache_n` in the response.
- Responses carry llama.cpp's `timings` names (`prompt_n`, `cache_n`, `prompt_per_second`,
  `predicted_per_second`, `draft_n`, `draft_n_accepted`). `/props`, `/slots` and
  `/metrics/prometheus` use llama-server's names.
- Reasoning effort takes `none`, `low`, `medium` or `high`; there is no `xhigh`.
- `/v1/models` is empty until the engine has said READY; `/health` answers before.
- The server checks the `Host` header: `gpu2`, the container's IPs and `MODEL_ALLOWED_HOSTS`
  pass.

## Known gfx1030 issues upstream

- [#2457](https://github.com/Niko1221/Strata/issues/2457), open: on 0.1.44, IQ3_S output on
  RX 6000 cards turns to garbage while Q2_0 is fine; 0.1.43.1 is correct. UD-Q4_K_XL on
  gfx1030 is not reported either way. 0.1.43.1 does not run UD-Q4_K_XL's prompt path on AMD,
  so this install pins 0.1.44.1 and checks output quality before measuring speed.
- [#884](https://github.com/Niko1221/Strata/issues/884): verify hangs after long prompts
  when MMQ prompts, adaptive swaps and SDMA copies meet; `STRATA_HIP_ADAPT_KERNEL_COPY=1`
  avoids it at no measured cost.
- [#1103](https://github.com/Niko1221/Strata/issues/1103): AMD's 7.14 gfx103X wheels time
  out in verify. This install uses the ROCm 10.0 packages instead, the runtime of the
  community RX 6900 XT reports.
- hipBLASLt ships no gfx1030 kernels, so dense prompt GEMMs use rocBLAS; there is no
  tuning table.

## Validation

```bash
shellcheck -S warning ./*.sh ./strata-serve-qwen38fn ./strata-qwen38fn-reload
# In CT 123, with the server stopped (both engines):
pct exec 123 -- bash -lc 'cd /opt/strata/strata-v0.1.44.1 && LD_LIBRARY_PATH=/opt/rocm/core-10.0/lib \
  build-hip/strata-device --selftest'
pct exec 123 -- systemd-run --wait --pipe -p LimitMEMLOCK=infinity -p User=llamacpp \
  -p SupplementaryGroups=render -E LD_LIBRARY_PATH=/opt/rocm/core-10.0/lib \
  ctest --test-dir /opt/strata/strata-v0.1.44.1/build-hip --output-on-failure --timeout 120 -E '^ple_parity$'
```

`ple_parity` needs a Q2_0 model fixture this box does not have.
