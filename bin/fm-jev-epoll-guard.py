#!/usr/bin/env python3
"""
fm-jev-epoll-guard.py - Jev Multi-Agent Host Network TCP Epoll Wait & Edge-Triggered Starvation Guard (Pattern 139)

Audits Linux kernel epoll resource limits (/proc/sys/fs/epoll/max_user_watches) and monitors
active epoll file descriptor registrations across multi-agent processes via /proc/<pid>/fdinfo/<fd>.

In high-concurrency multi-agent architectures running multiple LLM streaming harnesses (Grok,
Cursor, Codex, Pi, Agy), local LLM inference engines (vLLM), Node/Bun microservices, and
background watchers, thousands of asynchronous socket file descriptors are monitored via epoll(7).
If total registered watches approach fs.epoll.max_user_watches, calls to epoll_ctl(EPOLL_CTL_ADD)
fail immediately with ENOSPC, causing event loops to silently crash or stall.

This guard monitors global epoll watch saturation, per-process registration density, and
identifies runaway event loops or descriptor leaks before socket starvation occurs.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.1s).
"""

import argparse
import glob
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_MAX_USER_WATCHES = "/proc/sys/fs/epoll/max_user_watches"
DEFAULT_PROC_DIR = "/proc"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def get_process_cmdline(proc_dir: Path, pid: str) -> str:
    """Retrieves human-readable commandline or comm for a process."""
    cmd_file = proc_dir / pid / "cmdline"
    comm_file = proc_dir / pid / "comm"

    if cmd_file.is_file():
        try:
            content = cmd_file.read_bytes().replace(b"\x00", b" ").strip()
            if content:
                return content.decode("utf-8", errors="replace")[:80]
        except Exception:
            pass

    if comm_file.is_file():
        try:
            return comm_file.read_text().strip()
        except Exception:
            pass

    return "unknown"


def audit_epoll(
    max_watches_file: Optional[str] = None,
    proc_dir: Optional[str] = None,
    top_n: int = 5,
) -> Dict[str, Any]:
    """Audits system epoll watch limits and per-process registration density."""
    max_path = Path(max_watches_file or SYSCTL_MAX_USER_WATCHES)
    p_dir = Path(proc_dir or DEFAULT_PROC_DIR)

    max_user_watches = read_int_file(max_path)
    if max_user_watches is None or max_user_watches <= 0:
        max_user_watches = 1048576  # Safe Linux default

    total_epolls = 0
    total_watches = 0
    process_stats: Dict[str, Dict[str, Any]] = {}

    # Scan /proc/<pid>/fdinfo/* for epoll instances (tfd: entries)
    fdinfo_pattern = str(p_dir / "[0-9]*/fdinfo/*")
    try:
        for fdinfo_path in glob.glob(fdinfo_pattern):
            try:
                path_obj = Path(fdinfo_path)
                pid = path_obj.parts[-3]

                # Fast scan: check if fdinfo contains tfd:
                try:
                    lines = path_obj.read_text(errors="ignore").splitlines()
                except (PermissionError, FileNotFoundError, ProcessLookupError):
                    continue

                watches_in_fd = sum(1 for line in lines if line.startswith("tfd:"))
                if watches_in_fd > 0:
                    total_epolls += 1
                    total_watches += watches_in_fd

                    if pid not in process_stats:
                        process_stats[pid] = {
                            "pid": int(pid) if pid.isdigit() else pid,
                            "epoll_instances": 0,
                            "total_watches": 0,
                            "cmdline": "",
                        }
                    process_stats[pid]["epoll_instances"] += 1
                    process_stats[pid]["total_watches"] += watches_in_fd
            except Exception:
                continue
    except Exception:
        pass

    # Enrich top consumers with cmdline
    sorted_pids = sorted(
        process_stats.values(), key=lambda x: x["total_watches"], reverse=True
    )
    for entry in sorted_pids[: max(top_n, 10)]:
        entry["cmdline"] = get_process_cmdline(p_dir, str(entry["pid"]))

    top_consumers = sorted_pids[:top_n]

    # Calculate utilization
    watch_utilization_pct = round((total_watches / max_user_watches) * 100, 4)

    status = "HEALTHY"
    issues: List[str] = []
    recommendations: List[str] = []

    if watch_utilization_pct >= 80.0:
        status = "CRITICAL"
        issues.append(f"Host epoll watches critically saturated ({total_watches:,} / {max_user_watches:,}, {watch_utilization_pct}%)")
        recommendations.append("Immediately increase sysctl fs.epoll.max_user_watches to prevent ENOSPC crashes")
    elif watch_utilization_pct >= 50.0:
        status = "WARNING"
        issues.append(f"Host epoll watches approaching capacity ({total_watches:,} / {max_user_watches:,}, {watch_utilization_pct}%)")
        recommendations.append("Increase sysctl fs.epoll.max_user_watches or audit event-loop leaks in workers")

    # Check for single-process runaway watch count (> 50,000)
    for entry in top_consumers:
        if entry["total_watches"] > 50000:
            if status != "CRITICAL":
                status = "WARNING"
            issues.append(f"Process PID {entry['pid']} ({entry['cmdline'][:40]}) holds excessive epoll watches ({entry['total_watches']:,})")
            recommendations.append(f"Inspect PID {entry['pid']} for unregistered socket descriptor accumulation")

    if not recommendations:
        recommendations.append("Epoll instance allocation and registered target watch density operating within nominal thresholds")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "max_user_watches": max_user_watches,
            "total_epoll_instances": total_epolls,
            "total_epoll_watches": total_watches,
            "watch_utilization_pct": watch_utilization_pct,
            "top_consumers_count": len(top_consumers),
            "issues": issues,
            "recommendations": recommendations,
        },
        "top_consumers": top_consumers,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Epoll Wait Guard (Pattern 139)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--max-watches-file", type=str, help="Override path to max_user_watches sysctl")
    parser.add_argument("--proc-dir", type=str, help="Override path to /proc directory")
    parser.add_argument("--top-n", type=int, default=5, help="Number of top consumers to display (default: 5)")

    args = parser.parse_args()

    result = audit_epoll(
        max_watches_file=args.max_watches_file,
        proc_dir=args.proc_dir,
        top_n=args.top_n,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]

    print("=== Jev Host Network TCP Epoll Wait Guard (Pattern 139) ===")
    print(f"Status:                    {s['status']}")
    print(f"Max User Epoll Watches:    {s['max_user_watches']:,}")
    print(f"Active Epoll Instances:    {s['total_epoll_instances']:,}")
    print(f"Total Registered Watches:  {s['total_epoll_watches']:,}")
    print(f"Watch Limit Utilization:   {s['watch_utilization_pct']}%")

    if result["top_consumers"]:
        print("\nTop Epoll Watch Consumers:")
        for c in result["top_consumers"]:
            print(f"  - PID {c['pid']:<7} [{c['total_watches']:>4} watches across {c['epoll_instances']:>2} epolls]: {c['cmdline']}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
