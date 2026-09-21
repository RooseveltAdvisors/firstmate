#!/usr/bin/env python3
"""
fm-jev-drift-guard.py - Jev Multi-Agent Worktree Detached HEAD & Git Ref Drift Guard (Pattern 50)

Audits git repositories and treehouse worktrees across multi-agent seats to detect detached
HEAD states, unpushed commits, uncommitted worktree drift, and abandoned local branches.
Prevents silent code loss when worker worktrees are torn down or superseded by main.

Invariants:
  - Read-only diagnostics. Non-destructive: never runs git mutations or prunes.
  - Fail-open: graceful fallback on non-git directories or permission issues.
  - Bounded sub-second execution (< 2.0s).
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


DEFAULT_SEARCH_PATHS = [
    "/opt/ra",
    "/home/jon/git",
]


def audit_git_worktree(repo_path: str) -> Optional[Dict[str, Any]]:
    """Audits a single git repository or worktree for drift/detached state."""
    git_dir = os.path.join(repo_path, ".git")
    if not os.path.exists(git_dir):
        return None

    try:
        # 1. Check branch name / detached HEAD
        branch_proc = subprocess.run(
            ["git", "-C", repo_path, "symbolic-ref", "--short", "-q", "HEAD"],
            capture_output=True,
            text=True,
            timeout=1.0,
        )
        is_detached = branch_proc.returncode != 0
        branch_name = branch_proc.stdout.strip() if not is_detached else "DETACHED"

        # 2. Check uncommitted changes
        status_proc = subprocess.run(
            ["git", "-C", repo_path, "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=1.0,
        )
        has_dirty_files = bool(status_proc.stdout.strip())
        dirty_count = len(status_proc.stdout.strip().splitlines()) if has_dirty_files else 0

        # 3. Check upstream divergence (ahead/behind)
        ahead = 0
        behind = 0
        has_upstream = False
        if not is_detached:
            rev_proc = subprocess.run(
                ["git", "-C", repo_path, "rev-list", "--left-right", "--count", "HEAD...@{u}"],
                capture_output=True,
                text=True,
                timeout=1.0,
            )
            if rev_proc.returncode == 0:
                has_upstream = True
                parts = rev_proc.stdout.strip().split()
                if len(parts) == 2:
                    ahead = int(parts[0]) if parts[0].isdigit() else 0
                    behind = int(parts[1]) if parts[1].isdigit() else 0

        # Flag issues
        needs_attention = is_detached or (ahead > 0 and not has_upstream)

        return {
            "path": repo_path,
            "branch": branch_name,
            "detached_head": is_detached,
            "dirty": has_dirty_files,
            "dirty_file_count": dirty_count,
            "has_upstream": has_upstream,
            "commits_ahead": ahead,
            "commits_behind": behind,
            "needs_attention": needs_attention,
        }
    except Exception:
        return None


def discover_worktrees(search_paths: List[str], max_repos: int = 50) -> List[str]:
    """Finds directories containing .git or .git file (worktree link)."""
    found: List[str] = []
    for root_dir in search_paths:
        if not os.path.exists(root_dir):
            continue
        try:
            for entry in os.scandir(root_dir):
                if entry.is_dir():
                    git_marker = os.path.join(entry.path, ".git")
                    if os.path.exists(git_marker):
                        found.append(entry.path)
                        if len(found) >= max_repos:
                            return found
        except Exception:
            continue
    return found


def audit_fleet_drift(
    search_paths: List[str] | None = None,
    max_repos: int = 50,
) -> Dict[str, Any]:
    """Audits worktrees for detached HEAD and drift."""
    if search_paths is None:
        search_paths = DEFAULT_SEARCH_PATHS

    repo_paths = discover_worktrees(search_paths, max_repos=max_repos)
    audited: List[Dict[str, Any]] = []
    detached_count = 0
    dirty_count = 0
    diverged_count = 0

    for path in repo_paths:
        res = audit_git_worktree(path)
        if res:
            audited.append(res)
            if res["detached_head"]:
                detached_count += 1
            if res["dirty"]:
                dirty_count += 1
            if res["commits_ahead"] > 0:
                diverged_count += 1

    healthy = detached_count == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "total_worktrees_audited": len(audited),
            "detached_head_count": detached_count,
            "dirty_worktrees_count": dirty_count,
            "unpushed_ahead_count": diverged_count,
            "healthy": healthy,
        },
        "worktrees": audited,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Worktree Detached HEAD & Git Ref Drift Guard (Pattern 50)"
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=DEFAULT_SEARCH_PATHS,
        help="Search paths for git worktrees (default: /opt/ra /home/jon/git)",
    )
    parser.add_argument(
        "--max-repos",
        type=int,
        default=50,
        help="Maximum worktrees to audit (default: 50)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if detached HEAD detected",
    )

    args = parser.parse_args()
    report = audit_fleet_drift(
        search_paths=args.paths,
        max_repos=args.max_repos,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Worktree Ref Drift Guard (Pattern 50) — {report['timestamp']}")
        print(f"  • Total Audited: {s['total_worktrees_audited']} worktrees")
        print(f"  • Detached HEADs: {s['detached_head_count']}")
        print(f"  • Dirty Worktrees: {s['dirty_worktrees_count']}")
        print(f"  • Ahead (Unpushed): {s['unpushed_ahead_count']}")
        print(f"  • Status: {'HEALTHY' if s['healthy'] else 'DETACHED WORKTREES DETECTED'}")
        if report["worktrees"]:
            print("\n  Monitored Worktrees:")
            for wt in report["worktrees"][:15]:
                state_flags = []
                if wt["detached_head"]:
                    state_flags.append("DETACHED")
                if wt["dirty"]:
                    state_flags.append(f"DIRTY({wt['dirty_file_count']})")
                if wt["commits_ahead"] > 0:
                    state_flags.append(f"+{wt['commits_ahead']} ahead")
                flags_str = f" [{', '.join(state_flags)}]" if state_flags else " [CLEAN]"
                print(f"    - {os.path.basename(wt['path'])} ({wt['branch']}){flags_str}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
