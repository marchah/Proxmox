# Qwen3.8-Flash-Next: Strata's benchmark suite on one and two V620s, for Strata's community reports

Plan committed 2026-10-17 · Run 2026-10-17 · Status: done

## Question

Strata collects community benchmark reports in its repository (`bench/results/`, format in
`docs/COMMUNITY_BENCHMARKS.md`). Its own suite, `tools/strata_bench.py`, measures an install the
way it is used, through the HTTP API, and writes a report in that format. Our records measured
Strata with our own probes. This record runs Strata's suite on the best configuration we
measured for each card count, to write two reports in Strata's format:
- one V620 (GPU 2);
- two V620s in a layer split with pipeline windows.

Whether to submit them to Strata, and from which account, is the owner's decision.

## What answers it

For each configuration:
- Strata's results table, pooled over three engine starts: short chat, fresh 4K, 16K and 32K
  prompts, and the agent session's follow-up turns. It gives prompt throughput, decode
  throughput and time to first token, each as a median and range.
- Each start's medians, to show the spread between starts. With pipeline windows, decode varied
  by up to 5.5 t/s between starts in the [pipeline record](2026-10-17-strata-pipeline.md).
- The agent session's conversation-cache reuse, and the short chats' MTP acceptance.
- Needle recall at 32k and 56k prompt tokens, depths 10, 50 and 90, on the first start.

Every load must also pass these gates:
- no failed request in either tool;
- no `#267` line, stall or engine restart in the engine log;
- with pipeline windows, the log line that the pipeline is on;
- 0 MiB outside VRAM on each card the configuration uses (`vram-residency-sampler.py`).

## Configurations

`2026-10-17-strata-community-bench.cells`, in CT 123 holding both cards:

