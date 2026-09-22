#!/usr/bin/env python3
"""
fm-jev-disk-io-guard.py - Jev Multi-Agent Host Block Device IOPS & Latency Stall Guard (Pattern 87)

Audits Linux kernel block layer I/O queue depth and service latencies (/proc/diskstats) across physical NVMe
and SSD storage devices. Detects I/O wait stalls, elevated request queue depths, and high device service times
before multi-agent test suites (Playwright, pytest shards), compiler builds, or SQLite/Postgres transactions
suffer cascade timeouts.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback on missing diskstats or virtualized storage.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

DEFAULT_DISKSTATS_PATH = "/proc/diskstats"
DEFAULT_SYSFS_BLOCK_PATH = "/sys/block"
DEFAULT_WARN_IN_FLIGHT = 32
DEFAULT_CRIT_IN_FLIGHT = 64
DEFAULT_WARN_LATENCY_MS = 100.0
DEFAULT_WARN_ROTATIONAL_LATENCY_MS = 250.0


def is_whole_disk(name: str) -> bool:
    """Filters out partitions, virtual loop devices, and RAM disks."""
    if name.startswith(("loop", "ram", "dm-", "zram")):
        return False
    if name.startswith("nvme"):
        return not ("p" in name and name.split("p")[-1].isdigit())
    return not name[-1].isdigit()


def is_rotational(name: str, sysfs_path: str = DEFAULT_SYSFS_BLOCK_PATH) -> bool:
    """Detects whether device is rotational (HDD) or solid state (SSD/NVMe)."""
    rot_file = os.path.join(sysfs_path, name, "queue", "rotational")
    try:
        if os.path.exists(rot_file):
            with open(rot_file, "r") as f:
                return f.read().strip() == "1"
    except Exception:
        pass
    return False


def audit_disk_io(
    diskstats_path: str = DEFAULT_DISKSTATS_PATH,
    sysfs_path: str = DEFAULT_SYSFS_BLOCK_PATH,
    warn_in_flight: int = DEFAULT_WARN_IN_FLIGHT,
    crit_in_flight: int = DEFAULT_CRIT_IN_FLIGHT,
    warn_latency_ms: float = DEFAULT_WARN_LATENCY_MS,
    warn_rotational_latency_ms: float = DEFAULT_WARN_ROTATIONAL_LATENCY_MS,
) -> Dict[str, Any]:
    """Audits diskstats block devices for queue depth and service latency."""
    devices: Dict[str, Dict[str, Any]] = {}
    max_in_flight = 0
    total_reads = 0
    total_writes = 0
    issues: List[str] = []

    if not os.path.exists(diskstats_path):
        return {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "summary": {
                "status": "HEALTHY",
                "healthy": True,
                "devices_count": 0,
                "max_in_flight": 0,
                "issues": ["Diskstats file not found; fail-open."],
            },
            "devices": {},
        }

    try:
        with open(diskstats_path, "r") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 14:
                    dev_name = parts[2]
                    if not is_whole_disk(dev_name):
                        continue

                    reads = int(parts[3])
                    r_ms = int(parts[6])
                    writes = int(parts[7])
                    w_ms = int(parts[10])
                    in_flight = int(parts[11])
                    io_ms = int(parts[12])

                    total_reads += reads
                    total_writes += writes
                    if in_flight > max_in_flight:
                        max_in_flight = in_flight

                    avg_r_lat = round(r_ms / reads, 3) if reads > 0 else 0.0
                    avg_w_lat = round(w_ms / writes, 3) if writes > 0 else 0.0

                    rotational = is_rotational(dev_name, sysfs_path=sysfs_path)
                    dev_type = "HDD" if rotational else ("NVMe" if dev_name.startswith("nvme") else "SSD")
                    effective_latency_thresh = warn_rotational_latency_ms if rotational else warn_latency_ms

                    dev_data = {
                        "type": dev_type,
                        "rotational": rotational,
                        "reads": reads,
                        "writes": writes,
                        "in_flight": in_flight,
                        "io_ms": io_ms,
                        "avg_read_latency_ms": avg_r_lat,
                        "avg_write_latency_ms": avg_w_lat,
                    }
                    devices[dev_name] = dev_data

                    if in_flight >= crit_in_flight:
                        issues.append(f"Device {dev_name} ({dev_type}) has critical I/O queue depth: {in_flight} in-flight requests")
                    elif in_flight >= warn_in_flight:
                        issues.append(f"Device {dev_name} ({dev_type}) has elevated I/O queue depth: {in_flight} in-flight requests")

                    if avg_r_lat >= effective_latency_thresh:
                        issues.append(f"Device {dev_name} ({dev_type}) has elevated read latency: {avg_r_lat} ms/op (threshold: {effective_latency_thresh} ms)")
                    if avg_w_lat >= effective_latency_thresh:
                        issues.append(f"Device {dev_name} ({dev_type}) has elevated write latency: {avg_w_lat} ms/op (threshold: {effective_latency_thresh} ms)")

    except Exception as e:
        issues.append(f"Failed to parse diskstats: {str(e)}")

    status = "HEALTHY"
    if any("critical" in iss for iss in issues):
        status = "CRITICAL"
    elif issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "devices_count": len(devices),
            "max_in_flight": max_in_flight,
            "total_reads": total_reads,
            "total_writes": total_writes,
            "issues": issues,
        },
        "devices": devices,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Block Device IOPS & Latency Stall Guard (Pattern 87)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-inflight", type=int, default=DEFAULT_WARN_IN_FLIGHT, help=f"Warning in-flight queue depth (default {DEFAULT_WARN_IN_FLIGHT})")
    parser.add_argument("--crit-inflight", type=int, default=DEFAULT_CRIT_IN_FLIGHT, help=f"Critical in-flight queue depth (default {DEFAULT_CRIT_IN_FLIGHT})")
    parser.add_argument("--warn-latency", type=float, default=DEFAULT_WARN_LATENCY_MS, help=f"Warning latency in ms for SSD/NVMe (default {DEFAULT_WARN_LATENCY_MS})")
    parser.add_argument("--warn-rotational-latency", type=float, default=DEFAULT_WARN_ROTATIONAL_LATENCY_MS, help=f"Warning latency in ms for HDDs (default {DEFAULT_WARN_ROTATIONAL_LATENCY_MS})")
    parser.add_argument("--diskstats-path", type=str, default=DEFAULT_DISKSTATS_PATH, help="Path to /proc/diskstats")
    parser.add_argument("--sysfs-path", type=str, default=DEFAULT_SYSFS_BLOCK_PATH, help="Path to /sys/block")

    args = parser.parse_args()

    result = audit_disk_io(
        diskstats_path=args.diskstats_path,
        sysfs_path=args.sysfs_path,
        warn_in_flight=args.warn_inflight,
        crit_in_flight=args.crit_inflight,
        warn_latency_ms=args.warn_latency,
        warn_rotational_latency_ms=args.warn_rotational_latency,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Block Device I/O & Latency Guard (Pattern 87)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Block Devices Audited:  {summary['devices_count']} device(s)")
    print(f" Peak I/O Queue Depth:   {summary['max_in_flight']} in-flight request(s)")
    print(f" Cumulative Operations:  {summary['total_reads']:,} reads / {summary['total_writes']:,} writes")

    if result["devices"]:
        print("\nPer-Device Storage Health:")
        for dev, s in result["devices"].items():
            print(f"  - {dev:<10} [{s['type']:<4}] in-flight={s['in_flight']:<3} read_lat={s['avg_read_latency_ms']:<7}ms write_lat={s['avg_write_latency_ms']:<7}ms ({s['reads']:,} R / {s['writes']:,} W)")

    if summary["issues"]:
        print("\nActive Storage Warnings & I/O Saturation:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll physical storage devices nominal. Zero I/O queuing or service stalls detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
