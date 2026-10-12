#!/usr/bin/env python3
"""
fm-jev-coredump-guard.py - Jev Multi-Agent Core Dump & Crash Artifact Hygiene Guard (Pattern 54)

Audits host core dump storage, /tmp, and multi-agent development trees for orphaned core dumps,
minidumps, and JVM/Node fatal crash logs (e.g. core.*, hs_err_pid*.log, *.stackdump).
Prevents silent multi-gigabyte disk exhaustion and inode leakage across persistent agent sessions.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful fallback on unreadable directories or permission barriers.
  - Fast bounded execution (< 1.5s).
"""

import argparse
import fnmatch
import json
import os
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set


DEFAULT_SEARCH_PATHS = [
    "/var/lib/systemd/coredump",
    "/tmp",
    "/home/jon/git",
    "/opt/ra/firstmate",
]

CRASH_FILE_PATTERNS = [
    "core",
    "core.[0-9]*",
    "core.*.zst",
    "core.*.lz4",
    "core.*.gz",
    "*.core",
    "hs_err_pid*.log",
    "*.stackdump",
    "*.dmp",
    "crash-*.dump",
]

# Filenames to ignore that match 'core*' but are harmless utilities/docs
IGNORE_FILENAMES = {
    "core-js-banners",
    "core-js",
    "core.clj",
    "core.py",
    "core.rb",
    "core.rs",
    "core.ts",
    "core.js",
}


def matches_crash_pattern(filename: str) -> bool:
    """Checks if filename matches any known core dump / crash artifact pattern."""
    if filename in IGNORE_FILENAMES or filename.startswith("."):
        return False
    for pat in CRASH_FILE_PATTERNS:
        if fnmatch.fnmatch(filename, pat):
            return True
    return False


def scan_directory_entries(dir_path: str, now_ts: float) -> List[Dict[str, Any]]:
    """Inspects files in a single directory for crash artifacts."""
    artifacts: List[Dict[str, Any]] = []
    try:
        with os.scandir(dir_path) as it:
            for entry in it:
                try:
                    if entry.is_file(follow_symlinks=False) and matches_crash_pattern(entry.name):
                        st = entry.stat(follow_symlinks=False)
                        size_bytes = st.st_size
                        mtime_ts = st.st_mtime
                        age_hours = round((now_ts - mtime_ts) / 3600.0, 2)
                        artifacts.append({
                            "path": entry.path,
                            "filename": entry.name,
                            "size_bytes": size_bytes,
                            "size_mb": round(size_bytes / (1024 * 1024), 2),
                            "mtime": datetime.fromtimestamp(mtime_ts, timezone.utc).isoformat(),
                            "age_hours": age_hours,
                        })
                except (PermissionError, FileNotFoundError):
                    continue
    except (PermissionError, FileNotFoundError):
        pass
    return artifacts


def scan_path_for_crash_artifacts(
    root_dir: str,
    max_depth: int = 2,
    now_ts: Optional[float] = None,
) -> List[Dict[str, Any]]:
    """Scans a directory path up to max_depth for crash artifacts using fast scandir."""
    if not os.path.exists(root_dir):
        return []

    if now_ts is None:
        now_ts = time.time()

    artifacts: List[Dict[str, Any]] = []
    # 1. Always scan the root dir top-level
    artifacts.extend(scan_directory_entries(root_dir, now_ts))

    # 2. For /tmp and /var/lib/systemd/coredump, top-level is sufficient
    if root_dir in ("/tmp", "/var/lib/systemd/coredump"):
        return artifacts

    # 3. For project dirs (e.g. /home/jon/git), scan 1 level of subdirs (repos)
    if max_depth > 1:
        try:
            with os.scandir(root_dir) as it:
                for sub in it:
                    try:
                        if sub.is_dir(follow_symlinks=False):
                            # Skip common build/hidden dirs
                            if sub.name in (".git", "node_modules", ".cargo", ".cache", "venv", ".venv"):
                                continue
                            artifacts.extend(scan_directory_entries(sub.path, now_ts))
                    except (PermissionError, FileNotFoundError):
                        continue
        except (PermissionError, FileNotFoundError):
            pass

    return artifacts


