# Ansible: one-command benchmark batch

Drives the LLM-runtime benchmark batch on the Proxmox host from this machine.
`gpu` picks the V620 to benchmark through the container that serves it: GPU 1 is
CT 120 (Qwen3.6-35B-A3B, the default), GPU 2 is CT 123 (Qwen3.8-Flash-Next). Both run
llama.cpp; the `gpus` map in `benchmark.yml` holds each one's model, context, slot
counts, reload helper and results folder. It:

1. pushes the local `bench-runner/` suite to the host (latest, incl. uncommitted),
2. provisions CT 200 if it is missing (idempotent),
3. injects `HF_TOKEN` into the container's `/etc/bench-runner.env`,
4. checks the GPU container is serving its model and has its reload helper, then
   (re)loads the model at the chosen `--parallel`,
5. runs the batch: the regression items (baseline, concurrency sweep, input-length
   sweep, soak), then the agent-session and document-ingestion workloads at CT 120's
   operational slot layout (`bench-runner/BENCHMARKS.md`),
6. fetches the new result folders into `pro-v620/results/llamacpp/parallel-<n>/`
   (GPU 2: `llamacpp-gpu2/`).

The containers have no SSH of their own, so the playbook connects to the Proxmox
host over SSH and acts on the LXCs via `pct`. This is the "light" version — it
orchestrates the existing bash scripts rather than reimplementing them.

## Setup (once)

- Install Ansible on this machine: `pipx install ansible` (or `brew install ansible`).
- SSH-key access to the Proxmox host as `root`.
- Point Ansible at your host **without committing it** — the inventory reads the
  connection details from the environment. Either:
  - export the connection vars (these override everything):
    `export PVE_HOST=<proxmox-ip>` (and `PVE_USER=...` if not `root`); or
  - add a `Host pve` block to `~/.ssh/config` (with `HostName`/`User`/`IdentityFile`)
    and set nothing — the inventory falls back to the `pve` SSH alias.
- `cp secrets.yml.example secrets.yml` and put your real `hf_token` in it
  (`secrets.yml` is gitignored).

## Run

The repo-root `Makefile` wraps the common invocations (run from the repo root):

```bash
make help            # list targets
make ping            # test SSH connectivity to the Proxmox host
make check           # syntax-check the playbook
make smoke           # plumbing test (push + reload, no benchmarks)
make bench           # full batch on GPU 1, --parallel 4 (benchmark default; CT 120 ships --parallel 2)
make bench GPU=2     # the same on GPU 2 (CT 123, one 64k slot); runs for hours
make bench SUITE=short  # regression items only: no agent sessions or document ingestion
make bench INGEST=false # skip document ingestion (AGENT=false skips the agent sessions)
make bench PARALLEL=1 # single-slot run
make context-sweep   # context-length sweep on top of the batch (takes the same flags)
```

The raw equivalents (the repo-root `ansible.cfg` sets the default inventory, so `-i` is
optional):

```bash
ansible-playbook ansible/benchmark.yml -e @ansible/secrets.yml

# parallel=1 (single slot; results land in .../parallel-1/). Default is 4 on GPU 1; add -e gpu=2 for CT 123.
ansible-playbook ansible/benchmark.yml -e @ansible/secrets.yml -e parallel=1
```

Useful extra vars: `gpu` (`1` or `2`), `parallel` (benchmark concurrency, default 4 on
GPU 1 and 1 on GPU 2), `restore_parallel` (what the server is reloaded to when the run
finishes: 2 on CT 120 and 1 on CT 123, the operational `--parallel`; decoupled from
`parallel` so a benchmark never leaves prod downgraded; the workloads item also runs at
it), `agent_depth` (where agent sessions stop; 56000 on GPU 2), `suite` (`full` or `short`), `run_agent_sessions` and
`run_doc_ingest` (drop one workload), `reload_model=false` (skip the model reload),
`runtime_label=<name>` (force a separate results folder), or override the `benchmarks`
list. An item is a command string, or `{cmd, parallel}` to reload CT 120 at its own slot
count first. The workloads' results land in the same `parallel-<n>/` folder as the rest
of the batch; their summaries record the slot layout they ran on.

### Optional: context-length sweep

Host-orchestrated — reloads the model at each context length and benches it through
the host-telemetry sidecar. Results land in `pro-v620/results/llamacpp/context-sweep/`.

```bash
# add the sweep on top of the standard batch:
ansible-playbook -i ansible/inventory.ini ansible/benchmark.yml -e @ansible/secrets.yml \
  -e context_sweep=true -e context_sweep_contexts="4096 16384 32768 65536"

# or run ONLY the context sweep (skip the standard batch):
ansible-playbook -i ansible/inventory.ini ansible/benchmark.yml -e @ansible/secrets.yml \
  -e context_sweep=true -e '{"benchmarks": []}'
```

The sweep walks the model through small per-context reloads, so `run-context-sweep.sh`
restores CT 120 to the configured context/`--parallel` via an EXIT trap when it finishes —
even if it errors or is interrupted. A failed sweep no longer aborts the play (results are
still fetched); the failure is reported at the end.

## Notes

- It pushes your **local** checkout — commit/push to the branch when the results
  look good (not before each run).
- Results land in the gitignored `pro-v620/results/llamacpp/parallel-<n>/`; raw
  run data is not committed.
- Provisioning is skipped if CT 200 already exists; the model reload and the batch
  run every invocation.
- The batch auto-retargets CT 120's current IP before running, so a recreated or
  renumbered model container (e.g. after recreating CT 120 or a model swap that
  picks up a new DHCP lease) is benchmarked correctly without hand-editing
  `local-model.env`.
