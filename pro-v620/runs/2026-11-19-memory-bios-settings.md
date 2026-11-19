# Host memory: BIOS settings and read bandwidth

Plan committed 2026-11-19 · Run 2026-11-19 · Status: planned

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
  [bandwidth cap](../qwen38-flash-next/README.md#dimm-thermal-throttle), is left out.

## Method

- Harness: this commit. `membench-kernels.sh` staged on the host with `../push-harness.sh`;
  [`bios-set.sh`](../qwen38-flash-next/bios-set.sh) run on the Mac from a checkout of this
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

Intended: kernel 7.0.14-29-pve, BIOS P4.30, gcc 14.2.0, glibc 2.41, as on 2026-11-19; replaced
by each boot's `env.txt` and BIOS readback when the run starts.

---

## Results

## Deviations

## Conclusion
