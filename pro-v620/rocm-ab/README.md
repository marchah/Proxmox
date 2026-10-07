# Vulkan vs ROCm on the V620

Measures llama.cpp's Vulkan and ROCm backends on GPU 2 (`0000:83:00.0`), and what running in
a VM costs. ROCm needs AMD's own `amdgpu-dkms` kernel driver for discrete Radeon cards, which
an LXC cannot load beside the host kernel's in-tree `amdgpu`, so the ROCm setup runs in a
passthrough VM.

| Setup | Where | Kernel driver | Backend |
| --- | --- | --- | --- |
| A | CT 123 (LXC) | host in-tree `amdgpu` (`7.0.12-1-pve`) | Vulkan (RADV) — production |
| B | VM 301 | `amdgpu-dkms` 7.1.3 (driver 31.50) | Vulkan (RADV) |
| C | VM 301 | `amdgpu-dkms` 7.1.3 (driver 31.50) | ROCm 10.0 |

A vs B isolates the VM and its driver; B vs C isolates the backend. Each comparison is its
own phase, started only after the previous one has been reviewed.

Held equal across setups: llama.cpp `b11018` release builds (Vulkan `d5ae7502…`, ROCm
`6658e965…`), byte-identical models, Mesa `25.2.8-0ubuntu0.24.04.2`, the GFX offset
(`AB_OFFSET_MV`, default 0 = stock), the 250 W board cap, and the same blower curve (the
guest's temps feed [gpu-blower-control](../gpu-blower-control/README.md)).

**The test card runs at stock voltage.** At −100 mV it computes wrong results under
prefill load. The first Phase 1 attempt's perplexity gate went NaN from chunk 27 on
setup A. Repeats of that same perplexity run (MoE, wikitext-2 40 × 2048, b11018 Vulkan, CT 123):

| Offset | Runs | Final perplexity |
| --- | --- | --- |
| −100 mV | 3 | 5.5683, 5.6082, NaN: no two runs agree |
| 0 mV | 3 | 5.5681 ± 0.06500 every time, bit-identical |

No kernel fault and no thermal event; perplexity draws 214–244 W, close to the 250 W cap.

Models, both Unsloth `UD-Q5_K_XL`: Qwen3.6-35B-A3B (MoE, sha256 `25233af7…`, without the
MTP head) and Qwen3.8-27B (dense, sha256 `8601193d…`).

## Phase 1 — A vs B: the VM costs nothing measurable (2026-10-01)

Both setups ran llama.cpp `b11018` Vulkan with Mesa `25.2.8-0ubuntu0.24.04.2` on GPU 2 at
0 mV, 250 W cap, under the blower curve:

- **A:** host kernel `7.0.12-1-pve`, in-tree `amdgpu` 3.64.0.
- **B:** guest kernel `6.8.0-146-generic`, `amdgpu-dkms` 7.1.3.

Each figure is the median of three interleaved rounds, with the min–max in brackets. Each
round is llama-bench's mean of three repetitions. Units are tok/s.

| Model | Test | Depth | A | B | B vs A |
| --- | --- | ---: | ---: | ---: | ---: |
| 35B-A3B MoE | pp512 | 0 | 1665.3 [1617.5–1676.1] | 1659.7 [1639.9–1665.9] | −0.3% |
| | pp512 | 32768 | 779.4 [773.5–783.5] | 769.9 [768.4–777.7] | −1.2% |
| | tg128 | 0 | 80.6 [80.5–80.7] | 80.6 [80.5–80.6] | −0.1% |
| | tg128 | 32768 | 72.0 [72.0–72.1] | 71.9 [71.9–72.0] | −0.2% |
| | tg, 4 parallel | 512 | 195.5 [194.9–196.0] | 193.0 [188.1–193.3] | −1.3% |
| 27B dense | pp512 | 0 | 363.8 [362.4–364.0] | 367.8 [366.0–368.4] | +1.1% |
| | pp512 | 32768 | 231.3 [230.8–231.4] | 231.4 [231.2–231.5] | +0.0% |
| | tg128 | 0 | 18.4 [18.4–18.4] | 18.4 [18.4–18.4] | −0.3% |
| | tg128 | 32768 | 17.3 [17.3–17.3] | 17.2 [17.2–17.2] | −0.1% |
| | tg, 4 parallel | 512 | 57.5 [57.2–57.5] | 57.4 [55.5–57.4] | −0.2% |

The other cells (pp512 and tg128 at depth 8192; batched-bench at 1 and 2 parallel
sequences; batched prefill) fall within the same ±1.8%. Perplexity is bit-identical between
the setups: MoE 5.5681 ± 0.0650, dense 5.8564 ± 0.0689. The card ran the same in both
setups: 249 W median under load at the cap, sclk ~2155 MHz, peak junction 90–93 °C.

The 7–14% deficit measured for ROCm in a VM in June therefore came from ROCm, not from the VM.

At 0 mV a sustained prefill holds the card at its 250 W cap, and the blowers' 90 °C hotspot
override holds the junction at 90 °C. Perplexity peaked at 93 °C, against 77 °C for the same
run at −100 mV. The ~1 GiB GTT growth seen in round 1 comes from perplexity's full-vocabulary
logits, not from a KV spill: the speed rounds stay at 140 MiB.

## Phase 2 — A vs C: ROCm decodes slower, prefills faster deep in context (2026-10-01)

Same conditions as Phase 1, with C running ROCm 10.0 (`amdrocm-runtime10.0` and
`amdrocm-blas10.0-gfx1030` 10.0.0-4) in VM 301 on `amdgpu-dkms` 7.1.3. Each figure is the
median of three interleaved rounds, with the min–max in brackets. Units are tok/s.

| Model | Test | Depth | A (Vulkan) | C (ROCm) | C vs A |
| --- | --- | ---: | ---: | ---: | ---: |
| 35B-A3B MoE | pp512 | 0 | 1646.8 [1646.7–1652.3] | 1530.7 [1523.7–1540.7] | −7.0% |
| | pp512 | 8192 | 1291.8 [1286.6–1307.5] | 1331.3 [1322.2–1336.9] | +3.1% |
| | pp512 | 32768 | 773.3 [771.8–777.0] | 953.4 [950.9–960.5] | +23.3% |
| | tg128 | 0 | 80.7 [80.4–80.8] | 67.3 [67.2–67.6] | −16.6% |
| | tg128 | 8192 | 76.8 [76.8–76.9] | 67.6 [67.5–67.6] | −12.0% |
| | tg128 | 32768 | 72.1 [72.0–72.1] | 61.8 [61.8–61.9] | −14.2% |
| | tg, 4 parallel | 512 | 195.7 [195.5–195.8] | 184.1 [184.0–184.2] | −6.0% |
| 27B dense | pp512 | 0 | 365.1 [364.6–365.7] | 373.4 [370.3–375.4] | +2.3% |
| | pp512 | 8192 | 319.0 [318.8–319.9] | 340.9 [340.5–341.0] | +6.9% |
| | pp512 | 32768 | 232.2 [231.8–232.5] | 274.0 [273.7–274.1] | +18.0% |
| | tg128 | 0 | 18.4 [18.4–18.4] | 17.0 [17.0–17.0] | −7.6% |
| | tg128 | 8192 | 18.1 [18.1–18.1] | 16.9 [16.8–16.9] | −6.7% |
| | tg128 | 32768 | 17.3 [17.3–17.3] | 15.9 [15.9–15.9] | −8.2% |
| | tg, 4 parallel | 512 | 57.7 [57.7–57.7] | 52.1 [52.1–52.2] | −9.6% |

- **Decode:** Vulkan is faster on both models. ROCm's deficit on the MoE (−12 to −17%) is
  about twice its deficit on the dense model (−7 to −8%), and shrinks with parallel sequences
  on the MoE (−17% at 1, −6% at 4).
- **Prefill:** ROCm's prefill advantage grows with depth, reaching +23% (MoE) and +18%
  (dense) at 32k.
- **Correctness:** perplexity agrees within 0.04% (MoE 5.5668 vs 5.5681, dense 5.8587 vs
  5.8564), inside the ±0.065 error.
- **Card:** both ran at the 249 W cap; ROCm held a higher clock (2246 vs 2168 MHz median).

Treating a request as new prefill P plus decode D at 32k depth, ROCm finishes sooner only
when P/D exceeds about 9.5 (MoE) or 8 (dense). These measurements exclude speculative
decoding, which CT 120 uses and which speeds Vulkan decode by +49–77%
([`../spec-ab/`](../spec-ab/README.md)).

## Phase 3 — B vs C: the same result with the VM held constant (2026-10-01)

Vulkan and ROCm ran in the same VM on the same kernel and `amdgpu-dkms`. Every cell landed
within about one point of Phase 2:

| | MoE B (Vulkan) | MoE C (ROCm) | C vs B | Dense C vs B |
| --- | ---: | ---: | ---: | ---: |
| pp512 d0 | 1662.6 | 1529.2 | −8.0% | +1.3% |
| pp512 d32768 | 772.9 | 951.4 | +23.1% | +18.1% |
| tg128 d0 | 80.4 | 67.2 | −16.4% | −7.6% |
| tg128 d32768 | 72.1 | 61.7 | −14.3% | −8.0% |
| tg, 4 parallel | 193.5 | 183.8 | −5.0% | −9.4% |

The Phase 2 differences are therefore the backend's, not the VM's or the driver's.
Perplexity repeated exactly across phases, so both backends are deterministic at 0 mV:
Vulkan 5.5681 and 5.8564, ROCm 5.5668 and 5.8587.

## Phase 4 — MTP serving: a tie on CT 120's traffic (2026-10-01)

`run-spec.sh` ran CT 120's production server flags in VM 301 on both backends: 262k context,
2 slots, q8_0 KV, FA, batch 4096 and `--reasoning off`. Vulkan used CT 120's ubatch 1024;
ROCm used 512, the most it fits (the script's defaults). Each backend had a non-speculative
control and MTP at draft lengths 2, 3 and 4. The prompts were `../spec-ab/spec-probe.py`'s:
short code, prose and JSON (greedy and sampled), two concurrent streams, 16k/48k deep
contexts and a tool call. Figures are medians over 3 rotated repetitions, in tok/s, with
GPU 2 at 0 mV.

**ROCm cannot run CT 120's exact configuration.** At ubatch 1024 it aborted with
`ROCm error: out of memory` on the first 16k-token prompt. ROCm fits at ubatch 512, ending
at 30,437 of 30,704 MiB (267 MiB free). Vulkan keeps ubatch 1024 with ~680 MiB free plus
GTT. Two deep prompts at once on ROCm were not tested.

| MTP draft length 3 | Vulkan | ROCm | ROCm vs Vulkan |
| --- | ---: | ---: | ---: |
| code, greedy | 115.9 | 106.5 | −8% |
| prose, greedy | 100.2 | 92.9 | −7% |
| JSON, greedy | 132.5 | 121.4 | −8% |
| tool call | 134.5 | 113.0 | −16% |
| 16k depth decode / prefill | 98.7 / 1291 | 89.3 / 1308 | −10% / +1% |
| 48k depth decode / prefill | 82.5 / 863 | 76.0 / 1058 | −8% / +23% |
| 2 streams, code / prose / JSON | 140.9 / 105.0 / 152.5 | 131.5 / 112.6 / 142.3 | −7% / +7% / −7% |

- **MTP speedup:** MTP narrows the decode gap from −14% (no MTP) to −7 to −10%; ROCm's larger
  verify batches cost it less.
- **Draft length:** n3 is best or near-best single-stream on both backends. ROCm's best for
  two streams is n2 (137.7 / 122.1 / 149.7), within 5% of Vulkan n3. n4 collapses with two
  streams on Vulkan (75 tok/s on code) far more than on ROCm (109).
- **Correctness:** draft acceptance matches (71% at n3). Every arm returned valid tool
  calls, showed no repetition collapse, and gave identical greedy output across repetitions.

**Replaying CT 120's real traffic** (`replay-ct120.py`, 3,234 requests from MTP going live on
2026-09-22 to 2026-10-01):

- **Traffic:** 7.1M prompt tokens against 1.2M generated, 61% of requests ending at 32–64k
  context. Vulkan spent 6.7 h of GPU time on them.
- **Method:** scaled by the measured ratios at each request's depth, ROCm comes to **6.7 h
  (+0.2%)**: +8% under 8k context, −0.8% at 32–64k. The ratios come from cold-prefill
  averages, which understate ROCm's edge deep in context, so this leans toward Vulkan.
- **Result:** ROCm's deep prefill cancels its slower decode, so throughput is a tie.

## Phase 5 — a dense coder: ROCm wins (2026-10-02)

This measures ROCm against Vulkan on a dense model under a coding-agent workload. It is a
backend measurement, not a deployment plan: GPU 2 is slated for a large MoE. Setup:

- **Model:** Qwen3.8-27B UD-Q4_K_XL (sha256 `3f227079…`), with q8_0 KV, reasoning off and
  one 128k slot.
- **Speculation:** the model's two own drafters, plus a no-speculation control.
  - DFlash2 (`c18e800d…`) at draft length 8.
  - The MTP head `a4lg/Qwen3.8-27B-MTP-ONLY-GGUF` Q8_0 (`674d0fc3…`) at draft length 2.
    Longer MTP drafts measured worse when the old coder was tuned.
- **Session:** `agent-sim.py` grows one coding-agent conversation to ~126k tokens. It
  alternates ~4k-token file reads with a code-writing turn every third turn, keeps the
  prompt cache on and decodes greedily.
- **Runs:** two, each with 3 rotated repetitions. The second added the MTP arms against
  both backends' earlier best arms, which repeated within 0.1 min.
- **Settings:** GPU 2 at 0 mV, ubatch 1024 on both backends.

| Whole session | Vulkan | ROCm |
| --- | ---: | ---: |
| no speculation | 17.7 min | 14.3 min |
| DFlash2 n8 | 19.3 min | 13.2 min |
| MTP n2 | **16.9 min** | **12.8 min** |

MTP n2 is each backend's best. Each backend's best, in tok/s:

| Depth | Prefill of a file read: Vulkan / ROCm | Code writing: Vulkan / ROCm |
| --- | ---: | ---: |
| 0–32k | 249.5 / 332.7 (+33%) | 34.7 / 31.4 (−10%) |
| 32–64k | 172.3 / 246.6 (+43%) | 31.4 / 27.5 (−12%) |
| 64–96k | 129.6 / 196.7 (+52%) | 29.2 / 24.7 (−15%) |
| 96–128k | 104.0 / 165.4 (+59%) | 26.7 / 21.5 (−19%) |

- **Session:** ROCm finishes it 24% sooner (12.8 vs 16.9 min). Its prefill lead grows with
  depth, and a coding session prefills ~25 tokens for every one it generates.
- **Decode with MTP:** Vulkan decodes 10–19% faster, and MTP holds up with depth on both
  backends at 94% acceptance.
- **Break-even:** from these rates, ROCm finishes a turn sooner once it prefills more than
  2.4–3 tokens per generated token. Agentic coding with tool output is well above that;
  long-form generation with little input would favour Vulkan.
- **DFlash2 is not worth keeping:** on Vulkan it slows down past 32k (11.4 vs 16.5 tok/s at
  96–128k) and loses to no speculation overall. The +89% measured for the old coder came
  from short prompts.
- **Correctness:** every arm repeated its greedy text exactly on 40/40 turns, and Vulkan and
  ROCm with MTP wrote identical text on 34/40.
- **Fit:** one 128k slot leaves ROCm ~3.8 GiB free with MTP.

**Two agents at once** (`SESSIONS=2`): two concurrent sessions, one per slot, each reading
a different part of the corpus. `fit-probe.sh` loaded each two-slot configuration with MTP:

| Two slots, MTP n2 | Vulkan | ROCm |
| --- | --- | --- |
| 2×128k, Q8_0 head | loads: 30,139 MiB + 615 GTT | out of memory |
| 2×128k, Q6_K head (2.6 GiB) | loads: 28,773 MiB + 615 GTT | out of memory |
| 2×112k, Q8_0 head | — | out of memory |
| 2×96k, Q8_0 head | — | loads: 29,415 MiB |

**ROCm can serve two agents only at ~96k context each; Vulkan can give both the full 128k.**
At 2×96k (Q8_0 head, both backends), two sessions growing to ~92k each, 3 rotated
repetitions:

| Two agents | Vulkan + MTP | ROCm + MTP |
| --- | ---: | ---: |
| Wall time until both finish | 21.2 min [21.2–21.3] | **16.3 min [16.3–16.3]** |
| Prefill of a file read, 0–32k / 64–96k | 228.9 / 131.5 | 294.2 / 190.7 |
| Code writing while the other agent works, 64–96k | 5.2 | 10.8 |

- **Result:** ROCm keeps its lead with two agents, 23% faster.
- **Contention:** code writing slows sharply on both whenever the other agent is
  prefilling, but less on ROCm, which finishes that prefill sooner.
- **MTP and two agents:** it does not help Vulkan here; Vulkan took 21.2 min in an earlier
  partial no-speculation run too.
- **Memory:** ROCm ended at 30,081 of 30,704 MiB.
- **Determinism:** greedy text repeated on 44–47 of 58 turns rather than all. With two
  slots, each run batches the sessions' requests together differently, which flips
  near-ties on both backends alike.

## Conclusion

- **Vulkan stays the backend.** With MTP, ROCm 10.0 ties on CT 120's real traffic, so
  throughput does not decide it. The rest does:
  - ROCm cannot run the production ubatch, and has 267 MiB of VRAM left where RADV
    overflows to GTT. A ROCm OOM aborts the server; a RADV spill only slows it.
  - It needs the passthrough VM, which the host's thermal watchdog cannot see.
  - It decodes 7–16% slower in single-stream chat and tool calls.
- **For a dense coder, ROCm is faster.** With Qwen3.8-27B Q4 and MTP on both backends,
  ROCm finishes a 126k coding-agent session 24% sooner, and two concurrent agents 23%
  sooner. Vulkan decodes faster but prefills far slower, and coding agents prefill far more
  than they generate. ROCm needs the passthrough VM, and gives two agents ~96k context each
  where Vulkan fits 128k.
- **Not yet measured:** ROCm on a large MoE with experts offloaded to the CPU
  (`--n-cpu-moe`), GPU 2's intended workload. That workload is prefill-bound
  ([qwen38-flash-next](../qwen38-flash-next/README.md)), which is where ROCm is strongest,
  but ROCm decoded the MoE slower here, and CPU offload was not part of any phase.
- **The passthrough VM costs no throughput.** Its costs are operational: the card is
  exclusive to the VM, guest RAM is pinned, and the model reloads from the guest disk.
- **The −100 mV undervolt corrupts compute on both cards** under prefill load. That is a
  production finding independent of the backend question.

## Files

| File | Where | Role |
| --- | --- | --- |
| `stage-host.sh` | host | Copies both models to a temporary thin volume, fetches and checks the release tarballs, the cloud image and wikitext-2. |
| `create-vm.sh` | host | Creates VM 301: q35, OVMF with Secure Boot off, 16 vCPU, 64 GiB, guest agent on. |
| `stage-guest.sh` | host | Copies the harness, the release builds and the models into the guest, sha256-checked and idempotent. |
| `guest-setup.sh` | VM | `amdgpu-dkms` for every installed kernel, Mesa pinned to the production build, OverDrive enabled. |
| `guest-rocm.sh` | VM | ROCm 10.0 runtime and gfx1030 BLAS only; fails if the llama.cpp ROCm build has an unresolved library. |
| `card.sh` | host | Moves the card between the host and the VM: `to-vm`, `to-host`, `restore`, `status`. |
| `bench.sh` | CT 123 / VM | One round of one setup: llama-bench, llama-batched-bench, optional perplexity, 1 s GPU telemetry. |
| `run-phase.sh` | host | One phase: three rounds `X Y \| Y X \| X Y`, then restores production. |
| `summarize.py` | anywhere | Markdown tables from one phase's results. |
| `run-spec.sh` | host | Phase 4: CT 120's server flags in the VM, per backend, with and without MTP, measured by `../spec-ab/spec-probe.py`. |
| `replay-ct120.py` | CT 120 | Replays CT 120's journaled requests under the measured ROCm/Vulkan ratios. |
| `run-coder.sh` | host | Phase 5: the dense coder per backend, with and without DFlash2, one `agent-sim.py` session per arm. |
| `agent-sim.py` | VM | A scripted coding-agent session growing to ~126k tokens; one JSONL row per turn. |
| `summarize-coder.py` | anywhere | Phase 5 tables by depth band, session time and correctness. |
| `fit-probe.sh` | host | Loads two-slot coder configurations in the VM and reports which fit, with VRAM and GTT. |

## Preparing the VM

Once, from a pro-v620 checkout on the host at `/root/rocm-ab/src`. Build
`spec-ab/deep-context.txt` first, as `../spec-ab/run-ab.sh`'s header shows; it is not committed.

```sh
bash rocm-ab/stage-host.sh                        # models to a thin volume, release builds, image
bash rocm-ab/create-vm.sh                         # VM 301, no GPU yet
qm start 301                                      # booting without the card leaves production alone
bash rocm-ab/stage-guest.sh                       # harness, builds and models into the guest
ssh ubuntu@<vm> sudo bash /opt/rocm-ab/guest-setup.sh   # amdgpu-dkms, pinned Mesa
ssh ubuntu@<vm> sudo bash /opt/rocm-ab/guest-rocm.sh    # ROCm 10.0 (phases with setup C)
qm shutdown 301
```

`stage-guest.sh` checks every file by sha256 and copies only what is missing or different,
so rerun it after editing a harness script. The fresh cloud image has no QEMU guest agent, so
on first use it reaches the VM by its DHCP name (`rocm-ab.lan`) and installs the agent, which
`card.sh` and the runners need. `ONLY` limits which models it stages; the header
lists the regex for each phase. To restage with the card already assigned to the VM, run
`qm set 301 --delete hostpci0` first: `card.sh to-vm` adds it back.

## Running a phase

```sh
# host, from /root/rocm-ab/src (pro-v620 layout)
systemd-run --unit=rocm-ab-p1 --collect bash rocm-ab/run-phase.sh p1 A B
journalctl -fu rocm-ab-p1
```

`run-phase.sh` disables CT 123's model service for the phase, binds the model volume into
CT 123 read-only, and when the phase finishes or fails it runs `card.sh restore`: the card
returns to `amdgpu` at `AB_OFFSET_MV` (default 0), and CT 123's service is re-enabled. CT
120's card is never touched.

⚠️ **Cancelling with `systemctl stop` skips the restore.** Stopping the unit kills the whole
process group, so the restore started by the exit trap dies too, leaving the card on `vfio-pci`
and CT 123 stopped. Run `bash rocm-ab/card.sh restore` after stopping any run. `SMOKE=1` runs one
round with tiny shapes to check the pipeline.

Per round and model: `llama-bench -p 512 -n 128 -d 0,8192,32768 -r 3` and
`llama-batched-bench -npp 512 -ntg 128 -npl 1,2,4`, both with `-fa on -ctk q8_0 -ctv q8_0
-b 2048 -ub 1024 -t 8` and no speculative decoding. Round 1 adds perplexity on wikitext-2
(40 × 2048) as a correctness gate. Each run starts once the junction is at or below 50 °C.

## Safety

- The production thermal watchdog stops services, not hand-run benchmarks, and cannot read a
  passed-through card. `run-phase.sh` runs
  [`thermal-guard.sh`](../qwen38-flash-next/thermal-guard.sh) on whichever side holds the
  card. On the host its patterns name only the bench tools: `llama-server` would also match
  CT 120's production server, whose processes the host can see.
- `card.sh` refuses to unbind while host processes hold the card, waits for QEMU to release
  it before rebinding, and stops if the DRM node names CT 123 mounts have changed.
- Moving the card clears its OverDrive state. Each move re-applies `AB_OFFSET_MV` on that
  side and checks it.

## Teardown after the last phase

```sh
qm destroy 301 --purge
pct set 123 -delete mp1
umount /mnt/rocm-ab-models && lvremove -y pve/rocm-ab-models
```
