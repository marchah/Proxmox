# Test records

Each test campaign gets one record: a plan committed before the run, with the results
appended after it. Records live with the model they test, in
`<model dir>/runs/YYYY-MM-DD-<topic>.md`; records about the cards themselves are in
`pro-v620/runs/`. The model's README lists them and keeps the
current configuration; a record never changes what is deployed by itself.

## Rules

- **Commit the plan before the run.** Edit it freely until the run starts. After
  that, anything done differently goes under Deviations.
- **Fix "What answers it" in the plan**: the measurement and threshold that answer
  the question. The Conclusion reports the data against it. Whether to deploy is
  decided separately.
- **Run pinned code.** Stage `pro-v620/` on the host with
  [`push-harness.sh`](push-harness.sh), which writes `/root/harness/<sha12>/` and a
  `HARNESS_COMMIT` file; `placement-sweep.sh` refuses to run without it. `make bench`
  stops on uncommitted benchmark code. Scratch runs (`UNPINNED=true`,
  `ALLOW_DIRTY=true`) are not cited by records.
- **Paste the environment.** [`capture-env.sh`](capture-env.sh) records the llama.cpp
  build and binary checksum, the backend (Mesa or ROCm), kernel and firmware, each
  card's identity (`unique_id`), VBIOS, voltage offset, power cap and PCIe link, DIMMs,
  governor, the guest's env file, the server's command line and the model files.
  `placement-sweep.sh` saves it as `environment.json` and records each cell's command
  line beside it. `make bench` puts it in every run's `versions.json`, captured once
  before the batch reloads the model per item, so its env file and command line show the
  server as the batch found it; the slot layout a run used is in that run's own records
  (`/props` for the agent and ingestion workloads, `build_info.parallel` for the
  regression items). For a hand-run test, run `./capture-env.sh <vmid>` on the host
  first.
- **Start from the standard configurations**: two GPUs, one GPU, CPU only (the whole
  model in system RAM, no GPU), and an optimized configuration that leaves resources free,
  such as VRAM for a second model. Include each one that makes sense for the question,
  adapt it where the test needs to, and say in the plan why any is left out.
- **Run with every other guest shut down.** Before the run, shut down every guest the
  test does not use (`make bench` uses the GPU container and CT 200; a sweep uses only
  the GPU container) and list them in the record's Safety section. When the run ends,
  ask the owner before starting them again; never restart them automatically.
- **A record is frozen once its results are in.** A later run that changes the
  conclusion updates the README and gets its own record. A record whose data turns out
  invalid, for example a spill found afterwards, is deleted and the README stops
  citing it.
- **Link the method rules rather than copying them.** Interleaving, at least three
  reps, controls, the spill and output-sanity checks and the DIMM cap are in the
  harness and the component READMEs.
- **Raw data stays on the host** or in the gitignored `pro-v620/results/`. The record
  carries the summary tables and the path to the raw data.

## Template

```markdown
# <Model>: <question in a few words>

Plan committed YYYY-MM-DD · Run YYYY-MM-DD · Status: planned | running | done

## Question

## What answers it

## Configurations

<two GPUs · one GPU · CPU only · optimized (leaves resources free, e.g. VRAM for a second
model). Keep the ones that make sense for the question, adapt them as needed, and give
the reason for each one left out.>

## Controls

## Method

<harness commit or staging path; exact commands with their environment variables;
reps, depths, prompt classes; expected duration; where the raw data lands>

## Safety

<guests shut down for the run, and that they wait for the owner to restart them>

## Environment

<intended stack at plan time; replaced by environment.json when the run starts>

---

## Results

## Deviations

## Conclusion
```
