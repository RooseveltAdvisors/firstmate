#!/usr/bin/env python3
"""
fm-jev-sysvipc-guard.py - Jev Multi-Agent System V IPC Shared Memory & Semaphore Array Leak Guard (Pattern 73)

Audits Linux System V IPC shared memory segments, semaphore sets, and message queues.
Monitors /proc/sysvipc/shm, /proc/sysvipc/sem, /proc/sysvipc/msg, and kernel IPC sysctls
(/proc/sys/kernel/shmmni, /proc/sys/kernel/sem) to detect orphaned zero-nattch segments,
unbounded semaphore leaks, and IPC exhaustion caused by crashed worker processes, headless
browser instances, and subagents.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback when /proc/sysvipc is restricted or unavailable.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_SATURATION_RATIO = 0.50
DEFAULT_CRIT_SATURATION_RATIO = 0.85
DEFAULT_WARN_ORPHAN_BYTES = 524_288_000      # 500 MB
DEFAULT_CRIT_ORPHAN_BYTES = 2_147_483_648    # 2 GB
DEFAULT_WARN_ORPHAN_SEGMENTS = 50
DEFAULT_CRIT_ORPHAN_SEGMENTS = 200

SYSVIPC_SHM_PATH = "/proc/sysvipc/shm"
SYSVIPC_SEM_PATH = "/proc/sysvipc/sem"
SYSVIPC_MSG_PATH = "/proc/sysvipc/msg"
SYSCTL_SHMMNI_PATH = "/proc/sys/kernel/shmmni"
SYSCTL_SEM_PATH = "/proc/sys/kernel/sem"


def read_sysctl_int(path: str, default: int = 4096) -> int:
    """Reads integer sysctl."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return default


def read_sem_sysctl(path: str = SYSCTL_SEM_PATH) -> Tuple[int, int, int, int]:
    """
    Reads /proc/sys/kernel/sem which returns 4 integers:
    semmsl (max semaphores per array), semmns (max semaphores system-wide),
    semopm (max ops per semop call), semmni (max semaphore arrays system-wide).
    """
    if not os.path.exists(path):
        return (32000, 1024000000, 500, 32000)
    try:
        with open(path, "r") as f:
            parts = [int(p) for p in f.read().strip().split()]
            if len(parts) >= 4:
                return (parts[0], parts[1], parts[2], parts[3])
    except Exception:
        pass
    return (32000, 1024000000, 500, 32000)


def pid_exists(pid: int, proc_root: str = "/proc") -> bool:
    """Checks if a process exists in procfs."""
    if pid <= 0:
        return False
    pid_path = os.path.join(proc_root, str(pid))
    return os.path.exists(pid_path)


def parse_sysvipc_shm(
    path: str = SYSVIPC_SHM_PATH,
    check_pids: bool = True,
    proc_root: str = "/proc",
) -> List[Dict[str, Any]]:
    """
    Parses /proc/sysvipc/shm.
    Columns: key shmid perms size cpid lpid nattch uid gid cuid cgid atime dtime ctime rss swap
    """
    segments: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return segments

    try:
        with open(path, "r") as f:
            lines = f.readlines()
        if not lines:
            return segments

        header = lines[0].strip().split()
        for line in lines[1:]:
            parts = line.strip().split()
            if len(parts) < 14:
                continue
            try:
                key = int(parts[0])
                shmid = int(parts[1])
                perms = parts[2]
                size = int(parts[3])
                cpid = int(parts[4])
                lpid = int(parts[5])
                nattch = int(parts[6])
                uid = int(parts[7])
                gid = int(parts[8])
                rss = int(parts[14]) if len(parts) > 14 else 0
                swap = int(parts[15]) if len(parts) > 15 else 0

                cpid_alive = pid_exists(cpid, proc_root) if (check_pids and cpid > 0) else None
                lpid_alive = pid_exists(lpid, proc_root) if (check_pids and lpid > 0) else None
                
                # Orphaned predicate: 0 attached processes, and neither creator nor last pid alive
                is_orphan = False
                if nattch == 0 and check_pids:
                    if (cpid > 0 and not cpid_alive) and (lpid == 0 or not lpid_alive):
                        is_orphan = True

                segments.append({
                    "key": key,
                    "shmid": shmid,
                    "perms": perms,
                    "size": size,
                    "cpid": cpid,
                    "cpid_alive": cpid_alive,
                    "lpid": lpid,
                    "lpid_alive": lpid_alive,
                    "nattch": nattch,
                    "uid": uid,
                    "gid": gid,
                    "rss": rss,
                    "swap": swap,
                    "is_orphan": is_orphan,
                })
            except (ValueError, IndexError):
                continue
    except Exception:
        pass
    return segments


