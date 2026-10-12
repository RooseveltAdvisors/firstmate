#!/usr/bin/env python3
"""
bin/fm-jev-netdev-rss-guard.py - Linux Network Core RSS Key, Per-CPU Headroom & Softnet Guard (Pattern 300 / Pattern 438) - Tercentenary Milestone

Audits Linux network core Receive Side Scaling (RSS) key configuration, per-CPU network buffer
reservation, network device timestamp prequeueing, and softnet processing telemetry:
  - /proc/sys/net/core/netdev_rss_key: Toeplitz hash key for multiqueue RSS packet distribution (52 bytes hex format)
  - /proc/sys/net/core/mem_pcpu_rsv: Per-CPU network memory reservation pages for interrupt headroom (default 256 pages)
  - /proc/sys/net/core/netdev_tstamp_prequeue: Pre-queue packet timestamping switch (default 1)
  - /proc/sys/net/core/warnings: Network core stack warning rate limiting switch (default 0 or 1)
  - /proc/net/softnet_stat: Per-CPU softnet processing stats (processed, dropped, squeezed, collisions)

Invariants:
  - netdev_rss_key must be valid colon-separated hex bytes (40 or 52 bytes).
  - mem_pcpu_rsv must maintain sufficient per-CPU page headroom (>= 64 pages).
  - Fail-open: graceful fallback when sysctl paths or /proc/net/softnet_stat are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

SYSCTL_RSS_KEY = "/proc/sys/net/core/netdev_rss_key"
SYSCTL_MEM_PCPU_RSV = "/proc/sys/net/core/mem_pcpu_rsv"
SYSCTL_TSTAMP_PREQUEUE = "/proc/sys/net/core/netdev_tstamp_prequeue"
SYSCTL_WARNINGS = "/proc/sys/net/core/warnings"
PROC_SOFTNET_STAT = "/proc/net/softnet_stat"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_rss_key(path: str) -> Dict[str, Any]:
    if not os.path.isfile(path):
        return {
            "exists": False,
            "raw_key": "",
            "key_bytes": 0,
            "is_valid_format": False,
            "is_driver_default": True,
        }
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        parts = content.split(":")
        is_hex = all(
            len(p) == 2 and all(c in "0123456789abcdefABCDEF" for c in p)
            for p in parts
        )
        key_bytes = len(parts) if is_hex else 0
        all_zero = all(p == "00" for p in parts) if is_hex else True
        return {
            "exists": True,
            "raw_key": content,
            "key_bytes": key_bytes,
            "is_valid_format": is_hex and key_bytes in (40, 52),
            "is_driver_default": all_zero,
        }
    except Exception:
        return {
            "exists": False,
            "raw_key": "",
            "key_bytes": 0,
            "is_valid_format": False,
            "is_driver_default": True,
        }


def parse_softnet_stat(path: str) -> Dict[str, int]:
    totals: Dict[str, int] = {
        "cpu_count": 0,
        "processed": 0,
        "dropped": 0,
        "time_squeeze": 0,
        "cpu_collision": 0,
        "received_rps": 0,
        "flow_limit_count": 0,
    }
    if not os.path.isfile(path):
        return totals
    col_names = [
        "processed",
        "dropped",
        "time_squeeze",
        "cpu_collision",
        "received_rps",
        "flow_limit_count",
    ]
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        totals["cpu_count"] = len(lines)
        for line in lines:
            parts = line.split()
            if not parts:
                continue
            for idx, col in enumerate(col_names):
                if idx < len(parts):
                    try:
                        totals[col] += int(parts[idx], 16)
                    except ValueError:
                        continue
        return totals
    except Exception:
        return totals


def evaluate_netdev_rss(
    rss_key_file: str = SYSCTL_RSS_KEY,
    mem_pcpu_rsv_file: str = SYSCTL_MEM_PCPU_RSV,
    tstamp_prequeue_file: str = SYSCTL_TSTAMP_PREQUEUE,
    warnings_file: str = SYSCTL_WARNINGS,
    softnet_stat_file: str = PROC_SOFTNET_STAT,
    min_mem_pcpu_rsv: int = 64,
    warn_dropped: int = 100,
    warn_squeezed: int = 50_000,
    warn_collision: int = 500,
) -> Dict[str, Any]:
    rss_info = parse_rss_key(rss_key_file)
    mem_pcpu_rsv = read_sysctl_int(mem_pcpu_rsv_file, default=-1)
    tstamp_prequeue = read_sysctl_int(tstamp_prequeue_file, default=-1)
    warnings_val = read_sysctl_int(warnings_file, default=-1)

    softnet = parse_softnet_stat(softnet_stat_file)
    cpu_count = softnet.get("cpu_count", 0)
    processed = softnet.get("processed", 0)
    dropped = softnet.get("dropped", 0)
    squeezed = softnet.get("time_squeeze", 0)
    collision = softnet.get("cpu_collision", 0)
    received_rps = softnet.get("received_rps", 0)
    flow_limit_count = softnet.get("flow_limit_count", 0)

    issues: List[str] = []
    recommendations: List[str] = []

    if rss_info["exists"] and not rss_info["is_valid_format"]:
        issues.append(
            f"Invalid netdev_rss_key format: {rss_info['key_bytes']} bytes "
            f"(expected 40 or 52 hex colon-delimited bytes)"
        )
        recommendations.append(
            "Restore net.core.netdev_rss_key to valid 52-byte hex format or reset to default all zeroes"
        )

    if mem_pcpu_rsv < min_mem_pcpu_rsv and mem_pcpu_rsv != -1:
        issues.append(
            f"Sub-optimal per-CPU network memory reservation: mem_pcpu_rsv={mem_pcpu_rsv} pages "
            f"(< {min_mem_pcpu_rsv} pages headroom threshold)"
        )
        recommendations.append(
            f"Increase net.core.mem_pcpu_rsv to at least {min_mem_pcpu_rsv} pages (default: 256)"
        )

    if tstamp_prequeue not in (0, 1):
        issues.append(
            f"Invalid net.core.netdev_tstamp_prequeue: {tstamp_prequeue} (expected 0 or 1)"
        )
        recommendations.append(
            "Set net.core.netdev_tstamp_prequeue to 1 (nominal prequeue timestamping)"
        )

    if warnings_val not in (0, 1):
        issues.append(
            f"Invalid net.core.warnings: {warnings_val} (expected 0 or 1)"
        )
        recommendations.append(
            "Set net.core.warnings to 0 or 1"
        )

    if dropped > warn_dropped:
        issues.append(
            f"Elevated softnet packet drops: {dropped:,} drops (> {warn_dropped:,})"
        )
        recommendations.append(
            "Expand netdev_max_backlog and audit backlog queue drain rate across CPUs"
        )

    if squeezed > warn_squeezed:
        issues.append(
            f"Elevated softnet budget squeeze events: {squeezed:,} events (> {warn_squeezed:,})"
        )
        recommendations.append(
            "Increase net.core.netdev_budget and net.core.netdev_budget_usecs for higher NAPI processing budget"
        )

    if collision > warn_collision:
        issues.append(
            f"Elevated CPU transmit collisions: {collision:,} collisions (> {warn_collision:,})"
        )
        recommendations.append(
            "Review multiqueue TX queue distribution and lock contention across CPU cores"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "pattern": 300,
        "name": "netdev_rss",
        "description": "Host Network Receive Side Scaling (RSS) Key, Per-CPU Headroom & Softnet Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "rss_key_exists": rss_info["exists"],
        "rss_key_bytes": rss_info["key_bytes"],
        "is_driver_default_rss": rss_info["is_driver_default"],
        "mem_pcpu_rsv": mem_pcpu_rsv,
        "netdev_tstamp_prequeue": tstamp_prequeue,
        "warnings": warnings_val,
        "cpu_cores_audited": cpu_count,
        "softnet_processed": processed,
        "softnet_dropped": dropped,
        "softnet_squeezed": squeezed,
        "softnet_collision": collision,
        "received_rps": received_rps,
        "flow_limit_count": flow_limit_count,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Receive Side Scaling (RSS) Key, Per-CPU Headroom & Softnet Guard (Pattern 300 / Pattern 438)"
    )
    parser.add_argument("--rss-key-file", default=SYSCTL_RSS_KEY, help="Path to netdev_rss_key")
    parser.add_argument("--mem-pcpu-rsv-file", default=SYSCTL_MEM_PCPU_RSV, help="Path to mem_pcpu_rsv")
    parser.add_argument("--tstamp-prequeue-file", default=SYSCTL_TSTAMP_PREQUEUE, help="Path to netdev_tstamp_prequeue")
    parser.add_argument("--warnings-file", default=SYSCTL_WARNINGS, help="Path to warnings")
    parser.add_argument("--softnet-stat-file", default=PROC_SOFTNET_STAT, help="Path to softnet_stat")
    parser.add_argument("--min-mem-pcpu-rsv", type=int, default=64, help="Minimum per-CPU memory reservation pages")
    parser.add_argument("--warn-dropped", type=int, default=100, help="Warning threshold for dropped packets")
    parser.add_argument("--warn-squeezed", type=int, default=50_000, help="Warning threshold for squeeze events")
    parser.add_argument("--warn-collision", type=int, default=500, help="Warning threshold for collisions")
    parser.add_argument("--json", action="store_true", help="Output JSON format")

    args = parser.parse_args()
    report = evaluate_netdev_rss(
        rss_key_file=args.rss_key_file,
        mem_pcpu_rsv_file=args.mem_pcpu_rsv_file,
        tstamp_prequeue_file=args.tstamp_prequeue_file,
        warnings_file=args.warnings_file,
        softnet_stat_file=args.softnet_stat_file,
        min_mem_pcpu_rsv=args.min_mem_pcpu_rsv,
        warn_dropped=args.warn_dropped,
        warn_squeezed=args.warn_squeezed,
        warn_collision=args.warn_collision,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"=== [{report['status']}] Pattern 300: {report['description']} ===")
        print(f"  Timestamp:               {report['timestamp']}")
        print(f"  RSS Key Config:          {report['rss_key_bytes']} bytes (Driver Default: {report['is_driver_default_rss']})")
        print(f"  Per-CPU Memory Res:      {report['mem_pcpu_rsv']} pages")
        print(f"  Tstamp Prequeue:         {report['netdev_tstamp_prequeue']}")
        print(f"  Network Warnings:        {report['warnings']}")
        print(f"  CPU Cores Audited:       {report['cpu_cores_audited']}")
        print(f"  Softnet Processed:       {report['softnet_processed']:,}")
        print(f"  Softnet Dropped:         {report['softnet_dropped']:,}")
        print(f"  Softnet Squeezed:        {report['softnet_squeezed']:,}")
        print(f"  Softnet Collisions:      {report['softnet_collision']:,}")
        if report["issues"]:
            print("  Issues:")
            for iss in report["issues"]:
                print(f"    - {iss}")
        if report["recommendations"]:
            print("  Recommendations:")
            for rec in report["recommendations"]:
                print(f"    - {rec}")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
