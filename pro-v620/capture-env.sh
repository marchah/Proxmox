#!/usr/bin/env bash
# Print, as JSON, the software and hardware a llama.cpp guest is running on.
# Runs on the Proxmox HOST as root and changes nothing. Test records paste its output
# (see TEST-RECORDS.md); placement-sweep.sh and `make bench` save it with every run.
#
#   ./capture-env.sh 123                         # CT 123, its active llama.cpp unit
#   ./capture-env.sh 120 llamacpp                # name the unit
#   GUEST_SSH=root@rocm-vm ./capture-env.sh 310  # a VM: guest commands go over ssh
#   HASH_MODELS=true ./capture-env.sh 123        # also sha256 each model file (minutes)
#
# Model files are identified by name, size and download stamp. Their pinned checksums
# are in the repo at the harness commit the record names.
set -Eeuo pipefail

VMID="${1:?usage: capture-env.sh <vmid> [unit]}"
UNIT="${2:-}"
HASH_MODELS="${HASH_MODELS:-false}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"

if pct status "$VMID" >/dev/null 2>&1; then
  KIND=lxc
  CONFIG="$(pct config "$VMID")"
  guest() { pct exec "$VMID" -- bash -c "$1"; }
elif qm status "$VMID" >/dev/null 2>&1; then
  KIND=vm
  CONFIG="$(qm config "$VMID")"
  [ -n "${GUEST_SSH:-}" ] || die "${VMID} is a VM: set GUEST_SSH to reach its guest"
  guest() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$GUEST_SSH" "bash -c $(printf '%q' "$1")"; }
else
  die "no container or VM ${VMID}"
fi

if [ -z "$UNIT" ]; then
  for u in llamacpp-qwen38fn llamacpp llama-swap; do
    if guest "systemctl is-active --quiet $u" 2>/dev/null; then UNIT="$u"; break; fi
  done
fi
case "$UNIT" in
  llamacpp)          ENVFILE=/etc/llamacpp.env ;;
  llamacpp-qwen38fn) ENVFILE=/etc/llamacpp-qwen38fn.env ;;
  *)                 ENVFILE="" ;;
esac

# Cards: LXC passthrough binds /dev/dri/by-path/pci-<address>-render; a VM lists hostpci.
if [ "$KIND" = lxc ]; then
  CARDS="$(printf '%s\n' "$CONFIG" | { grep -oE 'pci-0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' || true; } | sed 's/^pci-//')"
else
  CARDS="$(printf '%s\n' "$CONFIG" | sed -nE 's/^hostpci[0-9]+: (0000:)?([0-9a-f]{2}:[0-9a-f]{2})(\.[0-9])?.*/0000:\2.0/p')"
fi
CARDS="$(printf '%s\n' "$CARDS" | sed '/^$/d' | sort -u | paste -sd' ' -)"

# The guest half runs where the binary and the model files are.
GUEST_JSON="$(guest "UNIT='${UNIT}' ENVFILE='${ENVFILE}' HASH_MODELS='${HASH_MODELS}' python3 -" <<'PY'
import glob, hashlib, json, os, re, shlex, subprocess

def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception as e:
        return "error: %s" % e

out = {"unit": os.environ["UNIT"] or None, "env_file": os.environ["ENVFILE"] or None}
env = {}
if out["env_file"] and os.path.exists(out["env_file"]):
    for line in open(out["env_file"]):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        try:
            v = " ".join(shlex.split(v))
        except ValueError:
            pass
        env[k] = "<redacted>" if re.search(r"TOKEN|SECRET|PASSWORD|API_KEY", k) else v
out["env"] = env
out["unit_active"] = sh("systemctl is-active %s" % out["unit"]) if out["unit"] else None

pid = sh("pgrep -o -x llama-server")
argv = []
if pid.isdigit():
    argv = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
    argv = [a.decode() for a in argv if a]
out["server_cmdline"] = " ".join(shlex.quote(a) for a in argv) or None

bindir = os.path.dirname(argv[0]) if argv else os.path.realpath(env.get("LLAMACPP_DIR", "/opt/llamacpp/current"))
bindir = os.path.realpath(bindir)
server = os.path.join(bindir, "llama-server")
ver = sh("LD_LIBRARY_PATH=%s %s --version 2>&1" % (shlex.quote(bindir), shlex.quote(server)))
out["llamacpp"] = {
    "dir": bindir,
    "version": next((l for l in ver.splitlines() if l.startswith("version")), None),
    "built_with": next((l for l in ver.splitlines() if l.startswith("built with")), None),
    "llama_server_sha256": sh("sha256sum %s | cut -c1-64" % shlex.quote(server)) or None,
    "devices": sh("LD_LIBRARY_PATH=%s %s --list-devices 2>&1 | grep -E '^ +[A-Za-z]+[0-9]+:'"
                  % (shlex.quote(bindir), shlex.quote(server))),
}
out["os"] = sh(". /etc/os-release && echo \"$PRETTY_NAME\"")
out["guest_kernel"] = sh("uname -r")
out["mesa"] = sh("dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null") or None
out["vulkan_driver"] = sh("vulkaninfo --summary 2>/dev/null | grep -m1 -E '^\\s+driverInfo' | sed 's/.*= //'") or None
out["rocm"] = sh("cat /opt/rocm/.info/version 2>/dev/null || dpkg-query -W -f='${Version}' rocm-core 2>/dev/null") or None

