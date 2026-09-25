#!/usr/bin/env python3
"""
bin/fm-jev-vfs-protect-guard.py - Linux Kernel VFS Link Protection & Mount Table Guard (Pattern 309 / Pattern 447)

Audits Linux kernel VFS filesystem protection parameters and link hardening:
  - /proc/sys/fs/protected_symlinks: Symlink traversal protection (TOCTOU race prevention in sticky/world-writable dirs)
  - /proc/sys/fs/protected_hardlinks: Hardlink creation protection (unauthorized file pinning prevention)
  - /proc/sys/fs/protected_fifos: FIFO creation protection in sticky world-writable directories
  - /proc/sys/fs/protected_regular: Regular file write protection in sticky world-writable directories
  - /proc/sys/fs/suid_dumpable: Process core dump restriction for SUID/privilege-elevated binaries
  - /proc/sys/fs/mount-max: Mount namespace ceiling (prevent mount exhaustion under container workloads)
  - /proc/sys/fs/leases-enable: Kernel file lease support
  - /proc/sys/fs/lease-break-time: Lease break grace interval in seconds

Invariants:
  - protected_symlinks and protected_hardlinks must be enabled (>= 1).
  - protected_fifos and protected_regular must be active (>= 1).
  - mount-max must provide sufficient namespace capacity (>= 1000).
  - Fail-open: graceful fallback when sysctl paths are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List

PROC_SYS_FS = "/proc/sys/fs"


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


def evaluate_vfs_protect(
    fs_dir: str = PROC_SYS_FS,
    warn_on_unprotected: bool = True,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    fs_path = Path(fs_dir)

    symlinks = read_sysctl_int(str(fs_path / "protected_symlinks"), default=1)
    hardlinks = read_sysctl_int(str(fs_path / "protected_hardlinks"), default=1)
    fifos = read_sysctl_int(str(fs_path / "protected_fifos"), default=1)
    regular = read_sysctl_int(str(fs_path / "protected_regular"), default=2)
    suid_dumpable = read_sysctl_int(str(fs_path / "suid_dumpable"), default=0)
    mount_max = read_sysctl_int(str(fs_path / "mount-max"), default=100000)
    leases_enable = read_sysctl_int(str(fs_path / "leases-enable"), default=1)
    lease_break_time = read_sysctl_int(str(fs_path / "lease-break-time"), default=45)

    if warn_on_unprotected and symlinks == 0:
        issues.append(
            "Kernel symlink protection is disabled (protected_symlinks=0); "
            "vulnerable to TOCTOU symlink traversal attacks in world-writable directories"
        )
        recommendations.append("Enable sysctl fs.protected_symlinks=1")
        status = "WARNING"

    if warn_on_unprotected and hardlinks == 0:
        issues.append(
            "Kernel hardlink protection is disabled (protected_hardlinks=0); "
            "unprivileged processes can pin and create hardlinks to unauthorized files"
        )
        recommendations.append("Enable sysctl fs.protected_hardlinks=1")
        status = "WARNING"

    if warn_on_unprotected and fifos == 0:
        issues.append(
            "Kernel FIFO protection is disabled (protected_fifos=0); "
            "vulnerable to FIFO spoofing and unauthorized data injection in shared directories"
        )
        recommendations.append("Enable sysctl fs.protected_fifos=1")
        status = "WARNING"

    if warn_on_unprotected and regular == 0:
        issues.append(
            "Kernel regular file protection is disabled (protected_regular=0); "
            "vulnerable to file overwrite attacks in sticky world-writable directories"
        )
        recommendations.append("Enable sysctl fs.protected_regular=2")
        status = "WARNING"

    if mount_max != -1 and mount_max < 1000:
        issues.append(
            f"Kernel mount table maximum is unusually low (mount-max={mount_max} < 1000); "
            "risk of mount table starvation under containerized agent environments"
        )
        recommendations.append("Set sysctl fs.mount-max >= 10000")
        status = "WARNING"

    healthy = len(issues) == 0
    is_hardened = (symlinks >= 1 and hardlinks >= 1 and fifos >= 1 and regular >= 1)

    return {
        "pattern": 309,
        "name": "vfs_protect",
        "description": "Linux Kernel VFS Filesystem Link Protection & Mount Table Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "protected_symlinks": symlinks,
        "protected_hardlinks": hardlinks,
        "protected_fifos": fifos,
        "protected_regular": regular,
        "suid_dumpable": suid_dumpable,
        "mount_max": mount_max,
        "leases_enable": leases_enable == 1,
        "lease_break_time_sec": lease_break_time,
        "is_hardened": is_hardened,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux Kernel VFS Link Protection & Mount Table Guard (Pattern 309 / Pattern 447)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--fs-dir", default=PROC_SYS_FS, help="Path to /proc/sys/fs")
    args = parser.parse_args()

    result = evaluate_vfs_protect(fs_dir=args.fs_dir)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  VFS Link Hardened: {result['is_hardened']}")
        print(f"  protected_symlinks={result['protected_symlinks']}, protected_hardlinks={result['protected_hardlinks']}")
        print(f"  protected_fifos={result['protected_fifos']}, protected_regular={result['protected_regular']}")
        print(f"  suid_dumpable={result['suid_dumpable']}, mount_max={result['mount_max']}")
        print(f"  leases_enable={result['leases_enable']}, lease_break_time={result['lease_break_time_sec']}s")
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
