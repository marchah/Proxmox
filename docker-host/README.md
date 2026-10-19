# docker-host — a Docker + Portainer VM

`create-vm-docker-host.sh` builds a Debian VM running **Docker + Compose + Portainer CE**, a
home for small, self-contained web apps as Compose stacks, so a new project costs a compose
file instead of a bespoke provisioning script.

**Why a VM.** Proxmox recommends running Docker in a VM: its own kernel and its own firewall
rules, isolated from the host's. Docker-in-LXC instead needs `nesting=1` + `keyctl=1` (often
privileged), puts `overlay2` on top of a container filesystem, tends to need those tweaks redone
after a Proxmox kernel bump, and shares a kernel with the host's firewall rules that Docker also
writes into. VMs use the repo's `300+` VMID range so container and VM ids never collide.

## Provision (on the Proxmox host, as root)

```bash
./docker-host/create-vm-docker-host.sh
```

Downloads a pinned, SHA-512-verified Debian cloud image, creates the VM with
cloud-init (a dedicated SSH key is generated at `/root/.ssh/docker-host`), then installs the qemu
guest agent, Docker from Docker's own apt repo, the Compose plugin, and Portainer CE — and
**health-polls Portainer's `/api/status`** before reporting success.

```bash
./docker-host/create-vm-docker-host.sh --reinstall-docker   # re-run ONLY the in-guest install
VMID=310 VM_NAME=apps ./docker-host/create-vm-docker-host.sh
MEMORY_MB=8192 CORES=6 DISK_SIZE=80G ./docker-host/create-vm-docker-host.sh
PORTAINER_IMAGE=portainer/portainer-ce:2.39.5 ./docker-host/create-vm-docker-host.sh
```

## First-time setup

1. Open **`https://<vm address>:9443`** and create the Portainer admin user. It's a self-signed
   cert, so expect a browser warning.
   ⚠️ Portainer only leaves initial setup open for a short window, then locks itself. If you see
   "instance timed out", restart it to reopen:
   ```bash
   ssh -i /root/.ssh/docker-host debian@<vm address> docker restart portainer
   ```
2. That's it — the local Docker environment is already connected via the socket.

## Adding a project

Keep the stack's compose file with the app, at `deploy/compose.yaml` in its own repo, then in
Portainer: **Stacks → Add stack → Repository**

| Field | Value |
| --- | --- |
| Repository URL | the app's repo |
| Reference | a branch the app's publish workflow moves only after the image is pushed, such as `refs/heads/deploy` |
| Compose path | `deploy/compose.yaml` |

Add any secrets as **stack environment variables** in that form — never in the compose file.
Enable **automatic updates** (poll on an interval) with "Re-pull image". Tracking `main` directly
races the image publish: a poll can redeploy the previous image and never retry, because the
commit already counts as deployed. A private repo or image needs a git credential on the stack
and a registry entry for `ghcr.io`.

## Operating it

```bash
# SSH in (the Proxmox host holds the key)
ssh -i /root/.ssh/docker-host debian@<vm address>

# From the guest
docker ps
docker logs --since 1h <container>
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

## Backups

Two things matter, and neither is the VM's OS disk (rebuildable by re-running the script):

- **`portainer_data`** — stack definitions, their environment variables, users, settings.
- **Each app's data volume.** Compose prefixes the stack name; list them with `docker volume ls`.

A VM-disk backup captures the Docker volumes only as part of the disk image. For a restore that
doesn't roll the whole VM back, also copy each volume out:

```bash
ssh -i /root/.ssh/docker-host debian@<vm address> \
  'docker run --rm -v <volume>:/d:ro debian:trixie-slim tar -C /d -czf - .' > <volume>.tgz
```

Restore with `tar --numeric-owner` into the volume while its container is stopped, so files keep
the uid the app runs as.
