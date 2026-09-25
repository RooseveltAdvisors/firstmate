#!/usr/bin/env python3
"""
bin/fm-jev-compaction-guard.py - Linux Kernel Memory Compaction & Defrag Guard (Pattern 317 / Pattern 455)

Audits Linux kernel memory compaction configuration (/proc/sys/vm/extfrag_threshold,
/proc/sys/vm/compaction_proactiveness), Transparent Hugepage (THP) defrag behavior
(/sys/kernel/mm/transparent_hugepage/defrag), and /proc/vmstat compaction counters
(compact_stall, compact_fail, compact_success, compact_daemon_wake) to detect
synchronous direct compaction stalls, excessive compaction failures, and latency
degradation under multi-agent concurrent allocations.

Invariants:
  - Critical when compaction_proactiveness >= 95.
  - Warning when compaction_proactiveness >= 80, extfrag_threshold not in 100..900,
    thp_defrag == 'always', or direct compaction failure ratio >= 90% (with >1M stalls).
  - Fail-open: graceful fallback when sysctl/sysfs paths are restricted.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_SYS_VM = "/proc/sys/vm"
PROC_VMSTAT = "/proc/vmstat"
THP_DEFRAG = "/sys/kernel/mm/transparent_hugepage/defrag"

DEFAULT_WARN_FAIL_PCT = 90.0
DEFAULT_WARN_PROACTIVENESS = 80
DEFAULT_CRIT_PROACTIVENESS = 95
DEFAULT_MIN_STALLS_FOR_WARN = 1000000


def read_sysctl_int(path: Path, default: int = -1) -> int:
    if not path.is_file():
        return default
    try:
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        return int(content) if content.isdigit() else default
    except (ValueError, OSError):
        return default


def parse_vmstat(path: Path) -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not path.is_file():
        return counters
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.strip().split()
            if len(parts) == 2:
                try:
                    counters[parts[0]] = int(parts[1])
                except ValueError:
                    continue
    except Exception:
        pass
    return counters


def parse_thp_mode(path: Path) -> str:
    if not path.is_file():
        return "unknown"
    try:
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        m = re.search(r"\[([a-z_+]+)\]", content)
        if m:
            return m.group(1)
        return content.split()[0] if content else "unknown"
    except Exception:
        return "unknown"


def evaluate_compaction(
    proc_sys_vm_dir: str = PROC_SYS_VM,
    vmstat_file: str = PROC_VMSTAT,
    thp_defrag_file: str = THP_DEFRAG,
    warn_fail_pct: float = DEFAULT_WARN_FAIL_PCT,
    warn_proactiveness: int = DEFAULT_WARN_PROACTIVENESS,
    crit_proactiveness: int = DEFAULT_CRIT_PROACTIVENESS,
    min_stalls_for_warn: int = DEFAULT_MIN_STALLS_FOR_WARN,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    vm_path = Path(proc_sys_vm_dir)
    vmstat_path = Path(vmstat_file)
    thp_path = Path(thp_defrag_file)

    extfrag_threshold = read_sysctl_int(vm_path / "extfrag_threshold", default=500)
    compaction_proactiveness = read_sysctl_int(vm_path / "compaction_proactiveness", default=20)
    thp_defrag = parse_thp_mode(thp_path)

    vmstat = parse_vmstat(vmstat_path)
    compact_stall = vmstat.get("compact_stall", 0)
    compact_fail = vmstat.get("compact_fail", 0)
    compact_success = vmstat.get("compact_success", 0)
    compact_daemon_wake = vmstat.get("compact_daemon_wake", 0)
    compact_migrate_scanned = vmstat.get("compact_migrate_scanned", 0)
    compact_free_scanned = vmstat.get("compact_free_scanned", 0)
    compact_isolated = vmstat.get("compact_isolated", 0)

    total_direct_attempts = compact_fail + compact_success
    fail_pct = (
        (compact_fail / total_direct_attempts * 100.0)
        if total_direct_attempts > 0
        else 0.0
    )

    # Evaluate extfrag_threshold
    if extfrag_threshold != -1 and (extfrag_threshold < 100 or extfrag_threshold > 900):
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"vm.extfrag_threshold abnormal ({extfrag_threshold}, nominal 100..900)"
        )
        recommendations.append("Reset sysctl vm.extfrag_threshold to default 500")

    # Evaluate compaction_proactiveness
    if compaction_proactiveness >= crit_proactiveness:
        status = "CRITICAL"
        issues.append(
            f"Compaction proactiveness critical ({compaction_proactiveness} >= {crit_proactiveness}); "
            "kcompactd background thread CPU hogging"
        )
        recommendations.append("Reduce sysctl vm.compaction_proactiveness to 20")
    elif compaction_proactiveness >= warn_proactiveness:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Compaction proactiveness elevated ({compaction_proactiveness} >= {warn_proactiveness})"
        )
        recommendations.append("Monitor kcompactd CPU utilization")

    # Evaluate THP defrag setting
    if thp_defrag == "always":
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            "THP defrag set to 'always'; risks synchronous direct compaction latency spikes"
        )
        recommendations.append("Set THP defrag to 'madvise' or 'defer+madvise'")

    # Evaluate compaction failure ratio if substantial stalls occurred
    if compact_stall >= min_stalls_for_warn and fail_pct >= warn_fail_pct:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Direct compaction failure ratio elevated ({fail_pct:.1f}% >= {warn_fail_pct}%, stalls={compact_stall:,})"
        )
        recommendations.append("Review zone fragmentation and reclaimable page cache")

    healthy = (status == "HEALTHY")
    is_compaction_healthy = (
        thp_defrag != "always"
        and compaction_proactiveness < warn_proactiveness
        and (extfrag_threshold == -1 or 100 <= extfrag_threshold <= 900)
    )

    return {
        "pattern": 317,
        "name": "compaction",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_compaction_healthy": is_compaction_healthy,
        "extfrag_threshold": extfrag_threshold,
        "compaction_proactiveness": compaction_proactiveness,
        "thp_defrag": thp_defrag,
        "compact_stall": compact_stall,
        "compact_fail": compact_fail,
        "compact_success": compact_success,
        "compact_fail_pct": round(fail_pct, 2),
        "compact_daemon_wake": compact_daemon_wake,
        "compact_migrate_scanned": compact_migrate_scanned,
        "compact_free_scanned": compact_free_scanned,
        "compact_isolated": compact_isolated,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux kernel memory compaction, proactiveness, and THP defrag behavior."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--vm-dir", default=PROC_SYS_VM, help=f"Path to /proc/sys/vm (default: {PROC_SYS_VM})")
    parser.add_argument("--vmstat-file", default=PROC_VMSTAT, help=f"Path to /proc/vmstat (default: {PROC_VMSTAT})")
    parser.add_argument("--thp-defrag-file", default=THP_DEFRAG, help=f"Path to thp defrag file (default: {THP_DEFRAG})")
    parser.add_argument("--warn-fail-pct", type=float, default=DEFAULT_WARN_FAIL_PCT, help="Compaction failure warning threshold %%")
    parser.add_argument("--warn-proactiveness", type=int, default=DEFAULT_WARN_PROACTIVENESS, help="Proactiveness warning threshold")
    parser.add_argument("--crit-proactiveness", type=int, default=DEFAULT_CRIT_PROACTIVENESS, help="Proactiveness critical threshold")

    args = parser.parse_args()

    result = evaluate_compaction(
        proc_sys_vm_dir=args.vm_dir,
        vmstat_file=args.vmstat_file,
        thp_defrag_file=args.thp_defrag_file,
        warn_fail_pct=args.warn_fail_pct,
        warn_proactiveness=args.warn_proactiveness,
        crit_proactiveness=args.crit_proactiveness,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 317 (compaction): {result['status']}")
        print(
            f"  Compaction: extfrag={result['extfrag_threshold']} | proactiveness={result['compaction_proactiveness']} | "
            f"THP Defrag: [{result['thp_defrag']}]"
        )
        print(
            f"  VMStat: stalls={result['compact_stall']:,} | success={result['compact_success']:,} | "
            f"fail={result['compact_fail']:,} ({result['compact_fail_pct']}%) | wakes={result['compact_daemon_wake']:,}"
        )
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
