#!/usr/bin/env python3
"""
fm-jev-pycache-guard.py - Jev Multi-Agent Python Bytecode & __pycache__ Invalidation Guard (Pattern 55)

Audits Python projects across multi-agent worktrees for orphaned .pyc bytecode files whose source .py
files have been deleted, moved, or renamed. Prevents phantom module imports, stale bytecode execution,
and ghost test failures across branch switches and worktree rebases.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling of missing directories or permissions.
  - Bounded fast execution (< 2.0s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple


DEFAULT_AUDIT_PATHS = [
    "/opt/ra/firstmate",
    "/home/jon/git/wt-portal-visual-qa",
    "/home/jon/git/jev",
]

DEFAULT_ORPHAN_WARN = 5
DEFAULT_ORPHAN_CRIT = 25


def extract_source_module_name(pyc_filename: str) -> str:
    """
    Extracts the source module base name from a pyc filename.
    Examples:
      - utils.cpython-311.pyc -> utils
      - gunicorn.conf.cpython-311.pyc -> gunicorn.conf
      - helper.pyc -> helper
    """
    stem = pyc_filename[:-4] if pyc_filename.endswith(".pyc") else pyc_filename
    if ".cpython-" in stem:
        return stem.split(".cpython-")[0]
    if ".pypy" in stem:
        return stem.split(".pypy")[0]
    return stem


def audit_pycache_dir(pycache_path: str) -> Tuple[List[Dict[str, Any]], int, int]:
    """
    Audits a single __pycache__ directory for orphaned .pyc files.
    Returns (orphaned_files, total_pyc_count, total_pyc_bytes).
    """
    orphans: List[Dict[str, Any]] = []
    total_count = 0
    total_bytes = 0

    parent_dir = os.path.dirname(pycache_path)

    try:
        with os.scandir(pycache_path) as it:
            for entry in it:
                try:
                    if entry.is_file(follow_symlinks=False) and entry.name.endswith(".pyc"):
                        total_count += 1
                        st = entry.stat(follow_symlinks=False)
                        size_bytes = st.st_size
                        total_bytes += size_bytes

                        mod_base = extract_source_module_name(entry.name)
                        source_py = os.path.join(parent_dir, f"{mod_base}.py")
                        source_pyw = os.path.join(parent_dir, f"{mod_base}.pyw")

                        if not os.path.exists(source_py) and not os.path.exists(source_pyw):
                            orphans.append({
                                "pyc_path": entry.path,
                                "pyc_name": entry.name,
                                "expected_source": source_py,
                                "size_bytes": size_bytes,
                                "size_kb": round(size_bytes / 1024.0, 2),
                                "mtime": datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat(),
                            })
                except (PermissionError, FileNotFoundError):
                    continue
    except (PermissionError, FileNotFoundError):
        pass

    return orphans, total_count, total_bytes


def audit_path_pycache(
    root_path: str,
    max_depth: int = 5,
) -> Dict[str, Any]:
    """Recursively audits a path for __pycache__ directories and orphaned .pyc files."""
    all_orphans: List[Dict[str, Any]] = []
    pycache_dirs_count = 0
    empty_pycache_dirs: List[str] = []
    total_pyc_files = 0
    total_pyc_bytes = 0

    if not os.path.exists(root_path):
        return {
            "root_path": root_path,
            "pycache_dirs_count": 0,
            "total_pyc_files": 0,
            "total_pyc_mb": 0.0,
            "orphaned_pyc_count": 0,
            "orphaned_pyc_kb": 0.0,
            "empty_pycache_dirs": [],
            "orphans": [],
        }

    root_depth = root_path.rstrip(os.path.sep).count(os.path.sep)

    try:
        for dirpath, dirnames, filenames in os.walk(root_path, followlinks=False):
            current_depth = dirpath.count(os.path.sep) - root_depth
            if current_depth >= max_depth:
                dirnames.clear()

            # Skip virtual environments and package managers
            if os.path.basename(dirpath) in (".git", "node_modules", ".cache", ".cargo", "venv", ".venv", ".tox"):
                dirnames.clear()
                continue

            if os.path.basename(dirpath) == "__pycache__":
                pycache_dirs_count += 1
                orphans, count, bytes_count = audit_pycache_dir(dirpath)
                total_pyc_files += count
                total_pyc_bytes += bytes_count
                all_orphans.extend(orphans)
                if count == 0 and len(filenames) == 0:
                    empty_pycache_dirs.append(dirpath)
                # Don't recurse inside __pycache__
                dirnames.clear()
    except (PermissionError, FileNotFoundError):
        pass

    orphaned_bytes = sum(o["size_bytes"] for o in all_orphans)

    return {
        "root_path": root_path,
        "pycache_dirs_count": pycache_dirs_count,
        "total_pyc_files": total_pyc_files,
        "total_pyc_mb": round(total_pyc_bytes / (1024 * 1024), 2),
        "orphaned_pyc_count": len(all_orphans),
        "orphaned_pyc_kb": round(orphaned_bytes / 1024.0, 2),
        "empty_pycache_dirs_count": len(empty_pycache_dirs),
        "empty_pycache_dirs": empty_pycache_dirs,
        "orphans": all_orphans,
    }


def audit_fleet_pycache(
    search_paths: Optional[List[str]] = None,
    orphan_warn: int = DEFAULT_ORPHAN_WARN,
    orphan_crit: int = DEFAULT_ORPHAN_CRIT,
    max_depth: int = 5,
) -> Dict[str, Any]:
    """Audits specified fleet paths for __pycache__ hygiene."""
    if search_paths is None:
        search_paths = DEFAULT_AUDIT_PATHS

    path_reports: List[Dict[str, Any]] = []
    total_orphans = 0
    total_orphan_bytes = 0
    total_pyc_count = 0
    total_pycache_dirs = 0

    for p in search_paths:
        expanded = os.path.expanduser(p)
        if os.path.exists(expanded):
            rep = audit_path_pycache(expanded, max_depth=max_depth)
            path_reports.append(rep)
            total_orphans += rep["orphaned_pyc_count"]
            total_orphan_bytes += sum(o["size_bytes"] for o in rep["orphans"])
            total_pyc_count += rep["total_pyc_files"]
            total_pycache_dirs += rep["pycache_dirs_count"]

    status = "HEALTHY"
    recommendation = "optimal"

    if total_orphans >= orphan_crit:
        status = "CRITICAL"
        recommendation = f"{total_orphans} orphaned .pyc files detected; run with --prune to eliminate phantom imports"
    elif total_orphans >= orphan_warn:
        status = "WARNING"
        recommendation = f"{total_orphans} orphaned .pyc files detected; run with --prune to eliminate stale bytecode"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "scanned_paths": search_paths,
            "total_pycache_dirs": total_pycache_dirs,
            "total_pyc_files": total_pyc_count,
            "total_orphaned_pyc_count": total_orphans,
            "total_orphaned_pyc_kb": round(total_orphan_bytes / 1024.0, 2),
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "roots": path_reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Python Bytecode & __pycache__ Invalidation Guard (Pattern 55)"
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=None,
        help="Paths to audit for __pycache__ directories (default: /opt/ra/firstmate, /home/jon/git/wt-portal-visual-qa, /home/jon/git/jev)",
    )
    parser.add_argument(
        "--orphan-warn",
        type=int,
        default=DEFAULT_ORPHAN_WARN,
        help=f"Warning threshold for orphaned .pyc files (default: {DEFAULT_ORPHAN_WARN})",
    )
    parser.add_argument(
        "--orphan-crit",
        type=int,
        default=DEFAULT_ORPHAN_CRIT,
        help=f"Critical threshold for orphaned .pyc files (default: {DEFAULT_ORPHAN_CRIT})",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=5,
        help="Max directory search depth (default: 5)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )
    parser.add_argument(
        "--prune",
        action="store_true",
        help="Remove orphaned .pyc files and delete empty __pycache__ directories",
    )

    args = parser.parse_args()

    results = audit_fleet_pycache(
        search_paths=args.paths,
        orphan_warn=args.orphan_warn,
        orphan_crit=args.orphan_crit,
        max_depth=args.depth,
    )

    if args.prune:
        pruned_count = 0
        pruned_bytes = 0
        for root in results["roots"]:
            for orphan in root["orphans"]:
                try:
                    os.remove(orphan["pyc_path"])
                    pruned_count += 1
                    pruned_bytes += orphan["size_bytes"]
                    orphan["pruned"] = True
                except Exception as e:
                    orphan["prune_error"] = str(e)
            for empty_dir in root.get("empty_pycache_dirs", []):
                try:
                    os.rmdir(empty_dir)
                except Exception:
                    pass
        results["summary"]["pruned_count"] = pruned_count
        results["summary"]["pruned_kb"] = round(pruned_bytes / 1024.0, 2)

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev PyCache Invalidation Guard (Pattern 55) - {results['timestamp']}")
    print(f"Audited {summary['total_pycache_dirs']} __pycache__ dirs ({summary['total_pyc_files']} total .pyc files)")
    print(f"Orphaned .pyc files: {summary['total_orphaned_pyc_count']} ({summary['total_orphaned_pyc_kb']} KB)")
    print(f"Health Status:       {summary['status']}")
    print(f"Recommendation:      {summary['recommendation']}")

    for root in results["roots"]:
        if root["orphaned_pyc_count"] > 0:
            print(f"\n  Found {root['orphaned_pyc_count']} orphans under {root['root_path']}:")
            for o in root["orphans"][:10]:
                print(f"    - {o['pyc_path']} (missing: {os.path.basename(o['expected_source'])})")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
