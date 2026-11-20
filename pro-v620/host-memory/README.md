# Host memory

Memory bandwidth of the Proxmox host (ROMED8-2T, EPYC 7532, 8 × 64 GB DDR4-3200 on all eight
channels, 204.8 GB/s theoretical) and the BIOS settings that act on it. Models that keep
experts in system RAM, Qwen3.8-Flash-Next in CT 123 and DeepSeek-V4.1-Flash in CT 125, decode at
the rate the host reads memory.

## Tools

Each runs on the host as root with every guest shut down, except `membench-sustained.sh`,
which logs each guest's CPU time instead.

| Script | Measures |
| --- | --- |
| [`membench.sh`](membench.sh) | STREAM 5.10 at 8–64 threads and a pointer-chase latency, built into `/root/membench` |
| [`membench-sustained.sh`](membench-sustained.sh) | `membench.sh`'s STREAM back to back for a set time, each pass beside the DIMM temperatures |
| [`membench-kernels.sh`](membench-kernels.sh) | STREAM with ordinary and with non-temporal stores ([`membench-stream-nt.c`](membench-stream-nt.c)), and a read-only pass ([`membench-readbw.c`](membench-readbw.c)), in rotated rounds behind a DIMM-temperature gate; run from a harness staged by [`../push-harness.sh`](../push-harness.sh) |
| [`bios-set.sh`](bios-set.sh) | Run on the Mac: writes BIOS attributes over Redfish from UEFI Setup. The BMC refuses those writes (see [BIOS settings](#bios-settings)) |

## Test records

Plans and results of each test campaign, per [TEST-RECORDS.md](../TEST-RECORDS.md).

| Date | Record | Status |
| --- | --- | --- |
| 2026-11-18 | [Store types and read-only bandwidth](../runs/2026-11-18-memory-bandwidth.md) | done |
| 2026-11-19 | [Read bandwidth at 64 threads](../runs/2026-11-19-memory-read-64-threads.md) | done |
| 2026-11-19 | [BIOS settings and read bandwidth](../runs/2026-11-19-memory-bios-settings.md) | done |

## Bandwidth

`membench.sh` on 2026-10-08, on all eight DDR4-3200 channels: 8 × 64 GB
`M393A8K40B22-CAE` 3DS RDIMMs, kernel `7.0.14-22-pve`, `schedutil` governor, guests running
but idle. BIOS: NPS1, memory interleaving Auto, APBDIS Auto, DF C-states enabled. STREAM
5.10, built with `gcc -O3 -march=native -fopenmp` and three 8 GB arrays, reports the best of
20 passes.

| Threads | Copy | Scale | Add | Triad |
| ---: | ---: | ---: | ---: | ---: |
| 8 | 151.0 GB/s | 96.3 | 107.5 | 107.5 |
| 16 | 152.7 | 97.3 | 106.4 | 106.6 |
| 32 | 148.6 | 95.4 | 104.3 | 104.4 |
| 64 | 141.9 | 94.1 | 103.6 | 103.6 |

Copy peaks at 75% of the 204.8 GB/s theoretical bandwidth. STREAM reports the bytes a
kernel names, not the bytes it moves. GCC compiles Copy to a `memcpy` call, and glibc
copies blocks that large with non-temporal stores, so Copy moves what it reports. Scale,
Add and Triad use ordinary stores, which first read each destination line.
`membench-kernels.sh` builds STREAM with non-temporal stores in every kernel, plus a
read-only pass. Measured 2026-11-18 on kernel `7.0.14-29-pve` with the same BIOS settings
and every guest shut down, at 16 threads, median of three rounds
([record](../runs/2026-11-18-memory-bandwidth.md)):

| Build | Copy | Scale | Add | Triad |
| --- | ---: | ---: | ---: | ---: |
| `membench.sh`'s flags | 149.9 GB/s | 96.3 | 104.9 | 104.9 |
| Non-temporal stores in every kernel | 145.6 | 147.7 | 144.7 | 144.9 |

Counting the destination reads, every kernel moves 140–150 GB/s. A non-temporal build
changes what STREAM reports, not the bandwidth. The read-only pass reached 113.0 GB/s at
8 threads, 136.6 at 16 and 141.7 at 32. On 2026-11-19 it read 141.5 GB/s at 32 threads and
142.1 at 64, the same within the rounds' spread
([record](../runs/2026-11-19-memory-read-64-threads.md)): the host reads at about 142 GB/s,
69% of the theoretical bandwidth, from 32 threads up. At 64 threads every STREAM kernel of
every build moves 0.4–4.0% less than at 32.

A random pointer chase with huge pages measured 116.45 ns/load over 256 MiB and
123.86 ns over 4 GiB. Report page configuration with latency: 4 KiB pages add
page-table walks.

## BIOS settings

Each measured alone on 2026-11-19 between two NPS1 baselines
([record](../runs/2026-11-19-memory-bios-settings.md)): NPS4 raises the read-only pass to
168.8 GB/s at 16 threads and 169.5 at 32, 18–24% above NPS1 and 83% of the theoretical
bandwidth, with each thread reading its own node's memory. Its passes vary: at the average
pass time it reads 8–10% more than NPS1. APBDIS 1 and DF C-states disabled make no
measurable difference (within 1.1%). The host runs NPS1, APBDIS Auto and DF C-states
enabled. BIOS settings are changed in iKVM: the BMC refuses Redfish BIOS writes, in Setup
too, and Redfish reads them back.

## DIMM thermal throttle

When the hottest DIMM reads 66 °C on the BMC (`TEMP_CPU1_DDR4A`–`H`), memory
bandwidth drops to about a third: STREAM Copy 52.7 GB/s, Triad 38 GB/s. It stays
there until the hottest DIMM cools to about 62–63 °C, and idle latency rises from
116 to 128 ns meanwhile. The BMC firmware names this event "DIMM throttling
(bandwidth capping)", asserted on the DIMMs' `EVENT_L` line. BIOS setup exposes no
trip point, and the OS cannot read or change it: after boot no device answers at
the DIMM sensor or SPD addresses on any host SMBus port, because the BMC owns that
bus. Nothing is logged: the SEL, EDAC and the kernel log stay silent.

`membench-sustained.sh` reruns the 16-thread STREAM back to back and logs every pass
beside the DIMM temperatures and each guest's CPU time. Under the BMC's previous fan
curve, 70% duty at 65 °C, it throttled after three minutes. FAN1–FAN3 at full speed hold
the DIMMs at 64–65 °C under the same load, so the BMC curve (open-loop table 1, driven by
the CPU and all eight DIMM sensors) now reaches 100% at 58 °C:

| °C | 30 | 40 | 45 | 50 | 55 | 58 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| FAN1–FAN3 duty | 30% | 35% | 45% | 60% | 80% | 100% |

With that curve, an hour of back-to-back passes (2026-10-08 07:11–08:12, guests
idle, case top open from 07:29) ran 172 of 175 passes at full speed, Copy ~151 GB/s
and Triad ~105.5 GB/s. At 08:05 DIMM F reached 66 °C just after CT 120 served a
request, and three passes, about two minutes, ran capped at 53 GB/s. ⚠️ At full fan
speed the hottest DIMM settles at 64–65 °C, so the curve alone does not prevent the
cap under sustained full-bandwidth load; more margin needs airflow aimed at the DIMMs.
Read DIMM temperatures alongside any CPU-offload throughput measurement.
