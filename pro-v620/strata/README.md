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

The kernel driver is the host's in-tree amdgpu (kernel 7.0.14-pve). ROCm's libraries stay
out of `ld.so`'s path, so llama.cpp's Vulkan stack in the same container is unchanged;
`install.sh` refuses a ROCm install that would replace Mesa, libdrm or the Vulkan loader.

HIP in CT 123 needs two container settings, which `use-engine.sh strata` makes:
- `/dev/kfd` through Proxmox device passthrough (`dev0:`). It joins a running container.
- A DRM cgroup rule that allows only GPU 2's two nodes (`c 226:1` card1, `c 226:128`
  renderD128) instead of `c 226:*`. KFD reports to a process every GPU whose render node
  the process's device cgroup allows. With `226:*` that includes GPU 1, which has no render
  node in CT 123. ROCm 10's thunk then fails to set GPU 1's memory policy (`Failed to set
  mem policy for GPU [0x1f6a]`), and HIP finds no device at all. With the narrow rule, GPU 1's
  KFD node reads `Operation not permitted` in CT 123 and HIP lists the one V620. llama.cpp
  serves unchanged under the same rule.

The rule names DRM minors, which change when the nodes renumber. After a renumber, fix the
mount entries as for CT 120 ([Recovering after a DRM renumber](../README.md#recovering-after-a-drm-renumber)),
then run `./use-engine.sh strata`: it resolves the minors from the by-path links again and
restarts CT 123 if they changed. A stale rule fails loudly, since llama.cpp's guard and
Strata's launcher both refuse to start without their device.

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
./use-engine.sh strata           # the two container settings above if missing, then Strata
./use-engine.sh strata-two-card  # Strata with GPU 1 attached too, for tests; CT 120 stopped
./use-engine.sh llamacpp         # back to the deployed llama.cpp server
```

Run `install.sh` from a terminal: under `systemd-run` the container steps' output did not
reach the journal, although they ran.

Each switch changes the cards CT 123 binds, the running unit, the unit enabled at boot and
the thermal watchdog's map together, so a reboot and a thermal trip both act on the engine
that holds each card. The DRM cgroup rule always allows exactly the cards CT 123 binds; a
changed rule or card set restarts CT 123 once.

`strata-two-card` attaches GPU 1 (`0000:03:00.0`) at its real node names, as
`glm53-flash/ct123-test-host.sh` does for llama.cpp. It needs CT 120 stopped and turns CT
120's autostart off; `strata` and `llamacpp` detach GPU 1 and give the autostart back. CT 120
itself is never started.
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
| Cards | `MODEL_GPUS=0000:83:00.0`: GPU 2, by PCI address | the launcher resolves addresses to HIP's numbering at every start; two addresses run a layer split (`MODEL_LAYER_SPLIT=auto`) or, without it, an expert helper |
| CPU expert workers | `--pool-workers 15` | CT 123's 24 CPUs sit on 21 cores; STREAM peaks at 16 threads ([memory bandwidth](../qwen38-flash-next/README.md#host-memory-bandwidth--2026-10-08)) |
| n-gram (PLE) table | `--ple-io direct` from the NVMe store | engine default |
| Memory limit | `--memory-limit-mib 118784` | the engine cannot see CT 123's 120 GiB limit from inside |
| Reasoning | `reasoning_effort: none` | llama.cpp runs `--reasoning off` |
| Sampling defaults | temperature 1.0, top_k 20, top_p 0.95, min_p 0.05 | llama-server's `/props` on CT 123; Strata's own default is greedy |
| RDNA2 switches | `STRATA_HIP_PROMPT_F16=1`, `STRATA_SH_STREAM=1`, `STRATA_HIP_ADAPT_KERNEL_COPY=1` | docs/AMD_HIP.md: FP16 prompt GEMMs, the shared-expert stream, kernel copies for the #884 hang |
| Route tail skip | `STRATA_ROUTE_TAIL_SKIP=0` | it skips a missed expert every token of a verify window routes at rank 7 or lower. Off by default on gfx1030 (on for CUDA and RDNA4); pinned off, as setup.py does for Unsloth files with every expert in RAM, where it raised KL against Q8_0 from 0.056 to 0.086 (docs/QUANTS.md) |

## Sweeps

[`strata-sweep.sh`](strata-sweep.sh) measures cells of env-file settings with the probes in
`../qwen38-flash-next/` in chat mode, the placement sweep's telemetry and gates, and the
engine's own account of each request. [`strata-summary.py`](strata-summary.py) adds the
engine's expert cache, VRAM residency and log lines to the speed tables. Its header lists the
cell keys; the [test record](../qwen38-flash-next/runs/2026-10-16-strata.md) has the commands.

## Differences from llama.cpp that matter to the tooling here

- No `/completion`, `/tokenize` or `/detokenize`. The probes run in chat mode
  (`PROBE_CHAT=true`); a `CONTEXT_FILE` needs the pack's tokenizer instead of the server.
- `cache_prompt` is ignored: the conversation cache reuses any matching prefix. A request
  with `"strata_checkpoint": false` reads its whole prompt (the probes send it on cold rows);
  check `timings.cache_n` in the response.
- Responses carry llama.cpp's `timings` names (`prompt_n`, `cache_n`, `prompt_per_second`,
  `predicted_per_second`, `draft_n`, `draft_n_accepted`). `/props`, `/slots` and
  `/metrics/prometheus` use llama-server's names.
- Reasoning effort takes `none`, `low`, `medium` or `high` (`xhigh` is accepted too). A
  caller's effort wins over the config's `none`: llama.cpp's `--reasoning off` ignores it, Strata
  thinks.
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
# In CT 123, with neither engine on the card (the tests allocate VRAM):
pct exec 123 -- systemctl stop strata-qwen38fn
pct exec 123 -- runuser -u llamacpp -- env LD_LIBRARY_PATH=/opt/rocm/core-10.0/lib \
  /opt/strata/strata-v0.1.44.1/build-hip/strata-device --list-devices   # one gfx1030
pct exec 123 -- runuser -u llamacpp -- env LD_LIBRARY_PATH=/opt/rocm/core-10.0/lib \
  /opt/strata/strata-v0.1.44.1/build-hip/strata-device --selftest
# As root: ctest writes into the build tree, and two tests page-lock memory.
pct exec 123 -- env LD_LIBRARY_PATH=/opt/rocm/core-10.0/lib bash -c 'ulimit -l unlimited;
  ctest --test-dir /opt/strata/strata-v0.1.44.1/build-hip --timeout 300 -E "^ple_parity$"'
pct exec 123 -- systemctl start strata-qwen38fn
```

`ple_parity` needs a Q2_0 model fixture this box does not have. On gfx1030 the matrix-core
(WMMA, fused prompt) and hipBLASLt tests skip, and `expert_multi_test` skips without AVX-512.
