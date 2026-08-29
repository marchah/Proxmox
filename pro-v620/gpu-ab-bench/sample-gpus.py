#!/usr/bin/env python3
"""Sample BOTH V620s + the PWM-hub fan channel to JSONL, once per interval.

Host-side: reads amdgpu hwmon/sysfs by PCI address (cardN is not stable) and the
out-of-tree nct6687 hwmon for the blower hub on PUMP_FAN1 (pwm2/fan2).
"""
import glob, json, os, sys, time

CARDS = {"gpu1": "0000:2d:00.0", "gpu2": "0000:06:00.0"}
NCT = "/sys/devices/platform/nct6687.2592/hwmon/hwmon4"


def rd(path, cast=int, default=None):
    try:
        with open(path) as fh:
            return cast(fh.read().strip())
    except Exception:
        return default


def hwmon(pci):
    hits = glob.glob("/sys/bus/pci/devices/%s/hwmon/hwmon*" % pci)
    return hits[0] if hits else None


def sample():
    out = {"ts": round(time.time(), 3)}
    for name, pci in CARDS.items():
        d = "/sys/bus/pci/devices/%s" % pci
        h = hwmon(pci)
        c = {
            "edge_c": rd("%s/temp1_input" % h, int, 0) / 1000.0 if h else None,
            "junction_c": rd("%s/temp2_input" % h, int, 0) / 1000.0 if h else None,
            "mem_c": rd("%s/temp3_input" % h, int, 0) / 1000.0 if h else None,
            "power_w": rd("%s/power1_average" % h, int, 0) / 1e6 if h else None,
            "sclk_mhz": rd("%s/freq1_input" % h, int, 0) / 1e6 if h else None,
            "mclk_mhz": rd("%s/freq2_input" % h, int, 0) / 1e6 if h else None,
            "mvolt": rd("%s/in0_input" % h, int, 0) if h else None,
            "busy_pct": rd("%s/gpu_busy_percent" % d, int),
            "vram_used": rd("%s/mem_info_vram_used" % d, int),
            "gtt_used": rd("%s/mem_info_gtt_used" % d, int),
            "link_speed": rd("%s/current_link_speed" % d, str),
            "link_width": rd("%s/current_link_width" % d, str),
        }
        out[name] = c
    out["fan_hub"] = {
        "pwm": rd("%s/pwm2" % NCT),
        "pwm_pct": round(100.0 * (rd("%s/pwm2" % NCT, int, 0) / 255.0), 1),
        "rpm": rd("%s/fan2_input" % NCT),
    }
    return out


def main():
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0
    path = sys.argv[2] if len(sys.argv) > 2 else "/root/gpu-ab-bench/telemetry.jsonl"
    with open(path, "a", buffering=1) as fh:
        while True:
            fh.write(json.dumps(sample()) + "\n")
            time.sleep(interval)


if __name__ == "__main__":
    main()
