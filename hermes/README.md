# Hermes Agent LXC

A persistent, **unprivileged Debian LXC** running [NousResearch's Hermes
Agent](https://hermes-agent.nousresearch.com/) (open-source, MIT) as the homelab's agent.
It is the consumer side of the system: it talks to the **CT 120 LLM runtime's**
OpenAI-compatible API and needs **no Nous Portal login**.

Provision it on the Proxmox host as root:

```bash
./create-lxc-hermes-agent.sh
```

…or directly, without cloning the repo:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/marchah/Proxmox/main/hermes/create-lxc-hermes-agent.sh)"
```

Defaults to **CT 121**, hostname `hermes`, starts on boot.

## What it runs

A single systemd service, `hermes.service`, runs `hermes gateway run` — one foreground
process that serves **both**:

- the **messaging gateway** (Telegram/Discord/Slack/… — configured post-provision), and
- Hermes's own **OpenAI-compatible API server** on **`0.0.0.0:8642`**
  (`/v1/chat/completions`, `/v1/responses`, `/v1/models`, `/api/jobs`).

This is the same command the official Hermes Docker image runs.

## What it points at

The provisioner auto-discovers CT 120's IP and writes `/root/.hermes/config.yaml`:

```yaml
model:
  default: qwen3.6-35b-a3b        # CT 120's --alias
  provider: custom
  base_url: http://<CT120-IP>:1234/v1
  api_key: ""                     # CT 120 is keyless
  context_length: 65536           # one CT 120 slot (262144 / --parallel 4)
terminal:
  backend: local                  # the LXC itself is the sandbox
```

`context_length` is pinned to a single CT 120 slot so one request can't exceed a slot and
get truncated. Concurrent Hermes subagents and external API clients all share CT 120's 4
slots — on CT 120, `llamacpp-reload <ctx> <parallel>` is the lever if you need to retune.

## Security posture

- The API server gives **full access to Hermes's toolset, including terminal commands**, so
  the bearer **`API_SERVER_KEY` is mandatory even on loopback**. The provisioner
  auto-generates one (`openssl rand -hex 16`) and prints it **once** in the summary — save
  it. It lives in `/root/.hermes/.env` (`chmod 600`).
- It binds `0.0.0.0`, i.e. it is reachable on your LAN; the key is the only gate. Call it
  with `Authorization: Bearer <key>`. Rotate by editing `.env` and `systemctl restart hermes`.
- The LXC is **unprivileged**, so it is the isolation boundary; Hermes runs as **root inside
  it** (the upstream installer needs apt/root for `playwright install --with-deps chromium`).
  Hardening path (not v1): run the service as a dedicated non-root user — the upstream Docker
  image drops to UID 10000.

## Adding messaging platforms (post-provision)

```bash
pct exec 121 -- hermes gateway setup        # interactive: add Telegram/Discord/Slack/…
pct exec 121 -- systemctl restart hermes
```

Platforms are **not** pre-wired by the provisioner — the gateway starts with none. Add them
here; `hermes gateway setup` walks you through both the bot token **and** the per-platform
user allowlist (without an allowlist Hermes denies all incoming users).

## Override env vars

| Var | Default | Purpose |
| --- | --- | --- |
| `VMID` / `LXC_HOSTNAME` | `121` / `hermes` | container id / hostname |
| `ROOT_SIZE_GB` / `MEMORY_MB` / `SWAP_MB` / `CORES` | `30` / `8192` / `2048` / `4` | sizing (sized for Playwright Chromium + Node + uv/py3.11) |
| `TARGET_LXC_VMID` | `120` | CT to discover the model API from |
| `TARGET_BASE_URL` | _(discovered)_ | override the model endpoint directly |
| `MODEL_IDENTIFIER` | `qwen3.6-35b-a3b` | served model id (CT 120's `--alias`) |
| `MODEL_CONTEXT_LENGTH` | `65536` | per-request context written into config.yaml |
| `HERMES_VERSION` | `v2026.6.19` | pinned git tag (installer fetched from the tag + SHA-256 verified); `latest` = main HEAD, **unverified** |
| `HERMES_INSTALLER_SHA256` | _(pinned)_ | expected SHA-256 of the tag's `scripts/install.sh`; bump together with the tag |
| `API_SERVER_KEY` | _(generated)_ | bearer key for the API server |
| `API_SERVER_PORT` | `8642` | API server port |
| `INSTALL_BROWSER` | `1` | `0` skips Playwright Chromium (leaner container) |

## Notes

- **Pinned by default.** The provisioner fetches `scripts/install.sh` from the pinned git
  tag's raw URL (`HERMES_VERSION`, default `v2026.6.19`), verifies its SHA-256 against
  `HERMES_INSTALLER_SHA256`, then runs it with `--branch <tag>` so the checked-out code
  matches the verified installer — the repo's "pin a tag + verify SHA-256" idiom, so a
  mutated upstream installer can't run as root. Bump both from the
  [releases page](https://github.com/NousResearch/hermes-agent/releases) using the **git
  tag** (e.g. `v2026.6.19`), **not** the `v0.17.0` marketing title (it is not a valid git
  ref); recompute the checksum with
  `curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/<tag>/scripts/install.sh | sha256sum`.
  `HERMES_VERSION=latest` opts out: it streams the mutable upstream installer (main HEAD),
  **unverified** — for testing only.
- **CT 120 IP drift:** the discovered `base_url` is written once. Give CT 120 a DHCP
  reservation so its IP is stable; if it does move, edit `model.base_url` in
  `/root/.hermes/config.yaml` and `systemctl restart hermes`.
- **Browser tools** work out of the box (verified): Hermes auto-injects `--no-sandbox` when
  it detects it is running as root, so headless Chromium launches in the LXC. The script
  installs `build-essential`/`python3` because Hermes's `npm install` compiles a native
  module (`node-pty`) via node-gyp, and its `agent-browser` daemon won't install without
  them. `nesting=1` is set on the container as well. Smoke-test from the host:
  `pct exec 121 -- bash -lc 'cd /usr/local/lib/hermes-agent && node_modules/.bin/agent-browser open https://example.com'`.
- **No download file-list to maintain.** Unlike the bench-runner, this script ships zero
  repo-local files into the container — the installer is fetched from the pinned upstream
  tag (and SHA-256-verified) and `config.yaml`/`.env`/the unit are generated inline — so
  there is nothing to keep in sync for the standalone `wget | bash` path.
