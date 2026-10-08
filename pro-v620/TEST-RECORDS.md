# Test records

Each test campaign gets one record: a plan committed before the run, with the results
appended after it. Records live with the model they test, in
`<model dir>/runs/YYYY-MM-DD-<topic>.md`. The model's README lists them and keeps the
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
  card's VBIOS, voltage offset, power cap and PCIe link, DIMMs, governor, the guest's
  env file, the server's command line and the model files. `placement-sweep.sh` saves
  it as `environment.json` and records each cell's command line beside it. `make bench`
  puts it in every run's `versions.json`, captured once before the batch reloads the
  model per item, so its env file and command line show the server as the batch found
  it; the slot layout a run used is in that run's own records (`/props` for the agent
  and ingestion workloads, `build_info.parallel` for the regression items). For a
  hand-run test, run `./capture-env.sh <vmid>` on the host first.
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

## Controls

## Method

<harness commit or staging path; exact commands with their environment variables;
reps, depths, prompt classes; expected duration; where the raw data lands>

## Safety

## Environment

<intended stack at plan time; replaced by environment.json when the run starts>

---

## Results

## Deviations

## Conclusion
```
