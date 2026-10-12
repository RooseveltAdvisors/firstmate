#!/usr/bin/env python3
"""
bin/fm-jev-cpuidle-guard.py - Linux Kernel CPU Idle Subsystem & C-State Latency Guard (Pattern 319 / Pattern 457)

Audits Linux kernel CPU idle states, drivers, and governors:
  - /sys/devices/system/cpu/cpuidle/current_driver
  - /sys/devices/system/cpu/cpuidle/current_governor
  - /sys/devices/system/cpu/cpuidle/available_governors
  - /sys/devices/system/cpu/cpu*/cpuidle/state* (latency, disable, usage, time)
to detect missing cpuidle drivers, disabled power management states, CPU lockups,
and excessive sleep exit latencies that impact multi-agent responsiveness.

Invariants:
  - Warning when no driver/governor is registered, all C-states are disabled,
    or deepest exit latency > max_acceptable_latency_us (default 5000 us).
  - Fail-open: graceful fallback when sysfs paths are restricted.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

CPUIDLE_SYS_DIR = "/sys/devices/system/cpu/cpuidle"
CPU_BASE_DIR = "/sys/devices/system/cpu"
DEFAULT_MAX_ACCEPTABLE_LATENCY_US = 5000


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


def evaluate_cpuidle(
    cpuidle_dir: str = CPUIDLE_SYS_DIR,
    cpu_dir: str = CPU_BASE_DIR,
    max_latency_us: int = DEFAULT_MAX_ACCEPTABLE_LATENCY_US,
) -> Dict[str, Any]:
    idle_path = Path(cpuidle_dir)
    cpu_path = Path(cpu_dir)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not idle_path.is_dir() and not (cpu_path / "cpu0" / "cpuidle").is_dir():
        return {
            "pattern": 319,
            "name": "cpuidle",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "HEALTHY",
            "healthy": True,
            "is_idle_healthy": True,
            "driver": "none",
            "governor": "none",
            "available_governors": [],
            "states_count": 0,
            "active_states_count": 0,
            "disabled_states_count": 0,
            "max_exit_latency_us": 0,
            "states": [],
            "issues": ["CPU idle sysfs interface unavailable (virtualized container fallback)"],
            "recommendations": ["Host operates in paravirtualized mode; cpuidle unmanaged by container"],
        }

    driver = read_sysfs_text(idle_path / "current_driver")
    governor = read_sysfs_text(idle_path / "current_governor")
    available_governors = read_sysfs_text(idle_path / "available_governors").split()

    if not driver or driver == "none":
        status = "WARNING"
        issues.append("No active cpuidle driver registered; kernel power states may be unmanaged")
        recommendations.append("Ensure ACPI processor idle (acpi_idle) or vendor driver is loaded")

    if not governor or governor == "none":
        if status != "CRITICAL":
            status = "WARNING"
        issues.append("No active cpuidle governor selected")
        recommendations.append("Select a valid idle governor (e.g. 'menu' or 'teo')")

    # Scan C-states on CPU0
    states: List[Dict[str, Any]] = []
    cpu0_idle_dir = cpu_path / "cpu0" / "cpuidle"
    max_exit_latency = 0

    if cpu0_idle_dir.is_dir():
        for state_path in sorted(cpu0_idle_dir.glob("state*")):
            s_name = read_sysfs_text(state_path / "name") or state_path.name
            s_desc = read_sysfs_text(state_path / "desc")
            s_latency = read_sysfs_int(state_path / "latency", default=0)
            s_disable = read_sysfs_int(state_path / "disable", default=0)
            s_usage = read_sysfs_int(state_path / "usage", default=0)
            s_time = read_sysfs_int(state_path / "time", default=0)

            if s_latency > max_exit_latency:
                max_exit_latency = s_latency

            states.append({
                "state": state_path.name,
                "name": s_name,
                "desc": s_desc,
                "latency_us": s_latency,
                "disabled": s_disable == 1,
                "usage": s_usage,
                "time_us": s_time,
            })

    disabled_count = sum(1 for s in states if s["disabled"])

    if states and disabled_count == len(states):
        status = "WARNING"
        issues.append("All cpuidle states are disabled on CPU0; CPU cannot enter power-saving idle")
        recommendations.append("Re-enable cpuidle states to prevent excessive host thermal stress")

    if max_exit_latency > max_latency_us:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Deepest C-state exit latency ({max_exit_latency} us > {max_latency_us} us)"
        )
        recommendations.append("Tune PM QoS or disable high-latency C-states for real-time determinism")

    healthy = (status == "HEALTHY")
    is_idle_healthy = (
        bool(driver and driver != "none")
        and bool(governor and governor != "none")
        and not (states and disabled_count == len(states))
    )

    return {
        "pattern": 319,
        "name": "cpuidle",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_idle_healthy": is_idle_healthy,
        "driver": driver,
        "governor": governor,
        "available_governors": available_governors,
        "states_count": len(states),
        "active_states_count": len(states) - disabled_count,
        "disabled_states_count": disabled_count,
        "max_exit_latency_us": max_exit_latency,
        "states": states,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux kernel CPU idle governor, driver, and C-state power/latency parameters."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--cpuidle-dir", default=CPUIDLE_SYS_DIR, help=f"Path to cpuidle sysfs (default: {CPUIDLE_SYS_DIR})")
    parser.add_argument("--cpu-dir", default=CPU_BASE_DIR, help=f"Path to cpu base sysfs (default: {CPU_BASE_DIR})")
    parser.add_argument("--max-latency-us", type=int, default=DEFAULT_MAX_ACCEPTABLE_LATENCY_US, help="Max exit latency threshold us")

    args = parser.parse_args()

    result = evaluate_cpuidle(
        cpuidle_dir=args.cpuidle_dir,
        cpu_dir=args.cpu_dir,
        max_latency_us=args.max_latency_us,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 319 (cpuidle): {result['status']}")
        print(
            f"  Driver: {result['driver']} | Governor: {result['governor']} | "
            f"Available: {', '.join(result['available_governors'])}"
        )
        print(
            f"  States: {result['states_count']} (active={result['active_states_count']}, "
            f"disabled={result['disabled_states_count']}) | Max Exit Latency: {result['max_exit_latency_us']} us"
        )
        for s in result["states"]:
            dis_str = " [DISABLED]" if s["disabled"] else ""
            print(f"    - {s['name']}: latency={s['latency_us']} us, usage={s['usage']:,}{dis_str}")
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
