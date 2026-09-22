#!/usr/bin/env python3
"""
fm-jev-cgroup-guard.py - Jev Multi-Agent Kernel Cgroup v2 Memory & PID Controller Throttling Guard (Pattern 76)

Audits Linux Cgroup v2 memory controllers, task/PID limits, pressure stall information (PSI),
and cgroup-level OOM / reclaim events across multi-agent slices (/sys/fs/cgroup/). Detects cgroup
PID exhaustion and memory reclamation stalls before tasks get throttled or killed by cgroup limits.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback when Cgroups v2 is unavailable or non-standard.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_PID_PCT = 60.0
DEFAULT_CRIT_PID_PCT = 85.0
DEFAULT_WARN_MEM_PRESSURE = 10.0
DEFAULT_CRIT_MEM_PRESSURE = 40.0

CGROUP_ROOT = "/sys/fs/cgroup"
PROC_SELF_CGROUP = "/proc/self/cgroup"


def read_cgroup_file(path: str) -> Optional[str]:
    """Reads a cgroup file safely."""
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            return f.read().strip()
    except Exception:
        return None


def read_cgroup_int(path: str) -> Optional[int]:
    """Reads integer value from a cgroup file, returning None if 'max' or unreadable."""
    val = read_cgroup_file(path)
    if val is None or val == "max":
        return None
    try:
        return int(val)
    except ValueError:
        return None


def parse_pressure_file(path: str) -> Dict[str, Dict[str, float]]:
    """
    Parses PSI file (memory.pressure, cpu.pressure, io.pressure).
    Format:
      some avg10=0.00 avg60=0.04 avg300=0.12 total=3646371367
      full avg10=0.00 avg60=0.04 avg300=0.12 total=3143449402
    """
    result: Dict[str, Dict[str, float]] = {
        "some": {"avg10": 0.0, "avg60": 0.0, "avg300": 0.0},
        "full": {"avg10": 0.0, "avg60": 0.0, "avg300": 0.0},
    }
    content = read_cgroup_file(path)
    if not content:
        return result

    for line in content.splitlines():
        parts = line.split()
        if not parts:
            continue
        tier = parts[0]
        if tier in result:
            for kv in parts[1:]:
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    if k in result[tier]:
                        try:
                            result[tier][k] = float(v)
                        except ValueError:
                            pass
    return result


def parse_events_file(path: str) -> Dict[str, int]:
    """
    Parses key-value events file (memory.events, pids.events).
    """
    result: Dict[str, int] = {}
    content = read_cgroup_file(path)
    if not content:
        return result

    for line in content.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            try:
                result[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return result


def resolve_cgroup_target(cgroup_root: str = CGROUP_ROOT, proc_cgroup: str = PROC_SELF_CGROUP) -> str:
    """Resolves the most relevant cgroup directory (scope, slice, or root)."""
    if not os.path.exists(proc_cgroup):
        return cgroup_root

    target_dir = cgroup_root
    try:
        with open(proc_cgroup, "r") as f:
            for line in f:
                parts = line.strip().split(":", 2)
                if len(parts) == 3 and parts[0] == "0":
                    rel_path = parts[2].lstrip("/")
                    candidate = os.path.join(cgroup_root, rel_path)
                    if os.path.isdir(candidate):
                        # Try to find slice level if inside a transient scope
                        parent = os.path.dirname(candidate)
                        if os.path.basename(parent).endswith(".slice") and os.path.isdir(parent):
                            target_dir = parent
                        else:
                            target_dir = candidate
                        break
    except Exception:
        pass

    return target_dir


def audit_cgroup(
    cgroup_dir: Optional[str] = None,
    cgroup_root: str = CGROUP_ROOT,
    proc_cgroup: str = PROC_SELF_CGROUP,
    warn_pid_pct: float = DEFAULT_WARN_PID_PCT,
    crit_pid_pct: float = DEFAULT_CRIT_PID_PCT,
    warn_mem_pressure: float = DEFAULT_WARN_MEM_PRESSURE,
    crit_mem_pressure: float = DEFAULT_CRIT_MEM_PRESSURE,
) -> Dict[str, Any]:
    """Audits cgroup v2 controllers and assesses health."""
    if not cgroup_dir:
        cgroup_dir = resolve_cgroup_target(cgroup_root=cgroup_root, proc_cgroup=proc_cgroup)

    mem_current = read_cgroup_int(os.path.join(cgroup_dir, "memory.current"))
    mem_max = read_cgroup_int(os.path.join(cgroup_dir, "memory.max"))
    mem_high = read_cgroup_int(os.path.join(cgroup_dir, "memory.high"))
    mem_events = parse_events_file(os.path.join(cgroup_dir, "memory.events"))
    mem_psi = parse_pressure_file(os.path.join(cgroup_dir, "memory.pressure"))

    pids_current = read_cgroup_int(os.path.join(cgroup_dir, "pids.current"))
    pids_max = read_cgroup_int(os.path.join(cgroup_dir, "pids.max"))
    pids_events = parse_events_file(os.path.join(cgroup_dir, "pids.events"))

    cpu_psi = parse_pressure_file(os.path.join(cgroup_dir, "cpu.pressure"))
    io_psi = parse_pressure_file(os.path.join(cgroup_dir, "io.pressure"))

    # Saturation calculations
    pid_sat_pct = None
    if pids_current is not None and pids_max is not None and pids_max > 0:
        pid_sat_pct = round((pids_current / pids_max) * 100.0, 2)

    mem_sat_pct = None
    if mem_current is not None and mem_max is not None and mem_max > 0:
        mem_sat_pct = round((mem_current / mem_max) * 100.0, 2)

    mem_pressure_some_10 = mem_psi["some"]["avg10"]

    issues: List[str] = []
    status = "HEALTHY"

    if pid_sat_pct is not None and pid_sat_pct >= crit_pid_pct:
        issues.append(f"Cgroup PID saturation critical: {pid_sat_pct}% of {pids_max} limit")
        status = "CRITICAL"
    elif pid_sat_pct is not None and pid_sat_pct >= warn_pid_pct:
        issues.append(f"Cgroup PID saturation elevated: {pid_sat_pct}% of {pids_max} limit")
        status = "WARNING"

    if mem_pressure_some_10 >= crit_mem_pressure:
        issues.append(f"Cgroup memory pressure stall critical: avg10={mem_pressure_some_10}%")
        status = "CRITICAL"
    elif mem_pressure_some_10 >= warn_mem_pressure:
        issues.append(f"Cgroup memory pressure stall elevated: avg10={mem_pressure_some_10}%")
        if status != "CRITICAL":
            status = "WARNING"

    if mem_sat_pct is not None and mem_sat_pct >= 95.0:
        issues.append(f"Cgroup memory limit critical: {mem_sat_pct}% of limit")
        status = "CRITICAL"
    elif mem_sat_pct is not None and mem_sat_pct >= 85.0:
        issues.append(f"Cgroup memory limit elevated: {mem_sat_pct}% of limit")
        if status != "CRITICAL":
            status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cgroup_path": cgroup_dir,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "pids_current": pids_current,
            "pids_max": pids_max if pids_max is not None else "max",
            "pid_saturation_pct": pid_sat_pct,
            "memory_current_bytes": mem_current,
            "memory_max_bytes": mem_max if mem_max is not None else "max",
            "memory_saturation_pct": mem_sat_pct,
            "memory_pressure_avg10": mem_pressure_some_10,
            "memory_oom_kill_count": mem_events.get("oom_kill", 0),
            "memory_high_events": mem_events.get("high", 0),
            "issues": issues,
        },
        "pressure": {
            "memory": mem_psi,
            "cpu": cpu_psi,
            "io": io_psi,
        },
        "events": {
            "memory": mem_events,
            "pids": pids_events,
        },
    }


def format_bytes(num_bytes: Optional[int]) -> str:
    """Formats bytes into human-readable string."""
    if num_bytes is None:
        return "unlimited (max)"
    b = float(num_bytes)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(b) < 1024.0:
            return f"{b:3.2f} {unit}"
        b /= 1024.0
    return f"{b:.2f} PB"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Kernel Cgroup v2 Memory & PID Controller Throttling Guard (Pattern 76)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--cgroup-dir", type=str, default=None, help="Target cgroup directory (default: auto-detect from /proc/self/cgroup)")
    parser.add_argument("--cgroup-root", type=str, default=CGROUP_ROOT, help="Path to /sys/fs/cgroup")
    parser.add_argument("--proc-cgroup", type=str, default=PROC_SELF_CGROUP, help="Path to /proc/self/cgroup")
    parser.add_argument("--warn-pid-pct", type=float, default=DEFAULT_WARN_PID_PCT, help=f"Warning PID saturation pct (default {DEFAULT_WARN_PID_PCT})")
    parser.add_argument("--crit-pid-pct", type=float, default=DEFAULT_CRIT_PID_PCT, help=f"Critical PID saturation pct (default {DEFAULT_CRIT_PID_PCT})")
    parser.add_argument("--warn-mem-pressure", type=float, default=DEFAULT_WARN_MEM_PRESSURE, help=f"Warning memory pressure avg10 pct (default {DEFAULT_WARN_MEM_PRESSURE})")
    parser.add_argument("--crit-mem-pressure", type=float, default=DEFAULT_CRIT_MEM_PRESSURE, help=f"Critical memory pressure avg10 pct (default {DEFAULT_CRIT_MEM_PRESSURE})")

    args = parser.parse_args()

    result = audit_cgroup(
        cgroup_dir=args.cgroup_dir,
        cgroup_root=args.cgroup_root,
        proc_cgroup=args.proc_cgroup,
        warn_pid_pct=args.warn_pid_pct,
        crit_pid_pct=args.crit_pid_pct,
        warn_mem_pressure=args.warn_mem_pressure,
        crit_mem_pressure=args.crit_mem_pressure,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Kernel Cgroup v2 Controller Guard (Pattern 76)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Target Cgroup:          {result['cgroup_path']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    pid_sat_str = f" ({summary['pid_saturation_pct']}%)" if summary['pid_saturation_pct'] is not None else ""
    print(f" PIDs (Tasks/Threads):   {summary['pids_current']} / {summary['pids_max']}{pid_sat_str}")
    mem_sat_str = f" ({summary['memory_saturation_pct']}%)" if summary['memory_saturation_pct'] is not None else ""
    print(f" Memory Usage:           {format_bytes(summary['memory_current_bytes'])} / {format_bytes(summary['memory_max_bytes'] if summary['memory_max_bytes'] != 'max' else None)}{mem_sat_str}")
    print(f" Memory Pressure (PSI):  avg10={summary['memory_pressure_avg10']:.2f}% (some)")
    print(f" OOM Kills / High Evts:  {summary['memory_oom_kill_count']} / {summary['memory_high_events']}")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo cgroup memory pressure stalls or PID limits reached.")
    print("================================================================================")


if __name__ == "__main__":
    main()
