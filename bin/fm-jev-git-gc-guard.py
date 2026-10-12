#!/usr/bin/env python3
"""
fm-jev-git-gc-guard.py - Jev Multi-Agent Orphan Git Pack & Loose Object Hygiene Guard (Pattern 53)

Audits git repositories across multi-agent seats for bloated loose objects (.git/objects/[0-9a-f]{2})
and uncompacted/orphan packfiles. Prevents inode saturation, disk bloat, and git command latency
caused by thousands of unpruned commit/blob objects across parallel worktrees.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Deduplicates worktrees pointing to the same common git objects store.
  - Fail-open: graceful handling of missing directories or permissions.
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

DEFAULT_LOOSE_WARN = 1000
DEFAULT_LOOSE_CRIT = 5000
DEFAULT_PACK_WARN = 20


def resolve_git_objects_dir(repo_path: str) -> Optional[Tuple[str, str]]:
    """
    Given a git working tree or bare repo, resolves the canonical repo root
    and the objects directory. Handles worktrees with gitdir and commondir.
    Returns (canonical_repo_id, objects_dir) or None.
    """
    git_entry = os.path.join(repo_path, ".git")
    if not os.path.exists(git_entry):
        # Could be a bare repo
        if os.path.exists(os.path.join(repo_path, "objects")) and os.path.exists(os.path.join(repo_path, "HEAD")):
            return (os.path.realpath(repo_path), os.path.realpath(os.path.join(repo_path, "objects")))
        return None

    if os.path.isfile(git_entry):
        # Worktree pointer file: "gitdir: /path/to/worktrees/name"
        try:
            with open(git_entry, "r", errors="replace") as f:
                line = f.readline().strip()
                if line.startswith("gitdir:"):
                    gitdir = line.split(":", 1)[1].strip()
                    if not os.path.isabs(gitdir):
                        gitdir = os.path.normpath(os.path.join(repo_path, gitdir))
                    if not os.path.exists(gitdir):
                        return None
                    # Check commondir
                    commondir_file = os.path.join(gitdir, "commondir")
                    if os.path.exists(commondir_file):
                        with open(commondir_file, "r", errors="replace") as cf:
                            commondir = cf.readline().strip()
                            if not os.path.isabs(commondir):
                                commondir = os.path.normpath(os.path.join(gitdir, commondir))
                            objects_dir = os.path.join(commondir, "objects")
                            return (os.path.realpath(commondir), os.path.realpath(objects_dir))
                    else:
                        # Fallback to parent of worktrees if applicable
                        parent_git = os.path.dirname(os.path.dirname(gitdir))
                        objects_dir = os.path.join(parent_git, "objects")
                        if os.path.exists(objects_dir):
                            return (os.path.realpath(parent_git), os.path.realpath(objects_dir))
                        return (os.path.realpath(gitdir), os.path.realpath(os.path.join(gitdir, "objects")))
        except Exception:
            return None
    elif os.path.isdir(git_entry):
        objects_dir = os.path.join(git_entry, "objects")
        return (os.path.realpath(git_entry), os.path.realpath(objects_dir))

    return None


def find_git_repos(search_paths: List[str], max_depth: int = 3) -> List[str]:
    """Finds directories containing a .git file or directory up to max_depth."""
    repos: List[str] = []
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

            # Skip common non-repo caches
            if os.path.basename(dirpath) in (".cargo", ".cache", "node_modules", ".gemini", "venv", ".venv"):
                dirnames.clear()
                continue

            if ".git" in dirnames or ".git" in filenames:
                real_dir = os.path.realpath(dirpath)
                if real_dir not in seen:
                    seen.add(real_dir)
                    repos.append(dirpath)
                # Don't recurse into subdirectories of a git repo looking for more git repos
                # unless they are worktrees or nested repos, but skipping saves time
                dirnames.clear()

    return repos


def inspect_git_objects(
    repo_path: str,
    objects_dir: str,
    loose_warn: int = DEFAULT_LOOSE_WARN,
    loose_crit: int = DEFAULT_LOOSE_CRIT,
    pack_warn: int = DEFAULT_PACK_WARN,
) -> Dict[str, Any]:
    """Audits loose objects and pack files in a git objects directory."""
    loose_count = 0
    loose_bytes = 0
    pack_count = 0
    pack_bytes = 0

    if os.path.exists(objects_dir) and os.path.isdir(objects_dir):
        try:
            with os.scandir(objects_dir) as it:
                for entry in it:
                    if entry.is_dir():
                        name = entry.name
                        # Loose object 2-char hex dirs: '00' - 'ff'
                        if len(name) == 2 and all(c in "0123456789abcdefABCDEF" for c in name):
                            try:
                                with os.scandir(entry.path) as sub_it:
                                    for obj in sub_it:
                                        if obj.is_file():
                                            loose_count += 1
                                            loose_bytes += obj.stat().st_size
                            except (PermissionError, FileNotFoundError):
                                pass
                        elif name == "pack":
                            try:
                                with os.scandir(entry.path) as pack_it:
                                    for pfile in pack_it:
                                        if pfile.is_file():
                                            if pfile.name.endswith(".pack"):
                                                pack_count += 1
                                                pack_bytes += pfile.stat().st_size
                                            elif pfile.name.endswith(".idx"):
                                                pack_bytes += pfile.stat().st_size
                            except (PermissionError, FileNotFoundError):
                                pass
        except (PermissionError, FileNotFoundError):
            pass

    status = "HEALTHY"
    recommendation = "optimal"

    if loose_count >= loose_crit:
        status = "CRITICAL"
        recommendation = "git gc --auto --prune=now recommended to reclaim loose object inodes"
    elif loose_count >= loose_warn:
        status = "WARNING"
        recommendation = "git gc --auto recommended to consolidate loose objects"
    elif pack_count >= pack_warn:
        status = "WARNING"
        recommendation = "git repack -d recommended to consolidate multiple packfiles"

    return {
        "repo_path": repo_path,
        "objects_dir": objects_dir,
        "loose_objects_count": loose_count,
        "loose_objects_size_bytes": loose_bytes,
        "loose_objects_size_mb": round(loose_bytes / (1024 * 1024), 2),
        "pack_files_count": pack_count,
        "pack_files_size_bytes": pack_bytes,
        "pack_files_size_mb": round(pack_bytes / (1024 * 1024), 2),
        "total_size_mb": round((loose_bytes + pack_bytes) / (1024 * 1024), 2),
        "status": status,
        "recommendation": recommendation,
    }


def audit_fleet_git_objects(
    search_paths: Optional[List[str]] = None,
    loose_warn: int = DEFAULT_LOOSE_WARN,
    loose_crit: int = DEFAULT_LOOSE_CRIT,
    pack_warn: int = DEFAULT_PACK_WARN,
    max_depth: int = 3,
) -> Dict[str, Any]:
    """Audits git object stores across the fleet paths."""
    if search_paths is None:
        search_paths = DEFAULT_AUDIT_PATHS

    repos = find_git_repos(search_paths, max_depth=max_depth)
    inspected_objects_dirs: Set[str] = set()
    repo_reports: List[Dict[str, Any]] = []

    total_loose_objects = 0
    total_loose_size_bytes = 0
    total_pack_files = 0
    total_pack_size_bytes = 0
    warning_count = 0
    critical_count = 0

    for repo in sorted(repos):
        res = resolve_git_objects_dir(repo)
        if not res:
            continue
        canon_id, objects_dir = res
        if objects_dir in inspected_objects_dirs:
            # Avoid auditing same shared object store multiple times
            continue
        inspected_objects_dirs.add(objects_dir)

        report = inspect_git_objects(
            repo,
            objects_dir,
            loose_warn=loose_warn,
            loose_crit=loose_crit,
            pack_warn=pack_warn,
        )
        repo_reports.append(report)

        total_loose_objects += report["loose_objects_count"]
        total_loose_size_bytes += report["loose_objects_size_bytes"]
        total_pack_files += report["pack_files_count"]
        total_pack_size_bytes += report["pack_files_size_bytes"]

        if report["status"] == "CRITICAL":
            critical_count += 1
        elif report["status"] == "WARNING":
            warning_count += 1

    overall_healthy = (critical_count == 0 and warning_count == 0)

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "scanned_paths": search_paths,
            "unique_repos_found": len(repos),
            "unique_object_stores_audited": len(inspected_objects_dirs),
            "total_loose_objects": total_loose_objects,
            "total_loose_size_mb": round(total_loose_size_bytes / (1024 * 1024), 2),
            "total_pack_files": total_pack_files,
            "total_pack_size_mb": round(total_pack_size_bytes / (1024 * 1024), 2),
            "total_git_objects_size_mb": round((total_loose_size_bytes + total_pack_size_bytes) / (1024 * 1024), 2),
            "critical_repos_count": critical_count,
            "warning_repos_count": warning_count,
            "healthy": overall_healthy,
        },
        "repositories": repo_reports,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Orphan Git Pack & Loose Object Hygiene Guard (Pattern 53)"
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=None,
        help="Paths or directories to scan for git repositories (default: /home/jon/git, /opt/ra/firstmate)",
    )
    parser.add_argument(
        "--loose-warn",
        type=int,
        default=DEFAULT_LOOSE_WARN,
        help=f"Loose objects count warning threshold (default: {DEFAULT_LOOSE_WARN})",
    )
    parser.add_argument(
        "--loose-crit",
        type=int,
        default=DEFAULT_LOOSE_CRIT,
        help=f"Loose objects count critical threshold (default: {DEFAULT_LOOSE_CRIT})",
    )
    parser.add_argument(
        "--pack-warn",
        type=int,
        default=DEFAULT_PACK_WARN,
        help=f"Pack files count warning threshold (default: {DEFAULT_PACK_WARN})",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=3,
        help="Max directory search depth when discovering git repositories (default: 3)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )
    parser.add_argument(
        "--auto-gc",
        action="store_true",
        help="Automatically trigger 'git gc --auto' on repositories in WARNING or CRITICAL state",
    )

    args = parser.parse_args()

    results = audit_fleet_git_objects(
        search_paths=args.paths,
        loose_warn=args.loose_warn,
        loose_crit=args.loose_crit,
        pack_warn=args.pack_warn,
        max_depth=args.depth,
    )

    if args.auto_gc:
        for r in results["repositories"]:
            if r["status"] in ("WARNING", "CRITICAL"):
                repo_path = r["repo_path"]
                try:
                    subprocess.run(
                        ["git", "-C", repo_path, "gc", "--auto", "--quiet"],
                        check=False,
                        timeout=30,
                    )
                    r["auto_gc_triggered"] = True
                except Exception as e:
                    r["auto_gc_error"] = str(e)

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev Git Object Hygiene Guard (Pattern 53) - {results['timestamp']}")
    print(f"Audited {summary['unique_object_stores_audited']} unique object stores across {summary['unique_repos_found']} repos")
    print(f"Total Loose Objects: {summary['total_loose_objects']} ({summary['total_loose_size_mb']} MB)")
    print(f"Total Pack Files:    {summary['total_pack_files']} ({summary['total_pack_size_mb']} MB)")
    print(f"Total Object Size:   {summary['total_git_objects_size_mb']} MB")
    print(f"Health Status:       {'HEALTHY' if summary['healthy'] else 'ACTION REQUIRED'}")

    if results["repositories"]:
        print("\nRepository Breakdown:")
        for r in results["repositories"]:
            status_symbol = "✓" if r["status"] == "HEALTHY" else ("!" if r["status"] == "WARNING" else "✗")
            print(
                f"  [{status_symbol}] {r['repo_path']}: "
                f"{r['loose_objects_count']} loose ({r['loose_objects_size_mb']}MB), "
                f"{r['pack_files_count']} packs ({r['pack_files_size_mb']}MB) -> {r['status']}"
            )
            if r["status"] != "HEALTHY":
                print(f"      Recommendation: {r['recommendation']}")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
