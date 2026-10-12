#!/usr/bin/env python3
"""
fm-jev-mqueue-guard.py - Jev Multi-Agent POSIX & System V IPC Message Queue Guard (Pattern 65)

Audits kernel POSIX message queues (/dev/mqueue, /proc/sys/fs/mqueue/queues_max)
and System V IPC message queues (/proc/sysvipc/msg).
Detects orphaned message queue exhaustion and unbounded IPC buffer accumulation across
parallel agent worker and daemon pipelines.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Fail-open: graceful handling on systems where /dev/mqueue is unmounted or permissions restricted.
  - Fast execution (< 0.1s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_WARN_QUEUE_RATIO = 0.50
DEFAULT_WARN_MSG_COUNT = 1000


def get_mqueue_limits(proc_root: str = "/proc") -> Tuple[int, int]:
    """Reads /proc/sys/fs/mqueue/queues_max and msg_max safely."""
    queues_max = 256
    msg_max = 10
    try:
        with open(os.path.join(proc_root, "sys/fs/mqueue/queues_max"), "r") as f:
            queues_max = int(f.read().strip())
    except Exception:
        pass

    try:
        with open(os.path.join(proc_root, "sys/fs/mqueue/msg_max"), "r") as f:
            msg_max = int(f.read().strip())
    except Exception:
        pass

    return queues_max, msg_max


def scan_posix_mqueues(mqueue_root: str = "/dev/mqueue") -> List[Dict[str, Any]]:
    """Scans POSIX message queues under /dev/mqueue."""
    queues: List[Dict[str, Any]] = []
    if not os.path.exists(mqueue_root):
        return queues

    try:
        entries = os.listdir(mqueue_root)
    except (PermissionError, FileNotFoundError):
        return queues

    for entry in entries:
        full_path = os.path.join(mqueue_root, entry)
        try:
            stat_info = os.stat(full_path)
            content = ""
            try:
                with open(full_path, "r", errors="replace") as f:
                    content = f.read().strip()
            except Exception:
                pass

            queues.append({
                "name": entry,
                "path": full_path,
                "size_bytes": stat_info.st_size,
                "uid": stat_info.st_uid,
                "gid": stat_info.st_gid,
                "mode": oct(stat_info.st_mode),
                "details": content,
            })
        except Exception:
            pass

    return queues


def scan_sysv_mqueues(proc_root: str = "/proc") -> List[Dict[str, Any]]:
    """Reads System V message queues from /proc/sysvipc/msg."""
    queues: List[Dict[str, Any]] = []
    msg_path = os.path.join(proc_root, "sysvipc/msg")
    if not os.path.exists(msg_path):
        return queues

    try:
        with open(msg_path, "r", errors="replace") as f:
            lines = f.readlines()
            if len(lines) <= 1:
                return queues
            # Skip header line
            for line in lines[1:]:
                parts = line.strip().split()
                if len(parts) >= 14:
                    queues.append({
                        "key": parts[0],
                        "msqid": int(parts[1]),
                        "perms": parts[2],
                        "cbytes": int(parts[3]),
                        "qnum": int(parts[4]),
                        "lspid": int(parts[5]),
                        "lrpid": int(parts[6]),
                        "uid": int(parts[7]),
                        "gid": int(parts[8]),
                    })
    except Exception:
        pass

    return queues


def audit_fleet_mqueues(
    proc_root: str = "/proc",
    mqueue_root: str = "/dev/mqueue",
    warn_queue_ratio: float = DEFAULT_WARN_QUEUE_RATIO,
    warn_msg_count: int = DEFAULT_WARN_MSG_COUNT,
) -> Dict[str, Any]:
    """Audits POSIX and System V IPC message queues across the host."""
    queues_max, msg_max = get_mqueue_limits(proc_root=proc_root)
    posix_queues = scan_posix_mqueues(mqueue_root=mqueue_root)
    sysv_queues = scan_sysv_mqueues(proc_root=proc_root)

    total_queues = len(posix_queues) + len(sysv_queues)
    queue_utilization_ratio = (len(posix_queues) / queues_max) if queues_max > 0 else 0.0

    total_sysv_messages = sum(q["qnum"] for q in sysv_queues)
    total_sysv_bytes = sum(q["cbytes"] for q in sysv_queues)

    status = "HEALTHY"
    reasons: List[str] = []

    if queue_utilization_ratio >= warn_queue_ratio:
        reasons.append(
            f"POSIX mqueue count ({len(posix_queues)}) exceeds {warn_queue_ratio*100:.0f}% of kernel max ({queues_max})"
        )
        status = "WARNING"

    if total_sysv_messages >= warn_msg_count:
        reasons.append(
            f"System V message queue accumulation ({total_sysv_messages} messages, {total_sysv_bytes} bytes) across {len(sysv_queues)} queues"
        )
        status = "WARNING"

    recommendation = "; ".join(reasons) if reasons else "optimal"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "posix_queues_count": len(posix_queues),
            "posix_queues_max": queues_max,
            "posix_msg_max": msg_max,
            "posix_utilization_ratio": round(queue_utilization_ratio, 4),
            "sysv_queues_count": len(sysv_queues),
            "sysv_total_messages": total_sysv_messages,
            "sysv_total_bytes": total_sysv_bytes,
            "warn_queue_ratio": warn_queue_ratio,
            "warn_msg_count": warn_msg_count,
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "posix_queues": posix_queues,
        "sysv_queues": sysv_queues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent POSIX & System V IPC Message Queue Guard (Pattern 65)"
    )
    parser.add_argument(
        "--warn-queue-ratio",
        type=float,
        default=DEFAULT_WARN_QUEUE_RATIO,
        help=f"Warn threshold for POSIX mqueue capacity ratio (default: {DEFAULT_WARN_QUEUE_RATIO})",
    )
    parser.add_argument(
        "--warn-msg-count",
        type=int,
        default=DEFAULT_WARN_MSG_COUNT,
        help=f"Warn threshold for total pending IPC messages (default: {DEFAULT_WARN_MSG_COUNT})",
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--verbose", action="store_true", help="Verbose queue listing")

    args = parser.parse_args()

    report = audit_fleet_mqueues(
        warn_queue_ratio=args.warn_queue_ratio,
        warn_msg_count=args.warn_msg_count,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        summary = report["summary"]
        status_str = summary["status"]
        print(f"[{status_str}] Jev POSIX & System V IPC Queue Guard (Pattern 65)")
        print(f"POSIX Message Queues: {summary['posix_queues_count']} / {summary['posix_queues_max']} (Max Msg: {summary['posix_msg_max']})")
        print(f"System V Message Queues: {summary['sysv_queues_count']} (Pending Msgs: {summary['sysv_total_messages']}, Bytes: {summary['sysv_total_bytes']:,})")
        print(f"Health Status: {summary['status']}")
        print(f"Recommendation: {summary['recommendation']}")

        if args.verbose:
            if report["posix_queues"]:
                print("\nPOSIX Message Queues:")
                for q in report["posix_queues"]:
                    print(f"  - {q['name']} ({q['size_bytes']} bytes, UID: {q['uid']})")
            if report["sysv_queues"]:
                print("\nSystem V Message Queues:")
                for q in report["sysv_queues"]:
                    print(f"  - MSQID {q['msqid']}: {q['qnum']} msgs, {q['cbytes']} bytes, UID: {q['uid']}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