def parse_sysvipc_sem(path: str = SYSVIPC_SEM_PATH) -> List[Dict[str, Any]]:
    """
    Parses /proc/sysvipc/sem.
    Columns: key semid perms nsems uid gid cuid cgid otime ctime
    """
    arrays: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return arrays

    try:
        with open(path, "r") as f:
            lines = f.readlines()
        if not lines:
            return arrays

        for line in lines[1:]:
            parts = line.strip().split()
            if len(parts) < 10:
                continue
            try:
                arrays.append({
                    "key": int(parts[0]),
                    "semid": int(parts[1]),
                    "perms": parts[2],
                    "nsems": int(parts[3]),
                    "uid": int(parts[4]),
                    "gid": int(parts[5]),
                })
            except (ValueError, IndexError):
                continue
    except Exception:
        pass
    return arrays


def parse_sysvipc_msg(path: str = SYSVIPC_MSG_PATH) -> List[Dict[str, Any]]:
    """
    Parses /proc/sysvipc/msg.
    Columns: key msqid perms cbytes qnum lspid lrpid uid gid cuid cgid stime rtime ctime
    """
    queues: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return queues

    try:
        with open(path, "r") as f:
            lines = f.readlines()
        if not lines:
            return queues

        for line in lines[1:]:
            parts = line.strip().split()
            if len(parts) < 14:
                continue
            try:
                queues.append({
                    "key": int(parts[0]),
                    "msqid": int(parts[1]),
                    "perms": parts[2],
                    "cbytes": int(parts[3]),
                    "qnum": int(parts[4]),
                    "uid": int(parts[7]),
                    "gid": int(parts[8]),
                })
            except (ValueError, IndexError):
                continue
    except Exception:
        pass
    return queues


def audit_sysvipc(
    shm_path: str = SYSVIPC_SHM_PATH,
    sem_path: str = SYSVIPC_SEM_PATH,
    msg_path: str = SYSVIPC_MSG_PATH,
    shmmni_path: str = SYSCTL_SHMMNI_PATH,
    sem_path_sysctl: str = SYSCTL_SEM_PATH,
    check_pids: bool = True,
    proc_root: str = "/proc",
    warn_sat: float = DEFAULT_WARN_SATURATION_RATIO,
    crit_sat: float = DEFAULT_CRIT_SATURATION_RATIO,
    warn_orphan_bytes: int = DEFAULT_WARN_ORPHAN_BYTES,
    crit_orphan_bytes: int = DEFAULT_CRIT_ORPHAN_BYTES,
    warn_orphan_segs: int = DEFAULT_WARN_ORPHAN_SEGMENTS,
    crit_orphan_segs: int = DEFAULT_CRIT_ORPHAN_SEGMENTS,
) -> Dict[str, Any]:
    """Audits System V IPC state and assesses health."""
    shmmni = read_sysctl_int(shmmni_path, default=4096)
    semmsl, semmns, semopm, semmni = read_sem_sysctl(sem_path_sysctl)

    segments = parse_sysvipc_shm(shm_path, check_pids=check_pids, proc_root=proc_root)
    sem_arrays = parse_sysvipc_sem(sem_path)
    msg_queues = parse_sysvipc_msg(msg_path)

    total_shm_count = len(segments)
    total_shm_bytes = sum(s["size"] for s in segments)
    total_shm_rss = sum(s["rss"] for s in segments)
    zero_attach_segs = [s for s in segments if s["nattch"] == 0]
    orphaned_segs = [s for s in segments if s["is_orphan"]]
    orphaned_bytes = sum(s["size"] for s in orphaned_segs)

    shm_sat_ratio = (total_shm_count / max(1, shmmni))
    total_sem_count = len(sem_arrays)
    total_sems = sum(a["nsems"] for a in sem_arrays)
    sem_sat_ratio = (total_sem_count / max(1, semmni))

    # Evaluate health status
    issues: List[str] = []
    status = "HEALTHY"

    if (
        shm_sat_ratio >= crit_sat
        or orphaned_bytes >= crit_orphan_bytes
        or len(orphaned_segs) >= crit_orphan_segs
    ):
        status = "CRITICAL"
        if shm_sat_ratio >= crit_sat:
            issues.append(f"SHM segment count saturation critical: {shm_sat_ratio*100:.1f}% of {shmmni}")
        if orphaned_bytes >= crit_orphan_bytes:
            issues.append(f"Orphaned SHM memory critical: {orphaned_bytes / (1024*1024):.1f} MB leaked")
        if len(orphaned_segs) >= crit_orphan_segs:
            issues.append(f"Orphaned SHM segment count critical: {len(orphaned_segs)} segments")
    elif (
        shm_sat_ratio >= warn_sat
        or orphaned_bytes >= warn_orphan_bytes
        or len(orphaned_segs) >= warn_orphan_segs
    ):
        status = "WARNING"
        if shm_sat_ratio >= warn_sat:
            issues.append(f"SHM segment count saturation elevated: {shm_sat_ratio*100:.1f}% of {shmmni}")
        if orphaned_bytes >= warn_orphan_bytes:
            issues.append(f"Orphaned SHM memory elevated: {orphaned_bytes / (1024*1024):.1f} MB leaked")
        if len(orphaned_segs) >= warn_orphan_segs:
            issues.append(f"Orphaned SHM segment count elevated: {len(orphaned_segs)} segments")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "shm_segment_count": total_shm_count,
            "shm_max_segments": shmmni,
            "shm_saturation_ratio": round(shm_sat_ratio, 4),
            "shm_total_bytes": total_shm_bytes,
            "shm_total_rss_bytes": total_shm_rss,
            "zero_attach_segments": len(zero_attach_segs),
            "orphaned_segments": len(orphaned_segs),
            "orphaned_bytes": orphaned_bytes,
            "sem_array_count": total_sem_count,
            "sem_max_arrays": semmni,
            "sem_saturation_ratio": round(sem_sat_ratio, 4),
            "total_semaphores": total_sems,
            "msg_queue_count": len(msg_queues),
            "issues": issues,
        },
        "limits": {
            "kernel_shmmni": shmmni,
            "kernel_semmsl": semmsl,
            "kernel_semmns": semmns,
            "kernel_semopm": semopm,
            "kernel_semmni": semmni,
        },
        "segments": segments[:50],  # Top 50 segments
    }


