#!/usr/bin/env python3
"""
fm-jev-pip-cache-guard.py - Jev Multi-Agent Pip & UV Package Cache Bloat Guard (Pattern 59)

Audits Python package caches (~/.cache/pip and ~/.cache/uv) for accumulated wheel archives,
stale build artifacts, and downloaded tarballs across multi-agent worktrees.
Prevents disk exhaustion from multi-gigabyte unpruned wheel caches.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling of missing cache directories.
  - Bounded fast execution (< 2.0s).
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_CACHE_PATHS = [
    os.path.expanduser("~/.cache/pip"),
    os.path.expanduser("~/.cache/uv"),
]

DEFAULT_MAX_TOTAL_GB = 15.0
DEFAULT_MAX_SINGLE_GB = 10.0


def get_dir_size_mb(path: str) -> float:
    """Calculates directory size in MB using du for sub-second execution."""
    if not os.path.exists(path):
        return 0.0
    try:
        res = subprocess.run(
            ["du", "-sm", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
        if res.returncode == 0 and res.stdout:
            val = res.stdout.strip().split()[0]
            return float(val)
    except Exception:
        pass
    return 0.0


def count_cache_wheels(cache_path: str, max_depth: int = 4) -> Tuple[int, int]:
    """Counts .whl and .tar.gz archives in cache directory."""
    wheel_count = 0
    tar_count = 0
    if not os.path.exists(cache_path):
        return 0, 0

    root_depth = cache_path.rstrip(os.path.sep).count(os.path.sep)
    try:
        for dirpath, dirnames, filenames in os.walk(cache_path, followlinks=False):
            current_depth = dirpath.count(os.path.sep) - root_depth
            if current_depth >= max_depth:
                dirnames.clear()

            for f in filenames:
                if f.endswith(".whl"):
                    wheel_count += 1
                elif f.endswith(".tar.gz") or f.endswith(".tgz"):
                    tar_count += 1
    except (PermissionError, FileNotFoundError):
        pass

    return wheel_count, tar_count


def audit_fleet_pip_caches(
    cache_paths: Optional[List[str]] = None,
    max_total_gb: float = DEFAULT_MAX_TOTAL_GB,
    max_single_gb: float = DEFAULT_MAX_SINGLE_GB,
) -> Dict[str, Any]:
    """Audits specified package cache directories."""
    if cache_paths is None:
        cache_paths = DEFAULT_CACHE_PATHS

    reports: List[Dict[str, Any]] = []
    total_mb = 0.0
    total_wheels = 0
    total_tarballs = 0
    oversized_caches: List[str] = []

    for p in cache_paths:
        expanded = os.path.expanduser(p)
        if not os.path.exists(expanded):
            continue

        size_mb = get_dir_size_mb(expanded)
        wheels, tarballs = count_cache_wheels(expanded)
        total_mb += size_mb
        total_wheels += wheels
        total_tarballs += tarballs

        size_gb = round(size_mb / 1024.0, 2)
        is_oversized = size_gb >= max_single_gb

        if is_oversized:
            oversized_caches.append(expanded)

        cache_type = "uv" if "uv" in expanded else ("pip" if "pip" in expanded else "python")
        reports.append({
            "path": expanded,
            "type": cache_type,
            "size_mb": round(size_mb, 1),
            "size_gb": size_gb,
            "wheel_count": wheels,
            "tarball_count": tarballs,
            "oversized": is_oversized,
        })

    total_gb = round(total_mb / 1024.0, 2)
    status = "HEALTHY"
    recommendation = "optimal"

    if total_gb >= max_total_gb:
        status = "WARNING"
        recommendation = f"Package cache total ({total_gb} GB) exceeds threshold ({max_total_gb} GB); run 'pip cache purge' or 'uv cache prune'"
    elif oversized_caches:
        status = "WARNING"
        recommendation = f"{len(oversized_caches)} oversized cache dirs detected (> {max_single_gb} GB)"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "scanned_caches": cache_paths,
            "total_size_mb": round(total_mb, 1),
            "total_size_gb": total_gb,
            "total_wheels": total_wheels,
            "total_tarballs": total_tarballs,
            "oversized_caches_count": len(oversized_caches),
            "max_total_gb_threshold": max_total_gb,
            "max_single_gb_threshold": max_single_gb,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "caches": reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Pip & UV Package Cache Guard (Pattern 59)"
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=None,
        help="Paths to cache directories (default: ~/.cache/pip, ~/.cache/uv)",
    )
    parser.add_argument(
        "--max-total-gb",
        type=float,
        default=DEFAULT_MAX_TOTAL_GB,
        help=f"Max total cache size in GB before warning (default: {DEFAULT_MAX_TOTAL_GB})",
    )
    parser.add_argument(
        "--max-single-gb",
        type=float,
        default=DEFAULT_MAX_SINGLE_GB,
        help=f"Max single cache directory size in GB before warning (default: {DEFAULT_MAX_SINGLE_GB})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )

    args = parser.parse_args()

    results = audit_fleet_pip_caches(
        cache_paths=args.paths,
        max_total_gb=args.max_total_gb,
        max_single_gb=args.max_single_gb,
    )

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev Pip & UV Cache Guard (Pattern 59) - {results['timestamp']}")
    print(f"Total Cache Size:    {summary['total_size_gb']} GB across {len(results['caches'])} locations")
    print(f"Total Cached Wheels: {summary['total_wheels']} wheels, {summary['total_tarballs']} source tarballs")
    print(f"Health Status:       {summary['status']}")
    print(f"Recommendation:      {summary['recommendation']}")

    if results["caches"]:
        print("\nCache Breakdown:")
        for c in results["caches"]:
            print(f"  - {c['path']}: {c['size_gb']} GB ({c['wheel_count']} wheels, {c['tarball_count']} tarballs) -> {'OVERSIZED' if c['oversized'] else 'OK'}")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
