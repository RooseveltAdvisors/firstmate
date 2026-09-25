#!/usr/bin/env python3
"""
bin/fm-jev-cpufreq-guard.py - Linux CPU Frequency Scaling, Governor & Boost Health Guard (Pattern 321 / Pattern 459)

Audits Linux kernel CPU frequency scaling subsystem (/sys/devices/system/cpu/cpu*/cpufreq/)
including active scaling governors, drivers (amd-pstate-epp, intel_pstate, acpi-cpufreq),
energy performance preferences (EPP), per-core clock frequencies, and hardware turbo boost
to detect CPU power-throttling, thermal frequency lockups, and governor misconfigurations
that degrade multi-agent compute throughput.

Invariants:
  - Warning if heterogeneous governors detected across active cores (asymmetric scheduling).
  - Warning if all cores clamped at minimum frequency (thermal / power throttle lock).
  - Fail-open: graceful fallback when sysfs paths are restricted or in containers.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

SYS_CPU_BASE = "/sys/devices/system/cpu"
SYS_CPUFREQ_DIR = "/sys/devices/system/cpu/cpufreq"


def read_sysfs_text(path: Path) -> str:
    """Reads stripped text from a sysfs attribute."""
    if not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        return ""


def read_sysfs_int(path: Path, default: int = 0) -> int:
    """Reads integer value from a sysfs attribute."""
    val = read_sysfs_text(path)
    if not val:
        return default
    try:
        return int(val)
    except ValueError:
        return default


def evaluate_cpufreq(
    base_cpu_dir: str = SYS_CPU_BASE,
    global_cpufreq_dir: str = SYS_CPUFREQ_DIR,
    warn_on_governor_mismatch: bool = True,
    warn_on_boost_disabled: bool = False,
) -> Dict[str, Any]:
    base_path = Path(base_cpu_dir)
    global_cpufreq_path = Path(global_cpufreq_dir)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not base_path.is_dir():
        return {
            "pattern": 321,
            "name": "cpufreq",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "HEALTHY",
            "healthy": True,
            "is_cpufreq_healthy": True,
            "total_cpus": 0,
            "cpufreq_cores": 0,
            "governors": [],
            "drivers": [],
            "energy_performance_preferences": [],
            "avg_cur_freq_mhz": 0.0,
            "min_cur_freq_mhz": 0.0,
            "max_cur_freq_mhz": 0.0,
            "boost_enabled": None,
            "issues": [],
            "recommendations": [
                "CPU sysfs directory not found; running in virtualized or containerized environment."
            ],
        }

    cpu_dirs = sorted(
        [
            p
            for p in base_path.iterdir()
            if p.is_dir() and p.name.startswith("cpu") and p.name[3:].isdigit()
        ],
        key=lambda p: int(p.name[3:]),
    )

    governors: Set[str] = set()
    drivers: Set[str] = set()
    epp_prefs: Set[str] = set()
    cur_freqs: List[int] = []
    min_freqs: List[int] = []
    max_freqs: List[int] = []
    boost_states: List[int] = []

    cpufreq_cores = 0

    for cpu_dir in cpu_dirs:
        cpufreq_dir = cpu_dir / "cpufreq"
        if not cpufreq_dir.is_dir():
            continue

        cpufreq_cores += 1

        gov = read_sysfs_text(cpufreq_dir / "scaling_governor")
        if gov:
            governors.add(gov)

        drv = read_sysfs_text(cpufreq_dir / "scaling_driver")
        if drv:
            drivers.add(drv)

        epp = read_sysfs_text(cpufreq_dir / "energy_performance_preference")
        if epp:
            epp_prefs.add(epp)

        cur_f = read_sysfs_int(cpufreq_dir / "scaling_cur_freq")
        if cur_f > 0:
            cur_freqs.append(cur_f)

        min_f = read_sysfs_int(cpufreq_dir / "scaling_min_freq")
        if min_f > 0:
            min_freqs.append(min_f)

        max_f = read_sysfs_int(cpufreq_dir / "scaling_max_freq")
        if max_f > 0:
            max_freqs.append(max_f)

        boost_file = cpufreq_dir / "boost"
        if boost_file.is_file():
            boost_states.append(read_sysfs_int(boost_file))

    # Check global boost if per-core boost files are absent
    global_boost_file = global_cpufreq_path / "boost"
    if not boost_states and global_boost_file.is_file():
        boost_states.append(read_sysfs_int(global_boost_file))

    if cpufreq_cores == 0:
        return {
            "pattern": 321,
            "name": "cpufreq",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "HEALTHY",
            "healthy": True,
            "is_cpufreq_healthy": True,
            "total_cpus": len(cpu_dirs),
            "cpufreq_cores": 0,
            "governors": [],
            "drivers": [],
            "energy_performance_preferences": [],
            "avg_cur_freq_mhz": 0.0,
            "min_cur_freq_mhz": 0.0,
            "max_cur_freq_mhz": 0.0,
            "boost_enabled": None,
            "issues": [],
            "recommendations": [
                "No cpufreq scaling interface exposed for CPU cores (fixed frequency or virtualized host)."
            ],
        }

    is_warning = False

    # Check for governor divergence across cores
    if len(governors) > 1 and warn_on_governor_mismatch:
        is_warning = True
        issues.append(
            f"Heterogeneous CPU frequency governors detected across cores: {sorted(governors)}; "
            f"risk of asymmetric core compute throughput"
        )
        recommendations.append(
            f"Harmonize CPU scaling governors across all {cpufreq_cores} cores using cpupower."
        )

    # Check for hardware boost state
    boost_enabled: Optional[bool] = None
    if boost_states:
        boost_enabled = all(b == 1 for b in boost_states)
        if not boost_enabled and warn_on_boost_disabled:
            is_warning = True
            issues.append("CPU hardware turbo boost is disabled across one or more cores")
            recommendations.append(
                "Enable turbo boost via /sys/devices/system/cpu/cpufreq/boost or BIOS settings if compute headroom is constrained."
            )

    # Frequency calculations (convert kHz to MHz)
    avg_cur_mhz = (sum(cur_freqs) / len(cur_freqs) / 1000.0) if cur_freqs else 0.0
    min_cur_mhz = (min(cur_freqs) / 1000.0) if cur_freqs else 0.0
    max_cur_mhz = (max(cur_freqs) / 1000.0) if cur_freqs else 0.0

    # Check for severe throttling lockup (cur_freq <= min_freq across all cores)
    if cur_freqs and min_freqs and len(cur_freqs) == len(min_freqs):
        clamped_count = sum(1 for c, m in zip(cur_freqs, min_freqs) if c <= m)
        if clamped_count == len(cur_freqs) and len(cur_freqs) > 1:
            is_warning = True
            issues.append(
                f"All {clamped_count} CPU cores are clamped at minimum frequency ({min_cur_mhz:.1f} MHz); "
                f"potential thermal or power throttle lock"
            )
            recommendations.append(
                "Inspect host thermals, cooling fan RPM, and dmesg thermal throttling events."
            )

    if is_warning:
        status = "WARNING"

    healthy = (status == "HEALTHY")
    is_cpufreq_healthy = healthy

    return {
        "pattern": 321,
        "name": "cpufreq",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_cpufreq_healthy": is_cpufreq_healthy,
        "total_cpus": len(cpu_dirs),
        "cpufreq_cores": cpufreq_cores,
        "governors": sorted(governors),
        "drivers": sorted(drivers),
        "energy_performance_preferences": sorted(epp_prefs),
        "avg_cur_freq_mhz": round(avg_cur_mhz, 2),
        "min_cur_freq_mhz": round(min_cur_mhz, 2),
        "max_cur_freq_mhz": round(max_cur_mhz, 2),
        "boost_enabled": boost_enabled,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux CPU frequency scaling governors, drivers, and clock frequencies."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--base-cpu-dir", default=SYS_CPU_BASE, help=f"Path to CPU sysfs (default: {SYS_CPU_BASE})")
    parser.add_argument("--cpufreq-dir", default=SYS_CPUFREQ_DIR, help=f"Path to cpufreq sysfs (default: {SYS_CPUFREQ_DIR})")
    parser.add_argument("--warn-on-boost-disabled", action="store_true", help="Warn if turbo boost is disabled")
    parser.add_argument("--ignore-governor-mismatch", action="store_true", help="Do not warn on heterogeneous governors")

    args = parser.parse_args()

    result = evaluate_cpufreq(
        base_cpu_dir=args.base_cpu_dir,
        global_cpufreq_dir=args.cpufreq_dir,
        warn_on_governor_mismatch=not args.ignore_governor_mismatch,
        warn_on_boost_disabled=args.warn_on_boost_disabled,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 321 (cpufreq): {result['status']}")
        print(
            f"  CPUs: {result['cpufreq_cores']}/{result['total_cpus']} active cpufreq cores | "
            f"Avg Clock: {result['avg_cur_freq_mhz']} MHz [{result['min_cur_freq_mhz']} - {result['max_cur_freq_mhz']} MHz]"
        )
        print(
            f"  Governors: {', '.join(result['governors']) or 'none'} | "
            f"Drivers: {', '.join(result['drivers']) or 'none'} | "
            f"EPP: {', '.join(result['energy_performance_preferences']) or 'none'}"
        )
        boost_str = "enabled" if result["boost_enabled"] is True else ("disabled" if result["boost_enabled"] is False else "N/A")
        print(f"  Turbo Boost: {boost_str}")
        if result["issues"]:
            print("  Issues:")
            for iss in result["issues"]:
                print(f"    - {iss}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