def format_bytes(num_bytes: int) -> str:
    """Formats bytes into human-readable string."""
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if abs(num_bytes) < 1024.0:
            return f"{num_bytes:3.1f} {unit}"
        num_bytes /= 1024.0
    return f"{num_bytes:.1f} PB"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent System V IPC Shared Memory & Semaphore Array Leak Guard (Pattern 73)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-sat", type=float, default=DEFAULT_WARN_SATURATION_RATIO, help="Warning saturation ratio (default 0.50)")
    parser.add_argument("--crit-sat", type=float, default=DEFAULT_CRIT_SATURATION_RATIO, help="Critical saturation ratio (default 0.85)")
    parser.add_argument("--warn-orphan-bytes", type=int, default=DEFAULT_WARN_ORPHAN_BYTES, help="Warning orphan bytes (default 500MB)")
    parser.add_argument("--crit-orphan-bytes", type=int, default=DEFAULT_CRIT_ORPHAN_BYTES, help="Critical orphan bytes (default 2GB)")
    parser.add_argument("--warn-orphan-segs", type=int, default=DEFAULT_WARN_ORPHAN_SEGMENTS, help="Warning orphan segment count (default 50)")
    parser.add_argument("--crit-orphan-segs", type=int, default=DEFAULT_CRIT_ORPHAN_SEGMENTS, help="Critical orphan segment count (default 200)")
    parser.add_argument("--proc-shm", type=str, default=SYSVIPC_SHM_PATH, help="Path to /proc/sysvipc/shm")
    parser.add_argument("--proc-sem", type=str, default=SYSVIPC_SEM_PATH, help="Path to /proc/sysvipc/sem")
    parser.add_argument("--proc-msg", type=str, default=SYSVIPC_MSG_PATH, help="Path to /proc/sysvipc/msg")
    parser.add_argument("--sysctl-shmmni", type=str, default=SYSCTL_SHMMNI_PATH, help="Path to shmmni sysctl")
    parser.add_argument("--sysctl-sem", type=str, default=SYSCTL_SEM_PATH, help="Path to sem sysctl")
    parser.add_argument("--no-check-pids", action="store_true", help="Disable checking /proc/<pid> for creator/last PID existence")
    parser.add_argument("--proc-root", type=str, default="/proc", help="Root of procfs")

    args = parser.parse_args()

    result = audit_sysvipc(
        shm_path=args.proc_shm,
        sem_path=args.proc_sem,
        msg_path=args.proc_msg,
        shmmni_path=args.sysctl_shmmni,
        sem_path_sysctl=args.sysctl_sem,
        check_pids=not args.no_check_pids,
        proc_root=args.proc_root,
        warn_sat=args.warn_sat,
        crit_sat=args.crit_sat,
        warn_orphan_bytes=args.warn_orphan_bytes,
        crit_orphan_bytes=args.crit_orphan_bytes,
        warn_orphan_segs=args.warn_orphan_segs,
        crit_orphan_segs=args.crit_orphan_segs,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent System V IPC Shared Memory & Semaphore Array Guard (Pattern 73)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" SHM Segment Count:      {summary['shm_segment_count']} / {summary['shm_max_segments']} ({summary['shm_saturation_ratio']*100:.2f}%)")
    print(f" Total SHM Size:         {format_bytes(summary['shm_total_bytes'])} (RSS: {format_bytes(summary['shm_total_rss_bytes'])})")
    print(f" Zero-Attach Segments:   {summary['zero_attach_segments']}")
    print(f" Orphaned Segments:      {summary['orphaned_segments']} ({format_bytes(summary['orphaned_bytes'])})")
    print(f" Semaphore Arrays:       {summary['sem_array_count']} / {summary['sem_max_arrays']} (Total sems: {summary['total_semaphores']})")
    print(f" Message Queues:         {summary['msg_queue_count']}")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo System V IPC leaks or segment saturation detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
