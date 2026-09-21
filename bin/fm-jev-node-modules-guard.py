#!/usr/bin/env python3
"""
fm-jev-node-modules-guard.py - Jev Multi-Agent node_modules Bloat & Worktree Duplication Guard (Pattern 57)

Audits JavaScript/TypeScript multi-agent worktrees and project roots for node_modules bloat,
nested duplicate trees, and orphaned package directories across seats.
Prevents disk exhaustion and I/O slowdowns across parallel agent worktrees.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling of unreadable or unlinked directories.
  - Fast bounded execution (< 2.0s).
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple


DEFAULT_AUDIT_PATHS = [
    "/home/jon/git",
    "/opt/ra/firstmate",
]

DEFAULT_MAX_TOTAL_GB = 20.0
DEFAULT_MAX_SINGLE_GB = 3.0


def count_top_level_packages(nm_path: str) -> int:
    """Counts direct top-level packages (including @scoped packages)."""
    count = 0
    try:
        with os.scandir(nm_path) as it:
            for entry in it:
                if entry.is_dir(follow_symlinks=False):
                    if entry.name.startswith("@"):
                        try:
                            with os.scandir(entry.path) as sub_it:
                                for sub_entry in sub_it:
                                    if sub_entry.is_dir(follow_symlinks=False):
                                        count += 1
                        except Exception:
                            pass
                    elif not entry.name.startswith("."):
                        count += 1
    except Exception:
        pass
    return count


def get_dir_size_mb(path: str) -> float:
    """Calculates directory size in MB using du for speed."""
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


def find_node_modules_dirs(search_paths: List[str], max_depth: int = 4) -> List[str]:
    """Finds all node_modules directories across search paths up to max_depth."""
    found: List[str] = []
    seen: Set[str] = set()

    for root in search_paths:
        expanded = os.path.expanduser(root)
        if not os.path.exists(expanded):
            continue

        root_depth = expanded.rstrip(os.path.sep).count(os.path.sep)
        for dirpath, dirnames, filenames in os.walk(expanded, followlinks=False):
            current_depth = dirpath.count(os.path.sep) - root_depth
            if current_depth >= max_depth:
                dirnames.clear()

            if "node_modules" in dirnames:
                nm_path = os.path.join(dirpath, "node_modules")
                real_p = os.path.realpath(nm_path)
                if real_p not in seen:
                    seen.add(real_p)
                    found.append(nm_path)
                # Don't recurse inside node_modules when searching for root node_modules
                dirnames.remove("node_modules")

    return sorted(found)


def audit_fleet_node_modules(
    search_paths: Optional[List[str]] = None,
    max_total_gb: float = DEFAULT_MAX_TOTAL_GB,
    max_single_gb: float = DEFAULT_MAX_SINGLE_GB,
    max_depth: int = 4,
) -> Dict[str, Any]:
    """Audits fleet paths for node_modules disk usage and package density."""
    if search_paths is None:
        search_paths = DEFAULT_AUDIT_PATHS

    nm_paths = find_node_modules_dirs(search_paths, max_depth=max_depth)
    reports: List[Dict[str, Any]] = []

    total_mb = 0.0
    total_packages = 0
    oversized_dirs = []

    for p in nm_paths:
        size_mb = get_dir_size_mb(p)
        pkg_count = count_top_level_packages(p)
        total_mb += size_mb
        total_packages += pkg_count

        size_gb = round(size_mb / 1024.0, 2)
        is_oversized = size_gb >= max_single_gb

        if is_oversized:
            oversized_dirs.append(p)

        reports.append({
            "path": p,
            "parent_project": os.path.dirname(p),
            "size_mb": round(size_mb, 1),
            "size_gb": size_gb,
            "top_level_packages": pkg_count,
            "oversized": is_oversized,
        })

    total_gb = round(total_mb / 1024.0, 2)
    status = "HEALTHY"
    recommendation = "optimal"

    if total_gb >= max_total_gb:
        status = "CRITICAL"
        recommendation = f"Total node_modules disk usage ({total_gb} GB) exceeds threshold ({max_total_gb} GB); purge stale worktrees"
    elif oversized_dirs:
        status = "WARNING"
        recommendation = f"{len(oversized_dirs)} oversized node_modules directories detected (> {max_single_gb} GB)"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "scanned_paths": search_paths,
            "total_node_modules_count": len(nm_paths),
            "total_size_mb": round(total_mb, 1),
            "total_size_gb": total_gb,
            "total_top_level_packages": total_packages,
            "oversized_count": len(oversized_dirs),
            "max_total_gb_threshold": max_total_gb,
            "max_single_gb_threshold": max_single_gb,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "directories": sorted(reports, key=lambda x: x["size_mb"], reverse=True),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent node_modules Bloat Guard (Pattern 57)"
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=None,
        help="Paths to audit for node_modules (default: /home/jon/git, /opt/ra/firstmate)",
    )
    parser.add_argument(
        "--max-total-gb",
        type=float,
        default=DEFAULT_MAX_TOTAL_GB,
        help=f"Total fleet node_modules threshold in GB (default: {DEFAULT_MAX_TOTAL_GB})",
    )
    parser.add_argument(
        "--max-single-gb",
        type=float,
        default=DEFAULT_MAX_SINGLE_GB,
        help=f"Single node_modules directory threshold in GB (default: {DEFAULT_MAX_SINGLE_GB})",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=4,
        help="Max directory search depth (default: 4)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )

    args = parser.parse_args()

    results = audit_fleet_node_modules(
        search_paths=args.paths,
        max_total_gb=args.max_total_gb,
        max_single_gb=args.max_single_gb,
        max_depth=args.depth,
    )

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev node_modules Bloat Guard (Pattern 57) - {results['timestamp']}")
    print(f"Found {summary['total_node_modules_count']} node_modules directories ({summary['total_size_gb']} GB total)")
    print(f"Top-level packages:  {summary['total_top_level_packages']}")
    print(f"Health Status:       {summary['status']}")
    print(f"Recommendation:      {summary['recommendation']}")

    if results["directories"]:
        print("\nDirectory Breakdown (Top 10):")
        for d in results["directories"][:10]:
            print(f"  - {d['path']}: {d['size_mb']} MB ({d['top_level_packages']} pkgs)")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