# Model files: what the running server loaded, else what the env file names.
def opt(*names):
    for i, a in enumerate(argv):
        if a in names and i + 1 < len(argv):
            return argv[i + 1]
    return None
paths = [opt("-m", "--model") or env.get("MODEL_PATH"), opt("--mmproj") or env.get("MODEL_MMPROJ"),
         opt("-md", "--model-draft")]
files = []
for p in [p for p in paths if p]:
    m = re.match(r"(.*-)0*1-of-(0*\d+)\.gguf$", p)
    files += sorted(glob.glob(m.group(1) + "*-of-" + m.group(2) + ".gguf")) if m else [p]
models = []
for f in files:
    rec = {"path": f, "exists": os.path.exists(f)}
    if rec["exists"]:
        rec["bytes"] = os.path.getsize(f)
        rec["verified_stamp"] = os.path.exists(f + ".verified")
        if os.environ.get("HASH_MODELS") == "true":
            h = hashlib.sha256()
            with open(f, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 24), b""):
                    h.update(chunk)
            rec["sha256"] = h.hexdigest()
    models.append(rec)
out["model_files"] = models
print(json.dumps(out))
PY
)" || die "guest capture failed for ${VMID}"

python3 - "$VMID" "$KIND" "$CARDS" "$GUEST_JSON" "$CONFIG" <<'PY'
import datetime, glob, json, os, platform, re, subprocess, sys

vmid, kind, cards, guest, config = sys.argv[1:6]

def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60).stdout.strip()
    except Exception as e:
        return "error: %s" % e

def read(path):
    try:
        return open(path).read().strip()
    except OSError:
        return None

def card(pci):
    base = "/sys/bus/pci/devices/" + pci
    hw = (glob.glob(base + "/hwmon/hwmon*") or [None])[0]
    od = read(base + "/pp_od_clk_voltage") or ""
    m = re.search(r"OD_VDDGFX_OFFSET:\s*\n\s*(\S+)", od)
    pcie = [l for l in (read(base + "/pp_dpm_pcie") or "").splitlines() if l.rstrip().endswith("*")]
    total = read(base + "/mem_info_vram_total")
    cap = read(hw + "/power1_cap") if hw else None
    return {
        "pci": pci,
        "name": sh("lspci -s %s | cut -d: -f3-" % pci[5:]) or None,
        "driver": os.path.basename(os.path.realpath(base + "/driver")) if os.path.exists(base + "/driver") else None,
        "vbios": read(base + "/vbios_version"),
        "vram_total_mib": int(total) // 1048576 if total else None,
        "od_vddgfx_offset": m.group(1) if m else None,
        "power_cap_w": int(cap) // 1000000 if cap else None,
        "pcie_link": pcie[0].split(":", 1)[1].strip(" *") if pcie else None,
    }

dimms = []
for block in sh("dmidecode -t memory 2>/dev/null").split("\n\n"):
    size = re.search(r"^\s+Size: (\d+ [GM]B)", block, re.M)
    if not size:
        continue
    get = lambda k: (re.search(r"^\s+%s: (.+)$" % k, block, re.M) or [None, None])[1]
    dimms.append({"locator": get("Bank Locator"), "size": size.group(1), "part": (get("Part Number") or "").strip(),
                  "configured_speed": get("Configured Memory Speed")})

cfg = {}
for line in config.splitlines():
    k, _, v = line.partition(": ")
    if k in ("memory", "swap", "cores", "cpulimit", "cpuunits", "ostype", "hostname", "name"):
        cfg[k] = v

env = {
    "captured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "host": {
        "hostname": platform.node(),
        "kernel": platform.release(),
        "pve_manager": sh("pveversion | cut -d/ -f2"),
        "pve_firmware": sh("dpkg-query -W -f='${Version}' pve-firmware"),
        "cpu": sh("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2").strip(),
        "governor": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
        "mem_gib": round(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30),
        "dimms": dimms,
    },
    "guest": dict(json.loads(guest), vmid=int(vmid), kind=kind, config=cfg),
    "cards": [card(c) for c in cards.split()],
}
print(json.dumps(env, indent=1))
PY
