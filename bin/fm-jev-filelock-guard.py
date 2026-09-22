#!/usr/bin/env python3
"""
fm-jev-filelock-guard.py - Jev Multi-Agent POSIX File Lock & Kernel flock/fcntl Contention Guard (Pattern 80)

Audits Linux kernel active file locks (/proc/locks), identifying POSIX, FLOCK, and OFD advisory locks across
all processes. Detects cross-process inode lock contention (multiple agents contending for the same database,
beads gate lock, git index, or package lockfile) and stale locks held by defunct/dead processes to prevent
silent multi-agent serialization bottlenecks and deadlocks.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback on systems with non-standard procfs.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

DEFAULT_WARN_CONTENTION_COUNT = 3
DEFAULT_CRIT_CONTENTION_COUNT = 8

PROC_LOCKS = "/proc/locks"


def get_process_name(pid: int) -> str:
    """Gets process command name from /proc/<pid>/comm."""
    comm_path = f"/proc/{pid}/comm"
    if os.path.exists(comm_path):
        try:
            with open(comm_path, "r") as f:
                return f.read().strip()
        except Exception:
            return "unknown"
    return "dead"


def parse_proc_locks(
    locks_path: str = PROC_LOCKS,
    check_pid_alive: bool = True,
) -> List[Dict[str, Any]]:
    """Parses /proc/locks into structured lock records."""
    locks: List[Dict[str, Any]] = []
    if not os.path.exists(locks_path):
        return locks

    try:
        with open(locks_path, "r") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 8:
                    idx = parts[0].rstrip(":")
                    lock_type = parts[1]      # POSIX, FLOCK, OFDLCK, LEASE
                    mode = parts[2]           # ADVISORY, MANDATORY
                    access = parts[3]         # READ, WRITE
                    try:
                        pid = int(parts[4])
                    except ValueError:
                        pid = -1
                    inode_key = parts[5]      # MAJ:MIN:INODE
                    range_start = parts[6]
                    range_end = parts[7]

                    is_alive = True
                    proc_name = "unknown"
                    if check_pid_alive and pid > 0:
                        is_alive = os.path.exists(f"/proc/{pid}")
                        proc_name = get_process_name(pid) if is_alive else "dead"

                    locks.append({
                        "id": idx,
                        "lock_type": lock_type,
                        "mode": mode,
                        "access": access,
                        "pid": pid,
                        "proc_name": proc_name,
                        "is_alive": is_alive,
                        "inode_key": inode_key,
                        "range": f"{range_start}-{range_end}",
                    })
    except Exception:
        pass

    return locks


def audit_file_locks(
    locks_path: str = PROC_LOCKS,
    warn_contention: int = DEFAULT_WARN_CONTENTION_COUNT,
    crit_contention: int = DEFAULT_CRIT_CONTENTION_COUNT,
    check_pid_alive: bool = True,
) -> Dict[str, Any]:
    """Audits kernel active file locks and identifies cross-agent contention."""
    locks = parse_proc_locks(locks_path, check_pid_alive=check_pid_alive)

    # Inode grouping to find contention
    inode_holders: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    pid_locks_count: Dict[int, int] = defaultdict(int)
    pid_names: Dict[int, str] = {}
    stale_dead_locks: List[Dict[str, Any]] = []

    posix_count = 0
    flock_count = 0
    write_locks_count = 0
    read_locks_count = 0

    for lk in locks:
        inode_holders[lk["inode_key"]].append(lk)
        if lk["pid"] > 0:
            pid_locks_count[lk["pid"]] += 1
            pid_names[lk["pid"]] = lk["proc_name"]
            if not lk["is_alive"]:
                stale_dead_locks.append(lk)

        if lk["lock_type"] == "POSIX":
            posix_count += 1
        elif lk["lock_type"] == "FLOCK":
            flock_count += 1

        if lk["access"] == "WRITE":
            write_locks_count += 1
        else:
            read_locks_count += 1

    # Contention: inodes held by multiple processes where at least one is WRITE
    contended_inodes: List[Dict[str, Any]] = []
    max_contention = 0

    for inode_key, holders in inode_holders.items():
        unique_pids = {h["pid"] for h in holders if h["pid"] > 0}
        has_write = any(h["access"] == "WRITE" for h in holders)
        if len(unique_pids) > 1 and has_write:
            contention_degree = len(unique_pids)
            if contention_degree > max_contention:
                max_contention = contention_degree
            contended_inodes.append({
                "inode_key": inode_key,
                "contenders_count": contention_degree,
                "holders": [
                    {"pid": h["pid"], "proc": h["proc_name"], "type": h["lock_type"], "access": h["access"]}
                    for h in holders
                ],
            })

    # Sort contended inodes descending
    contended_inodes.sort(key=lambda x: x["contenders_count"], reverse=True)

    # Top lock holders
    top_pids = sorted(pid_locks_count.items(), key=lambda x: x[1], reverse=True)[:5]
    top_holders = [{"pid": pid, "proc_name": pid_names.get(pid, "unknown"), "locks_held": count} for pid, count in top_pids]

    issues: List[str] = []
    status = "HEALTHY"

    if max_contention >= crit_contention:
        status = "CRITICAL"
        issues.append(f"Severe file lock contention: {max_contention} processes contending for same inode (deadlock risk)")
    elif max_contention >= warn_contention or len(contended_inodes) >= 5:
        status = "WARNING"
        issues.append(f"Elevated file lock contention: {len(contended_inodes)} contested files, peak {max_contention} contenders")

    if stale_dead_locks:
        if status == "HEALTHY":
            status = "WARNING"
        issues.append(f"Stale locks held by non-existent processes: {len(stale_dead_locks)} locks")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_locks": len(locks),
            "posix_locks": posix_count,
            "flock_locks": flock_count,
            "write_locks": write_locks_count,
            "read_locks": read_locks_count,
            "contended_inodes_count": len(contended_inodes),
            "max_contenders_per_file": max_contention,
            "stale_dead_locks_count": len(stale_dead_locks),
            "issues": issues,
        },
        "top_holders": top_holders,
        "contended_inodes": contended_inodes[:5],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent POSIX File Lock & Kernel flock/fcntl Contention Guard (Pattern 80)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-contention", type=int, default=DEFAULT_WARN_CONTENTION_COUNT, help=f"Warning contention count (default {DEFAULT_WARN_CONTENTION_COUNT})")
    parser.add_argument("--crit-contention", type=int, default=DEFAULT_CRIT_CONTENTION_COUNT, help=f"Critical contention count (default {DEFAULT_CRIT_CONTENTION_COUNT})")
    parser.add_argument("--proc-locks", type=str, default=PROC_LOCKS, help="Path to /proc/locks")

    args = parser.parse_args()

    result = audit_file_locks(
        locks_path=args.proc_locks,
        warn_contention=args.warn_contention,
        crit_contention=args.crit_contention,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent File Lock & Contention Guard (Pattern 80)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Active Locks:           {summary['total_locks']} total ({summary['flock_locks']} FLOCK, {summary['posix_locks']} POSIX)")
    print(f" Access Types:           {summary['write_locks']} WRITE, {summary['read_locks']} READ")
    print(f" Contended Inodes:       {summary['contended_inodes_count']} contested (peak {summary['max_contenders_per_file']} contenders/file)")
    print(f" Stale / Dead Locks:     {summary['stale_dead_locks_count']}")

    if result["top_holders"]:
        print("\nTop Lock Holders:")
        for h in result["top_holders"]:
            print(f"  - PID {h['pid']:<7} ({h['proc_name']:<16}): {h['locks_held']} locks")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo destructive lock contention, deadlocks, or orphaned file locks detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
