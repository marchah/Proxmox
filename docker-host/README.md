# docker-host — the app-stack host (VM 300)

A Debian VM running **Docker + Compose + Portainer CE**. It hosts the homelab's small,
self-contained web apps as Compose stacks — currently MealDeal, and whatever comes next — so a
new project costs a compose file instead of a bespoke provisioning script.

Apps here no longer consume a VMID each: they are containers inside this one VM.

## Why this is a VM, and the only VM

Everything else in this repo is a native LXC, and that is right for the GPU/LLM containers —
they need host device passthrough and gain nothing from Docker. This is the deliberate exception.

Proxmox recommends running Docker in a VM. Docker-in-LXC needs `nesting=1` + `keyctl=1` (and is
frequently run privileged), which weakens namespace isolation, puts Docker's `overlay2` on top of
a container filesystem — the classic breakage — tends to need its nesting/AppArmor tweaks redone
after a Proxmox kernel bump, and shares a kernel with this host's hand-rolled nftables NAT
(`host-net/wifi-nat`) that Docker also writes firewall rules into. A VM walls all of that off for
about 4 GB of RAM, which this host has spare.

**VMID 300:** this repo's `100-119`/`120-139`/… ranges allocate *containers*. VMs get their own
`300+` range so the two numbering schemes never collide.

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

1. Open **`https://192.168.1.93:9443`** and create the Portainer admin user. It's a self-signed
   cert, so expect a browser warning.
   ⚠️ Portainer only leaves initial setup open for a short window, then locks itself. If you see
   "instance timed out", restart it to reopen:
   ```bash
   ssh pve 'ssh -i /root/.ssh/docker-host debian@10.10.10.100 -- docker restart portainer'
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

Then expose it on the LAN by adding a port-forward to `host-net/wifi-nat/wifi-nat.env` and
running `install.sh --reload-nft`.

## Operating it

```bash
# SSH in (the host holds the key)
ssh pve 'ssh -i /root/.ssh/docker-host debian@10.10.10.100'

# From the guest
docker ps
docker compose -f /opt/stacks/<project>/compose.yaml logs -f
docker compose -f /opt/stacks/<project>/compose.yaml up -d --build   # rebuild + restart
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
**`http://192.168.1.93:4000`** (SPA + GraphQL at `/graphql`).

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

### Image source — build now, pull later

The stack currently **builds from mealdeal's git repo** (BuildKit takes a git URL as build
context) because that repo publishes no image yet — its GitHub Actions are billing-locked. Every
redeploy therefore rebuilds, a few minutes each.

Once [marchah/mealdeal#36](https://github.com/marchah/mealdeal/pull/36) is merged and billing is
unlocked, switch to pulling — a two-line edit in the compose file:

1. delete the `build:` block
2. change `pull_policy: build` → `pull_policy: always`

Updates then take ~10 s, and rollback is pinning a previous immutable tag
(`image: ghcr.io/marchah/mealdeal:sha-abc1234`). Note the GHCR package is created **private** by
default — flip it to public after the first publish, or give Portainer a `read:packages` token.

## What you give up versus the old per-app LXC

The retired `mealdeal/create-lxc-mealdeal.sh` health-checked each new release and
**automatically restored the previous one** on failure. Portainer has no health-gated rollback: a
broken deploy leaves a broken stack until you act. With published image tags that's a ~10 s fix
(redeploy pinning the previous `sha-` tag); while still building from git it means changing the
ref. That was a conscious trade for not maintaining one bespoke script per app.

The compose file does define a healthcheck (a GraphQL `{__typename}` probe, since the app has no
`/health` route), so a wedged container is at least *visible* as unhealthy in `docker ps` and in
the Portainer UI — it just won't self-heal.

## Backups

Two things matter, and neither is the VM's OS disk (rebuildable by re-running the script):

- **`portainer_data`** — stack definitions, users, settings.
- **Each app's data volume** — e.g. `mealdeal_mealdeal-data` holds the deal database.

```bash
# List what exists
ssh pve 'ssh -i /root/.ssh/docker-host debian@10.10.10.100 -- docker volume ls'

# Copy a volume out to the Proxmox host
ssh pve 'ssh -i /root/.ssh/docker-host debian@10.10.10.100 -- \
  docker run --rm -v mealdeal_mealdeal-data:/d alpine tar -cz -C /d .' > mealdeal-data.tgz
```

The weekly `vzdump` job (Sundays 01:00, all guests, keep-last=3 → `Synology-Backup`) covers this
VM's disk, which is enough to rebuild it — but a VM-disk backup captures the Docker volumes only
as part of that disk image. For a restore that doesn't involve rolling the whole VM back, keep
the volume tarballs above.

See the "Backups" note in the repo root `CLAUDE.md` for the `tmpdir` requirement on this host —
`vzdump` cannot write its temp files to the NFS target for unprivileged containers.
