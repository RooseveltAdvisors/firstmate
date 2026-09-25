#!/usr/bin/env python3
"""
bin/fm-jev-pipe-capacity-guard.py - Linux Kernel VFS Pipe Capacity Guard (Pattern 308 / Pattern 446)

Audits Linux kernel VFS pipe buffer capacity configuration and user allocation limits:
  - /proc/sys/fs/pipe-max-size: Maximum pipe buffer capacity for unprivileged processes (default 1MB)
  - /proc/sys/fs/pipe-user-pages-hard: Hard ceiling on user memory allocated to pipe buffers (0 = unlimited)
  - /proc/sys/fs/pipe-user-pages-soft: Soft threshold triggering unprivileged allocation throttling (default 16384 pages / 64MB)

Invariants:
  - pipe_max_size must be >= 64KB to avoid IPC pipeline stalls and context-switching storms.
  - pipe_max_size must not exceed 16MB to prevent unbounded per-pipe kernel memory pinning.
  - pipe_user_pages_soft must provide adequate headroom (>= 1024 pages / 4MB).
  - If hard limit is configured, it must be >= soft limit.
  - Fail-open: graceful fallback when sysfs/sysctl paths are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List

PROC_FS_PIPE_MAX_SIZE = "/proc/sys/fs/pipe-max-size"
PROC_FS_PIPE_USER_PAGES_HARD = "/proc/sys/fs/pipe-user-pages-hard"
PROC_FS_PIPE_USER_PAGES_SOFT = "/proc/sys/fs/pipe-user-pages-soft"

DEFAULT_MIN_PIPE_MAX_SIZE = 65_536  # 64 KB minimum
DEFAULT_MAX_PIPE_MAX_SIZE = 16_777_216  # 16 MB maximum
DEFAULT_MIN_PIPE_USER_SOFT_PAGES = 1_024  # 4 MB minimum soft limit (1024 * 4KB)


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        parts = content.split()
        return int(parts[0]) if parts and parts[0].lstrip("-").isdigit() else default
    except (ValueError, OSError, IndexError):
        return default


def evaluate_pipe_capacity(
    pipe_max_size_file: str = PROC_FS_PIPE_MAX_SIZE,
    pipe_user_pages_hard_file: str = PROC_FS_PIPE_USER_PAGES_HARD,
    pipe_user_pages_soft_file: str = PROC_FS_PIPE_USER_PAGES_SOFT,
    min_pipe_max_size: int = DEFAULT_MIN_PIPE_MAX_SIZE,
    max_pipe_max_size: int = DEFAULT_MAX_PIPE_MAX_SIZE,
    min_pipe_user_soft_pages: int = DEFAULT_MIN_PIPE_USER_SOFT_PAGES,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    pipe_max_size = read_sysctl_int(pipe_max_size_file, default=-1)
    pipe_user_pages_hard = read_sysctl_int(pipe_user_pages_hard_file, default=-1)
    pipe_user_pages_soft = read_sysctl_int(pipe_user_pages_soft_file, default=-1)

    if pipe_max_size != -1:
        if pipe_max_size < min_pipe_max_size:
            issues.append(
                f"pipe-max-size ({pipe_max_size} B) is below safe minimum ({min_pipe_max_size} B); IPC pipelines risk throughput degradation"
            )
            recommendations.append(f"Set sysctl fs.pipe-max-size >= {min_pipe_max_size}")
            status = "WARNING"
        elif pipe_max_size > max_pipe_max_size:
            issues.append(
                f"pipe-max-size ({pipe_max_size} B) exceeds maximum safe ceiling ({max_pipe_max_size} B); risks kernel memory pinning"
            )
            recommendations.append(f"Set sysctl fs.pipe-max-size <= {max_pipe_max_size}")
            status = "WARNING"

    if pipe_user_pages_soft != -1:
        if pipe_user_pages_soft < min_pipe_user_soft_pages:
            issues.append(
                f"pipe-user-pages-soft ({pipe_user_pages_soft} pages) is below recommended minimum ({min_pipe_user_soft_pages} pages)"
            )
            recommendations.append(f"Set sysctl fs.pipe-user-pages-soft >= {min_pipe_user_soft_pages}")
            status = "WARNING"

    if (
        pipe_user_pages_hard > 0
        and pipe_user_pages_soft > 0
        and pipe_user_pages_hard < pipe_user_pages_soft
    ):
        issues.append(
            f"pipe-user-pages-hard ({pipe_user_pages_hard}) is less than pipe-user-pages-soft ({pipe_user_pages_soft}); inverted ceiling configuration"
        )
        recommendations.append("Ensure fs.pipe-user-pages-hard >= fs.pipe-user-pages-soft")
        status = "CRITICAL"

    healthy = len(issues) == 0

    pipe_max_size_kb = (pipe_max_size / 1024.0) if pipe_max_size > 0 else 0.0
    pipe_user_soft_mb = (pipe_user_pages_soft * 4096 / (1024.0 * 1024.0)) if pipe_user_pages_soft > 0 else 0.0
    pipe_user_hard_mb = (pipe_user_pages_hard * 4096 / (1024.0 * 1024.0)) if pipe_user_pages_hard > 0 else 0.0

    return {
        "pattern": 308,
        "name": "pipe_capacity",
        "description": "Linux Kernel VFS Pipe Buffer Capacity & Allocation Limit Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "pipe_max_size_bytes": pipe_max_size,
        "pipe_max_size_kb": pipe_max_size_kb,
        "pipe_user_pages_soft": pipe_user_pages_soft,
        "pipe_user_soft_mb": pipe_user_soft_mb,
        "pipe_user_pages_hard": pipe_user_pages_hard,
        "pipe_user_hard_mb": pipe_user_hard_mb,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux Kernel VFS Pipe Capacity Guard (Pattern 308 / Pattern 446)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--pipe-max-size-file", default=PROC_FS_PIPE_MAX_SIZE, help="Path to pipe-max-size sysctl")
    parser.add_argument("--pipe-user-pages-hard-file", default=PROC_FS_PIPE_USER_PAGES_HARD, help="Path to pipe-user-pages-hard sysctl")
    parser.add_argument("--pipe-user-pages-soft-file", default=PROC_FS_PIPE_USER_PAGES_SOFT, help="Path to pipe-user-pages-soft sysctl")
    args = parser.parse_args()

    result = evaluate_pipe_capacity(
        pipe_max_size_file=args.pipe_max_size_file,
        pipe_user_pages_hard_file=args.pipe_user_pages_hard_file,
        pipe_user_pages_soft_file=args.pipe_user_pages_soft_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  Pipe Max Size: {result['pipe_max_size_bytes']} B ({result['pipe_max_size_kb']:.1f} KB)")
        print(f"  User Pages Soft: {result['pipe_user_pages_soft']} pages ({result['pipe_user_soft_mb']:.1f} MB)")
        print(f"  User Pages Hard: {result['pipe_user_pages_hard']} pages ({result['pipe_user_hard_mb']:.1f} MB)")
        if result["issues"]:
            print("  Issues:")
            for issue in result["issues"]:
                print(f"    - {issue}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    if not result["healthy"]:
        sys.exit(1 if result["status"] == "WARNING" else 2)


if __name__ == "__main__":
    main()
