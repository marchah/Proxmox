# coder-runner (CT 122)

A small, **generic, disposable** LXC that serves as the **execution sandbox** for the autonomous coding
loop. The Hermes agent LXC (**CT 121**) drives it over **ssh + rsync** so that *untrusted project code* —
`npm ci` (arbitrary install scripts!), builds, tests, running the app — executes **here**, never inside
CT 121 (which holds Hermes's config + Slack/Discord/git tokens).

It holds **no secrets**, is **repo-agnostic** (one runner serves every repo the loop works on), and is
created **once** — new repos are added purely on CT 121 via `hermes project`, never a new LXC.

```
CT 121 hermes (10.10.10.121)                 CT 122 coder-runner (10.10.10.122, NO secrets)
  gateway + kanban dispatcher                  node 26 + git + build toolchain (+aider optional)
  git repos + managed worktrees + token  ── rsync worktree + ssh 'npm ci && checks' ──▶ runs ALL execution
  coder's native TEXT edits only               /build/<task>/ per task · disposable
  ← auto-commits the worktree (reliable)
```

Trust is **one-directional** (CT 121 → CT 122, never back): CT 122 gets the code + build commands and
nothing else. A rogue execution is confined to this disposable runner.

## Create it (once, on the Proxmox host as root)

The runner needs CT 121's public key so CT 121 can ssh in. Generate it on CT 121 first, then pass it:

```bash
# 1. On CT 121: make the key (idempotent)
pct exec 121 -- bash -lc 'test -f /root/.ssh/coder-runner || ssh-keygen -t ed25519 -f /root/.ssh/coder-runner -N ""'

# 2. On the Proxmox host: create the runner, authorizing that key
CODER_SSH_PUBKEY="$(pct exec 121 -- cat /root/.ssh/coder-runner.pub)" \
  ./create-lxc-coder-runner.sh
```

Then add the dnsmasq reservation so CT 121 can reach it by name (`coder-runner`) — see
`host-net/wifi-nat/wifi-nat.env` (`10.10.10.122`), and reload dnsmasq.

## Verify

```bash
pct exec 121 -- ssh -i /root/.ssh/coder-runner -o StrictHostKeyChecking=accept-new coder-runner 'node -v'
```

## Useful overrides

| Var | Default | Purpose |
|-----|---------|---------|
| `VMID` | `122` | container id (120–139 AI range) |
| `LXC_HOSTNAME` | `coder-runner` | hostname / dnsmasq name |
| `MAC` | `BC:24:11:C0:DE:22` | fixed MAC for a deterministic DHCP reservation |
| `NODE_MAJOR` | `26` | Node major (NodeSource, tarball fallback) |
| `CODER_SSH_PUBKEY` | *(empty)* | CT 121 pubkey to authorize (required for the loop) |
| `INSTALL_AIDER` | `0` | also install aider (talks to CT 120); off by default |
| `CORES` / `MEMORY_MB` / `ROOT_SIZE_GB` | `4` / `4096` / `24` | sizing |
| `START_ON_BOOT` | `1` | persistent (unlike the disposable bench-runner) |

## Disposable / rebuild

Nothing important lives here — nuke and recreate any time:

```bash
pct stop 122
pct destroy 122 --purge
# then re-run create-lxc-coder-runner.sh
```

## How the loop uses it

Two helper scripts live in the Hermes coder/reviewer profiles on CT 121 (not in this repo):

- `run-on-runner.sh <worktree> <cmd>` — rsync the worktree to `coder-runner:/build/<hash>/` and run `<cmd>`
  there over ssh, streaming output and propagating the exit code.
- `checks-on-runner.sh <worktree>` — detect the repo type (`package.json` → `npm ci && npm run typecheck &&
  npm run lint`; `pyproject.toml` → ruff/mypy/pytest) and run the right checks via `run-on-runner.sh`.

The coder edits natively in its CT 121 worktree, runs `checks-on-runner.sh .` (execution on CT 122), and
finishes with `kanban_complete` — Hermes auto-commits the managed worktree. The reviewer runs the same
checks to decide PASS/FAIL. See the `autonomous-coding-loop` design notes.
