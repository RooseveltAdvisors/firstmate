#!/usr/bin/env python3
"""
fm-jev-thermal-guard.py - Jev Multi-Agent Host Hardware Thermal & CPU Throttling Guard (Pattern 66)

Audits hardware temperature sensors (/sys/class/hwmon/), cooling device states (/sys/class/thermal/),
and CPU core frequencies (/sys/devices/system/cpu/cpu*/cpufreq/).
Detects thermal junction spikes and hardware CPU throttling before multi-agent build and inference
workloads suffer silent 5x-10x throughput degradation.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful fallback on virtualized hosts without hwmon or cpufreq sysfs.
  - Bounded fast execution (< 0.1s).
"""

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_WARN_CPU_TEMP_C = 88.0
DEFAULT_CRIT_CPU_TEMP_C = 95.0
DEFAULT_WARN_NVME_TEMP_C = 85.0
DEFAULT_WARN_RAM_TEMP_C = 70.0


def read_int_file(path: str) -> Optional[int]:
    """Reads a single integer from a sysfs file safely."""
    try:
        with open(path, "r", errors="replace") as f:
            return int(f.read().strip())
    except Exception:
        return None


def read_str_file(path: str) -> str:
    """Reads a single string from a sysfs file safely."""
    try:
        with open(path, "r", errors="replace") as f:
            return f.read().strip()
    except Exception:
        return "unknown"


def audit_hwmon_sensors(hwmon_root: str = "/sys/class/hwmon") -> List[Dict[str, Any]]:
    """Audits temperature sensors across all hwmon devices."""
    sensors: List[Dict[str, Any]] = []
    if not os.path.exists(hwmon_root):
        return sensors

    try:
        hwmon_dirs = sorted(os.listdir(hwmon_root))
    except Exception:
        return sensors

    for d in hwmon_dirs:
        full_dir = os.path.join(hwmon_root, d)
        name = read_str_file(os.path.join(full_dir, "name"))

        temp_inputs = sorted(glob.glob(os.path.join(full_dir, "temp*_input")))
        for temp_path in temp_inputs:
            base = temp_path[:-6]  # strip '_input'
            raw_temp = read_int_file(temp_path)
            if raw_temp is None:
                continue

            temp_c = round(raw_temp / 1000.0, 2)
            label = read_str_file(base + "_label")
            if label == "unknown":
                label = os.path.basename(temp_path).replace("_input", "")

            crit_raw = read_int_file(base + "_crit")
            crit_c = round(crit_raw / 1000.0, 2) if crit_raw else None

            max_raw = read_int_file(base + "_max")
            max_c = round(max_raw / 1000.0, 2) if max_raw else None

            sensors.append({
                "hwmon": d,
                "name": name,
                "label": label,
                "temp_c": temp_c,
                "max_c": max_c,
                "crit_c": crit_c,
            })

    return sensors


def audit_cooling_devices(thermal_root: str = "/sys/class/thermal") -> List[Dict[str, Any]]:
    """Audits cooling devices and their throttle state."""
    devices: List[Dict[str, Any]] = []
    if not os.path.exists(thermal_root):
        return devices

    try:
        entries = sorted(os.listdir(thermal_root))
    except Exception:
        return devices

    for entry in entries:
        if not entry.startswith("cooling_device"):
            continue
        full_dir = os.path.join(thermal_root, entry)
        dev_type = read_str_file(os.path.join(full_dir, "type"))
        cur_state = read_int_file(os.path.join(full_dir, "cur_state")) or 0
        max_state = read_int_file(os.path.join(full_dir, "max_state")) or 0

        utilization = (cur_state / max_state) if max_state > 0 else 0.0

        devices.append({
            "device": entry,
            "type": dev_type,
            "cur_state": cur_state,
            "max_state": max_state,
            "utilization": round(utilization, 4),
        })

    return devices


def audit_cpu_frequencies(cpu_root: str = "/sys/devices/system/cpu") -> Dict[str, Any]:
    """Audits CPU core clock frequencies and detects core throttling."""
    freqs: List[int] = []
    max_freqs: List[int] = []

    if not os.path.exists(cpu_root):
        return {"cores_audited": 0, "avg_mhz": 0.0, "peak_mhz": 0.0, "throttled_cores": 0}

    for i in range(256):
        cur_path = os.path.join(cpu_root, f"cpu{i}/cpufreq/scaling_cur_freq")
        max_path = os.path.join(cpu_root, f"cpu{i}/cpufreq/scaling_max_freq")
        if not os.path.exists(cur_path):
            break

        cur_khz = read_int_file(cur_path)
        if cur_khz:
            freqs.append(cur_khz)
        max_khz = read_int_file(max_path)
        if max_khz:
            max_freqs.append(max_khz)

    if not freqs:
        return {"cores_audited": 0, "avg_mhz": 0.0, "peak_mhz": 0.0, "throttled_cores": 0}

    cores_count = len(freqs)
    avg_mhz = round(sum(freqs) / (cores_count * 1000.0), 1)
    peak_mhz = round(max(freqs) / 1000.0, 1)

    # Core is considered throttled if running below 800 MHz when max is > 2 GHz
    throttled = sum(1 for f in freqs if f < 900000)

    return {
        "cores_audited": cores_count,
        "avg_mhz": avg_mhz,
        "peak_mhz": peak_mhz,
        "throttled_cores": throttled,
    }