def audit_fleet_crash_artifacts(
    search_paths: Optional[List[str]] = None,
    max_age_hours: float = 24.0,
    max_total_mb: float = 500.0,
    max_depth: int = 2,
) -> Dict[str, Any]:
    """Audits crash artifacts across all search paths."""
    if search_paths is None:
        search_paths = DEFAULT_SEARCH_PATHS

    now_ts = time.time()
    all_artifacts: List[Dict[str, Any]] = []
    scanned_roots: List[str] = []
    seen_paths: Set[str] = set()

    for p in search_paths:
        expanded = os.path.expanduser(p)
        if os.path.exists(expanded):
            scanned_roots.append(expanded)
            items = scan_path_for_crash_artifacts(expanded, max_depth=max_depth, now_ts=now_ts)
            for item in items:
                if item["path"] not in seen_paths:
                    seen_paths.add(item["path"])
                    all_artifacts.append(item)

    total_size_bytes = sum(a["size_bytes"] for a in all_artifacts)
    total_size_mb = round(total_size_bytes / (1024 * 1024), 2)
    stale_artifacts = [a for a in all_artifacts if a["age_hours"] >= max_age_hours]

    status = "HEALTHY"
    recommendation = "optimal"

    if total_size_mb >= max_total_mb:
        status = "CRITICAL"
        recommendation = f"Total crash artifacts ({total_size_mb} MB) exceed critical threshold ({max_total_mb} MB); purge recommended"
    elif stale_artifacts:
        status = "WARNING"
        recommendation = f"{len(stale_artifacts)} stale crash artifacts detected (> {max_age_hours}h old); cleanup recommended"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "scanned_paths": scanned_roots,
            "total_artifacts_count": len(all_artifacts),
            "stale_artifacts_count": len(stale_artifacts),
            "total_size_mb": total_size_mb,
            "max_age_hours_threshold": max_age_hours,
            "max_total_mb_threshold": max_total_mb,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "artifacts": sorted(all_artifacts, key=lambda x: x["size_bytes"], reverse=True),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Core Dump & Crash Artifact Hygiene Guard (Pattern 54)"
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=None,
        help="Paths to scan for crash artifacts (default: /var/lib/systemd/coredump, /tmp, /home/jon/git, /opt/ra/firstmate)",
    )
    parser.add_argument(
        "--max-age-hours",
        type=float,
        default=24.0,
        help="Flag crash artifacts older than this age in hours (default: 24.0)",
    )
    parser.add_argument(
        "--max-total-mb",
        type=float,
        default=500.0,
        help="Flag warning/critical if total crash artifacts exceed this MB limit (default: 500.0)",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=2,
        help="Max directory search depth (default: 2)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Remove stale crash artifacts older than max-age-hours (requires explicit flag)",
    )

    args = parser.parse_args()

    results = audit_fleet_crash_artifacts(
        search_paths=args.paths,
        max_age_hours=args.max_age_hours,
        max_total_mb=args.max_total_mb,
        max_depth=args.depth,
    )

    if args.clean and results["artifacts"]:
        cleaned_count = 0
        cleaned_bytes = 0
        for a in results["artifacts"]:
            if a["age_hours"] >= args.max_age_hours:
                try:
                    os.remove(a["path"])
                    cleaned_count += 1
                    cleaned_bytes += a["size_bytes"]
                    a["deleted"] = True
                except Exception as e:
                    a["delete_error"] = str(e)
        results["summary"]["cleaned_count"] = cleaned_count
        results["summary"]["cleaned_mb"] = round(cleaned_bytes / (1024 * 1024), 2)

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev Core Dump & Crash Artifact Guard (Pattern 54) - {results['timestamp']}")
    print(f"Audited paths:        {len(summary['scanned_paths'])} scanned roots")
    print(f"Total Crash Artifacts:{summary['total_artifacts_count']} ({summary['total_size_mb']} MB)")
    print(f"Stale Artifacts:      {summary['stale_artifacts_count']} (> {summary['max_age_hours_threshold']}h)")
    print(f"Health Status:        {'HEALTHY' if summary['healthy'] else summary['status']}")
    print(f"Recommendation:       {summary['recommendation']}")

    if results["artifacts"]:
        print("\nArtifact Breakdown:")
        for a in results["artifacts"][:15]:
            print(f"  - {a['path']}: {a['size_mb']} MB (age: {a['age_hours']}h)")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
