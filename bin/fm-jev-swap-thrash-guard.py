#!/usr/bin/env python3
"""
fm-jev-swap-thrash-guard.py - Jev Multi-Agent Swap I/O Thrashing & Major Page Fault Stall Guard (Pattern 79)

Audits Linux kernel memory swap saturation (/proc/meminfo), swap-in/out I/O activity and major page fault
stalls (/proc/vmstat: pswpin, pswpout, pgmajfault, oom_kill), and real-time kernel memory pressure stalls
(/proc/pressure/memory: some/full avg10) to prevent thread freezing, API timeouts, and test runner stalls
during memory-intensive multi-agent compilation, inference, and test execution.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback on systems without PSI or non-standard procfs.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

DEFAULT_WARN_SWAP_SAT_PCT = 85.0
DEFAULT_CRIT_SWAP_SAT_PCT = 95.0
DEFAULT_WARN_PSI_SOME = 10.0
DEFAULT_CRIT_PSI_SOME = 30.0
DEFAULT_WARN_PSI_FULL = 5.0
DEFAULT_CRIT_PSI_FULL = 15.0

PROC_VMSTAT = "/proc/vmstat"
PROC_MEMINFO = "/proc/meminfo"
PROC_PRESSURE_MEM = "/proc/pressure/memory"


def parse_vmstat(path: str = PROC_VMSTAT) -> Dict[str, int]:
    """Parses /proc/vmstat key-value counters."""
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        counters[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass
    return counters


def parse_meminfo(path: str = PROC_MEMINFO) -> Dict[str, int]:
    """Parses /proc/meminfo into kB dictionary."""
    mem: Dict[str, int] = {}
    if not os.path.exists(path):
        return mem
    try:
        with open(path, "r") as f:
            for line in f:
                parts = line.split(":")
                if len(parts) >= 2:
                    k = parts[0].strip()
                    v = parts[1].strip().split()[0]
                    try:
                        mem[k] = int(v)
                    except ValueError:
                        pass
    except Exception:
        pass
    return mem


def parse_psi_memory(path: str = PROC_PRESSURE_MEM) -> Dict[str, Dict[str, float]]:
    """Parses /proc/pressure/memory for some and full pressure percentages."""
    pressure: Dict[str, Dict[str, float]] = {
        "some": {"avg10": 0.0, "avg60": 0.0, "avg300": 0.0, "total": 0.0},
        "full": {"avg10": 0.0, "avg60": 0.0, "avg300": 0.0, "total": 0.0},
    }
    if not os.path.exists(path):
        return pressure

    try:
        with open(path, "r") as f:
            for line in f:
                parts = line.split()
                if not parts:
                    continue
                metric_type = parts[0]  # 'some' or 'full'
                if metric_type in pressure:
                    for field in parts[1:]:
                        if "=" in field:
                            k, v = field.split("=", 1)
                            try:
                                pressure[metric_type][k] = float(v)
                            except ValueError:
                                pass
    except Exception:
        pass
    return pressure


def audit_swap_thrashing(
    vmstat_path: str = PROC_VMSTAT,
    meminfo_path: str = PROC_MEMINFO,
    psi_path: str = PROC_PRESSURE_MEM,
    warn_swap_pct: float = DEFAULT_WARN_SWAP_SAT_PCT,
    crit_swap_pct: float = DEFAULT_CRIT_SWAP_SAT_PCT,
    warn_psi_some: float = DEFAULT_WARN_PSI_SOME,
    crit_psi_some: float = DEFAULT_CRIT_PSI_SOME,
    warn_psi_full: float = DEFAULT_WARN_PSI_FULL,
    crit_psi_full: float = DEFAULT_CRIT_PSI_FULL,
) -> Dict[str, Any]:
    """Audits swap usage, major page faults, and real-time kernel memory pressure stalls."""
    vm = parse_vmstat(vmstat_path)
    mem = parse_meminfo(meminfo_path)
    psi = parse_psi_memory(psi_path)

    swap_total_kb = mem.get("SwapTotal", 0)
    swap_free_kb = mem.get("SwapFree", 0)
    swap_cached_kb = mem.get("SwapCached", 0)
    swap_used_kb = swap_total_kb - swap_free_kb if swap_total_kb >= swap_free_kb else 0

    swap_total_mb = round(swap_total_kb / 1024.0, 2)
    swap_free_mb = round(swap_free_kb / 1024.0, 2)
    swap_used_mb = round(swap_used_kb / 1024.0, 2)
    swap_cached_mb = round(swap_cached_kb / 1024.0, 2)

    swap_sat_pct = round((swap_used_kb / swap_total_kb * 100.0), 2) if swap_total_kb > 0 else 0.0

    pswpin = vm.get("pswpin", 0)
    pswpout = vm.get("pswpout", 0)
    pgfault = vm.get("pgfault", 0)
    pgmajfault = vm.get("pgmajfault", 0)
    oom_kill = vm.get("oom_kill", 0)
    compact_stall = vm.get("compact_stall", 0)

    psi_some_avg10 = psi["some"].get("avg10", 0.0)
    psi_full_avg10 = psi["full"].get("avg10", 0.0)

    issues: List[str] = []
    status = "HEALTHY"

    # Evaluate PSI pressure stalls
    if psi_some_avg10 >= crit_psi_some or psi_full_avg10 >= crit_psi_full:
        status = "CRITICAL"
        issues.append(f"Severe kernel memory pressure stall: some={psi_some_avg10}%, full={psi_full_avg10}% (processes blocking on swap/paging)")
    elif psi_some_avg10 >= warn_psi_some or psi_full_avg10 >= warn_psi_full:
        status = "WARNING"
        issues.append(f"Elevated kernel memory pressure stall: some={psi_some_avg10}%, full={psi_full_avg10}%")

    # Evaluate Swap saturation
    if swap_sat_pct >= crit_swap_pct:
        status = "CRITICAL"
        issues.append(f"Critical swap saturation: {swap_sat_pct}% used ({swap_used_mb} MB / {swap_total_mb} MB)")
    elif swap_sat_pct >= warn_swap_pct:
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Elevated swap saturation: {swap_sat_pct}% used ({swap_used_mb} MB / {swap_total_mb} MB)")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "swap_total_mb": swap_total_mb,
            "swap_used_mb": swap_used_mb,
            "swap_free_mb": swap_free_mb,
            "swap_cached_mb": swap_cached_mb,
            "swap_saturation_pct": swap_sat_pct,
            "psi_some_avg10": psi_some_avg10,
            "psi_full_avg10": psi_full_avg10,
            "pgmajfault_total": pgmajfault,
            "pswpin_total": pswpin,
            "pswpout_total": pswpout,
            "oom_kill_total": oom_kill,
            "compact_stall_total": compact_stall,
            "issues": issues,
        },
        "psi": psi,
        "meminfo_kb": {
            "SwapTotal": swap_total_kb,
            "SwapFree": swap_free_kb,
            "SwapCached": swap_cached_kb,
            "MemAvailable": mem.get("MemAvailable", 0),
            "MemTotal": mem.get("MemTotal", 0),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Swap I/O Thrashing & Major Page Fault Stall Guard (Pattern 79)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-swap", type=float, default=DEFAULT_WARN_SWAP_SAT_PCT, help=f"Warning swap saturation pct (default {DEFAULT_WARN_SWAP_SAT_PCT})")
    parser.add_argument("--crit-swap", type=float, default=DEFAULT_CRIT_SWAP_SAT_PCT, help=f"Critical swap saturation pct (default {DEFAULT_CRIT_SWAP_SAT_PCT})")
    parser.add_argument("--warn-psi-some", type=float, default=DEFAULT_WARN_PSI_SOME, help=f"Warning PSI some avg10 pct (default {DEFAULT_WARN_PSI_SOME})")
    parser.add_argument("--crit-psi-some", type=float, default=DEFAULT_CRIT_PSI_SOME, help=f"Critical PSI some avg10 pct (default {DEFAULT_CRIT_PSI_SOME})")
    parser.add_argument("--proc-vmstat", type=str, default=PROC_VMSTAT, help="Path to /proc/vmstat")
    parser.add_argument("--proc-meminfo", type=str, default=PROC_MEMINFO, help="Path to /proc/meminfo")
    parser.add_argument("--proc-psi", type=str, default=PROC_PRESSURE_MEM, help="Path to /proc/pressure/memory")

    args = parser.parse_args()

    result = audit_swap_thrashing(
        vmstat_path=args.proc_vmstat,
        meminfo_path=args.proc_meminfo,
        psi_path=args.proc_psi,
        warn_swap_pct=args.warn_swap,
        crit_swap_pct=args.crit_swap,
        warn_psi_some=args.warn_psi_some,
        crit_psi_some=args.crit_psi_some,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Swap I/O Thrashing & Major Page Fault Guard (Pattern 79)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Swap Footprint:         {summary['swap_used_mb']} MB / {summary['swap_total_mb']} MB ({summary['swap_free_mb']} MB free)")
    print(f" Swap Saturation:        {summary['swap_saturation_pct']}% (Cached: {summary['swap_cached_mb']} MB)")
    print(f" Kernel Memory PSI:      some avg10={summary['psi_some_avg10']}%, full avg10={summary['psi_full_avg10']}%")
    print(f" Major Page Faults:      {summary['pgmajfault_total']:,} total")
    print(f" Swap I/O Counters:      pswpin={summary['pswpin_total']:,}, pswpout={summary['pswpout_total']:,}")
    print(f" OOM Kills / Compaction: {summary['oom_kill_total']} OOM kills, {summary['compact_stall_total']:,} compaction stalls")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo swap thrashing or synchronous memory pressure stalls detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