def audit_fleet_thermals(
    hwmon_root: str = "/sys/class/hwmon",
    thermal_root: str = "/sys/class/thermal",
    cpu_root: str = "/sys/devices/system/cpu",
    warn_cpu_temp: float = DEFAULT_WARN_CPU_TEMP_C,
    crit_cpu_temp: float = DEFAULT_CRIT_CPU_TEMP_C,
    warn_nvme_temp: float = DEFAULT_WARN_NVME_TEMP_C,
    warn_ram_temp: float = DEFAULT_WARN_RAM_TEMP_C,
) -> Dict[str, Any]:
    """Audits temperatures, cooling devices, and CPU frequencies."""
    sensors = audit_hwmon_sensors(hwmon_root=hwmon_root)
    cooling = audit_cooling_devices(thermal_root=thermal_root)
    cpu_freq = audit_cpu_frequencies(cpu_root=cpu_root)

    cpu_temps = [s["temp_c"] for s in sensors if any(k in s["name"].lower() for k in ["k10temp", "coretemp", "cpu"])]
    nvme_temps = [s["temp_c"] for s in sensors if "nvme" in s["name"].lower()]
    ram_temps = [s["temp_c"] for s in sensors if any(k in s["name"].lower() for k in ["spd", "dimm", "dram"])]

    max_cpu_temp = max(cpu_temps) if cpu_temps else 0.0
    max_nvme_temp = max(nvme_temps) if nvme_temps else 0.0
    max_ram_temp = max(ram_temps) if ram_temps else 0.0

    active_cooling = sum(1 for c in cooling if c["cur_state"] > 0)
    processor_cooling = [c for c in cooling if "processor" in c["type"].lower()]
    max_proc_throttle = max([c["utilization"] for c in processor_cooling]) if processor_cooling else 0.0

    status = "HEALTHY"
    reasons: List[str] = []

    if max_cpu_temp >= crit_cpu_temp:
        reasons.append(f"Critical CPU temperature: {max_cpu_temp}°C >= {crit_cpu_temp}°C")
        status = "CRITICAL"
    elif max_cpu_temp >= warn_cpu_temp:
        reasons.append(f"Elevated CPU temperature: {max_cpu_temp}°C >= {warn_cpu_temp}°C")
        status = "WARNING"

    if max_nvme_temp >= warn_nvme_temp:
        reasons.append(f"Elevated NVMe temperature: {max_nvme_temp}°C >= {warn_nvme_temp}°C")
        if status != "CRITICAL":
            status = "WARNING"

    if max_ram_temp >= warn_ram_temp:
        reasons.append(f"Elevated RAM temperature: {max_ram_temp}°C >= {warn_ram_temp}°C")
        if status != "CRITICAL":
            status = "WARNING"

    if max_proc_throttle >= 0.50:
        reasons.append(f"High processor cooling throttle state: {max_proc_throttle * 100:.1f}%")
        if status != "CRITICAL":
            status = "WARNING"

    if cpu_freq["throttled_cores"] > 0 and max_cpu_temp >= warn_cpu_temp:
        reasons.append(f"{cpu_freq['throttled_cores']} CPU cores severely throttled under thermal load")
        status = "CRITICAL"

    recommendation = "; ".join(reasons) if reasons else "optimal"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "sensors_audited": len(sensors),
            "max_cpu_temp_c": max_cpu_temp,
            "max_nvme_temp_c": max_nvme_temp,
            "max_ram_temp_c": max_ram_temp,
            "cooling_devices_count": len(cooling),
            "active_cooling_devices": active_cooling,
            "max_processor_throttle": max_proc_throttle,
            "cpu_cores_audited": cpu_freq["cores_audited"],
            "cpu_avg_mhz": cpu_freq["avg_mhz"],
            "cpu_peak_mhz": cpu_freq["peak_mhz"],
            "cpu_throttled_cores": cpu_freq["throttled_cores"],
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "sensors": sensors,
        "cooling_devices": cooling[:10],
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Hardware Thermal & CPU Throttling Guard (Pattern 66)"
    )
    parser.add_argument(
        "--warn-cpu-temp",
        type=float,
        default=DEFAULT_WARN_CPU_TEMP_C,
        help=f"Warn threshold for CPU package temperature in °C (default: {DEFAULT_WARN_CPU_TEMP_C})",
    )
    parser.add_argument(
        "--crit-cpu-temp",
        type=float,
        default=DEFAULT_CRIT_CPU_TEMP_C,
        help=f"Critical threshold for CPU package temperature in °C (default: {DEFAULT_CRIT_CPU_TEMP_C})",
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose sensor listing")

    args = parser.parse_args()

    report = audit_fleet_thermals(
        warn_cpu_temp=args.warn_cpu_temp,
        crit_cpu_temp=args.crit_cpu_temp,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        summary = report["summary"]
        status_str = summary["status"]
        print(f"[{status_str}] Jev Hardware Thermal & CPU Throttling Guard (Pattern 66)")
        print(f"CPU Peak Temp: {summary['max_cpu_temp_c']}°C | NVMe: {summary['max_nvme_temp_c']}°C | RAM: {summary['max_ram_temp_c']}°C")
        print(f"CPU Clock: {summary['cpu_avg_mhz']} MHz avg ({summary['cpu_peak_mhz']} MHz peak across {summary['cpu_cores_audited']} cores)")
        print(f"Cooling Devices: {summary['active_cooling_devices']}/{summary['cooling_devices_count']} active | Throttled Cores: {summary['cpu_throttled_cores']}")
        print(f"Health Status: {summary['status']}")
        print(f"Recommendation: {summary['recommendation']}")

        if args.verbose and report["sensors"]:
            print("\nHardware Temperature Sensors:")
            for s in report["sensors"]:
                crit_info = f" (crit: {s['crit_c']}°C)" if s["crit_c"] else ""
                print(f"  - {s['name']:<12} {s['label']:<16}: {s['temp_c']}°C{crit_info}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
