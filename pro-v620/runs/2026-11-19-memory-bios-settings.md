# Host memory: BIOS settings and read bandwidth

Plan committed 2026-11-19 · Run 2026-11-19 · Status: done

## Question

With the BIOS as set on 2026-09-16 (NPS1, APBDIS Auto, DF C-states enabled), the host reads
memory at about 142 GB/s from 32 threads up, 69% of the 204.8 GB/s theoretical bandwidth
([2026-11-18](2026-11-18-memory-bandwidth.md), [2026-11-19](2026-11-19-memory-read-64-threads.md)).
AMD's tuning guidance for memory-bound work names three BIOS settings that act on the I/O die:
four NUMA nodes per socket (NPS4), APBDIS 1 with the SOC P-state fixed at P0, and DF C-states
disabled. Does any of them, set alone, raise the host's read bandwidth?

## What answers it

`readbw`'s best rate, median of three rounds, at 16 and at 32 threads, compared with the two
baselines that bracket the run at the same thread count.

- A setting **raises** read bandwidth if, at either thread count, its median is more than 2%
  above both baselines' medians, and **lowers** it if more than 2% below both. Otherwise it
  makes no measurable difference. The three rounds of every cell were within 1.3% of each other
  in both earlier runs.
- If the two baselines differ by more than 2% at a thread count, the comparisons at that count
  are reported but not judged.
- STREAM's four kernels, in bytes moved, are reported for every setting as a percentage of the
  baselines' mean.
- A boot is measured only after the BIOS reports the requested values over Redfish, and for
  NPS4 after Linux shows four NUMA nodes.

## Configurations

One setting changes at a time; every other setting stays at its baseline value. Five boots:

| Boot | NPS | APBDIS | DF C-states | Set with `bios-set.sh` |
| --- | --- | --- | --- | --- |
| 1 Baseline A | NPS1 | Auto | Enabled | nothing: the boot running since 2026-11-16 |
| 2 NPS4 | NPS4 | Auto | Enabled | `CbsDfCmnDramNps=CbsDfCmnDramNpsNPS4` |
| 3 APBDIS | NPS1 | 1 | Enabled | `CbsDfCmnDramNps=CbsDfCmnDramNpsNPS1 CbsCmnApbdis=CbsCmnApbdis1` |
| 4 DF C-states off | NPS1 | Auto | Disabled | `CbsCmnApbdis=CbsCmnApbdisAuto CbsCmnGnbSMUDfCstates=CbsCmnGnbSMUDfCstatesDisabled` |
| 5 Baseline B | NPS1 | Auto | Enabled | `CbsCmnGnbSMUDfCstates=CbsCmnGnbSMUDfCstatesEnabled` |

The Fixed SOC Pstate attribute (`CbsCmnFixedSocPstate`) already reads P0 and applies only when
APBDIS is 1, so boot 3 changes APBDIS alone. Every boot runs the same four binaries as
2026-11-18 (`stream-gcc`, `stream-plain`, `stream-nt`, `readbw`) at 16 and 32 threads, the two
fastest counts.

Under NPS4, STREAM and `readbw` first-touch their arrays with the same static partitioning as
their timed loops, so each thread reads memory on its own node. The figure is NUMA-local
bandwidth, the best case; a program that does not place its memory gets less.

Left out:

- NPS2, and combinations of the three settings: each is tested alone first. A combination is
  worth a run only if more than one setting raises read bandwidth.
- The standard model configurations and speculative decoding: no model runs here. If a setting
  raises read bandwidth, a model test on CT 125, whose DeepSeek engine reads its experts from
  system RAM, is the next record.
- 8 and 64 threads: slower than 16 and 32 in both earlier runs.

## Controls

- Baseline A, on the current boot, and baseline B, on a fresh boot with the original settings,
  bracket the three settings. Their difference is the run's drift.
- Every boot builds the binaries from the pinned STREAM source with the same compiler; the
  checksums in each `env.txt` show they match.
