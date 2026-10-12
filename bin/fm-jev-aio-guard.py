#!/usr/bin/env python3
"""
bin/fm-jev-aio-guard.py - Linux Native Asynchronous I/O (AIO) Capacity Guard (Pattern 316 / Pattern 454)

Audits Linux kernel native asynchronous I/O event consumption (/proc/sys/fs/aio-nr)
against system-wide allocation limits (/proc/sys/fs/aio-max-nr) to detect AIO event ring
saturation, io_setup EAGAIN failures, and database/storage async I/O bottlenecks under
multi-agent concurrent database and file operations.

Invariants:
  - Critical when AIO utilization >= 90.0%.
  - Warning when AIO utilization >= 75.0% or aio-max-nr < 65,536.
  - Fail-open: graceful fallback when sysctl paths are restricted.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_FS = "/proc/sys/fs"

DEFAULT_WARN_AIO_PCT = 75.0
DEFAULT_CRIT_AIO_PCT = 90.0
DEFAULT_MIN_AIO_MAX_NR = 65536


def parse_int_sysctl(path: Path, default: int = 0) -> int:
    if not path.is_file():
        return default
    try:
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        parts = content.split()
        return int(parts[0]) if parts and parts[0].lstrip("-").isdigit() else default
    except (ValueError, OSError, IndexError):
        return default


def evaluate_aio(
    fs_dir: str = PROC_FS,
    warn_aio_pct: float = DEFAULT_WARN_AIO_PCT,
    crit_aio_pct: float = DEFAULT_CRIT_AIO_PCT,
    min_aio_max_nr: int = DEFAULT_MIN_AIO_MAX_NR,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    fs_path = Path(fs_dir)
    aio_nr = parse_int_sysctl(fs_path / "aio-nr", default=0)
    aio_max_nr = parse_int_sysctl(fs_path / "aio-max-nr", default=65536)

    aio_pct = (aio_nr / aio_max_nr * 100.0) if aio_max_nr > 0 else 0.0
    aio_headroom = max(0, aio_max_nr - aio_nr)

    # Check aio_max_nr floor
    if aio_max_nr < min_aio_max_nr:
        status = "WARNING"
        issues.append(
            f"Kernel aio-max-nr is constrained ({aio_max_nr:,} < {min_aio_max_nr:,}); "
            "risk of io_setup EAGAIN failures under concurrent multi-agent database workloads"
        )
        recommendations.append(f"Increase sysctl fs.aio-max-nr >= {min_aio_max_nr}")

    # Check AIO event ring saturation
    if aio_pct >= crit_aio_pct:
        status = "CRITICAL"
        issues.append(
            f"Linux native AIO event capacity critical ({aio_pct:.2f}% >= {crit_aio_pct}%, "
            f"active_events={aio_nr:,}, max_events={aio_max_nr:,})"
        )
        recommendations.append("Increase sysctl fs.aio-max-nr immediately or audit async I/O consumers")
    elif aio_pct >= warn_aio_pct:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Linux native AIO event capacity elevated ({aio_pct:.2f}% >= {warn_aio_pct}%, "
            f"active_events={aio_nr:,}, max_events={aio_max_nr:,})"
        )
        recommendations.append("Monitor AIO event ring allocations across processes")

    healthy = (status == "HEALTHY")
    is_capacity_healthy = (aio_pct < warn_aio_pct) and (aio_max_nr >= min_aio_max_nr)

    return {
        "pattern": 316,
        "name": "aio",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_capacity_healthy": is_capacity_healthy,
        "aio_nr": aio_nr,
        "aio_max_nr": aio_max_nr,
        "aio_utilization_pct": round(aio_pct, 4),
        "aio_headroom": aio_headroom,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux native asynchronous I/O event consumption and limits."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--fs-dir", default=PROC_FS, help=f"Path to /proc/sys/fs (default: {PROC_FS})")
    parser.add_argument("--warn-aio-pct", type=float, default=DEFAULT_WARN_AIO_PCT, help="AIO warning threshold %%")
    parser.add_argument("--crit-aio-pct", type=float, default=DEFAULT_CRIT_AIO_PCT, help="AIO critical threshold %%")
    parser.add_argument("--min-aio-max-nr", type=int, default=DEFAULT_MIN_AIO_MAX_NR, help="Minimum aio-max-nr floor")

    args = parser.parse_args()

    result = evaluate_aio(
        fs_dir=args.fs_dir,
        warn_aio_pct=args.warn_aio_pct,
        crit_aio_pct=args.crit_aio_pct,
        min_aio_max_nr=args.min_aio_max_nr,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 316 (aio): {result['status']}")
        print(
            f"  Events: {result['aio_nr']:,} / {result['aio_max_nr']:,} ({result['aio_utilization_pct']}%) | "
            f"Headroom: {result['aio_headroom']:,} events"
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
