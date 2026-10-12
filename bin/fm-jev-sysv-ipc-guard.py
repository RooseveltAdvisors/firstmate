#!/usr/bin/env python3
"""
bin/fm-jev-sysv-ipc-guard.py - Linux System V IPC Resource & Memory Leak Guard (Pattern 313 / Pattern 451)

Audits Linux System V IPC shared memory (/proc/sysvipc/shm), semaphores (/proc/sysvipc/sem),
message queues (/proc/sysvipc/msg), and kernel IPC limits (/proc/sys/kernel/shmmni,
/proc/sys/kernel/sem, /proc/sys/kernel/msgmni, /proc/sys/kernel/msgmax, /proc/sys/kernel/msgmnb)
to detect IPC resource leaks, unattached shared memory bloat, semaphore array exhaustion,
and message queue saturation across multi-agent processes.

Invariants:
  - Warn when IPC table utilization (SHM, SEM, MSG) >= 75%, critical when >= 90%.
  - Warn when unattached SHM segments >= 100, critical when >= 500.
  - Graceful fallback when sysvipc pseudo-files or sysctls are restricted.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PROC_SYSVIPC = "/proc/sysvipc"
PROC_SYS_KERNEL = "/proc/sys/kernel"

DEFAULT_WARN_IPC_PCT = 75.0
DEFAULT_CRIT_IPC_PCT = 90.0
DEFAULT_WARN_UNATTACHED_SHM = 100
DEFAULT_CRIT_UNATTACHED_SHM = 500


def parse_int_sysctl(path: Path, default: int = 0) -> int:
    if not path.is_file():
        return default
    try:
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        parts = content.split()
        return int(parts[0]) if parts and parts[0].lstrip("-").isdigit() else default
    except (ValueError, OSError, IndexError):
        return default


def parse_sem_sysctl(path: Path) -> Tuple[int, int, int, int]:
    if not path.is_file():
        return 32000, 1024000000, 500, 32000
    try:
        parts = path.read_text(encoding="utf-8", errors="replace").split()
        if len(parts) >= 4:
            return int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
    except (ValueError, OSError, IndexError):
        pass
    return 32000, 1024000000, 500, 32000


def parse_shm(path: Path) -> Tuple[int, int, int]:
    if not path.is_file():
        return 0, 0, 0
    try:
        lines = [line.strip() for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    except Exception:
        return 0, 0, 0

    if len(lines) <= 1:
        return 0, 0, 0

    segments = len(lines) - 1
    total_bytes = 0
    unattached = 0

    for line in lines[1:]:
        parts = line.split()
        if len(parts) >= 7:
            try:
                size = int(parts[3])
                total_bytes += size
                nattch = int(parts[6])
                if nattch == 0:
                    unattached += 1
            except (ValueError, IndexError):
                pass

    return segments, total_bytes, unattached


def parse_sem(path: Path) -> Tuple[int, int]:
    if not path.is_file():
        return 0, 0
    try:
        lines = [line.strip() for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    except Exception:
        return 0, 0

    if len(lines) <= 1:
        return 0, 0

    arrays = len(lines) - 1
    total_nsems = 0

    for line in lines[1:]:
        parts = line.split()
        if len(parts) >= 4:
            try:
                total_nsems += int(parts[3])
            except (ValueError, IndexError):
                pass

    return arrays, total_nsems


def parse_msg(path: Path) -> Tuple[int, int, int]:
    if not path.is_file():
        return 0, 0, 0
    try:
        lines = [line.strip() for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    except Exception:
        return 0, 0, 0

    if len(lines) <= 1:
        return 0, 0, 0

    queues = len(lines) - 1
    total_bytes = 0
    total_messages = 0

    for line in lines[1:]:
        parts = line.split()
        if len(parts) >= 5:
            try:
                total_bytes += int(parts[3])
                total_messages += int(parts[4])
            except (ValueError, IndexError):
                pass

    return queues, total_messages, total_bytes


def evaluate_sysv_ipc(
    sysvipc_dir: str = PROC_SYSVIPC,
    kernel_dir: str = PROC_SYS_KERNEL,
    warn_ipc_pct: float = DEFAULT_WARN_IPC_PCT,
    crit_ipc_pct: float = DEFAULT_CRIT_IPC_PCT,
    warn_unattached_shm: int = DEFAULT_WARN_UNATTACHED_SHM,
    crit_unattached_shm: int = DEFAULT_CRIT_UNATTACHED_SHM,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    ipc_path = Path(sysvipc_dir)
    kernel_path = Path(kernel_dir)

    shm_file = ipc_path / "shm"
    sem_file = ipc_path / "sem"
    msg_file = ipc_path / "msg"

    shm_segments, shm_bytes, unattached_shm = parse_shm(shm_file)
    sem_arrays, sem_nsems = parse_sem(sem_file)
    msg_queues, msg_total_messages, msg_total_bytes = parse_msg(msg_file)

    shmmni = parse_int_sysctl(kernel_path / "shmmni", default=4096)
    semmsl, semmns, semopm, semmni = parse_sem_sysctl(kernel_path / "sem")
    msgmni = parse_int_sysctl(kernel_path / "msgmni", default=32000)
    msgmax = parse_int_sysctl(kernel_path / "msgmax", default=8192)
    msgmnb = parse_int_sysctl(kernel_path / "msgmnb", default=16384)

    shm_pct = (shm_segments / shmmni * 100.0) if shmmni > 0 else 0.0
    sem_pct = (sem_arrays / semmni * 100.0) if semmni > 0 else 0.0
    msg_pct = (msg_queues / msgmni * 100.0) if msgmni > 0 else 0.0

    # Check unattached shared memory
    if unattached_shm >= crit_unattached_shm:
        status = "CRITICAL"
        issues.append(
            f"Severe orphaned shared memory leak ({unattached_shm} unattached segments >= {crit_unattached_shm})"
        )
        recommendations.append("Sweep and destroy orphaned System V shared memory segments (ipcrm -m)")
    elif unattached_shm >= warn_unattached_shm:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Elevated orphaned shared memory ({unattached_shm} unattached segments >= {warn_unattached_shm})"
        )
        recommendations.append("Audit multi-agent processes creating detached shared memory segments")

    # Check SHM segment capacity
    if shm_pct >= crit_ipc_pct:
        status = "CRITICAL"
        issues.append(
            f"IPC shared memory segment table critical ({shm_pct:.2f}% >= {crit_ipc_pct}%, segments={shm_segments}, max={shmmni})"
        )
        recommendations.append(f"Increase sysctl kernel.shmmni above {shmmni}")
    elif shm_pct >= warn_ipc_pct:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"IPC shared memory segment table elevated ({shm_pct:.2f}% >= {warn_ipc_pct}%, segments={shm_segments}, max={shmmni})"
        )
        recommendations.append("Monitor System V shared memory allocation rates")

    # Check SEM capacity
    if sem_pct >= crit_ipc_pct:
        status = "CRITICAL"
        issues.append(
            f"IPC semaphore array capacity critical ({sem_pct:.2f}% >= {crit_ipc_pct}%, arrays={sem_arrays}, max={semmni})"
        )
        recommendations.append(f"Increase sysctl kernel.sem semmni parameter above {semmni}")
    elif sem_pct >= warn_ipc_pct:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"IPC semaphore array capacity elevated ({sem_pct:.2f}% >= {warn_ipc_pct}%, arrays={sem_arrays}, max={semmni})"
        )
        recommendations.append("Audit semaphore array consumers and cleanup stale undo structures")

    # Check MSG capacity
    if msg_pct >= crit_ipc_pct:
        status = "CRITICAL"
        issues.append(
            f"IPC message queue capacity critical ({msg_pct:.2f}% >= {crit_ipc_pct}%, queues={msg_queues}, max={msgmni})"
        )
        recommendations.append(f"Increase sysctl kernel.msgmni above {msgmni}")
    elif msg_pct >= warn_ipc_pct:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"IPC message queue capacity elevated ({msg_pct:.2f}% >= {warn_ipc_pct}%, queues={msg_queues}, max={msgmni})"
        )
        recommendations.append("Audit message queue consumers and purge backlogged queues")

    healthy = (status == "HEALTHY")
    is_ipc_healthy = (
        (unattached_shm < warn_unattached_shm)
        and (shm_pct < warn_ipc_pct)
        and (sem_pct < warn_ipc_pct)
        and (msg_pct < warn_ipc_pct)
    )

    return {
        "pattern": 313,
        "name": "sysv_ipc",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_ipc_healthy": is_ipc_healthy,
        "shm_segments": shm_segments,
        "shm_total_bytes": shm_bytes,
        "shm_unattached": unattached_shm,
        "shm_max_segments": shmmni,
        "shm_utilization_pct": round(shm_pct, 4),
        "sem_arrays": sem_arrays,
        "sem_total_nsems": sem_nsems,
        "sem_max_arrays": semmni,
        "sem_utilization_pct": round(sem_pct, 4),
        "semmsl": semmsl,
        "semmns": semmns,
        "semopm": semopm,
        "msg_queues": msg_queues,
        "msg_total_messages": msg_total_messages,
        "msg_total_bytes": msg_total_bytes,
        "msg_max_queues": msgmni,
        "msg_utilization_pct": round(msg_pct, 4),
        "msgmax": msgmax,
        "msgmnb": msgmnb,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux System V IPC shared memory, semaphores, and message queue capacity."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--sysvipc-dir", default=PROC_SYSVIPC, help=f"Path to /proc/sysvipc (default: {PROC_SYSVIPC})")
    parser.add_argument("--kernel-dir", default=PROC_SYS_KERNEL, help=f"Path to /proc/sys/kernel (default: {PROC_SYS_KERNEL})")
    parser.add_argument("--warn-ipc-pct", type=float, default=DEFAULT_WARN_IPC_PCT, help="IPC table warning threshold %%")
    parser.add_argument("--crit-ipc-pct", type=float, default=DEFAULT_CRIT_IPC_PCT, help="IPC table critical threshold %%")
    parser.add_argument("--warn-unattached-shm", type=int, default=DEFAULT_WARN_UNATTACHED_SHM, help="Unattached SHM warning threshold")
    parser.add_argument("--crit-unattached-shm", type=int, default=DEFAULT_CRIT_UNATTACHED_SHM, help="Unattached SHM critical threshold")

    args = parser.parse_args()

    result = evaluate_sysv_ipc(
        sysvipc_dir=args.sysvipc_dir,
        kernel_dir=args.kernel_dir,
        warn_ipc_pct=args.warn_ipc_pct,
        crit_ipc_pct=args.crit_ipc_pct,
        warn_unattached_shm=args.warn_unattached_shm,
        crit_unattached_shm=args.crit_unattached_shm,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 313 (sysv_ipc): {result['status']}")
        print(
            f"  SHM: {result['shm_segments']} / {result['shm_max_segments']} segments ({result['shm_utilization_pct']}%) | "
            f"Bytes: {result['shm_total_bytes']} B | Unattached: {result['shm_unattached']}"
        )
        print(
            f"  SEM: {result['sem_arrays']} / {result['sem_max_arrays']} arrays ({result['sem_utilization_pct']}%) | "
            f"NSEMS: {result['sem_total_nsems']} | semmsl={result['semmsl']} semmns={result['semmns']}"
        )
        print(
            f"  MSG: {result['msg_queues']} / {result['msg_max_queues']} queues ({result['msg_utilization_pct']}%) | "
            f"Msgs: {result['msg_total_messages']} | Bytes: {result['msg_total_bytes']} B"
        )
        if result["issues"]:
            print("  Issues:")
            for iss in result["issues"]:
                print(f"    - {iss}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
