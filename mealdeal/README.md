# mealdeal — grocery-deal tracker (CT 110)

An unprivileged Debian LXC running **[MealDeal](https://github.com/marchah/mealdeal)**: a
self-hosted grocery-deal tracker. One Node process serves the built React SPA, the GraphQL API
at `/graphql`, and — once IMAP is configured — the ingest cron in-process. Deal extraction runs
against **CT 120** (`llamacpp:1234`), so no cloud API key is involved.

It sits in the **100-119 infra/services** range, not the AI range: like Hermes, it only
*consumes* CT 120's API.

## Provision (on the Proxmox host, as root)

```bash
./mealdeal/create-lxc-mealdeal.sh
```

That resolves a Debian 12 template, creates CT 110, installs pinned Node + pnpm, clones the app,
builds the first release, installs the systemd service, and **health-polls** `/graphql` until the
server answers (else it dumps the journal and exits non-zero).

Ingest starts **disabled** — the script prints the two lines to fill in. To arm it at provision
time instead, pass the mailbox credentials (they are written to a mode-600 file and never travel
through `argv`):

```bash
IMAP_USER=deals@gmail.com IMAP_PASSWORD='<app password>' ./mealdeal/create-lxc-mealdeal.sh
```

### Useful overrides

```bash
VMID=110 LXC_HOSTNAME=mealdeal APP_PORT=4000 ./mealdeal/create-lxc-mealdeal.sh
APP_BRANCH=main ./mealdeal/create-lxc-mealdeal.sh              # or a tag/branch to pin
OPENAI_BASE_URL=http://gpu2:8080/v1 ./mealdeal/create-lxc-mealdeal.sh   # extract on CT 123 instead
GEOCODER_BASE_URL=http://my-nominatim:8080 ./mealdeal/create-lxc-mealdeal.sh  # keep addresses internal
USER_LOCATION=02139 ./mealdeal/create-lxc-mealdeal.sh          # near-me features
DATA_SIZE_GB=0 ./mealdeal/create-lxc-mealdeal.sh               # DB on the rootfs, no extra volume
MEMORY_MB=6144 CORES=6 ./mealdeal/create-lxc-mealdeal.sh       # faster builds
NODE_VERSION=v26.5.0 NODE_SHA256=<linux-x64 sha> PNPM_VERSION=11.13.1 ...
```

## Operate

⚠️ Wrap the `mealdeal-*` wrappers in `bash -lc '…'` — they live in `/usr/local/bin`, which a
bare `pct exec` PATH omits (`/sbin:/bin:/usr/sbin:/usr/bin`). Same gotcha as the bench-runner's
`llm-bench-*` commands.

```bash
pct exec 110 -- bash -lc 'mealdeal-status'           # release, commit, health, ingest, DB size
pct exec 110 -- bash -lc 'mealdeal-update'           # deploy latest main (see "Updating" below)
pct exec 110 -- bash -lc 'mealdeal-update --check'   # report only; exit 10 if an update is available
pct exec 110 -- bash -lc 'mealdeal-rollback'         # activate the previous release, no rebuild
pct exec 110 -- bash -lc 'mealdeal-ingest'           # run one ingest pass now, print the counts
pct exec 110 -- systemctl status mealdeal
pct exec 110 -- journalctl -u mealdeal -n 100 --no-pager
```

Reach the app from the LAN at **`http://192.168.1.93:4000`** (the host's WiFi IP + the `:4000`
DNAT forward), or as `http://mealdeal:4000` from another container.

## Updating

`mealdeal-update` is the whole update story, and it is **safe by construction**: the running
service is never replaced by an unverified build.

1. `git fetch`; if the tracked branch's commit already matches the live release, it exits 0.
2. Builds into a staging dir, replaying mealdeal's own Dockerfile pipeline in order
   (`install` → `build-schema` → `gen` → web `build` → api `build` → `deploy --prod`).
   **A build failure here never touches the running service.**
3. Renames the staging dir to `releases/<sha>`, flips `current`, restarts.
4. Health-checks `/graphql`. If the new release does not answer, it **restores the previous
   release** and restarts again, then reports failure loudly.
5. Prunes old releases beyond `KEEP_RELEASES` (default 3), never the live one.

```bash
pct exec 110 -- bash -lc 'mealdeal-update --force'      # rebuild the same commit (e.g. after an env change)
pct exec 110 -- bash -lc 'mealdeal-update --ref v0.2.0' # deploy a specific tag/branch/sha
pct exec 110 -- bash -lc 'mealdeal-rollback <sha>'      # jump to any retained release
```

### Making it automatic

Updates are deliberately **manual** — the app is under active development by the autonomous
coding loop, so unattended deploys of every merge to `main` are not wanted yet. When they are,
this is the whole change (no script edit needed):

```bash
pct exec 110 -- bash -c 'cat >/etc/systemd/system/mealdeal-update.service <<EOF
[Unit]
Description=MealDeal update (build latest main, health-check, roll back on failure)
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/mealdeal-update
EOF
cat >/etc/systemd/system/mealdeal-update.timer <<EOF
[Unit]
Description=MealDeal daily update check
[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload && systemctl enable --now mealdeal-update.timer'
```

The rollback path means a bad commit self-heals: the timer fires, the build or health check
fails, the previous release comes back, and the failure is in `journalctl -u mealdeal-update`.

## Enabling ingest

The app disables ingest entirely when `IMAP_HOST`/`IMAP_USER`/`IMAP_PASSWORD` are not all set
(`settings.IMAP` is `null`), which is why a credential-free provision comes up clean.

```bash
pct exec 110 -- nano /etc/mealdeal.env
#   IMAP_HOST=imap.gmail.com
#   IMAP_USER=deals@gmail.com
#   IMAP_PASSWORD=<16-char app password, NOT the account password>
#   INGEST_INLINE=1
pct exec 110 -- systemctl restart mealdeal
pct exec 110 -- bash -lc 'mealdeal-ingest'   # one pass: {"messagesSeen":N,"dealsAdded":N,...}
```

Use a **Gmail app password** (Google account → Security → 2-Step Verification → App passwords),
not the account password. If a value contains a space, `#`, or `$`, quote it — systemd parses
this file as an `EnvironmentFile`.

`INGEST_INLINE=0` is the only value that disables the scheduler; any other string enables it.

## Layout

| Path | What |
| --- | --- |
| `/opt/mealdeal/repo` | git clone; the build workspace |
| `/opt/mealdeal/releases/<sha>` | a built, production-pruned release (`dist` + prod `node_modules` + `drizzle` + `web`) |
| `/opt/mealdeal/current` | symlink to the release systemd runs |
| `/var/lib/mealdeal/mealdeal.db` | the SQLite database (**mp0, `backup=1`**) |
| `/etc/mealdeal.env` | app environment incl. the IMAP password (**mode 600**) |
| `/etc/mealdeal-deploy.env` | deploy knobs for the wrappers (non-secret) |
| `/opt/node/current` | pinned Node, SHA-256 verified |

**Backups are split deliberately.** The database is the one thing that cannot be rebuilt, so it
lives on its own small mount point with `backup=1` — set explicitly, because Proxmox mount points
default to `backup=0`. Node, `node_modules`, and the built releases are all reproducible from git.

⚠️ Unlike the other containers in this repo, the rootfs is **not** `backup=0`: a container's root
disk cannot be excluded from `vzdump` at all (PVE rejects `backup=` on `rootfs` — the
append-`backup=0` idiom used elsewhere here is a silent no-op behind a `|| true`). To keep backups
lean, exclude the rebuildable tree in the backup job instead:

```bash
vzdump 110 --exclude-path /opt/mealdeal
```

Restore is therefore: re-run the provisioning script, then drop the backed-up `mealdeal.db`
into `/var/lib/mealdeal/` and restart. Migrations are idempotent and run at every boot, so an
older DB is brought up to the current schema automatically.

## Why native instead of the app's Dockerfile

MealDeal ships a `Dockerfile` and `docker-compose.yml`, but this homelab runs no Docker — every
other container is a native LXC with a systemd unit, and Docker-in-LXC would need `nesting=1` +
`keyctl=1` for one service. There is also no image to pull (the repo's GitHub Actions are
billing-locked), so *something* has to build from source either way.

The cost is that the build pipeline is replayed in `mealdeal-update` rather than read from the
Dockerfile. **If mealdeal's Dockerfile build stages, pinned pnpm version, or runtime layout
change, `mealdeal-update` and this script's `PNPM_VERSION`/`NODE_VERSION` must be updated to
match.** The build asserts its outputs (`dist/server.js`, `drizzle/`, `web/index.html`) so a
drifted layout fails the build instead of shipping a broken release.

## Notes

- **No `build-essential`.** mealdeal's Dockerfile builds on `node:26-slim`, which has no
  compiler, so every dependency resolves to a prebuilt binary. If a future dependency needs to
  compile, that changes and the build will say so.
- **The service runs as the unprivileged `mealdeal` user**, not root, with `ProtectSystem=full`
  and write access limited to the database directory (`ReadWritePaths=`, set by a drop-in).
- **Health is checked via GraphQL, not a `/health` route** (the app has none): a `{__typename}`
  reply proves the HTTP server is up, the schema built, and the startup migrations completed.
- **Geocoding privacy.** By default, merchant addresses found in newsletters are sent to public
  Nominatim (rate-limited to ~4 req/min) with an identifying user agent. Set `GEOCODER_BASE_URL`
  to a self-hosted geocoder to keep them internal.
- The `:4000` LAN port-forward and the `10.10.10.110` DHCP reservation live in
  `host-net/wifi-nat/wifi-nat.env`; re-apply them with `install.sh --reload-dns` and
  `install.sh --reload-nft`.
