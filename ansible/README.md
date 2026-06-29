# Ansible: one-command benchmark batch

Drives the LLM-runtime benchmark batch on the Proxmox host from this machine.
CT 120 runs llama.cpp (`llama-server`); the playbook selects the reload command,
results label, and telemetry patterns for it. It:

1. pushes the local `bench-runner/` suite to the host (latest, incl. uncommitted),
2. provisions CT 200 if it is missing (idempotent),
3. injects `HF_TOKEN` into the container's `/etc/bench-runner.env`,
4. (re)loads the model at the chosen `--parallel`,
5. runs the batch (baseline, concurrency sweep, input-length sweep, soak),
6. fetches the new result folders into `pro-v620/results/llamacpp/parallel-<n>/`.

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
make bench           # full batch, --parallel 4 (the operational default)
make bench PARALLEL=1 # single-slot run
make context-sweep   # context-length sweep on top of the batch
```

The raw equivalents (the repo-root `ansible.cfg` sets the default inventory, so `-i` is
optional):

```bash
ansible-playbook ansible/benchmark.yml -e @ansible/secrets.yml

# parallel=1 (single slot; results land in .../parallel-1/). Default is 4.
ansible-playbook ansible/benchmark.yml -e @ansible/secrets.yml -e parallel=1
```

Useful extra vars: `parallel`, `reload_model=false` (skip the model reload),
`runtime_label=<name>` (force a separate results folder), or override the
`benchmarks` list.

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

The sweep leaves the model at its last context, so the playbook reloads it back to the
configured context/`--parallel` afterward (unless `reload_model=false`).

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
