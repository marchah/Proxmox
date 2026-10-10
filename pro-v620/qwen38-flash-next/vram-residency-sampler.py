#!/usr/bin/env python3
"""Sample where a card's llama-server buffers live, with the card's clocks, once a second.

Runs on the Proxmox HOST as root (it reads debugfs and other processes' fdinfo):

    ./vram-residency-sampler.py --pci 0000:83:00.0 --output /root/residency.jsonl

Each JSONL line holds the card's memory and core clock levels, power, busy %, VRAM and
GTT in use and temperatures, and for each process named --comm that has the card open:

- from /proc/<pid>/fdinfo, the kernel's own accounting: resident VRAM and GTT,
  `amd-evicted-vram` (memory that asked for VRAM but sits in GTT) and the requested
  VRAM and GTT;
- from debugfs `amdgpu_gem_info`, the count and bytes of its buffers in each placement;
  `UNKNOWN` counts buffers the kernel could not lock to read, those in use by a submission.

When a buffer of at least --min-move-mib changes placement, the line also carries a
`moves` list (handle, size, from, to); a buffer read as UNKNOWN keeps its last known
placement. GEM handles are reused, so a buffer freed and another of the same size created
under its handle between two samples reads as a move. The first line for a process lists every such
buffer's placement as its starting point. A process that appears again with a new pid
(the server restarted) starts a new baseline.
"""
import argparse
import json
import os
import re
import signal
import sys
import time
from datetime import datetime, timezone

FDINFO_KEYS = {
    "drm-resident-vram": "resident_vram_kib",
    "drm-resident-gtt": "resident_gtt_kib",
    "amd-evicted-vram": "evicted_vram_kib",
    "amd-requested-vram": "requested_vram_kib",
    "amd-requested-gtt": "requested_gtt_kib",
}
UNIT_KIB = {"KiB": 1, "MiB": 1024, "GiB": 1024 * 1024}
GEM_PID = re.compile(r"^pid\s+(\d+)\s+command\s+(.*):\s*$")
GEM_BO = re.compile(r"^\s+0x([0-9a-f]+):\s+(\d+) byte (\S+)")


def read(path, default=None):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return default


def current_level_mhz(path):
    for line in (read(path) or "").splitlines():
        if line.rstrip().endswith("*"):
            m = re.search(r"(\d+)\s*Mhz", line, re.I)
            return int(m.group(1)) if m else None
    return None


def card_sample(dev):
    def num(name, scale=1):
        raw = read(os.path.join(dev, name))
        try:
            return round(int(raw) / scale, 1)
        except (TypeError, ValueError):
            return None

    hw = None
    hwroot = os.path.join(dev, "hwmon")
    for name in sorted(os.listdir(hwroot)) if os.path.isdir(hwroot) else []:
        hw = os.path.join(hwroot, name)
        break
    out = {
        "mclk_mhz": current_level_mhz(os.path.join(dev, "pp_dpm_mclk")),
        "sclk_mhz": current_level_mhz(os.path.join(dev, "pp_dpm_sclk")),
        "fclk_mhz": current_level_mhz(os.path.join(dev, "pp_dpm_fclk")),
        "gpu_busy": num("gpu_busy_percent"),
        "mem_busy": num("mem_busy_percent"),
        "vram_used_mib": num("mem_info_vram_used", 2**20),
        "gtt_used_mib": num("mem_info_gtt_used", 2**20),
    }
    if hw:
        out["power_w"] = num(os.path.join("hwmon", os.path.basename(hw), "power1_average"), 1e6)
        out["edge_c"] = num(os.path.join("hwmon", os.path.basename(hw), "temp1_input"), 1000)
        out["junction_c"] = num(os.path.join("hwmon", os.path.basename(hw), "temp2_input"), 1000)
        out["mem_c"] = num(os.path.join("hwmon", os.path.basename(hw), "temp3_input"), 1000)
    return out


