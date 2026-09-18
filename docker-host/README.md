# docker-host — the app-stack host (VM 300)

A Debian VM running **Docker + Compose + Portainer CE**. It hosts the homelab's small,
self-contained web apps as Compose stacks — currently MealDeal and work-board — so a
new project costs a compose file instead of a bespoke provisioning script. A stack's
compose file usually lives in `stacks/` here; work-board's lives in its own repo, and
[work-board specifics](#work-board-specifics) covers its setup.

Apps share this VM and do not consume individual VMIDs.

Docker has its own kernel and firewall inside VM 300. GPU model servers use
native LXCs with device passthrough. VMs use the repo's `300+` VMID range.

## Provision (on the Proxmox host, as root)

```bash
./docker-host/create-vm-docker-host.sh
```

Downloads a pinned, SHA-512-verified Debian cloud image, creates VM 300 with cloud-init (a
dedicated SSH key is generated at `/root/.ssh/docker-host`), then installs the qemu guest agent,
Docker from Docker's own apt repo, the Compose plugin, and Portainer CE — and **health-polls
Portainer's `/api/status`** before reporting success.

```bash
./docker-host/create-vm-docker-host.sh --reinstall-docker   # re-run ONLY the in-guest install
MEMORY_MB=8192 CORES=6 DISK_SIZE=80G ./docker-host/create-vm-docker-host.sh
PORTAINER_IMAGE=portainer/portainer-ce:2.39.5 ./docker-host/create-vm-docker-host.sh
```

## First-time setup

1. Open **`https://192.168.1.250:9443`** and create the Portainer admin user. It's a self-signed
   cert, so expect a browser warning.
   ⚠️ Portainer only leaves initial setup open for a short window, then locks itself. If you see
   "instance timed out", restart it to reopen:
   ```bash
   ssh pve 'ssh -i /root/.ssh/docker-host debian@docker-host -- docker restart portainer'
   ```
2. That's it — the local Docker environment is already connected via the socket.

## Adding a project

Commit a compose file under `docker-host/stacks/<project>/compose.yaml` in this repo, then in
Portainer: **Stacks → Add stack → Repository**

| Field | Value |
| --- | --- |
| Repository URL | `https://github.com/marchah/Proxmox` |
| Reference | `refs/heads/main` |
| Compose path | `docker-host/stacks/<project>/compose.yaml` |

Add any secrets as **stack environment variables** in that form — never in the compose file,
since this repo is public. Optionally enable **automatic updates** (poll on an interval, or a
webhook): Portainer compares the repo's latest commit hash against what it deployed and
redeploys on change.

It is reachable on the LAN immediately — the VM has its own LAN address.

## Operating it

```bash
# SSH in (the host holds the key)
ssh pve 'ssh -i /root/.ssh/docker-host debian@docker-host'

# From the guest
docker ps
docker compose -f /opt/stacks/<project>/compose.yaml logs -f
docker compose -f /opt/stacks/<project>/compose.yaml up -d   # pull + restart per pull_policy
```

Day-to-day, prefer the Portainer UI: it does logs, console, env-var edits, redeploys, and volume
inspection without SSH.

Upgrading Portainer itself is a pull + recreate; users, stacks, and settings live in the
`portainer_data` volume:

```bash
docker pull portainer/portainer-ce:<newer> && docker rm -f portainer && \
  docker run -d --name portainer --restart=always -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data \
  portainer/portainer-ce:<newer>
```

(Or just bump `PORTAINER_IMAGE` and re-run `--reinstall-docker`, which does exactly this.)

## MealDeal specifics

Stack: [`stacks/mealdeal/compose.yaml`](stacks/mealdeal/compose.yaml). Live at
**`http://192.168.1.250:4000`** (SPA + GraphQL at `/graphql`).

Extraction uses CT 120 at `http://llamacpp:1234/v1`, model `qwen3.6-35b-a3b`.

**Ingest is off until you add mailbox credentials.** Blank `IMAP_USER`/`IMAP_PASSWORD` make the
app disable ingest entirely rather than crash, so the stack comes up clean. To enable it, set
these as Portainer stack env vars and redeploy:

```
IMAP_USER=<the mailbox address>
IMAP_PASSWORD=<Gmail APP password, not the account password>
INGEST_INLINE=1
INGEST_TOKEN=<any random string; guards the manual trigger>
```

Trigger one pass on demand:
```bash
docker exec mealdeal sh -c 'wget -qO- --post-data="" \
  --header="x-ingest-token: $INGEST_TOKEN" http://127.0.0.1:4000/internal/ingest'
```

### Image source — pulls a published image

The stack pulls `ghcr.io/marchah/mealdeal`, published by the app's `Publish image` workflow. The package is **public**, so anonymous pull works and Portainer needs no registry
credentials. Nothing is built on this host — a redeploy is a ~10 s pull.

| Tag | Use |
| --- | --- |
| `ghcr.io/marchah/mealdeal:main` | what the stack tracks; follows the app's default branch |
| `ghcr.io/marchah/mealdeal:sha-<short>` | immutable per-commit — **pin this to roll back** |
| semver tags | from `v*` releases |

`pull_policy: always` matters: without it a redeploy can reuse a stale local layer cache instead
of fetching the new `main`.

**To roll back**, edit the compose `image:` to a known-good `sha-` tag and redeploy:

```yaml
image: ghcr.io/marchah/mealdeal:sha-b63ad81
```

## work-board specifics

Stack: **not in this repo.** It lives with the app at
[`deploy/compose.yaml`](https://github.com/marchah/work-board) in the private
`marchah/work-board` repo, because that file and the app's `config.toml` must agree with each
other and splitting them across repos made one change a two-repo change. Portainer reads it as
a git stack from there.

Live at **`http://192.168.1.250:4100`** — a Linear + GitHub board answering "what should I work
on next?". Holds no state: the snapshot is in memory and rebuilt on the next tick, so there is
no volume to back up.

⚠️ Being a private repo, it needs Portainer credentials **twice** — git, to read the compose,
and registry, to pull the image — where MealDeal needs neither. Details live in that repo's
README; the general lesson for this one is to **check a stack's repo and package visibility
before assuming anonymous access**, rather than generalising from MealDeal.

## Health and rollback

The MealDeal healthcheck queries GraphQL `{__typename}`. An unhealthy deployment
is visible in Docker and Portainer; rollback requires selecting a known-good
image tag and redeploying.

## Backups

Two things matter, and neither is the VM's OS disk (rebuildable by re-running the script):

- **`portainer_data`** — stack definitions, users, settings.
- **Each app's data volume** — e.g. `mealdeal_mealdeal-data` holds the deal database.

```bash
# List what exists
ssh pve 'ssh -i /root/.ssh/docker-host debian@docker-host -- docker volume ls'

# Copy a volume out to the Proxmox host
ssh pve 'ssh -i /root/.ssh/docker-host debian@docker-host -- \
  docker run --rm -v mealdeal_mealdeal-data:/d alpine tar -cz -C /d .' > mealdeal-data.tgz
```

The weekly `vzdump` job (Sundays 01:00, all guests, keep-last=3 → `Synology-Backup`) covers this
VM's disk, which is enough to rebuild it — but a VM-disk backup captures the Docker volumes only
as part of that disk image. For a restore that doesn't involve rolling the whole VM back, keep
the volume tarballs above.

See the "Backups" note in the repo root `CLAUDE.md` for the `tmpdir` requirement on this host —
`vzdump` cannot write its temp files to the NFS target for unprivileged containers.
