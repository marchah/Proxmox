# docker-host — the app-stack host (VM 300)

A Debian VM running **Docker + Compose + Portainer CE**. It hosts the homelab's small,
self-contained web apps as Compose stacks — currently MealDeal, work-board and Project
Planner — so a new project costs a compose file instead of a bespoke provisioning script. A
stack's compose file usually lives in `stacks/` here; work-board's and Project Planner's live
in their own repos ([work-board specifics](#work-board-specifics),
[Project Planner specifics](#project-planner-specifics)).

Apps share this VM and do not consume individual VMIDs.

**Why a VM, and the only one here.** Proxmox recommends running Docker in a VM, and
that is what this is: its own kernel and its own firewall rules, isolated from the
host's. Docker-in-LXC instead needs `nesting=1` + `keyctl=1` (often privileged), puts
`overlay2` on top of a container filesystem, tends to need those tweaks redone after a
Proxmox kernel bump, and shares a kernel with the host's firewall rules that Docker
also writes into. The cost is about 4 GB of RAM, which this host has spare. The GPU
model servers stay native LXCs — they need device passthrough and gain nothing here.
VMs use the repo's `300+` VMID range so container and VM ids never collide.

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
on next?". The board itself holds no state: the snapshot is in memory and rebuilt on the next
tick, so a restart costs one collection cycle. Its **three-day plan is the exception** and lives
in the `work-board-plan` volume — nothing can rebuild it, so see [Backups](#backups).

⚠️ That volume must stay **named**, not a bind mount. The container runs as uid 10001, and
Docker copies an empty named volume's ownership from the image's chowned `/data`; a bind mount
keeps the host's ownership instead, and the first edit then fails with `cannot be written:
Permission denied` on the page.

⚠️ Being a private repo, it needs Portainer credentials **twice** — git, to read the compose,
and registry, to pull the image — where MealDeal needs neither. Details live in that repo's
README; the general lesson for this one is to **check a stack's repo and package visibility
before assuming anonymous access**, rather than generalising from MealDeal.

## Project Planner specifics

Stack: **not in this repo.** It lives with the app at
[`deploy/compose.yaml`](https://github.com/marchah/project-planner/blob/main/deploy/compose.yaml)
in the public `marchah/project-planner` repo. Both the repo and its GHCR package are public, so
Portainer needs no git or registry credentials (MealDeal's case, not work-board's).

Live at **`http://192.168.1.250:4200`** — a sticky-note board for project ideas, which Hermes
researches into plans with clarifying questions. The board uses GraphQL at `/graphql`; Hermes on
CT 121 captures ideas over REST at `/api/ideas` and reads them over MCP at `/mcp/`, reaching the
board as `http://docker-host.lan:4200`. The board in turn starts research runs on Hermes' API.

| Stack env var | Value | Why |
| --- | --- | --- |
| `PUBLIC_URL` | `http://192.168.1.250:4200` | Base of the links the REST API returns (the one Hermes posts to Slack). Without it they use the caller's `Host`, i.e. `docker-host`, which browsers on the LAN do not all resolve |
| `TITLE_MODEL_BASE_URL` | `http://llamacpp.lan:1234/v1` | CT 120's llama.cpp, which writes each new idea's title. Unset, ideas are saved untitled |
| `HERMES_API_URL` | `http://hermes.lan:8642` | CT 121's Hermes API, which runs research. Unset, research is off and the note's button is hidden |
| `HERMES_API_KEY` | *(secret, on the stack only)* | CT 121's `API_SERVER_KEY` from `/root/.hermes/.env`. Rotating it there means updating it here |
| `HERMES_PROVIDER` | `openai-codex` | Research runs on Codex through the ChatGPT subscription (billed `included`). Empty: Hermes' default, CT 120's Qwen |
| `RESEARCH_ON_CAPTURE` | `true` | Every new idea is researched on its own, without pressing the note's button (since 2026-10-07, once the first runs were judged good) |
| `REFRESH_SCHEDULE` | `0 10 * * 0` | Every planned idea not shelved, done or muted is re-checked Sundays 10:00; a slot missed while the board was down is caught up when it starts. Empty: never on a schedule |
| `REFRESH_TIMEZONE` | `America/New_York` | The zone `REFRESH_SCHEDULE` is read in. Empty: UTC |
| `SLACK_BOT_TOKEN` | *(secret, on the stack only)* | CT 121's `SLACK_BOT_TOKEN` from `/root/.hermes/.env`: the board posts each Slack-captured idea's first plan, plan changes and failures in its thread, as the same bot. Rotating it there means updating it here |

The app repo holds no environment-specific values, so these live only here and on the stack. Use
full hostnames (`<host>.lan`) or IPs: the stack has no `dns:` override, and Docker's resolver on
this VM returns `ENOTFOUND` for single-label names such as `llamacpp` on a compose network, while
`llamacpp.lan` and `hermes.lan` resolve.

A settings change takes effect on the next redeploy, not when it is saved: use **Pull and
redeploy** after editing them.

The stack tracks the app repo's **`deploy` branch**, not `main`, and polls it every 5 minutes. The
app's `Publish image` workflow moves `deploy` to a commit only after that commit's image is pushed,
so a redeploy always pulls the new image, and a commit whose image fails to build is never
deployed. Tracking `main` directly raced the ~2-minute publish: a poll in between redeployed the
previous image and never retried, because the commit already counted as deployed. It happened on
the switch-over itself, 2026-10-02. **Stacks → project-planner → Pull and redeploy** is still the
manual override.

## Health and rollback

The MealDeal healthcheck queries GraphQL `{__typename}`. An unhealthy deployment
is visible in Docker and Portainer; rollback requires selecting a known-good
image tag and redeploying.

work-board's `/healthz` answers 200 once its **first collection has completed**, and
deliberately not whether Linear or GitHub succeeded — a board correctly reporting that Linear
is down is a working board, and failing the healthcheck on that would restart-loop the
container through an outage it exists to display. So a healthy container with a red banner on
the page is the intended combination, not a broken healthcheck.

Project Planner's `/healthz` answers 200 once database migrations have run. Roll back by pinning
`ghcr.io/marchah/project-planner:sha-<short>` in its compose file.

## Backups

Two things matter, and neither is the VM's OS disk (rebuildable by re-running the script):

- **`portainer_data`** — stack definitions, users, settings.
- **Each app's data volume** — `mealdeal_mealdeal-data` holds the deal database,
  `work-board_work-board-plan` holds work-board's three-day plan, and
  `project-planner_project-planner-data` holds every captured idea with its plans, questions and
  research history. Tarballs taken before each schema migration so far are in
  `/var/backups/project-planner/` on this VM. Compose prefixes the stack name, so confirm them with the
  `docker volume ls` below. The plan and the ideas are the ones no API can regenerate: MealDeal's
  deals re-scrape, work-board's board rebuilds from Linear and GitHub, but nothing knows which
  tickets you picked for Wednesday or what you wrote down as an idea.

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
