# Repository guidance

This repo provisions and operates a Proxmox AI homelab. macOS is the authoring
machine; provisioning and host-service scripts run on the Proxmox host as root.
Use component READMEs for deployment commands, defaults, and measurements.

## Where to look

- [README.md](README.md): guest inventory and VMID allocation.
- [pro-v620/](pro-v620/README.md): CT 120, GPU passthrough and Qwen3.6 serving.
- [qwen38-flash-next/](pro-v620/qwen38-flash-next/README.md): CT 123 and the optional
  two-card CT 120 configuration, placement measurements and cutover procedure.
- [hermes/](hermes/README.md): CT 121 agent gateway.
- [kb-rag/](kb-rag/README.md): CT 140 retrieval API and corpus policy.
- [bench-runner/](bench-runner/README.md) and [ansible/](ansible/README.md): endpoint
  benchmarks, telemetry and reports.
- [docker-host/](docker-host/README.md): VM 300, Compose stacks and Portainer.
- [host-notifications/](host-notifications/README.md): Proxmox notifications to Slack.

The retired Hermes coding loop remains under [hermes/config/](hermes/config/README.md)
and [coder-runner/](coder-runner/README.md). CT 122 was removed; those helpers require
recreating the runner and its SSH key. Execute project builds/tests in a disposable
runner, separate from the agent container holding credentials.

## Editing conventions

- Keep GPU/model/engine provisioning explicit in its own script. Follow the existing
  config block → helpers → ordered `main()` pipeline, with quoted heredocs for scripts
  sent through `pct exec ... bash -s`.
- Update release tags and checksums together. Change repository pins when updating
  a live installation so a rebuild reproduces it.
- Keep model weights, generated results, caches and secrets out of git. Push secrets
  as mode-600 files and remove temporary copies. Private channel IDs belong in env
  files, with examples committed separately.
- Keep docs about current behavior. Replace incorrect statements in place; delete
  superseded instructions and duplicate explanations. Git history holds the change
  narrative. Label measurements with the build, hardware and settings used.
- Host services use an idempotent `install.sh`, systemd unit and `.env` file.
  `hermes/config/` and `hermes/token-usage-collector/` installers run inside CT 121.
- Put comments on their own lines in systemd `EnvironmentFile` files; inline
  comments become part of the value.

### Standalone installs

Provisioners support both a local checkout and individual downloads from GitHub raw.
When adding or renaming shipped files, update the matching download list:

- `bench-runner/create-lxc-bench-runner.sh`: `files=(...)` in `download_benchmark_suite`.
- `kb-rag/create-lxc-kb-rag.sh`: `APP_FILES=(...)`.

### Validation

Use `bash -n` and `shellcheck` for changed shell scripts, including extensionless
launchers. Parse/compile changed Python files. `make check` syntax-checks the Ansible
playbook; `make bench` and `make context-sweep` operate the remote lab and are not
local tests. There is no CI or general automated test suite.

## GPU operating constraints

The ROMED8-2T has two V620s on CPU-direct Gen4 x16 slots:

| PCI address | Workload | Blower |
| --- | --- | --- |
| `0000:03:00.0` | CT 120 `llamacpp` | FAN5 |
| `0000:83:00.0` | CT 123 `llamacpp-qwen38fn` | FAN4 |

- Pin passthrough by `/dev/dri/by-path/pci-<address>-render`, resolving the real
  destination node name. `cardN` numbering can change after hardware/kernel changes;
  follow the recovery procedure in `pro-v620/README.md`.
- Verify RADV sees the expected number of devices and the intended card holds the
  model. The startup guard catches CPU fallback, but not GTT spill. Read free VRAM
  and GTT together after a real request.
- CT 120 and CT 123 must never own the same card. Use `ct120-cutover.sh` for the
  two-card alternative: it changes passthrough, CT 123's `onboot` and the watchdog
  service map together.
- Both servers use `--reasoning off --reasoning-format auto`. The first disables
  thinking; the second removes empty think tags from response content. Revalidate
  response content and tool calls when changing these flags or the KV cache type.
- [gpu-blower-control/](pro-v620/gpu-blower-control/README.md) drives FAN4/FAN5 via
  IPMI; [undervolt/](pro-v620/undervolt/README.md) applies −100 mV to both cards.
  Confirm physical fan pairing after rewiring. The BMC manages CPU/DIMM cooling.
- [gpu-thermal-watchdog/](pro-v620/gpu-thermal-watchdog/README.md) stops the mapped
  service at 102 °C junction / 101 °C memory and leaves it stopped. A trip warrants
  checking cooling before restarting. Keep its map aligned with the owning units.
- The watchdog cannot stop a manually launched benchmark. Use an independent
  thermal guard. The B550 harness in `gpu-ab-bench/` and `fan-control/` target the
  retired board; use the ROMED8-2T guard in `qwen38-flash-next/` for current sweeps.

## Benchmark conventions

- Interleave configurations with at least three repetitions. Match model hashes,
  binary, prompt set, context depth and power settings. Check output correctness as
  well as speed; include a non-speculative control when testing a drafter.
- Quote decode with prompt class and depth, and report prefill separately.
- CT 200 CPU/RAM/process telemetry describes the client. Use
  `bench-runner/host/run-with-target-telemetry.sh` for model-server metrics; after
  merging telemetry, regenerate reports with `finalize-run.py`.
- The in-container suite layers local model config, profile defaults and process
  env overrides, checks `/v1/models`, runs enabled targets, then writes JSON/JSONL
  results and `REPORT.md`/`SLO.md`. See `bench-runner/BENCHMARKS.md` for schemas.
- Wrappers in `/usr/local/bin` need a login shell through `pct exec`:
  `pct exec 200 -- bash -lc 'llm-bench-baseline'`.

## Host networking and backups

Guests use DHCP on `vmbr0`, with LAN hostnames under `lan`. Reserve guest leases on
the router; prefer hostnames to copied IP addresses. The host address is
`192.168.1.93`.

The weekly backup job runs Sundays at 01:00 to `Synology-Backup` NFS, keeps three
copies and covers all guests. `/models` mount points use `backup=0`; root disks
remain included. To omit rebuildable bulk on a root disk, use the backup job's
`--exclude-path` setting, e.g. `/opt/kb-rag` for CT 140.

- `/etc/vzdump.conf` needs `tmpdir: /var/tmp`: the NAS rejects the mapped UID used
  for unprivileged LXC temporary files. Archives still stream to NFS.
- Allow-list the NAS's NFS clients by subnet (`192.168.1.0/24`), not by the host's
  exact IP: an exact-IP entry breaks every backup silently with `mount.nfs: access
  denied by server` the next time the host address changes. Set it in DSM under
  Control Panel → Shared Folder → NFS Permissions.
- Back up Docker volumes for restores that do not roll back the whole VM.
- The token ledger under `/root/.hermes/token-usage/` is excluded from the git
  config backup; its off-box copy is CT 121's weekly vzdump. It cannot be rebuilt.
- Use a bind mount when exposing another NAS share to a container.