| Cell | Cards | Settings over `strata-qwen38fn.env` | Source |
| --- | --- | --- | --- |
| `one` | GPU 2 (`0000:83:00.0`) | `--spec 5`, `STRATA_MMQ_KQ=1`, `--suffix-draft 0` | The [Strata record](2026-10-16-strata.md#conclusion)'s kept settings, stage 8's `strata-best` |
| `two` | split21: GPU 2 first, then GPU 1 | `--pipeline-windows 2`, `--spec 4 --spec-min-p 0.7`, `STRATA_MMQ_KQ=1`, `--suffix-draft 0` | The pipeline record's soaked `s4p7-pw2` |

Both keep the env file's other settings:
- UD-Q4_K_XL with the MTP draft layer;
- 65,536-token context, INT8 KV with a 32,768-token resident window;
- 15 CPU workers, a 1,024 MiB VRAM reserve, direct PLE reads;
- the RDNA2 switches, and route-tail-skip off.

**Left out:**
- the freeze switches: they turn the prompt cache off, which the suite's agent session measures;
- `--clients`: one slot, and pipeline windows turn off with `--batch` slots;
- thinking: the suite turns it off.

## Method

- **Harness:** the commit that adds this plan, staged with `../push-harness.sh`. It adds:
  - [`strata-community-bench.sh`](../../strata/strata-community-bench.sh): `strata-sweep.sh`'s
    cells, base-env check and restore, with Strata's suite in place of our probes;
  - [`strata-bench-summary.py`](../../strata/strata-bench-summary.py): the per-cell tables
    across loads. `test_strata_cell.py` covers it, and each of three mutations fails a test.
- **Per load:** a cold start, then, inside the container through the server's loopback address:
  - `tools/strata_bench.py --config /var/lib/strata-qwen38fn/config.json --url http://127.0.0.1:1234 --long`.
    The tool runs one warm-up chat and a 1K prompt, which it leaves out. Then it runs three runs
    of each test, with greedy decoding and thinking off.
  - on the first pass, `tools/needle_bench.py --lengths 32k,56k --depths 10,50,90`.

  Both tools come from the installed Strata `296b59d`. Upstream main's `strata_bench.py` differs
  only for a server the tool starts itself.
- **Order:** `one`, `two`, three passes, every load cold.
- **Duration:** about 45 minutes, at about 6 minutes per load and 4 for the needles.
- **Run**, from `/root/harness/<sha12>/pro-v620/qwen38-flash-next/`:

```bash
../strata/use-engine.sh strata-two-card
UNIT=strata-qwen38fn PATTERNS=build-hip/strata ./thermal-guard.sh   # separate shell; VMID unset, so both cards
for pci in 0000:83:00.0 0000:03:00.0; do
  systemd-run --unit="vram-residency-${pci:5:2}" --collect /usr/bin/python3 "$PWD/vram-residency-sampler.py" \
    --pci "$pci" --comm strata --output "/root/qwen38-flash-next/strata-bench-${pci:5:2}-residency.jsonl"
done
CELLS=runs/2026-10-17-strata-community-bench.cells ../strata/strata-community-bench.sh
../strata/use-engine.sh strata
```

- **Raw data:** `/root/qwen38-flash-next/strata-bench-<ts>/` on the host.
- **The reports:** one folder per configuration, in Strata's layout:
  - `README.md` from the template;
  - each load's `results.json` and the needles;
  - the engine's start-up lines;
  - the cells and both scripts.

  Facts the tool cannot read get added by hand:
  - PCIe link, power cap, storage and background load;
  - host RAM: inside CT 123 the tool reads the container's 120 GiB limit;
  - the `STRATA_*` switches: the launcher exports them, and they are not in `config.json`.

  Each report is read for private content before it leaves the lab.

## Safety

- **Other guests:** CT 120 `llamacpp`, CT 121 `hermes`, CT 140 `kb-rag`, CT 200 `bench-runner`,
  CT 201 `llamacpp-builder` and VM 300 `docker-host` have been stopped since the pipeline record.
  They stay stopped and wait for the owner.
- **Two-card switch:** `use-engine.sh strata-two-card` attaches GPU 1 to CT 123, saves and turns
  off CT 120's autostart, and maps both cards to `strata-qwen38fn` in the watchdog.
- **Thermal:** `thermal-guard.sh` watches both cards, and a trip stops the run. No load starts
  while the hottest DIMM is above 58 °C.
- **End state:** `use-engine.sh strata` returns CT 123 to GPU 2 alone, serving the unchanged env
  file.

## Environment

From the run's `environment.json` (`capture-env.sh`, 2026-10-17 19:56 UTC), the same as the
[text record](2026-10-17-strata-text.md#environment)'s:
- Strata v0.1.44.1 (`296b59d`), ggml from llama.cpp `3cf0325`, engine SHA-256 `3a97b4b0…0de2`;
- ROCm 10.0.0-4, HIP runtime 7.15.26333;
- both V620s at the 250 W cap and 0 mV offset, PCIe 16 GT/s x16;
- the four UD-Q4_K_XL shards with verified SHA-256 stamps.

The host's model store, which the reports name, is an NVMe SSD (BIWIN NV7400 2 TB), ext4 on LVM.

---

## Results

Run 2026-10-17 15:56–16:34 ET, harness `ed6680b`, three interleaved passes of `one` and `two`, in
CT 123 holding both cards. Raw data is in `/root/qwen38-flash-next/strata-bench-20261017T195625Z/`,
and its `SUMMARY.md` is `strata-bench-summary.py`'s output. Every number pools the requests of
the three starts: the median, then the lowest and highest request.

| Test | `one` | `two` | `two` / `one` |
| --- | ---: | ---: | ---: |
| Short chat decode, t/s | 43.2 (35.6–52.7) | 64.9 (50.1–97.0) | ×1.50 |
| Short chat TTFT, s | 0.78 (0.67–0.84) | 0.41 (0.38–0.43) | |
| 4K prompt (4,019 tokens), t/s | 848 (843–851) | 858 (852–859) | ×1.01 |
| 16K prompt (16,058), t/s | 1,022 (1,020–1,027) | 1,308 (1,305–1,310) | ×1.28 |
| 32K prompt (32,049), t/s | 1,008 (1,007–1,009) | 1,527 (1,524–1,530) | ×1.52 |
| 32K TTFT, s | 31.9 (31.8–31.9) | 21.0 (21.0–21.1) | |
| Agent follow-up decode, t/s | 46.8 (31.2–62.8) | 62.1 (43.2–73.6) | ×1.33 |
| Agent follow-up TTFT, s | 4.02 (2.68–4.57) | 4.00 (2.34–4.51) | |
| Agent cache hit over follow-ups | 68.6–68.7% | 68.6–68.7% | |
| Short-chat MTP acceptance | 54.9% | 68.6% | |
| Needles found | 6 of 6 | 6 of 6 | |

**Between starts**, the medians of each start:
- short-chat decode: 41.2, 43.3, 46.5 t/s for `one`; 64.1, 65.3, 62.2 for `two`;
- 32K prompt: 1,009, 1,008, 1,007 t/s for `one`; 1,529, 1,527, 1,525 for `two`.

**Agent session:** the conversation cache reused every earlier turn. Each session read 3–75
earlier-turn tokens again, and each follow-up read only its new file, about 1,500 words. The first
turn, with nothing cached, took 2.7 s to the first token on one card and 1.9 s on two.

**Needles:** at 32,778 and 60,995 prompt tokens, depths 10, 50 and 90, all six found in both
configurations. The 60k prompts took 64 s on one card and 38 s on two. Depth 90 took less, because
it shares the depth-50 prompt's first half, which the cache reused.

**Against our own probes,** greedy 256-token replies with prompts up to 23k tokens:
- `one` decoded 49.2 t/s in the [Strata record](2026-10-16-strata.md#stage-8-against-llamacpp)
  and `two` 67.7 in the pipeline record's soak.
- The suite's short chats are 100 tokens and accept fewer drafts: 55% on one card, against 64% in
  our probes.
- The suite's prompt speeds agree with ours: about 1,000 t/s on one card and 1,430 on two at 23k
  in our probes, against 1,008 and 1,527 at 32k here.

**Engine and memory:**
- Expert cache: 7,546 slots (22.02 GiB) on one card, with 930 MiB of VRAM free after load. On two
  cards, 8,139 + 7,657 slots, with 1,008 and 822 MiB free.
- The RAM arena held all the experts: 71.73 GiB, page-locked.
- Decode expert-cache hit rate, from the engine's per-request lines: median 90.3% (57.4–98.1) on
  one card, 98.3% (88.6–99.6) on two.
- Loads took 25–26 s on one card and 36 s on two. The suite took 278–281 s and 217–218 s per
  start.

**Checks:**
- Each load's engine log has one start line and no stall, `#267` line, non-finite line or
  fallback to the serial loop.
- The three `two` loads show the pipeline on. That makes 126 pipeline-windows requests across 3
  starts, with no hang.
- Neither tool reported a failed or skipped request.
- Memory: the samplers saw no gap between requested and resident VRAM in 2,198 samples per card.
  Another 9 per card had only one counter and are left out.
- Thermal: no trip. GPU and DIMM temperatures were not sampled by this runner.

**End state** (16:35 ET):
- `use-engine.sh strata` returned CT 123 to GPU 2 alone, serving the unchanged env file;
- the watchdog map is restored;
- CT 120 is stopped, with `onboot=1` again;
- the guard and samplers are stopped, and the other guests stay stopped for the owner.

## Deviations

- **Needle lengths:** the needles ran at 32k and 60k, not the plan's 32k and 56k. The runner's
  default stayed at `32k,60k`. The 60k prompts, 60,995 tokens, fit the 65,536-token context, and
  all were found.

## Conclusion

Measured with Strata's own suite on the configurations our records found best, on Strata v0.1.44.1
(`296b59d`), UD-Q4_K_XL, 65,536-token context, one slot, greedy, thinking off:
- **One V620:** 43.2 t/s short-chat decode, about 1,000 t/s prompt from 16K to 32K tokens.
- **Two V620s** in a layer split with `--pipeline-windows 2` and `--spec 4 --spec-min-p 0.7`:
  - decode ×1.50 on short chats, ×1.33 in the agent session;
  - prompt ×1.28 at 16K and ×1.52 at 32K tokens, and unchanged at 4K.
- Both recalled 6 of 6 needles up to 61k tokens, with the conversation cache reusing every earlier
  agent turn.

The data supports two reports in the format of Strata's `docs/COMMUNITY_BENCHMARKS.md`, one per
configuration. Drafts, with each start's `results.json`, the needles, an engine-log excerpt and
rows for Strata's `bench/results/COMMUNITY.md`, are on the host in
`/root/qwen38-flash-next/strata-bench-20261017T195625Z/upstream-reports/`. They were checked for
private content, and the tool's redaction holds: the host name shows only as `<host>`. Whether to
submit them, and from which account, is the owner's decision.
