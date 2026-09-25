#!/usr/bin/env python3
"""
bin/fm-jev-posix-shm-guard.py - POSIX Shared Memory & Named Semaphore Hygiene Guard (Pattern 312 / Pattern 450)

Audits Linux POSIX shared memory mount point (/dev/shm) capacity, inode usage,
IPC limits, and allocated memory objects (PostgreSQL buffers, Chrome render segments, named semaphores)
to detect shared memory exhaustion (ENOSPC on shm_open/ftruncate), inode starvation,
and orphaned IPC memory leaks across multi-agent processes.

Audits:
  - /dev/shm capacity (bytes, used, free, usage %)
  - /dev/shm inode utilization (inodes, used, free, inode usage %)
  - /proc/sys/kernel/shmmax (max size of a shared memory segment in bytes)
  - /proc/sys/kernel/shmall (total amount of shared memory pages available system-wide)
  - /proc/sys/kernel/shmmni (system-wide max number of shared memory segments)
  - Active /dev/shm objects (total, semaphores, postgres, chrome)

Invariants:
  - Warn when /dev/shm usage >= 80%, critical when >= 95%.
  - Warn when inode usage >= 80%, critical when >= 95%.
  - Graceful fallback when /dev/shm or sysctl paths are restricted.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

DEV_SHM_PATH = "/dev/shm"
PROC_SYS_KERNEL = "/proc/sys/kernel"

DEFAULT_WARN_USAGE_PCT = 80.0
DEFAULT_CRIT_USAGE_PCT = 95.0
DEFAULT_WARN_INODE_PCT = 80.0
DEFAULT_CRIT_INODE_PCT = 95.0
MIN_RECOMMENDED_SHMMNI = 1024


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


def evaluate_posix_shm(
    shm_dir: str = DEV_SHM_PATH,
    kernel_dir: str = PROC_SYS_KERNEL,
    warn_usage_pct: float = DEFAULT_WARN_USAGE_PCT,
    crit_usage_pct: float = DEFAULT_CRIT_USAGE_PCT,
    warn_inode_pct: float = DEFAULT_WARN_INODE_PCT,
    crit_inode_pct: float = DEFAULT_CRIT_INODE_PCT,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    shm_path = Path(shm_dir)
    kernel_path = Path(kernel_dir)

    total_bytes = 0
    used_bytes = 0
    free_bytes = 0
    usage_pct = 0.0
    total_inodes = 0
    used_inodes = 0
    free_inodes = 0
    inode_usage_pct = 0.0

    shm_exists = shm_path.is_dir()
    if shm_exists:
        try:
            stat = os.statvfs(str(shm_path))
            total_bytes = stat.f_blocks * stat.f_frsize
            free_bytes = stat.f_bavail * stat.f_frsize
            used_bytes = total_bytes - free_bytes
            if total_bytes > 0:
                usage_pct = round((used_bytes / total_bytes) * 100.0, 2)

            total_inodes = stat.f_files
            free_inodes = stat.f_ffree
            used_inodes = max(0, total_inodes - free_inodes)
            if total_inodes > 0:
                inode_usage_pct = round((used_inodes / total_inodes) * 100.0, 2)
        except Exception as e:
            issues.append(f"Failed to statvfs {shm_dir}: {e}")
            status = "WARNING"
    else:
        issues.append(f"POSIX shared memory directory not found: {shm_dir}")
        status = "WARNING"

    named_semaphores = 0
    postgres_segments = 0
    chrome_segments = 0
    total_objects = 0

    if shm_exists:
        try:
            for entry in shm_path.iterdir():
                total_objects += 1
                name = entry.name
                if name.startswith("sem."):
                    named_semaphores += 1
                elif name.startswith("PostgreSQL."):
                    postgres_segments += 1
                elif "Chrome" in name:
                    chrome_segments += 1
        except Exception:
            pass

    shmmax = read_sysctl_int(str(kernel_path / "shmmax"), default=-1)
    shmall = read_sysctl_int(str(kernel_path / "shmall"), default=-1)
    shmmni = read_sysctl_int(str(kernel_path / "shmmni"), default=4096)

    # Threshold checks
    if usage_pct >= crit_usage_pct:
        status = "CRITICAL"
        issues.append(
            f"{shm_dir} space usage is critical ({usage_pct}% >= {crit_usage_pct}%); "
            "risk of immediate ENOSPC on shm_open"
        )
        recommendations.append(f"Clean orphaned segments or increase tmpfs size on {shm_dir}")
    elif usage_pct >= warn_usage_pct:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"{shm_dir} space usage is elevated ({usage_pct}% >= {warn_usage_pct}%)"
        )
        recommendations.append(f"Monitor memory objects and cleanup unused segments in {shm_dir}")

    if inode_usage_pct >= crit_inode_pct:
        status = "CRITICAL"
        issues.append(
            f"{shm_dir} inode usage is critical ({inode_usage_pct}% >= {crit_inode_pct}%); "
            "risk of inode exhaustion for named semaphores and shm objects"
        )
        recommendations.append(f"Remove excessive named semaphores or remount {shm_dir} with higher nr_inodes")
    elif inode_usage_pct >= warn_inode_pct:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"{shm_dir} inode usage is elevated ({inode_usage_pct}% >= {warn_inode_pct}%)"
        )
        recommendations.append(f"Audit high inode consuming applications in {shm_dir}")

    if shmmni != -1 and shmmni < MIN_RECOMMENDED_SHMMNI:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"kernel.shmmni ({shmmni}) is below recommended minimum ({MIN_RECOMMENDED_SHMMNI})"
        )
        recommendations.append(f"Set sysctl kernel.shmmni >= {MIN_RECOMMENDED_SHMMNI}")

    healthy = (status == "HEALTHY")
    is_exhaustion_free = (usage_pct < warn_usage_pct) and (inode_usage_pct < warn_inode_pct)

    total_mb = round(total_bytes / (1024 * 1024), 2)
    used_mb = round(used_bytes / (1024 * 1024), 2)
    free_mb = round(free_bytes / (1024 * 1024), 2)

    return {
        "pattern": 312,
        "name": "posix_shm",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "shm_dir": str(shm_dir),
        "total_bytes": total_bytes,
        "total_mb": total_mb,
        "used_bytes": used_bytes,
        "used_mb": used_mb,
        "free_bytes": free_bytes,
        "free_mb": free_mb,
        "usage_pct": usage_pct,
        "total_inodes": total_inodes,
        "used_inodes": used_inodes,
        "free_inodes": free_inodes,
        "inode_usage_pct": inode_usage_pct,
        "total_objects": total_objects,
        "named_semaphores": named_semaphores,
        "postgres_segments": postgres_segments,
        "chrome_segments": chrome_segments,
        "shmmax": shmmax,
        "shmall": shmall,
        "shmmni": shmmni,
        "is_exhaustion_free": is_exhaustion_free,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux POSIX shared memory capacity, inode usage, and IPC parameters."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--shm-dir", default=DEV_SHM_PATH, help=f"Path to POSIX shm directory (default: {DEV_SHM_PATH})")
    parser.add_argument("--kernel-dir", default=PROC_SYS_KERNEL, help=f"Path to /proc/sys/kernel (default: {PROC_SYS_KERNEL})")
    parser.add_argument("--warn-usage-pct", type=float, default=DEFAULT_WARN_USAGE_PCT, help="Space warning threshold %%")
    parser.add_argument("--crit-usage-pct", type=float, default=DEFAULT_CRIT_USAGE_PCT, help="Space critical threshold %%")
    parser.add_argument("--warn-inode-pct", type=float, default=DEFAULT_WARN_INODE_PCT, help="Inode warning threshold %%")
    parser.add_argument("--crit-inode-pct", type=float, default=DEFAULT_CRIT_INODE_PCT, help="Inode critical threshold %%")

    args = parser.parse_args()

    result = evaluate_posix_shm(
        shm_dir=args.shm_dir,
        kernel_dir=args.kernel_dir,
        warn_usage_pct=args.warn_usage_pct,
        crit_usage_pct=args.crit_usage_pct,
        warn_inode_pct=args.warn_inode_pct,
        crit_inode_pct=args.crit_inode_pct,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 312 (posix_shm): {result['status']}")
        print(
            f"  Space: {result['used_mb']} MB / {result['total_mb']} MB ({result['usage_pct']}%) | "
            f"Free: {result['free_mb']} MB"
        )
        print(
            f"  Inodes: {result['used_inodes']} / {result['total_inodes']} ({result['inode_usage_pct']}%) | "
            f"Free: {result['free_inodes']}"
        )
        print(
            f"  Objects: {result['total_objects']} total ({result['named_semaphores']} sem, "
            f"{result['postgres_segments']} pg, {result['chrome_segments']} chrome)"
        )
        print(
            f"  Sysctl: shmmax={result['shmmax']} | shmall={result['shmall']} | shmmni={result['shmmni']}"
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