def gem_info(path, comm):
    """{pid: {handle: (size, placement)}} for processes whose command starts with comm."""
    procs, cur = {}, None
    for line in (read(path) or "").splitlines():
        m = GEM_PID.match(line)
        if m:
            cur = int(m.group(1)) if m.group(2).startswith(comm) else None
            if cur is not None:
                procs.setdefault(cur, {})
            continue
        if cur is None:
            continue
        m = GEM_BO.match(line)
        if m:
            procs[cur][m.group(1)] = (int(m.group(2)), m.group(3))
    return procs


def fdinfo(pid, pci):
    """Sum the kernel's per-client memory counters over the pid's fds on this card."""
    total, found = {}, False
    fd_dir = f"/proc/{pid}/fd"
    try:
        fds = os.listdir(fd_dir)
    except OSError:
        return None
    for fd in fds:
        try:
            if not os.readlink(os.path.join(fd_dir, fd)).startswith("/dev/dri/"):
                continue
        except OSError:
            continue
        info = read(f"/proc/{pid}/fdinfo/{fd}") or ""
        if f"drm-pdev:\t{pci}" not in info:
            continue
        found = True
        for line in info.splitlines():
            key, _, value = line.partition(":")
            if key in FDINFO_KEYS:
                # The kernel prints each size in the largest unit that divides it evenly.
                parts = value.split()
                kib = int(parts[0]) * UNIT_KIB.get(parts[1] if len(parts) > 1 else "", 1 / 1024) if parts else 0
                total[FDINFO_KEYS[key]] = total.get(FDINFO_KEYS[key], 0) + int(kib)
    return total if found else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--pci", required=True, help="card PCI address, e.g. 0000:83:00.0")
    ap.add_argument("--output", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--comm", default="llama-server", help="process name prefix to follow")
    ap.add_argument("--min-move-mib", type=float, default=16.0,
                    help="smallest buffer whose placement changes are listed")
    args = ap.parse_args()

    dev = f"/sys/bus/pci/devices/{args.pci}"
    gem_path = f"/sys/kernel/debug/dri/{args.pci}/amdgpu_gem_info"
    if not os.path.isdir(dev):
        sys.exit(f"no such PCI device: {args.pci}")
    if read(gem_path) is None:
        sys.exit(f"cannot read {gem_path}: run as root with debugfs mounted")
    min_move = args.min_move_mib * 2**20

    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))

    last = {}  # pid -> {handle: (size, placement)} for buffers >= min_move
    with open(args.output, "a", buffering=1) as out:
        while not stop:
            t0 = time.time()
            rec = {"t": round(t0, 3), "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                   "pci": args.pci, "card": card_sample(dev), "procs": []}
            for pid, bos in sorted(gem_info(gem_path, args.comm).items()):
                proc = {"pid": pid}
                fi = fdinfo(pid, args.pci)
                if fi:
                    proc.update(fi)
                by = {}
                for size, place in bos.values():
                    slot = by.setdefault(place, [0, 0])
                    slot[0] += 1
                    slot[1] += size
                proc["bos"] = {place: {"count": c, "mib": round(b / 2**20, 1)} for place, (c, b) in by.items()}
                # gem_info prints UNKNOWN for a buffer it could not lock (one in use by a
                # submission); keep its last known placement rather than call it a move.
                big = {h: (v[0], last.get(pid, {}).get(h, (None, v[1]))[1] if v[1] == "UNKNOWN" else v[1])
                       for h, v in bos.items() if v[0] >= min_move}
                if pid not in last:
                    proc["baseline"] = [[h, round(s / 2**20, 1), p] for h, (s, p) in sorted(big.items())]
                else:
                    moves = [[h, round(s / 2**20, 1), last[pid][h][1] if h in last[pid] else None, p]
                             for h, (s, p) in sorted(big.items())
                             if h not in last[pid] or last[pid][h][1] != p]
                    moves += [[h, round(s / 2**20, 1), p, None]
                              for h, (s, p) in sorted(last[pid].items()) if h not in big]
                    if moves:
                        proc["moves"] = moves
                last[pid] = big
                rec["procs"].append(proc)
            for pid in [p for p in last if p not in {x["pid"] for x in rec["procs"]}]:
                del last[pid]
            out.write(json.dumps(rec, separators=(",", ":")) + "\n")
            time.sleep(max(0.0, args.interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
