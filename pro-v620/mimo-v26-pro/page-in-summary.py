#!/usr/bin/env python3
"""Per sweep cell, what the model store read and how close memory came to its limits.

    ./page-in-summary.py <sweep OUT_DIR> <page-in-sampler TSV>

A cell's window is its probes: the first to the last timestamp of the sweep's
<tag>.gpu.tsv, which the sweep samples only while the probes run, so the load is left out.
For each window it prints the store's reads and the host's major faults over the window,
CT 123's peak memory and its least headroom under the CT limit, and the host's least
MemFree. A cell fails the record's RAM rule when the store read more than 1 GiB, the CT
came within 2 GiB of its limit, or the host's MemFree fell under 4 GiB.

MemAvailable counts the experts' page cache as reclaimable, so it cannot show the host's
margin. A TSV from before the sampler logged MemFree is summarised on MemAvailable, and
the header says so.
"""
import csv, pathlib, sys

READ_MAX_MIB, CT_HEADROOM_MIB, HOST_FREE_MIB = 1024, 2048, 4096


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    out_dir, tsv = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    with tsv.open() as f:
        rows = [{k: float(v) for k, v in r.items()} for r in csv.DictReader(f, delimiter="\t")]
    if not rows:
        sys.exit(f"{tsv}: no samples")

    host = "host_free_mib" if "host_free_mib" in rows[0] else "host_avail_mib"
    print("cell\twindow_s\tstore_read_mib\tmajflt\tct_peak_mib\tct_least_headroom_mib"
          f"\t{host.replace('host_', 'host_least_')}\tram_rule")
    for gpu in sorted(out_dir.glob("*.gpu.tsv")):
        stamps = [float(line.split("\t", 1)[0]) for line in gpu.read_text().splitlines() if line]
        if not stamps:
            continue
        t0, t1 = min(stamps), max(stamps)
        before = [r for r in rows if r["epoch"] <= t0]
        after = [r for r in rows if r["epoch"] >= t1]
        inside = [r for r in rows if t0 <= r["epoch"] <= t1]
        tag = gpu.name[: -len(".gpu.tsv")]
        if not before or not after or not inside:
            print(f"{tag}\t{t1 - t0:.0f}\tno samples cover this window")
            continue
        start, end = before[-1], after[0]
        reads = end["store_read_mib"] - start["store_read_mib"]
        majflt = end["pgmajfault"] - start["pgmajfault"]
        peak = max(r["ct_mib"] for r in inside)
        # No limit read (cgroup missing or unlimited) fails the rule rather than passing it.
        headroom = min((r["ct_max_mib"] - r["ct_mib"] for r in inside if r["ct_max_mib"] > 0),
                       default=None)
        host_least = min(r[host] for r in inside)
        ok = (reads <= READ_MAX_MIB and headroom is not None and headroom >= CT_HEADROOM_MIB
              and host_least >= HOST_FREE_MIB)
        shown = "?" if headroom is None else f"{headroom:.0f}"
        print(f"{tag}\t{t1 - t0:.0f}\t{reads:.0f}\t{majflt:.0f}\t{peak:.0f}\t{shown}"
              f"\t{host_least:.0f}\t{'pass' if ok else 'FAIL'}")


if __name__ == "__main__":
    main()