- STREAM validates its arrays after every run and `readbw` checks every pass's sum; a run that
  fails is left out. Each run starts with the hottest DIMM at or below 55 °C, and a run during
  which any DIMM reaches 66 °C, the
  [bandwidth cap](../host-memory/README.md#dimm-thermal-throttle), is left out.

## Method

- Harness: this commit. `membench-kernels.sh` staged on the host with `../push-harness.sh`;
  [`bios-set.sh`](../host-memory/bios-set.sh) run on the Mac from a checkout of this
  commit, with the BMC login in a mode-600 netrc file outside the repository.
- `bios-set.sh` checks each name and value against the BIOS's attribute registry, sets a
  one-time boot into Setup with `ipmitool chassis bootdev bios`, reboots the host, writes the
  values over Redfish once Setup accepts them (the BMC refuses BIOS writes while the OS runs),
  restarts the host from Setup so POST applies them, waits for the new boot and reads the
  values back. It refuses to run while any guest is running.
- Each boot, on the host:
  `OUT=/root/membench/bios-2026-11-19/<boot>-<label> THREADS="16 32" /root/harness/<sha12>/pro-v620/qwen38-flash-next/membench-kernels.sh`,
  otherwise with the defaults (`ROUNDS=3 COOL_C=55 CAP_C=66`): three rounds, the binary order
  rotated each round.
- Before each measurement: the BIOS values over Redfish, the NUMA node count, each GPU's
  render node and the CPU governor.
- Expected duration: about 2 hours. Baseline A takes about 13 minutes; each later boot about
  25: two restarts, then the measurement.
- Raw data: `/root/membench/bios-2026-11-19/` on the host, one directory per boot laid out as on
  2026-11-18, and each boot's `bios-set.sh` output beside it as `<boot>-<label>.bios-set.log`.

## Safety

- Every guest is stopped. CT 121 (`hermes`), CT 120 (`llamacpp`, no slot busy) and CT 125
  (`ds41-strata`, no request in the last 10 minutes) were shut down on 2026-11-19 at the
  owner's request, before this plan was committed. CT 123, 126, 127, 200 and 201 were already
  stopped, and the host has no VMs.
- `onboot` of every container is saved in `/root/onboot-before-bios-20261119.txt`; CT 120, 121
  and 125 were set to 0 so the reboots do not start them. After boot 5 it is restored from that
  file, and the guests wait for the owner to say to start them.
- Boot 5 restores the settings of 2026-09-16 (NPS1, APBDIS Auto, DF C-states enabled), checked
  over Redfish, together with the GPU render nodes, before `onboot` is restored.
- If Setup accepts no write within 15 minutes, `bios-set.sh` stops with the host in Setup, and
  the owner sets the values in iKVM: NUMA nodes per socket under Advanced → AMD CBS → DF Common
  Options → Memory Addressing; APBDIS, Fixed SOC Pstate and DF Cstates under Advanced → AMD CBS
  → NBIO Common Options → SMU Common Options. If the host does not boot within 25 minutes, it
  is checked in iKVM.
- No other BIOS setting changes. The governor stays `schedutil`, set by `cpu-governor.service`
  at every boot.

## Environment

From boot 1's `env.txt` (`/root/membench/bios-2026-11-19/1-baseline-a/env.txt`):

```text
date: 2026-11-19T16:22:09-05:00
harness: d4eaba3eb6848ab8ab69fa00c8af9cf4276bba37
smoke: false
kernel: 7.0.14-29-pve
bios: P4.30 05/20/2026
cpu: AMD EPYC 7532 32-Core Processor
microcode: 0x830107d
governor: schedutil
numa_nodes: 1
thp: always [madvise] never
gcc: gcc (Debian 14.2.0-19) 14.2.0
glibc: ldd (Debian GLIBC 2.41-12+deb13u4) 2.41
glibc_copy_thresholds: x86.cpu_features.non_temporal_threshold=0xc00000 x86.cpu_features.rep_movsb_threshold=0xc00000 x86.cpu_features.rep_movsb_stop_threshold=0xc00000
array_doubles: stream 1000000000 x 3, readbw 2000000000; ntimes 20
threads: 16 32; rounds 3; cool 55 C; cap 66 C
omp: OMP_PROC_BIND=spread OMP_PLACES=cores
dimms: 8 x (64 GB, M393A8K40B22-CAE, 3200 MT/s)
guests: 120, 121, 123, 125, 126, 127, 200, 201 all stopped
checksums:
  a52bae5e175bea3f7832112af9c085adab47117f7d2ce219165379849231692b  src/stream.c
  1a4e6be3319b874fadfa24823642028557122853ffc22a85987a021956cd780d  src/stream-nt.c
  9b61e9c27f7021fe18e9e53f41eaf3c08c556b58831684c2c16259e37b16d7f9  bin/readbw
  7333b0b11f1e5717337daa543f9a7b478de8474aa992118f7d5cdfaa1f2da886  bin/stream-gcc
  2e3c3e01e65b6bed94a2497bbfe7b598ce81a1d90bcd04cc682dfd9a10b9be2c  bin/stream-nt
  94b4c0a75403934ed2cb59d9bbebe928bb52ce9e7e5014eb33f2765c0d4db8e9  bin/stream-plain
```

The DIMM and guest lists are condensed from eight identical lines each. The other five boots'
`env.txt` differ only in date, load, NUMA node count and thread list (below); every boot's
source and binary checksums are the ones above. The BIOS over Redfish before each measurement,
with Linux's NUMA node count:

| Boot | Measured from (ET) | NPS | APBDIS | Fixed SOC Pstate | DF C-states | NUMA nodes | Threads |
| --- | --- | --- | --- | --- | --- | ---: | --- |
| 1 Baseline A | 16:22 | NPS1 | Auto | P0 | Enabled | 1 | 16, 32 |
| 2 NPS4 | 17:12 | NPS4 | Auto | P0 | Enabled | 4 | 16, 32 |
| 3 APBDIS | 17:29 | NPS1 | 1 | P0 | Enabled | 1 | 16, 32, 64 |
| 4 DF C-states off | 17:56 | NPS1 | Auto | P0 | Disabled | 1 | 16, 32, 64 |
| 5 NPS4 again | 18:23 | NPS4 | Auto | P0 | Enabled | 4 | 16, 32, 64 |
| 6 Baseline B | 18:47 | NPS1 | Auto | P0 | Enabled | 1 | 16, 32, 64 |

Under NPS4, Linux puts cores 0–7, 8–15, 16–23 and 24–31 (with their SMT siblings) on nodes 0–3,
about 128 GB each. On every boot the GPU render nodes were unchanged
(`0000:03:00.0` → `renderD129`, `0000:83:00.0` → `renderD128`) and the governor was `schedutil`.

---

## Results

Run 2026-11-19 16:22–19:08 ET: six boots, 192 runs, all validated. Every run started with the
hottest DIMM at or below 55 °C; the hottest reading of the run was 57 °C, so no run was capped
and none was left out. The three rounds of every `readbw` cell are within 0.9% of each other.
Full tables: `summary.md` in each boot's directory under `/root/membench/bios-2026-11-19/`.

`readbw`, best rate in GB/s, median of three rounds:

| Boot | 16 threads | 32 threads | 64 threads |
| --- | ---: | ---: | ---: |
| 1 Baseline A | 136.5 | 142.6 | — |
| 2 NPS4 | 168.7 | 169.5 | — |
| 3 APBDIS 1 | 136.9 | 144.1 | 145.1 |
| 4 DF C-states off | 137.4 | 144.0 | 145.1 |
| 5 NPS4 again | 168.8 | 169.5 | 165.7 |
| 6 Baseline B | 136.9 | 144.0 | 145.1 |

The same against the baselines:

| Setting | 16 threads, vs A / vs B | 32 threads, vs A / vs B | 64 threads, vs B |
| --- | ---: | ---: | ---: |
| NPS4 (boot 2) | +23.6% / +23.2% | +18.9% / +17.7% | — |
| NPS4 (boot 5) | +23.7% / +23.3% | +18.9% / +17.7% | +14.2% |
| APBDIS 1 | +0.3% / 0.0% | +1.1% / +0.1% | 0.0% |
| DF C-states off | +0.7% / +0.4% | +1.0% / 0.0% | 0.0% |

Baseline B is 0.3% above baseline A at 16 threads and 1.0% above at 32.

Pass times vary under NPS4. On every NPS1 boot the slowest of a run's 19 timed passes is within
4% of the fastest at 16 and 32 threads and within 9% at 64; on the NPS4 boots it takes up to 67%
longer at 16 threads, 50% at 32 and 51% at 64. At the average pass time `readbw` reads, in GB/s:

| Boot | 16 threads | 32 threads | 64 threads |
| --- | ---: | ---: | ---: |
| 1 Baseline A | 135.6 | 142.2 | — |
| 2 NPS4 | 146.6 | 157.2 | — |
| 5 NPS4 again | 146.6 | 158.0 | 153.8 |
| 6 Baseline B | 136.4 | 143.3 | 142.2 |

STREAM, best rate in bytes moved (the [2026-11-18 record's](2026-11-18-memory-bandwidth.md)
factors), GB/s at 16 threads:

| Binary | Kernel | 1 Baseline A | 2 NPS4 | 3 APBDIS 1 | 4 DF off | 5 NPS4 again | 6 Baseline B |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `stream-gcc` | Copy | 150.9 | 168.6 | 153.2 | 153.0 | 168.9 | 153.2 |
| `stream-gcc` | Scale | 146.1 | 162.9 | 146.6 | 146.6 | 162.9 | 146.4 |
| `stream-gcc` | Add | 140.7 | 159.7 | 141.9 | 141.9 | 159.7 | 141.9 |
| `stream-gcc` | Triad | 140.4 | 160.0 | 142.0 | 142.0 | 160.0 | 142.0 |
| `stream-plain` | Copy | 147.3 | 164.9 | 148.9 | 148.9 | 164.9 | 148.9 |
| `stream-plain` | Scale | 144.9 | 164.4 | 146.2 | 146.2 | 164.4 | 146.2 |
| `stream-plain` | Add | 143.3 | 165.5 | 143.9 | 144.0 | 165.6 | 144.0 |
| `stream-plain` | Triad | 143.6 | 165.7 | 144.3 | 144.3 | 165.7 | 144.3 |
| `stream-nt` | Copy | 146.8 | 173.5 | 149.6 | 149.6 | 173.6 | 149.7 |
| `stream-nt` | Scale | 149.5 | 173.5 | 149.8 | 149.9 | 173.5 | 149.8 |
| `stream-nt` | Add | 145.8 | 169.3 | 147.7 | 148.0 | 169.3 | 147.9 |
| `stream-nt` | Triad | 146.1 | 169.3 | 147.7 | 147.8 | 169.3 | 147.6 |

Against the mean of the two baselines, NPS4 moves 10.9–17.1% more across the twelve kernels at
16 threads and 9.4–13.6% more at 32; APBDIS 1 and DF C-states off 0.0–0.9%. At 64 threads,
against baseline B: NPS4 7.9–12.0% more, APBDIS 1 and DF C-states off within 0.1%.

## Deviations

- **The BMC refused the BIOS writes in Setup too.** On boot 2, `bios-set.sh` set the one-time
  boot into Setup and rebooted the host, which stopped in Setup, but the BMC answered every
  write for 15 minutes, and one more by hand afterwards, with the same HTTP 500 it gives while
  the OS runs. Its output is `2-nps4.redfish-attempt.log`. From then on the owner set each boot's
  values in iKVM (Setup's menus, then Save & Exit), after a reboot into Setup with
  `ipmitool chassis bootdev bios options=efiboot`. Each boot's values were read back over Redfish
  before measuring, as planned, by a helper outside the repository that then started
  `membench-kernels.sh` from the same harness commit; the read-back and host checks are in
  `<boot>-<label>.bios-set.log`, and boot 1's in `1-baseline-a.bios-readback.log`.
- **64 threads from boot 3 on**, at the owner's request after boot 2. Baseline A and boot 2 ran
  16 and 32 threads only, so 64-thread figures compare with baseline B alone.
- **A second NPS4 boot**, at the owner's request after boot 3: boot 5 measures NPS4 at 64 threads
  and repeats it. Boot 5 set DF C-states back to Enabled and NPS to NPS4 together; baseline B
  became boot 6, which set NPS back to NPS1.
- `env.txt` names every DIMM "DIMM 0", as on 2026-11-18: the harness prints dmidecode's
  `Locator`, and this board puts the channel letter in `Bank Locator`.

## Conclusion

- **NPS4 raises read bandwidth.** `readbw` reads 168.7–168.8 GB/s at 16 threads and 169.5 at
  32 on two NPS4 boots that agree within 0.1%: 23.2–23.7% and 17.7–18.9% above both baselines
  (criterion: more than 2%). At 64 threads it reads 165.7, 14.2% above baseline B. 169.5 GB/s is
  83% of the 204.8 GB/s peak. It is NUMA-local bandwidth, each thread reading its own node's
  memory. NPS4's passes vary: at the average pass time it reads 7.5–10.3% more than baseline B,
  not 14–23%. Automatic NUMA balancing was off (`kernel.numa_balancing = 0`); the cause of the
  variation was not found. STREAM moves 9.4–17.1% more under NPS4 at 16 and 32 threads.
- **APBDIS 1 makes no measurable difference**: 0.0–1.1% at every thread count (criterion: 2%).
  The 1.0–1.1% over baseline A at 32 threads is matched by baseline B, a fresh boot with the
  original settings, so it comes from the fresh boot, not the setting.
- **DF C-states disabled makes no measurable difference**: 0.0–1.0% at every thread count.
- **Drift**: baseline B is within 1.0% of baseline A, inside the 2% bound, so every comparison
  is judged.
- The plan's condition for a model test is met: a CT 125 decode test under NPS4 against NPS1 is
  the next record. The host ended the run on the settings of 2026-09-16: NPS1, APBDIS Auto, DF
  C-states enabled, read back over Redfish.
