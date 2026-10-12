#!/usr/bin/env python3
"""
bin/fm-jev-mem-reserve-guard.py - Linux Kernel Admin & User Memory Reserve Guard (Pattern 311 / Pattern 449)

Audits Linux kernel memory headroom reservation sysctls:
  - /proc/sys/vm/admin_reserve_kbytes: Dedicated memory headroom for root/CAP_SYS_ADMIN processes during OOM events
  - /proc/sys/vm/user_reserve_kbytes: Headroom reserved for user processes to prevent single-process memory monopolization
  - /proc/sys/vm/min_slab_ratio: Reclaimable slab threshold ratio
  - /proc/sys/vm/lowmem_reserve_ratio: Per-zone protection ratios for lower memory zones (DMA, DMA32, Normal)
  - /proc/sys/vm/min_free_kbytes: Minimum free memory watermark cushion

Invariants:
  - admin_reserve_kbytes must be >= 8MB (8192 KB) to prevent SSH/console lockout under heavy memory pressure.
  - user_reserve_kbytes must be >= 64MB (65536 KB) for unprivileged task stability.
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

PROC_SYS_VM = "/proc/sys/vm"

RECOMMENDED_MIN_ADMIN_RESERVE_KB = 8192   # 8 MB
RECOMMENDED_MIN_USER_RESERVE_KB = 65536   # 64 MB


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


def read_space_separated_ints(path: str) -> List[int]:
    if not os.path.isfile(path):
        return []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return [int(x) for x in content.split() if x.lstrip("-").isdigit()]
    except (ValueError, OSError):
        return []


def evaluate_mem_reserve(
    vm_dir: str = PROC_SYS_VM,
    min_admin_reserve_kb: int = RECOMMENDED_MIN_ADMIN_RESERVE_KB,
    min_user_reserve_kb: int = RECOMMENDED_MIN_USER_RESERVE_KB,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    vm_path = Path(vm_dir)

    admin_reserve = read_sysctl_int(str(vm_path / "admin_reserve_kbytes"), default=8192)
    user_reserve = read_sysctl_int(str(vm_path / "user_reserve_kbytes"), default=131072)
    min_slab_ratio = read_sysctl_int(str(vm_path / "min_slab_ratio"), default=5)
    min_free_kbytes = read_sysctl_int(str(vm_path / "min_free_kbytes"), default=67584)
    lowmem_ratios = read_space_separated_ints(str(vm_path / "lowmem_reserve_ratio"))

    if admin_reserve != -1 and admin_reserve < min_admin_reserve_kb:
        issues.append(
            f"admin_reserve_kbytes ({admin_reserve} KB) is below recommended minimum ({min_admin_reserve_kb} KB); "
            "risk of root shell lockout during catastrophic out-of-memory events"
        )
        recommendations.append(f"Set sysctl vm.admin_reserve_kbytes >= {min_admin_reserve_kb}")
        status = "WARNING"

    if user_reserve != -1 and user_reserve < min_user_reserve_kb:
        issues.append(
            f"user_reserve_kbytes ({user_reserve} KB) is below recommended minimum ({min_user_reserve_kb} KB); "
            "risk of unprivileged memory monopolization"
        )
        recommendations.append(f"Set sysctl vm.user_reserve_kbytes >= {min_user_reserve_kb}")
        status = "WARNING"

    healthy = len(issues) == 0
    is_adequately_reserved = (
        admin_reserve >= min_admin_reserve_kb and user_reserve >= min_user_reserve_kb
    )

    admin_mb = (admin_reserve / 1024.0) if admin_reserve > 0 else 0.0
    user_mb = (user_reserve / 1024.0) if user_reserve > 0 else 0.0
    min_free_mb = (min_free_kbytes / 1024.0) if min_free_kbytes > 0 else 0.0

    return {
        "pattern": 311,
        "name": "mem_reserve",
        "description": "Linux Kernel Admin & User Memory Headroom Reserve Guard",
        "status": status,
        "healthy": healthy,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "admin_reserve_kbytes": admin_reserve,
        "admin_reserve_mb": round(admin_mb, 2),
        "user_reserve_kbytes": user_reserve,
        "user_reserve_mb": round(user_mb, 2),
        "min_free_kbytes": min_free_kbytes,
        "min_free_mb": round(min_free_mb, 2),
        "min_slab_ratio": min_slab_ratio,
        "lowmem_reserve_ratios": lowmem_ratios,
        "is_adequately_reserved": is_adequately_reserved,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Linux Kernel Admin & User Memory Reserve Guard (Pattern 311 / Pattern 449)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--vm-dir", default=PROC_SYS_VM, help="Path to /proc/sys/vm")
    args = parser.parse_args()

    result = evaluate_mem_reserve(vm_dir=args.vm_dir)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Pattern {result['pattern']} - {result['description']}")
        print(f"  Adequately Reserved: {result['is_adequately_reserved']}")
        print(f"  Admin Reserve: {result['admin_reserve_kbytes']} KB ({result['admin_reserve_mb']} MB)")
        print(f"  User Reserve: {result['user_reserve_kbytes']} KB ({result['user_reserve_mb']} MB)")
        print(f"  Min Free: {result['min_free_kbytes']} KB ({result['min_free_mb']} MB), Min Slab Ratio: {result['min_slab_ratio']}%")
        print(f"  Lowmem Reserve Ratios: {result['lowmem_reserve_ratios']}")
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
