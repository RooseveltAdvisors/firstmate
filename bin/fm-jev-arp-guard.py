#!/usr/bin/env python3
"""
bin/fm-jev-arp-guard.py - Host Network IP Neighbor & ARP Table Saturation Guard (Pattern 204)

Audits Linux kernel IPv4 neighbor discovery (ARP) table metrics and garbage collection thresholds from:
  - /proc/net/arp (IP address, HW type, Flags, HW address, Mask, Device)
  - /proc/sys/net/ipv4/neigh/default/gc_thresh1, gc_thresh2, gc_thresh3, gc_stale_time, unres_qlen

Detects ARP table exhaustion (ENOBUFS neighbor table overflow), excessive unresolved neighbor probes,
and aggressive garbage collector pressure before local and container communication fails.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_arp_table(path: str = "/proc/net/arp") -> Tuple[List[Dict[str, str]], Dict[str, int]]:
    entries: List[Dict[str, str]] = []
    counts: Dict[str, int] = {
        "total": 0,
        "resolved": 0,
        "incomplete": 0,
        "other": 0,
    }
    if not os.path.exists(path):
        return entries, counts

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
        if len(lines) <= 1:
            return entries, counts

        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 6:
                ip, hw_type, flags, mac, mask, dev = parts[:6]
                entry = {
                    "ip": ip,
                    "hw_type": hw_type,
                    "flags": flags,
                    "mac": mac,
                    "mask": mask,
                    "dev": dev,
                }
                entries.append(entry)
                counts["total"] += 1
                if flags == "0x2":
                    counts["resolved"] += 1
                elif flags == "0x0":
                    counts["incomplete"] += 1
                else:
                    counts["other"] += 1
    except Exception:
        pass

    return entries, counts


def audit_arp(
    proc_arp: str = "/proc/net/arp",
    proc_sys_neigh: str = "/proc/sys/net/ipv4/neigh/default",
) -> Dict[str, Any]:
    entries, counts = parse_arp_table(proc_arp)

    gc_thresh1 = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_thresh1"), 128)
    gc_thresh2 = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_thresh2"), 512)
    gc_thresh3 = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_thresh3"), 1024)
    gc_stale_time = read_sysctl_int(os.path.join(proc_sys_neigh, "gc_stale_time"), 60)
    unres_qlen = read_sysctl_int(os.path.join(proc_sys_neigh, "unres_qlen"), 3)

    total = counts["total"]
    resolved = counts["resolved"]
    incomplete = counts["incomplete"]

    sat_thresh1 = float(total) / max(1, gc_thresh1)
    sat_thresh2 = float(total) / max(1, gc_thresh2)
    sat_thresh3 = float(total) / max(1, gc_thresh3)
    incomplete_ratio = float(incomplete) / max(1, total)

    issues: List[str] = []
    status = "HEALTHY"

    if total >= gc_thresh3:
        issues.append(
            f"CRITICAL: ARP table saturated ({total} entries >= gc_thresh3 {gc_thresh3}); neighbor allocation stalls"
        )
        status = "CRITICAL"
    elif total >= gc_thresh2:
        issues.append(
            f"WARNING: ARP table elevated ({total} entries >= gc_thresh2 {gc_thresh2}); 5s garbage collection active"
        )
        status = "WARNING"
    elif sat_thresh1 > 0.95:
        issues.append(
            f"NOTE: ARP table approaching gc_thresh1 ({total}/{gc_thresh1} entries, {sat_thresh1:.1%} saturation)"
        )

    if incomplete_ratio > 0.90 and total > 50:
        issues.append(
            f"WARNING: High proportion of incomplete ARP probes ({incomplete}/{total} entries = {incomplete_ratio:.1%})"
        )
        if status != "CRITICAL":
            status = "WARNING"

    healthy = status == "HEALTHY"
    recommendation = (
        "ARP neighbor table and GC thresholds are nominal."
        if healthy
        else "; ".join(issues)
    )

    # Device breakdown
    by_dev: Dict[str, int] = {}
    for e in entries:
        dev = e.get("dev", "unknown")
        by_dev[dev] = by_dev.get(dev, 0) + 1

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "total_entries": total,
            "resolved_entries": resolved,
            "incomplete_entries": incomplete,
            "incomplete_ratio": round(incomplete_ratio, 4),
            "gc_thresh1": gc_thresh1,
            "gc_thresh2": gc_thresh2,
            "gc_thresh3": gc_thresh3,
            "gc_stale_time_sec": gc_stale_time,
            "unres_qlen": unres_qlen,
            "saturation_thresh1": round(sat_thresh1, 4),
            "saturation_thresh2": round(sat_thresh2, 4),
            "saturation_thresh3": round(sat_thresh3, 4),
            "device_distribution": by_dev,
            "issues": issues,
            "recommendation": recommendation,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network IP Neighbor & ARP Table Saturation Guard (Pattern 204)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_arp()
    s = report["summary"]

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 204: Host Network IP Neighbor & ARP Table Guard")
        print(
            f"  Entries: {s['total_entries']} total (resolved: {s['resolved_entries']}, incomplete: {s['incomplete_entries']} [{s['incomplete_ratio']:.1%}])"
        )
        print(
            f"  Thresholds: thresh1={s['gc_thresh1']} ({s['saturation_thresh1']:.1%}), thresh2={s['gc_thresh2']} ({s['saturation_thresh2']:.1%}), thresh3={s['gc_thresh3']} ({s['saturation_thresh3']:.1%})"
        )
        print(f"  Devices: {s['device_distribution']}")
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
