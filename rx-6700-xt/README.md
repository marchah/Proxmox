# Radeon RX 6700 XT

Scripts in this folder target the desktop server with a Radeon RX 6700 XT.

## LM Studio Qwen3.5 9B LXC

`create-lxc-lmstudio-qwen3.5-9b.sh` creates an Ubuntu LXC intended to run LM
Studio's `lms` CLI in headless/server mode with the RX 6700 XT passed through.

This script is deliberately narrow:

- GPU: Radeon RX 6700 XT
- ROCm compatibility override: `HSA_OVERRIDE_GFX_VERSION=10.3.0`
- Repository: `unsloth/Qwen3.5-9B-GGUF`
- File: `Qwen3.5-9B-Q4_K_M.gguf`
- Identifier: `qwen3.5-9b`
- Context length: `64000`
- GPU offload: `max`
- API bind: `0.0.0.0:1234`
- Model storage: `/models`

Run it on the Proxmox host as `root`:

```bash
./create-lxc-lmstudio-qwen3.5-9b.sh
```

Useful Proxmox/container overrides:

```bash
VMID=120 LXC_HOSTNAME=lmstudio ./create-lxc-lmstudio-qwen3.5-9b.sh
MODELS_SIZE_GB=500 MEMORY_MB=24576 CORES=8 ./create-lxc-lmstudio-qwen3.5-9b.sh
PASSWORD='temporary-root-password' ./create-lxc-lmstudio-qwen3.5-9b.sh
```

The script creates:

- a privileged Ubuntu LXC
- a local `/models` mount on `local-lvm` with backup disabled
- `/dev/kfd` and `/dev/dri` passthrough for AMD GPU access
- a `lmstudio` user inside the container
- a systemd service named `lmstudio.service`

Check the service inside the LXC:

```bash
pct exec 120 -- systemctl status lmstudio.service
pct exec 120 -- journalctl -u lmstudio.service -n 100 --no-pager
```

Check the OpenAI-compatible endpoint:

```bash
curl http://<container-ip>:1234/v1/models
```

## Storage

The container stores model files under `/models`, backed by local Proxmox
storage. The mount has `backup=0` because model weights are large and
re-downloadable. Back up container configuration, service files, prompts, and
small application state separately.

## AMD ROCm Caveat

The RX 6700 XT is a consumer RDNA2 GPU. Current official ROCm documentation does
not list it as a supported Radeon target, so this setup should be treated as
experimental until validated.

The service sets:

```text
HSA_OVERRIDE_GFX_VERSION=10.3.0
```

That override is a common compatibility attempt for Navi 22 / RX 6700 XT class
hardware, but it does not turn the card into an officially supported ROCm GPU.

## Requirements

- Proxmox host with `pct` and `pveam`
- Ubuntu 24.04 LXC template available or downloadable
- AMD GPU visible on the Proxmox host as `/dev/kfd` and `/dev/dri`
- Network access from the LXC to download LM Studio and the Hugging Face model
