#!/usr/bin/env python3
"""
fm-jev-arp-guard.py - Jev Multi-Agent Host Network Neighbor Table (ARP / ND) Saturation Guard (Pattern 92)

Audits Linux kernel neighbor table / ARP table (/proc/net/arp) against garbage collection thresholds
(/proc/sys/net/ipv4/neigh/default/gc_thresh1, gc_thresh2, gc_thresh3). Detects table saturation before
the kernel drops packets with "neighbour: table overflow!", preventing catastrophic connectivity stalls
across container bridges, multi-agent RPC channels, and upstream gateways.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when procfs files are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_NET_ARP = "/proc/net/arp"
NEIGH_DIR = "/proc/sys/net/ipv4/neigh/default"

DEFAULT_WARN_SATURATION_PCT = 70.0
DEFAULT_CRIT_SATURATION_PCT = 85.0
DEFAULT_WARN_INCOMPLETE = 25
DEFAULT_CRIT_INCOMPLETE = 100


def read_int_file(path: Path, default: int = 0) -> int:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return default
    try:
        return int(path.read_text().strip())
    except Exception:
        return default


def audit_arp(
    arp_path: Optional[str] = None,
    gc_thresh1_path: Optional[str] = None,
    gc_thresh2_path: Optional[str] = None,
    gc_thresh3_path: Optional[str] = None,
    warn_sat_pct: float = DEFAULT_WARN_SATURATION_PCT,
    crit_sat_pct: float = DEFAULT_CRIT_SATURATION_PCT,
    warn_incomplete: int = DEFAULT_WARN_INCOMPLETE,
    crit_incomplete: int = DEFAULT_CRIT_INCOMPLETE,
) -> Dict[str, Any]:
    """Audits ARP / neighbor table capacity and entry states."""
    arp_file = Path(arp_path) if arp_path else Path(PROC_NET_ARP)
    t1_file = Path(gc_thresh1_path) if gc_thresh1_path else Path(NEIGH_DIR) / "gc_thresh1"
    t2_file = Path(gc_thresh2_path) if gc_thresh2_path else Path(NEIGH_DIR) / "gc_thresh2"
    t3_file = Path(gc_thresh3_path) if gc_thresh3_path else Path(NEIGH_DIR) / "gc_thresh3"

    thresh1 = read_int_file(t1_file, 128)
    thresh2 = read_int_file(t2_file, 512)
    thresh3 = read_int_file(t3_file, 1024)

    entries: List[Dict[str, str]] = []
    complete_count = 0
    incomplete_count = 0
    permanent_count = 0
    other_count = 0
    by_device: Dict[str, int] = {}

    if arp_file.is_file():
        try:
            lines = arp_file.read_text().strip().splitlines()
            if len(lines) > 1:
                # First line is header: IP address HW type Flags HW address Mask Device
                for line in lines[1:]:
                    parts = line.split()
                    if len(parts) >= 6:
                        ip = parts[0]
                        hw_type = parts[1]
                        flags_str = parts[2]
                        hw_addr = parts[3]
                        mask = parts[4]
                        device = parts[5]

                        flags_val = int(flags_str, 16) if flags_str.startswith("0x") else 0
                        if flags_val == 0:
                            incomplete_count += 1
                            state = "INCOMPLETE"
                        elif flags_val & 0x4:
                            permanent_count += 1
                            state = "PERMANENT"
                        elif flags_val & 0x2:
                            complete_count += 1
                            state = "REACHABLE"
                        else:
                            other_count += 1
                            state = "OTHER"

                        by_device[device] = by_device.get(device, 0) + 1
                        entries.append(
                            {
                                "ip": ip,
                                "hw_type": hw_type,
                                "flags": flags_str,
                                "hw_address": hw_addr,
                                "mask": mask,
                                "device": device,
                                "state": state,
                            }
                        )
        except Exception:
            pass

    total_entries = len(entries)
    saturation_pct = round((total_entries / thresh3) * 100.0, 2) if thresh3 > 0 else 0.0
    headroom = max(0, thresh3 - total_entries)

    issues: List[str] = []
    if saturation_pct >= crit_sat_pct:
        issues.append(
            f"Critical ARP/neighbor saturation: {saturation_pct}% ({total_entries:,} / {thresh3:,} limit). Imminent neighbor table overflow risk."
        )
    elif saturation_pct >= warn_sat_pct:
        issues.append(
            f"Elevated ARP/neighbor saturation: {saturation_pct}% ({total_entries:,} / {thresh3:,} limit)."
        )

    if incomplete_count >= crit_incomplete:
        issues.append(
            f"High count of incomplete/unresolved neighbor entries: {incomplete_count:,} stale targets. Check network sweeps or routing drift."
        )
    elif incomplete_count >= warn_incomplete:
        issues.append(
            f"Elevated count of incomplete neighbor entries: {incomplete_count:,} unresolved targets."
        )

    status = "HEALTHY"
    if any("Critical" in iss or "High count" in iss for iss in issues):
        status = "CRITICAL"
    elif issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_entries": total_entries,
            "complete_entries": complete_count,
            "incomplete_entries": incomplete_count,
            "permanent_entries": permanent_count,
            "gc_thresh1": thresh1,
            "gc_thresh2": thresh2,
            "gc_thresh3": thresh3,
            "saturation_pct": saturation_pct,
            "headroom_entries": headroom,
            "device_distribution": by_device,
            "issues": issues,
        },
        "sample_entries": entries[:20],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Neighbor Table (ARP / ND) Saturation Guard (Pattern 92)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument(
        "--warn-saturation-pct",
        type=float,
        default=DEFAULT_WARN_SATURATION_PCT,
        help=f"Warning saturation percentage (default {DEFAULT_WARN_SATURATION_PCT}%%)",
    )
    parser.add_argument(
        "--crit-saturation-pct",
        type=float,
        default=DEFAULT_CRIT_SATURATION_PCT,
        help=f"Critical saturation percentage (default {DEFAULT_CRIT_SATURATION_PCT}%%)",
    )
    parser.add_argument(
        "--warn-incomplete",
        type=int,
        default=DEFAULT_WARN_INCOMPLETE,
        help=f"Warning incomplete entries count (default {DEFAULT_WARN_INCOMPLETE})",
    )
    parser.add_argument(
        "--crit-incomplete",
        type=int,
        default=DEFAULT_CRIT_INCOMPLETE,
        help=f"Critical incomplete entries count (default {DEFAULT_CRIT_INCOMPLETE})",
    )
    parser.add_argument("--arp-path", type=str, default=None, help="Path to /proc/net/arp")
    parser.add_argument("--thresh1-path", type=str, default=None, help="Path to gc_thresh1")
    parser.add_argument("--thresh2-path", type=str, default=None, help="Path to gc_thresh2")
    parser.add_argument("--thresh3-path", type=str, default=None, help="Path to gc_thresh3")
    args = parser.parse_args()

    result = audit_arp(
        arp_path=args.arp_path,
        gc_thresh1_path=args.thresh1_path,
        gc_thresh2_path=args.thresh2_path,
        gc_thresh3_path=args.thresh3_path,
        warn_sat_pct=args.warn_saturation_pct,
        crit_sat_pct=args.crit_saturation_pct,
        warn_incomplete=args.warn_incomplete,
        crit_incomplete=args.crit_incomplete,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = (
        "\033[32m"
        if summary["healthy"]
        else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    )
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network Neighbor Table (ARP) Guard (Pattern 92)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Active Neighbor Entries:{summary['total_entries']:,} / {summary['gc_thresh3']:,} (gc_thresh3)")
    print(f" Table Saturation:       {summary['saturation_pct']}%")
    print(f" Available Headroom:     {summary['headroom_entries']:,} entries")
    print(f" Complete / Reachable:   {summary['complete_entries']:,}")
    print(f" Incomplete / Stale:     {summary['incomplete_entries']:,}")
    print(f" Permanent / Static:     {summary['permanent_entries']:,}")
    print(f" GC Thresholds:          gc_thresh1={summary['gc_thresh1']}, gc_thresh2={summary['gc_thresh2']}, gc_thresh3={summary['gc_thresh3']}")
    if summary["device_distribution"]:
        dist = ", ".join(f"{dev}: {cnt}" for dev, cnt in summary["device_distribution"].items())
        print(f" Device Distribution:   {dist}")

    if summary["issues"]:
        print("\nActive Neighbor / ARP Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nHost neighbor / ARP table nominal. Zero table overflow or resolution stall risk.")
    print("================================================================================")


if __name__ == "__main__":
    main()
