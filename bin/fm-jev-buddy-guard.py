#!/usr/bin/env python3
"""
fm-jev-buddy-guard.py - Jev Multi-Agent Kernel Buddy Allocator & Fragmentation Guard (Pattern 67)

Audits Linux kernel buddy allocator memory fragmentation via /proc/buddyinfo.
Detects high-order physical page starvation (orders 7..10, 512KB..4MB) and extreme external memory
fragmentation before kernel DMA allocations, jumbo networking, or LLM GPU buffers trigger
synchronous memory compaction latency stalls.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling on virtualized or non-standard kernel /proc/buddyinfo.
  - Bounded fast execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_WARN_FRAGMENTATION_RATIO = 0.85
PAGE_SIZE_KB = 4


def parse_buddyinfo(buddyinfo_path: str = "/proc/buddyinfo") -> List[Dict[str, Any]]:
    """Parses /proc/buddyinfo into structured per-node/per-zone order statistics."""
    zones: List[Dict[str, Any]] = []
    if not os.path.exists(buddyinfo_path):
        return zones

    try:
        with open(buddyinfo_path, "r", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                # Format: Node <N>, zone <ZoneName> <order0> <order1> ... <order10>
                if len(parts) >= 15 and parts[0] == "Node" and parts[2] == "zone":
                    node_id = parts[1].rstrip(",")
                    zone_name = parts[3]
                    orders = [int(p) for p in parts[4:15]]

                    total_pages = sum(orders[order] * (2 ** order) for order in range(len(orders)))
                    total_bytes = total_pages * PAGE_SIZE_KB * 1024

                    high_order_pages = sum(orders[order] * (2 ** order) for order in range(7, len(orders)))
                    high_order_ratio = (high_order_pages / total_pages) if total_pages > 0 else 0.0

                    # External fragmentation index: fraction of free memory in low-order blocks (< order 7)
                    ext_frag_ratio = 1.0 - high_order_ratio

                    zones.append({
                        "node": node_id,
                        "zone": zone_name,
                        "orders": orders,
                        "total_free_pages": total_pages,
                        "total_free_mb": round(total_bytes / (1024 * 1024), 2),
                        "high_order_pages": high_order_pages,
                        "high_order_count": sum(orders[7:]),
                        "external_fragmentation_ratio": round(ext_frag_ratio, 4),
                    })
    except Exception:
        pass

    return zones


def audit_fleet_buddy(
    buddyinfo_path: str = "/proc/buddyinfo",
    warn_fragmentation_ratio: float = DEFAULT_WARN_FRAGMENTATION_RATIO,
) -> Dict[str, Any]:
    """Audits kernel buddy page allocation and fragmentation health."""
    zones = parse_buddyinfo(buddyinfo_path=buddyinfo_path)

    total_free_mb = sum(z["total_free_mb"] for z in zones)
    total_high_order_count = sum(z["high_order_count"] for z in zones)

    normal_zone = next((z for z in zones if z["zone"].lower() == "normal"), None)

    status = "HEALTHY"
    reasons: List[str] = []

    if normal_zone:
        if normal_zone["high_order_count"] == 0 and normal_zone["total_free_mb"] > 1000:
            reasons.append(
                f"Severe high-order page starvation in Normal zone (0 blocks order 7-10 across {normal_zone['total_free_mb']} MB free); compaction risk"
            )
            status = "WARNING"
        elif normal_zone["external_fragmentation_ratio"] >= warn_fragmentation_ratio:
            reasons.append(
                f"High external fragmentation in Normal zone ({normal_zone['external_fragmentation_ratio']*100:.1f}% >= {warn_fragmentation_ratio*100:.0f}%)"
            )
            status = "WARNING"

    recommendation = "; ".join(reasons) if reasons else "optimal"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "zones_audited": len(zones),
            "total_free_mb": round(total_free_mb, 2),
            "total_high_order_blocks": total_high_order_count,
            "normal_zone_free_mb": normal_zone["total_free_mb"] if normal_zone else 0.0,
            "normal_zone_frag_ratio": normal_zone["external_fragmentation_ratio"] if normal_zone else 0.0,
            "normal_zone_high_orders": normal_zone["high_order_count"] if normal_zone else 0,
            "warn_fragmentation_ratio": warn_fragmentation_ratio,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "zones": zones,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Kernel Buddy Allocator & Fragmentation Guard (Pattern 67)"
    )
    parser.add_argument(
        "--warn-fragmentation-ratio",
        type=float,
        default=DEFAULT_WARN_FRAGMENTATION_RATIO,
        help=f"Warn threshold for external memory fragmentation ratio (default: {DEFAULT_WARN_FRAGMENTATION_RATIO})",
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose zone order breakdown")

    args = parser.parse_args()

    report = audit_fleet_buddy(
        warn_fragmentation_ratio=args.warn_fragmentation_ratio,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        summary = report["summary"]
        status_str = summary["status"]
        print(f"[{status_str}] Jev Kernel Buddy Allocator Guard (Pattern 67)")
        print(f"Total Free Memory in Zones: {summary['total_free_mb']} MB across {summary['zones_audited']} zones")
        print(f"High-Order Blocks (Order 7-10): {summary['total_high_order_blocks']}")
        print(f"Normal Zone: {summary['normal_zone_free_mb']} MB free | Frag Ratio: {summary['normal_zone_frag_ratio']*100:.1f}%")
        print(f"Health Status: {summary['status']}")
        print(f"Recommendation: {summary['recommendation']}")

        if args.verbose:
            print("\nZone Page Order Distribution (Orders 0..10):")
            for z in report["zones"]:
                orders_str = " ".join(f"{o:5d}" for o in z["orders"])
                print(f"  Node {z['node']} zone {z['zone']:<8}: {orders_str} (High: {z['high_order_count']})")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
