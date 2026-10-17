# Qwen3.8-Flash-Next: Strata's benchmark suite on one and two V620s, for Strata's community reports

Plan committed 2026-10-17 · Run — · Status: planned

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

As in the [text record](2026-10-17-strata-text.md#environment). This run's `environment.json`
replaces this section.

---

## Results

## Deviations

## Conclusion
