#!/usr/bin/env python3
"""
fm-jev-worktree-reaper.py - Jev Git Worktree Stale Prune & Detached Branch Reaper (Pattern 19)

Scans git worktrees across fleet repositories and treehouse roots, detects clean
worktrees whose branches or detached HEADs have already landed on origin/main, and
safely removes them to recover disk space, prune obsolete worktree registrations,
and prevent git clutter.

Safety invariants:
- NEVER touches dirty worktrees (uncommitted changes or untracked files).
- NEVER removes the main/root repository worktree.
- NEVER deletes a worktree still referenced by the fleet: a Firstmate task
  record (state/<task>.meta worktree=) naming it or a path above it, a durable
  treehouse pool lease, or a running process with its cwd or an open file
  inside it all make a worktree referenced, and a reference forbids reaping
  regardless of git state.
- Treats an inconclusive process probe (no process table, or any pid whose
  cwd or fds cannot be read) as referenced: reaping is optional maintenance,
  so doubt resolves to keep.
- Verifies that HEAD or branch is an ancestor of origin/main before reaping.
  Merged ancestry alone is never sufficient - the reference proof above must
  also pass, so a worktree is reaped only when it is provably unreferenced.
- Fully supports dry-run mode for safe previewing.
- Fails open gracefully on git errors.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple


def find_repo_dir(repo_name: str) -> Optional[str]:
    if not repo_name:
        return None
    # 1. Look in treehouse roots
    th_root = Path.home() / ".treehouse"
    if th_root.exists():
        for candidate in th_root.glob(f"*/*/{repo_name}"):
            if candidate.is_dir() and (candidate / ".git").exists():
                return str(candidate)
    # 2. Look in /home/jon/git
    git_root = Path("/home/jon/git")
    if git_root.exists():
        direct = git_root / repo_name
        if direct.is_dir() and (direct / ".git").exists():
            return str(direct)
        wt = git_root / f"wt-{repo_name}"
        if wt.is_dir() and (wt / ".git").exists():
            return str(wt)
    return None


def canon(path: str) -> str:
    return os.path.realpath(os.path.expanduser(path))


def default_fm_home() -> str:
    # FM_HOME wins when set; otherwise the checkout holding this script is the
    # main home (firstmate's repo root and its operational home coincide).
    env_home = os.environ.get("FM_HOME", "")
    if env_home:
        return env_home
    return str(Path(__file__).resolve().parent.parent)


REGISTRY_LOCAL_RE = re.compile(
    r"^- ([A-Za-z0-9._-]+) - (.+) \(home:\s*([^;)]*);\s*scope:\s*(.*);"
    r"\s*projects:\s*([^;)]*);\s*added\s+(\d{4}-\d{2}-\d{2})\)\s*$"
)
REGISTRY_REMOTE_RE = re.compile(
    r"^- ([A-Za-z0-9._-]+) - (.+) \(host:\s*([^;)]*);\s*root:\s*([^;)]*);"
    r"\s*home:\s*([^;)]*);\s*scope:\s*(.*);\s*projects:\s*([^;)]*);"
    r"\s*added\s+(\d{4}-\d{2}-\d{2})\)\s*$"
)


def registry_homes(fm_home: str) -> Optional[List[str]]:
    # Local secondmate routes from data/secondmates.md: "- <id> - ... (home:
    # <path>; ...)". Lines starting with "host:" are wrapped continuation
    # lines, not entries. A registered home that does not exist locally simply
    # contributes nothing.
    registry = Path(fm_home) / "data" / "secondmates.md"
    homes: List[str] = []
    if not registry.is_file():
        return homes
    try:
        lines = registry.read_text(errors="replace").splitlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith("host:") or not line.startswith("- "):
            continue
        match = REGISTRY_LOCAL_RE.match(line)
        if match:
            homes.append(match.group(3).strip())
            continue
        match = REGISTRY_REMOTE_RE.match(line)
        if match:
            homes.append(match.group(5).strip())
    return homes


def collect_task_refs(fm_home: str) -> Optional[Dict[str, str]]:
    # Owning task ids: every state/<task>.meta worktree= value across the main
    # home, registered secondmate homes, and local homes under the
    # FM_SECONDMATE_HOMES_DIR root. Returns canonical worktree path -> source description, or None
    # when a found record source could not be read (the proof is incomplete).
    refs: Dict[str, str] = {}
    reg_homes = registry_homes(fm_home)
    if reg_homes is None:
        return None
    homes = {canon(fm_home)}
    for home in reg_homes:
        if os.path.isdir(home):
            homes.add(canon(home))
    homes_base = os.environ.get("FM_SECONDMATE_HOMES_DIR", "/home/jon/.firstmate-homes")
    try:
        home_names = sorted(os.listdir(homes_base))
    except FileNotFoundError:
        home_names = []
    except OSError:
        return None
    for name in home_names:
        home = os.path.join(homes_base, name)
        if os.path.isdir(home):
            homes.add(canon(home))
    for home in sorted(homes):
        state_dir = os.path.join(home, "state")
        try:
            names = sorted(n for n in os.listdir(state_dir) if n.endswith(".meta"))
        except FileNotFoundError:
            continue
        except OSError:
            return None
        for name in names:
            meta = os.path.join(state_dir, name)
            try:
                with open(meta, errors="replace") as fh:
                    for line in fh:
                        if line.startswith("worktree="):
                            value = line[len("worktree="):].strip()
                            if value:
                                task = os.path.splitext(name)[0]
                                refs.setdefault(canon(value), f"task record {task} in {home}")
            except OSError:
                return None
    return refs


def collect_lease_refs() -> Optional[Dict[str, str]]:
    # Durable treehouse pool leases: ~/.treehouse/<pool>/treehouse-state.json
    # entries with leased=true. Returns canonical slot path -> holder, or None
    # when a found state file could not be read (the proof is incomplete).
    refs: Dict[str, str] = {}
    treehouse_root = Path.home() / ".treehouse"
    for state_file in sorted(glob.glob(str(treehouse_root / "*" / "treehouse-state.json"))):
        try:
            with open(state_file, errors="replace") as fh:
                data = json.load(fh)
            for entry in data.get("worktrees") or []:
                path = entry.get("path")
                if entry.get("leased") and path:
                    holder = entry.get("lease_holder") or "unknown"
                    refs[canon(path)] = f"treehouse lease held by {holder}"
        except (OSError, ValueError, AttributeError, TypeError):
            return None
    return refs


def reference_source(path: str, refs: Dict[str, str]) -> Optional[str]:
    # A candidate is referenced when it equals a referenced path, sits under
    # one (a nested clone inside a task slot), or contains one (a referenced
    # worktree lives deeper inside the candidate).
    candidate = canon(path)
    for ref, source in refs.items():
        if candidate == ref or candidate.startswith(ref + os.sep) or ref.startswith(candidate + os.sep):
            return source
    return None


def proc_pid_uid(pid_dir: Path) -> str:
    try:
        for line in (pid_dir / "status").read_text().splitlines():
            if line.startswith("Uid:"):
                return line.split()[1]
    except (OSError, IndexError):
        pass
    return "?"


def target_inside(target: str, candidate: str) -> bool:
    if target.endswith(" (deleted)"):
        target = target[: -len(" (deleted)")]
    if not target.startswith("/"):
        return False
    resolved = os.path.realpath(target)
    return resolved == candidate or resolved.startswith(candidate + os.sep)


def processes_in(path: str) -> Tuple[Optional[List[str]], str]:
    # PIDs holding the candidate open: cwd or an fd under it. A confident zero
    # needs a positive-clean proof - every pid's cwd and fds readable, nothing
    # found - so an unreadable pid is doubt (reported with its uid and pid) and
    # callers must keep.
    candidate = canon(path)
    proc_root = Path(os.environ.get("FM_PROC_ROOT_OVERRIDE") or "/proc")
    if not proc_root.is_dir():
        return None, f"no process table at {proc_root}"
    try:
        entries = sorted(proc_root.iterdir())
    except OSError:
        return None, f"unenumerable process table at {proc_root}"
    pids: List[str] = []
    doubt: List[str] = []
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            matched = target_inside(os.readlink(entry / "cwd"), candidate)
        except FileNotFoundError:
            continue
        except OSError:
            doubt.append(f"pid {entry.name} uid {proc_pid_uid(entry)}")
            continue
        try:
            fds = sorted((entry / "fd").iterdir())
        except FileNotFoundError:
            fds = []
        except OSError:
            doubt.append(f"pid {entry.name} uid {proc_pid_uid(entry)}")
            continue
        for fd in fds:
            if matched:
                break
            try:
                matched = target_inside(os.readlink(fd), candidate)
            except FileNotFoundError:
                continue
            except OSError:
                doubt.append(f"pid {entry.name} uid {proc_pid_uid(entry)}")
                break
        if matched:
            pids.append(entry.name)
    if pids:
        return pids, ""
    if doubt:
        return None, "unreadable " + ", ".join(doubt[:5])
    return [], ""


def run_git(args: List[str], cwd: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )


def is_worktree_dirty(worktree_path: str) -> bool:
    res = run_git(["status", "--porcelain"], cwd=worktree_path)
    return bool(res.stdout.strip())


def is_ancestor(commit: str, base: str, repo_path: str) -> bool:
    res = run_git(["merge-base", "--is-ancestor", commit, base], cwd=repo_path)
    return res.returncode == 0


def get_worktrees(repo_path: str) -> List[Dict[str, Any]]:
    res = run_git(["worktree", "list", "--porcelain"], cwd=repo_path)
    if res.returncode != 0:
        return []

    worktrees: List[Dict[str, Any]] = []
    current: Dict[str, Any] = {}

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            if current and "path" in current:
                worktrees.append(current)
                current = {}
            continue

        parts = line.split(" ", 1)
        key = parts[0]
        val = parts[1] if len(parts) > 1 else ""

        if key == "worktree":
            current["path"] = val
        elif key == "HEAD":
            current["head"] = val
        elif key == "branch":
            current["branch"] = val.replace("refs/heads/", "")
        elif key == "detached":
            current["detached"] = True

    if current and "path" in current:
        worktrees.append(current)

    return worktrees


def reap_worktrees(
    repo_path: str,
    base_branch: str = "origin/main",
    dry_run: bool = False,
    prune_branches: bool = False,
) -> Dict[str, Any]:
    report: Dict[str, Any] = {
        "repo_path": repo_path,
        "base_branch": base_branch,
        "dry_run": dry_run,
        "total_worktrees": 0,
        "active_preserved": 0,
        "dirty_preserved": 0,
        "unmerged_preserved": 0,
        "referenced_preserved": 0,
        "referenced_worktrees": [],
        "reaped_worktrees": [],
        "reaped_branches": [],
    }

    if not os.path.isdir(repo_path):
        return report

    # Make sure repo_path is a git repo
    git_check = run_git(["rev-parse", "--show-toplevel"], cwd=repo_path)
    if git_check.returncode != 0:
        return report

    root_path = os.path.realpath(git_check.stdout.strip())
    worktrees = get_worktrees(repo_path)
    report["total_worktrees"] = len(worktrees)

    # Verify base_branch exists
    base_check = run_git(["rev-parse", "--verify", base_branch], cwd=repo_path)
    if base_check.returncode != 0:
        # Fallback to main or master
        for fallback in ["main", "origin/master", "master"]:
            fallback_res = run_git(["rev-parse", "--verify", fallback], cwd=repo_path)
            if fallback_res.returncode == 0:
                base_branch = fallback
                base_check = fallback_res
                break

    base_sha = base_check.stdout.strip() if base_check.returncode == 0 else ""

    # Reference proof (fm-av46m): a worktree is reaped only when provably
    # unreferenced - no owning task record, no durable treehouse lease, and no
    # running process inside it. Merged ancestry or age alone never suffices.
    task_refs = collect_task_refs(default_fm_home())
    lease_refs = collect_lease_refs()

    for wt in worktrees:
        path = os.path.realpath(wt["path"])
        # Invariant 1: never reap root repository
        if path == root_path:
            report["active_preserved"] += 1
            continue

        if not os.path.exists(path):
            # Prunable stale worktree entry
            if not dry_run:
                run_git(["worktree", "prune"], cwd=repo_path)
            report["reaped_worktrees"].append({"path": path, "reason": "missing_directory"})
            continue

        # Invariant 2: never reap a worktree the fleet still references
        if task_refs is None or lease_refs is None:
            ref_source = "reference scan inconclusive"
        else:
            ref_source = reference_source(path, task_refs) or reference_source(path, lease_refs)
        if ref_source:
            report["referenced_preserved"] += 1
            report["referenced_worktrees"].append({"path": path, "source": ref_source})
            continue

        # Invariant 3: never reap dirty worktrees
        if is_worktree_dirty(path):
            report["dirty_preserved"] += 1
            continue

        head_sha = wt.get("head")
        branch_name = wt.get("branch")
        is_detached = wt.get("detached", False)

        # Invariant 4: never reap newly created or aligned active feature branches
        # If head_sha equals base_sha on a named branch, work is just starting or synchronized!
        if branch_name and head_sha and base_sha and head_sha == base_sha:
            report["active_preserved"] += 1
            continue

        # Invariant 5: check if landed on base_branch
        is_merged = False
        if is_detached:
            if head_sha and is_ancestor(head_sha, base_branch, repo_path):
                is_merged = True
        elif branch_name:
            if head_sha and is_ancestor(head_sha, base_branch, repo_path):
                is_merged = True
            else:
                # Check if branch was squash-merged via gh pr view
                gh_res = subprocess.run(
                    ["gh", "pr", "view", branch_name, "--json", "state", "-q", ".state"],
                    cwd=path,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if gh_res.returncode == 0 and gh_res.stdout.strip().upper() == "MERGED":
                    is_merged = True

        if not is_merged:
            report["unmerged_preserved"] += 1
            continue

        # Invariant 6: never reap a worktree with a live process inside it, and
        # never reap when the process probe cannot answer - doubt keeps it.
        pids, probe_doubt = processes_in(path)
        if pids is None:
            report["referenced_preserved"] += 1
            report["referenced_worktrees"].append(
                {"path": path, "source": f"process probe inconclusive ({probe_doubt})"}
            )
            continue
        if pids:
            report["referenced_preserved"] += 1
            report["referenced_worktrees"].append(
                {"path": path, "source": "running process(es) " + ",".join(pids[:5])}
            )
            continue

        # Clean, confirmed merged, and provably unreferenced -> SAFE TO REAP
        reap_record = {
            "path": path,
            "head": head_sha[:7] if head_sha else "",
            "branch": branch_name or ("detached" if is_detached else "unknown"),
            "reason": "ancestor_of_" + base_branch,
        }
        report["reaped_worktrees"].append(reap_record)

        if not dry_run:
            del_res = run_git(["worktree", "remove", "--force", path], cwd=repo_path)
            if del_res.returncode == 0 and prune_branches and branch_name:
                run_git(["branch", "-d", branch_name], cwd=repo_path)
                report["reaped_branches"].append(branch_name)

    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Git Worktree Stale Prune & Detached Branch Reaper (Pattern 19)"
    )
    parser.add_argument(
        "--repo-dir",
        default=os.getcwd(),
        help="Path to git repository or worktree root",
    )
    parser.add_argument(
        "--base-branch",
        default="origin/main",
        help="Base upstream branch to check for merged ancestry (default: origin/main)",
    )
    parser.add_argument(
        "--repo-name",
        default="",
        help="Repository name to target across treehouse/workspace roots (e.g. tutti, Portal, Zeta)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate reaping scan without modifying worktrees or branches",
    )
    parser.add_argument(
        "--prune-branches",
        action="store_true",
        help="Also delete merged local tracking branches after removing worktree",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON telemetry",
    )

    args = parser.parse_args()

    repo_dir = args.repo_dir
    if args.repo_name:
        found = find_repo_dir(args.repo_name)
        if found:
            repo_dir = found
        elif not os.path.exists(repo_dir) or not os.path.exists(os.path.join(repo_dir, ".git")):
            if args.json:
                print(json.dumps({"error": f"Repository '{args.repo_name}' not found", "reaped_worktrees": []}))
            else:
                print(f"Jev Worktree Reaper: repository '{args.repo_name}' not found; skipped.")
            return 0

    report = reap_worktrees(
        repo_path=repo_dir,
        base_branch=args.base_branch,
        dry_run=args.dry_run,
        prune_branches=args.prune_branches,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status_tag = "[DRY_RUN]" if report["dry_run"] else "[REAPER_APPLIED]"
        print(f"Jev Worktree Stale Prune & Branch Reaper {status_tag}:")
        print(f"  • Repository: {report['repo_path']}")
        print(f"  • Total Worktrees: {report['total_worktrees']}")
        print(f"  • Preserved (Main): {report['active_preserved']}")
        print(f"  • Preserved (Dirty / In-Flight): {report['dirty_preserved']}")
        print(f"  • Preserved (Unmerged): {report['unmerged_preserved']}")
        print(f"  • Preserved (Referenced): {report['referenced_preserved']}")
        for r in report["referenced_worktrees"]:
            print(f"     ↳ Referenced: {r['path']} ({r['source']})")
        print(f"  • Safe Worktrees Reaped: {len(report['reaped_worktrees'])}")
        for r in report["reaped_worktrees"]:
            print(f"     ↳ Reaped: {r['path']} ({r.get('branch', 'detached')} @ {r.get('head', '')})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
