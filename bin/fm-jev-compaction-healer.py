#!/usr/bin/env python3
"""
fm-jev-compaction-healer.py - Jev Multi-Agent Proactive Memory Compaction & Fragmentation Healer (Pattern 68)

Audits Linux kernel memory fragmentation, compaction stalls, and kcompactd efficiency.
Detects severe external memory fragmentation in the Normal zone, quantifies direct synchronous
compaction latency stalls, and evaluates or proactively triggers memory compaction to replenish
high-order buddy allocator blocks (orders 7..10) for low-latency LLM inference and subagent execution.

Invariants:
  - Read-only diagnostics by default. Non-destructive unless --heal is explicitly passed.
  - Fail-open: graceful degradation on missing sysctl or virtualized environments.
  - Fast bounded execution (< 0.05s in audit mode).
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_COMPACTION_FAIL_RATIO = 0.70
DEFAULT_WARN_FRAG_RATIO = 0.85
PAGE_SIZE_KB = 4
COMPACT_MEMORY_PATH = "/proc/sys/vm/compact_memory"
PROACTIVENESS_PATH = "/proc/sys/vm/compaction_proactiveness"
EXTFRAG_THRESHOLD_PATH = "/proc/sys/vm/extfrag_threshold"
VMSTAT_PATH = "/proc/vmstat"
BUDDYINFO_PATH = "/proc/buddyinfo"


def parse_buddyinfo(path: str = BUDDYINFO_PATH) -> List[Dict[str, Any]]:
    """Parses /proc/buddyinfo into structured order counts per zone."""
    zones = []
    if not os.path.exists(path):
        return zones

    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 15 and parts[0] == "Node" and parts[2] == "zone":
                    node_id = parts[1].rstrip(",")
                    zone_name = parts[3]
                    orders = [int(p) for p in parts[4:15]]

                    total_pages = sum(count * (2**i) for i, count in enumerate(orders))
                    high_order_pages = sum(count * (2**i) for i, count in enumerate(orders[7:], start=7))
                    high_order_count = sum(orders[7:])

                    frag_ratio = 1.0 - (high_order_pages / total_pages) if total_pages > 0 else 0.0

                    zones.append({
                        "node": node_id,
                        "zone": zone_name,
                        "orders": orders,
                        "total_free_pages": total_pages,
                        "total_free_mb": round((total_pages * PAGE_SIZE_KB) / 1024.0, 2),
                        "high_order_count": high_order_count,
                        "high_order_free_mb": round((high_order_pages * PAGE_SIZE_KB) / 1024.0, 2),
                        "external_fragmentation_ratio": round(frag_ratio, 4),
                    })
    except Exception:
        pass

    return zones


def parse_vmstat_compaction(path: str = VMSTAT_PATH) -> Dict[str, int]:
    """Extracts compaction-related counters from /proc/vmstat."""
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters

    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) == 2 and parts[0].startswith("compact_"):
                    try:
                        counters[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except Exception:
        pass

    return counters


def read_sysctl_val(path: str) -> Optional[int]:
    """Reads integer sysctl value from /proc/sys/vm/ path."""
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return None


def trigger_compaction(compact_memory_path: str = COMPACT_MEMORY_PATH) -> Tuple[bool, str]:
    """Triggers kernel memory compaction via /proc/sys/vm/compact_memory."""
    if not os.path.exists(compact_memory_path):
        return False, f"{compact_memory_path} does not exist"

    # Try direct write first
    try:
        with open(compact_memory_path, "w") as f:
            f.write("1\n")
        return True, "Triggered proactive kernel memory compaction successfully (direct write)"
    except PermissionError:
        # Fall back to sudo if available
        try:
            res = subprocess.run(
                ["sudo", "-n", "sh", "-c", f"echo 1 > {compact_memory_path}"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if res.returncode == 0:
                return True, "Triggered proactive kernel memory compaction successfully via sudo"
            else:
                return False, f"sudo compaction failed: {res.stderr.strip()}"
        except Exception as e:
            return False, f"Error executing compaction: {str(e)}"
    except Exception as e:
        return False, f"Error writing to {compact_memory_path}: {str(e)}"


def audit_compaction(
    buddyinfo_path: str = BUDDYINFO_PATH,
    vmstat_path: str = VMSTAT_PATH,
    proactiveness_path: str = PROACTIVENESS_PATH,
    extfrag_threshold_path: str = EXTFRAG_THRESHOLD_PATH,
    warn_frag_ratio: float = DEFAULT_WARN_FRAG_RATIO,
    warn_fail_ratio: float = DEFAULT_WARN_COMPACTION_FAIL_RATIO,
) -> Dict[str, Any]:
    """Performs full fleet audit of memory compaction health."""
    zones = parse_buddyinfo(buddyinfo_path)
    vmstat = parse_vmstat_compaction(vmstat_path)
    proactiveness = read_sysctl_val(proactiveness_path)
    extfrag_threshold = read_sysctl_val(extfrag_threshold_path)

    normal_zone = next((z for z in zones if z["zone"].lower() == "normal"), None)
    if not normal_zone and zones:
        normal_zone = zones[-1]

    compact_stall = vmstat.get("compact_stall", 0)
    compact_fail = vmstat.get("compact_fail", 0)
    compact_success = vmstat.get("compact_success", 0)
    compact_daemon_wake = vmstat.get("compact_daemon_wake", 0)
    compact_isolated = vmstat.get("compact_isolated", 0)

    total_attempts = compact_fail + compact_success
    fail_ratio = (compact_fail / total_attempts) if total_attempts > 0 else 0.0

    normal_frag = normal_zone["external_fragmentation_ratio"] if normal_zone else 0.0
    normal_high_orders = normal_zone["high_order_count"] if normal_zone else 0
    normal_free_mb = normal_zone["total_free_mb"] if normal_zone else 0.0

    status = "HEALTHY"
    recommendation = "Kernel memory buddy allocator and compaction health are nominal."

    if normal_frag >= 0.95 and normal_high_orders < 10 and fail_ratio >= warn_fail_ratio:
        status = "CRITICAL"
        recommendation = (
            f"Severe external memory fragmentation ({normal_frag*100:.1f}%) and high compaction failure rate ({fail_ratio*100:.1f}%). "
            f"Only {normal_high_orders} high-order blocks (orders 7-10) available in Normal zone with {compact_stall:,} historic stalls. "
            "Action: Run proactive compaction (echo 1 > /proc/sys/vm/compact_memory) or tune vm.compaction_proactiveness=50."
        )
    elif normal_frag >= warn_frag_ratio or normal_high_orders < 30:
        status = "WARNING"
        recommendation = (
            f"Elevated memory fragmentation ({normal_frag*100:.1f}%) in Normal zone. "
            f"High-order block availability is depleted ({normal_high_orders} blocks). "
            "Monitor compaction stall frequency and consider proactive defragmentation."
        )

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": (status == "HEALTHY"),
            "normal_zone_free_mb": normal_free_mb,
            "normal_zone_frag_ratio": normal_frag,
            "normal_zone_high_orders": normal_high_orders,
            "compact_stall_count": compact_stall,
            "compact_fail_count": compact_fail,
            "compact_success_count": compact_success,
            "compact_fail_ratio": round(fail_ratio, 4),
            "compact_daemon_wake": compact_daemon_wake,
            "compact_isolated": compact_isolated,
            "compaction_proactiveness": proactiveness,
            "extfrag_threshold": extfrag_threshold,
            "recommendation": recommendation,
        },
        "zones": zones,
        "vmstat_counters": vmstat,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Proactive Memory Compaction & Fragmentation Healer (Pattern 68)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--heal", action="store_true", help="Trigger proactive kernel memory compaction")
    parser.add_argument(
        "--warn-frag-ratio",
        type=float,
        default=DEFAULT_WARN_FRAG_RATIO,
        help=f"Warn threshold for external memory fragmentation ratio (default: {DEFAULT_WARN_FRAG_RATIO})",
    )
    parser.add_argument(
        "--warn-fail-ratio",
        type=float,
        default=DEFAULT_WARN_COMPACTION_FAIL_RATIO,
        help=f"Warn threshold for compaction failure ratio (default: {DEFAULT_WARN_COMPACTION_FAIL_RATIO})",
    )

    args = parser.parse_args()

    # Pre-audit
    report = audit_compaction(
        warn_frag_ratio=args.warn_frag_ratio,
        warn_fail_ratio=args.warn_fail_ratio,
    )

    heal_result = None
    if args.heal:
        success, msg = trigger_compaction()
        post_report = audit_compaction(
            warn_frag_ratio=args.warn_frag_ratio,
            warn_fail_ratio=args.warn_fail_ratio,
        )
        heal_result = {
            "success": success,
            "message": msg,
            "post_high_orders": post_report["summary"]["normal_zone_high_orders"],
            "post_frag_ratio": post_report["summary"]["normal_zone_frag_ratio"],
        }
        report["heal_result"] = heal_result

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"[{s['status']}] Jev Memory Compaction & Fragmentation Healer (Pattern 68)")
        print(f"Normal Zone: {s['normal_zone_free_mb']} MB free | Frag: {s['normal_zone_frag_ratio']*100:.1f}% | High-Order Blocks (7-10): {s['normal_zone_high_orders']}")
        print(f"Compaction Stats: {s['compact_stall_count']:,} stalls | {s['compact_success_count']:,} succ | {s['compact_fail_count']:,} fail ({s['compact_fail_ratio']*100:.1f}%) | {s['compact_daemon_wake']:,} kcompactd wakes")
        print(f"Sysctls: proactiveness={s['compaction_proactiveness']} | extfrag_threshold={s['extfrag_threshold']}")
        print(f"Status: {s['status']}")
        print(f"Recommendation: {s['recommendation']}")

        if heal_result:
            print(f"\n[HEAL EXECUTION]")
            print(f"Status: {'SUCCESS' if heal_result['success'] else 'FAILED'}")
            print(f"Message: {heal_result['message']}")
            print(f"Post-Compaction Normal Zone High Orders: {heal_result['post_high_orders']} (Frag: {heal_result['post_frag_ratio']*100:.1f}%)")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
