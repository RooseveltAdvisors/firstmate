#!/usr/bin/env python3
"""
fm-jev-symlink-guard.py - Jev Multi-Agent Broken Symlink & Dangling Worktree Link Guard (Pattern 52)

Audits fleet tool directories, node_modules links, and treehouse worktrees for broken symlinks
and dangling .git worktree pointer files caused by seat teardowns, branch pruning, or directory moves.
Prevents "No such file or directory" (ENOENT) subshell crashes and git worktree corruption.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful fallback on permission issues.
  - Bounded sub-second execution (< 1.5s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


DEFAULT_AUDIT_PATHS = [
    "/opt/ra/firstmate/bin",
    "/opt/ra/firstmate/scratch",
    "/home/jon/git",
]


def audit_path_symlinks(root_dir: str, max_depth: int = 3) -> List[Dict[str, Any]]:
    """Recursively audits a directory for broken symlinks and dangling .git files."""
    broken: List[Dict[str, Any]] = []
    if not os.path.exists(root_dir):
        return broken

    root_depth = root_dir.rstrip(os.path.sep).count(os.path.sep)

    for dirpath, dirnames, filenames in os.walk(root_dir, followlinks=False):
        current_depth = dirpath.count(os.path.sep) - root_depth
        if current_depth >= max_depth:
            dirnames.clear()  # Don't recurse further

        # 1. Check symlinks in directory entries (both dirs and files)
        all_entries = dirnames + filenames
        for entry in all_entries:
            full_path = os.path.join(dirpath, entry)
            try:
                if os.path.islink(full_path):
                    target = os.readlink(full_path)
                    # Check if target exists
                    if not os.path.exists(full_path):
                        broken.append({
                            "path": full_path,
                            "type": "broken_symlink",
                            "target": target,
                        })
            except (PermissionError, FileNotFoundError):
                continue
            except Exception:
                continue

        # 2. Check for dangling .git file (worktree pointers)
        if ".git" in filenames:
            git_file = os.path.join(dirpath, ".git")
            try:
                if os.path.isfile(git_file) and not os.path.islink(git_file):
                    with open(git_file, "r", errors="replace") as f:
                        line = f.readline().strip()
                        if line.startswith("gitdir:"):
                            gitdir_target = line.split(":", 1)[1].strip()
                            if not os.path.exists(gitdir_target):
                                broken.append({
                                    "path": git_file,
                                    "type": "dangling_gitdir_worktree",
                                    "target": gitdir_target,
                                })
            except Exception:
                pass

    return broken


def audit_fleet_symlinks(
    search_paths: List[str] | None = None,
    max_depth: int = 3,
) -> Dict[str, Any]:
    """Audits specified paths for broken symlinks and dangling worktree pointers."""
    if search_paths is None:
        search_paths = DEFAULT_AUDIT_PATHS

    all_broken: List[Dict[str, Any]] = []
    scanned_roots: List[str] = []

    for p in search_paths:
        expanded = os.path.expanduser(p)
        if os.path.exists(expanded):
            scanned_roots.append(expanded)
            items = audit_path_symlinks(expanded, max_depth=max_depth)
            all_broken.extend(items)

    healthy = len(all_broken) == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "audited_paths": scanned_roots,
            "broken_links_count": len(all_broken),
            "healthy": healthy,
        },
        "broken_links": all_broken,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Broken Symlink & Dangling Worktree Link Guard (Pattern 52)"
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=DEFAULT_AUDIT_PATHS,
        help="Root paths to audit for broken links (default: /opt/ra/firstmate/bin /opt/ra/firstmate/scratch /home/jon/git)",
    )
    parser.add_argument(
        "--max-depth",
        type=int,
        default=3,
        help="Maximum directory traversal depth (default: 3)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if broken symlinks detected",
    )

    args = parser.parse_args()
    report = audit_fleet_symlinks(
        search_paths=args.paths,
        max_depth=args.max_depth,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Broken Symlink & Worktree Link Guard (Pattern 52) — {report['timestamp']}")
        print(f"  • Monitored Paths: {', '.join(s['audited_paths'])}")
        print(f"  • Broken Symlinks / Pointers: {s['broken_links_count']}")
        print(f"  • Status: {'HEALTHY' if s['healthy'] else 'ACTION REQUIRED'}")
        if report["broken_links"]:
            print("\n  Broken Links Detected:")
            for item in report["broken_links"][:15]:
                print(f"    - {item['path']} -> {item['target']} ({item['type']})")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
