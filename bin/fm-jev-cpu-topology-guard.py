#!/usr/bin/env python3
"""
bin/fm-jev-cpu-topology-guard.py - Linux CPU Topology, SMT & Offline Processor Guard (Pattern 322 / Pattern 460)

Audits Linux kernel CPU system devices (/sys/devices/system/cpu/*) to detect offline
processors (/sys/devices/system/cpu/offline), SMT multithreading state (/sys/devices/system/cpu/smt/*),
isolated CPU cores (/sys/devices/system/cpu/isolated), and physical socket/die/core topology
to detect unexpected hardware core drops, thermal fault deactivations, or SMT regressions.

Invariants:
  - Warning if any CPU cores are offline.
  - Fail-open: graceful fallback when sysfs paths are restricted or in containers.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

SYSFS_CPU_DIR = "/sys/devices/system/cpu"


def read_sysfs_text(path: Path) -> str:
    """Reads stripped text from a sysfs attribute."""
    if not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        return ""


def parse_cpu_range(range_str: str) -> List[int]:
    """Parses a CPU list string (e.g. '0-3,5,7-9') into integer list."""
    if not range_str:
        return []
    res: List[int] = []
    for part in range_str.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            try:
                start, end = part.split("-", 1)
                res.extend(range(int(start), int(end) + 1))
            except ValueError:
                continue
        else:
            try:
                res.append(int(part))
            except ValueError:
                continue
    return sorted(res)


def evaluate_cpu_topology(
    cpu_dir: str = SYSFS_CPU_DIR,
    warn_on_offline: bool = True,
    warn_on_smt_disabled: bool = False,
) -> Dict[str, Any]:
    c_path = Path(cpu_dir)
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not c_path.is_dir():
        return {
            "pattern": 322,
            "name": "cpu_topology",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "HEALTHY",
            "healthy": True,
            "is_topology_healthy": True,
            "total_cpus": 0,
            "online_cpus": 0,
            "offline_cpus": 0,
            "isolated_cpus": 0,
            "physical_cores": 0,
            "dies": 0,
            "sockets": 0,
            "smt_active": None,
            "smt_control": None,
            "online_range": "",
            "offline_range": "",
            "issues": [],
            "recommendations": [
                "CPU sysfs directory not found; running in virtualized or containerized environment."
            ],
        }

    online_raw = read_sysfs_text(c_path / "online")
    offline_raw = read_sysfs_text(c_path / "offline")
    isolated_raw = read_sysfs_text(c_path / "isolated")

    online_cpus = parse_cpu_range(online_raw)
    offline_cpus = parse_cpu_range(offline_raw)
    isolated_cpus = parse_cpu_range(isolated_raw)

    smt_dir = c_path / "smt"
    smt_active_raw = read_sysfs_text(smt_dir / "active")
    smt_control_raw = read_sysfs_text(smt_dir / "control")
    smt_active = (smt_active_raw == "1") if smt_active_raw else None

    packages: Set[str] = set()
    dies: Set[str] = set()
    physical_cores: Set[str] = set()
    enumerated_cpus: List[int] = []

    for c_entry in sorted(c_path.iterdir()):
        if c_entry.is_dir() and re.match(r"^cpu\d+$", c_entry.name):
            cpuid = int(c_entry.name[3:])
            enumerated_cpus.append(cpuid)
            top = c_entry / "topology"
            pkg_id = read_sysfs_text(top / "physical_package_id") or "0"
            die_id = read_sysfs_text(top / "die_id") or "0"
            core_id = read_sysfs_text(top / "core_id") or str(cpuid)
            packages.add(pkg_id)
            dies.add(f"{pkg_id}:{die_id}")
            physical_cores.add(f"{pkg_id}:{die_id}:{core_id}")

    is_warning = False

    if offline_cpus and warn_on_offline:
        is_warning = True
        issues.append(
            f"{len(offline_cpus)} CPU core(s) are OFFLINE: {offline_raw} "
            "(potential hardware fault, thermal trip, or manual disablement)"
        )
        recommendations.append(
            "Inspect dmesg for MCE/thermal events and bring offline CPUs back online via sysfs."
        )

    if smt_active is False and warn_on_smt_disabled:
        is_warning = True
        issues.append(f"CPU Simultaneous Multithreading (SMT) is inactive (control: '{smt_control_raw}')")
        recommendations.append("Verify BIOS SMT setting or enable via /sys/devices/system/cpu/smt/control.")

    if isolated_cpus:
        recommendations.append(
            f"{len(isolated_cpus)} core(s) isolated from general scheduler ({isolated_raw})"
        )

    if not offline_cpus and not issues:
        recommendations.append(
            f"All {len(online_cpus)} CPU thread(s) across {len(physical_cores)} physical core(s), "
            f"{len(dies)} die(s), and {len(packages)} socket(s) are online and healthy"
        )

    status = "WARNING" if is_warning else "HEALTHY"
    healthy = (status == "HEALTHY")
    is_topology_healthy = healthy

    return {
        "pattern": 322,
        "name": "cpu_topology",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_topology_healthy": is_topology_healthy,
        "total_cpus": len(enumerated_cpus),
        "online_cpus": len(online_cpus),
        "offline_cpus": len(offline_cpus),
        "isolated_cpus": len(isolated_cpus),
        "physical_cores": len(physical_cores),
        "dies": len(dies),
        "sockets": len(packages),
        "smt_active": smt_active,
        "smt_control": smt_control_raw or None,
        "online_range": online_raw,
        "offline_range": offline_raw,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux CPU topology, offline processors, and SMT multithreading state."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--cpu-dir", default=SYSFS_CPU_DIR, help=f"Path to CPU sysfs (default: {SYSFS_CPU_DIR})")
    parser.add_argument("--warn-on-smt-disabled", action="store_true", help="Warn if SMT is disabled")
    parser.add_argument("--ignore-offline", action="store_true", help="Do not warn on offline CPU cores")

    args = parser.parse_args()

    result = evaluate_cpu_topology(
        cpu_dir=args.cpu_dir,
        warn_on_offline=not args.ignore_offline,
        warn_on_smt_disabled=args.warn_on_smt_disabled,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 322 (cpu_topology): {result['status']}")
        print(
            f"  CPUs: {result['online_cpus']}/{result['total_cpus']} online | "
            f"Physical Cores: {result['physical_cores']} | Sockets: {result['sockets']} | Dies: {result['dies']}"
        )
        smt_str = "active" if result["smt_active"] else ("disabled" if result["smt_active"] is False else "N/A")
        print(f"  SMT: {smt_str} (control: {result['smt_control'] or 'N/A'})")
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
