#!/usr/bin/env python3
"""
bin/fm-jev-block-queue-guard.py - Linux Kernel Block Device Queue & I/O Scheduler Guard (Pattern 320 / Pattern 458)

Audits Linux kernel block device queue configurations across storage devices (/sys/block/*/queue)
including I/O schedulers, request queue depths (nr_requests), read-ahead buffers (read_ahead_kb),
rotational device flags, and interrupt completion affinities (rq_affinity) to detect shallow I/O
queues, suboptimal NVMe schedulers, and storage bottlenecks under concurrent multi-agent workloads.

Invariants:
  - Warning when physical block device nr_requests < min_nr_requests (default: 64).
  - Fail-open: graceful fallback when sysfs paths are restricted or in containers.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSFS_BLOCK_DIR = "/sys/block"
DEFAULT_MIN_NR_REQUESTS = 64


def read_sysfs_text(path: Path) -> str:
    """Reads stripped text from a sysfs attribute."""
    if not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        return ""


def read_sysfs_int(path: Path, default: int = 0) -> int:
    """Reads integer value from a sysfs attribute."""
    val = read_sysfs_text(path)
    if not val:
        return default
    try:
        return int(val)
    except ValueError:
        return default


def parse_bracketed_scheduler(path: Path) -> str:
    """Extracts the active scheduler enclosed in brackets, e.g. '[none] mq-deadline' -> 'none'."""
    raw = read_sysfs_text(path)
    if not raw:
        return "none"
    for token in raw.split():
        if token.startswith("[") and token.endswith("]"):
            return token[1:-1]
    return raw


def evaluate_block_queue(
    block_dir: str = SYSFS_BLOCK_DIR,
    min_nr_requests: int = DEFAULT_MIN_NR_REQUESTS,
) -> Dict[str, Any]:
    b_path = Path(block_dir)
    issues: List[str] = []
    recommendations: List[str] = []
    devices: List[Dict[str, Any]] = []
    status = "HEALTHY"

    if not b_path.is_dir():
        return {
            "pattern": 320,
            "name": "block_queue",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "HEALTHY",
            "healthy": True,
            "is_queue_healthy": True,
            "devices_count": 0,
            "device_names": [],
            "min_nr_requests_observed": 0,
            "devices": [],
            "issues": ["Block sysfs interface unavailable (virtualized container fallback)"],
            "recommendations": ["Storage layer unmanaged by local container namespace"],
        }

    for dev_path in sorted(b_path.iterdir()):
        dev_name = dev_path.name
        # Skip virtual devices and device mapper partitions
        if dev_name.startswith(("loop", "ram", "zram", "dm-")):
            continue
        queue_dir = dev_path / "queue"
        if not queue_dir.is_dir():
            continue

        scheduler = parse_bracketed_scheduler(queue_dir / "scheduler")
        nr_requests = read_sysfs_int(queue_dir / "nr_requests", default=0)
        read_ahead_kb = read_sysfs_int(queue_dir / "read_ahead_kb", default=0)
        max_sectors_kb = read_sysfs_int(queue_dir / "max_sectors_kb", default=0)
        rotational = read_sysfs_int(queue_dir / "rotational", default=0)
        rq_affinity = read_sysfs_int(queue_dir / "rq_affinity", default=0)
        discard_granularity = read_sysfs_int(queue_dir / "discard_granularity", default=0)

        dev_info = {
            "device": dev_name,
            "scheduler": scheduler,
            "nr_requests": nr_requests,
            "read_ahead_kb": read_ahead_kb,
            "max_sectors_kb": max_sectors_kb,
            "rotational": rotational == 1,
            "rq_affinity": rq_affinity,
            "discard_granularity": discard_granularity,
        }
        devices.append(dev_info)

        if nr_requests > 0 and nr_requests < min_nr_requests:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(
                f"Shallow I/O queue depth on {dev_name}: nr_requests={nr_requests} < {min_nr_requests}"
            )
            recommendations.append(f"Increase /sys/block/{dev_name}/queue/nr_requests to at least {min_nr_requests}")

        if dev_name.startswith("nvme") and scheduler not in ("none", "mq-deadline"):
            recommendations.append(
                f"Consider setting scheduler to 'none' for NVMe device {dev_name} to minimize lock contention"
            )

    if not devices:
        return {
            "pattern": 320,
            "name": "block_queue",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "HEALTHY",
            "healthy": True,
            "is_queue_healthy": True,
            "devices_count": 0,
            "device_names": [],
            "min_nr_requests_observed": 0,
            "devices": [],
            "issues": ["No physical block devices detected in sysfs"],
            "recommendations": ["Storage devices virtualized or handled via network mounts"],
        }

    healthy = (status == "HEALTHY")
    min_observed = min((d["nr_requests"] for d in devices), default=0)
    is_queue_healthy = min_observed >= min_nr_requests

    return {
        "pattern": 320,
        "name": "block_queue",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_queue_healthy": is_queue_healthy,
        "devices_count": len(devices),
        "device_names": [d["device"] for d in devices],
        "min_nr_requests_observed": min_observed,
        "devices": devices,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux kernel block device queue parameters, I/O schedulers, and read-ahead buffers."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--block-dir", default=SYSFS_BLOCK_DIR, help=f"Path to block sysfs (default: {SYSFS_BLOCK_DIR})")
    parser.add_argument("--min-nr-requests", type=int, default=DEFAULT_MIN_NR_REQUESTS, help="Minimum acceptable nr_requests")

    args = parser.parse_args()

    result = evaluate_block_queue(
        block_dir=args.block_dir,
        min_nr_requests=args.min_nr_requests,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 320 (block_queue): {result['status']}")
        print(
            f"  Devices: {result['devices_count']} ({', '.join(result['device_names'])}) | "
            f"Min Queue Depth: {result['min_nr_requests_observed']}"
        )
        for d in result["devices"]:
            rot_str = "HDD" if d["rotational"] else "SSD/NVMe"
            print(
                f"    - {d['device']} ({rot_str}): scheduler=[{d['scheduler']}], "
                f"nr_requests={d['nr_requests']}, read_ahead_kb={d['read_ahead_kb']} KB"
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
