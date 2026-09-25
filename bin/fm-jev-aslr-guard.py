#!/usr/bin/env python3
"""
bin/fm-jev-aslr-guard.py - Linux Kernel ASLR & Virtual Memory Security Hardening Guard (Pattern 315 / Pattern 453)

Audits Linux kernel Address Space Layout Randomization (ASLR) and memory space protection sysctls
(/proc/sys/kernel/randomize_va_space, /proc/sys/vm/mmap_min_addr,
/proc/sys/vm/unprivileged_userfaultfd, /proc/sys/vm/legacy_va_layout) to detect disabled ASLR
(randomize_va_space=0), NULL pointer dereference exploitation risk (mmap_min_addr=0),
unprivileged userfaultfd race exploitation primitives, and legacy constrained VA layouts.

Invariants:
  - Critical when randomize_va_space == 0 (ASLR disabled) or mmap_min_addr == 0 (NULL pointer dereference).
  - Warning when randomize_va_space == 1 (conservative ASLR), mmap_min_addr < 4096, unprivileged_userfaultfd == 1, or legacy_va_layout == 1.
  - Fail-open: graceful fallback when sysctl paths are restricted.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_SYS_KERNEL = "/proc/sys/kernel"
PROC_SYS_VM = "/proc/sys/vm"

ASLR_MODES = {
    0: "disabled",
    1: "conservative",
    2: "full",
}

DEFAULT_MIN_MMAP_ADDR = 4096


def parse_int_file(path: Path, default: int = -1) -> int:
    if not path.is_file():
        return default
    try:
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        parts = content.split()
        return int(parts[0]) if parts and parts[0].lstrip("-").isdigit() else default
    except (ValueError, OSError, IndexError):
        return default


def evaluate_aslr(
    kernel_dir: str = PROC_SYS_KERNEL,
    vm_dir: str = PROC_SYS_VM,
    min_mmap_addr: int = DEFAULT_MIN_MMAP_ADDR,
    warn_on_conservative_aslr: bool = True,
    warn_on_userfaultfd_enabled: bool = True,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    k_path = Path(kernel_dir)
    vm_path = Path(vm_dir)

    va_val = parse_int_file(k_path / "randomize_va_space", default=2)
    va_mode = ASLR_MODES.get(va_val, f"unknown_{va_val}")

    mmap_min = parse_int_file(vm_path / "mmap_min_addr", default=65536)
    userfaultfd = parse_int_file(vm_path / "unprivileged_userfaultfd", default=0)
    legacy_va = parse_int_file(vm_path / "legacy_va_layout", default=0)

    # ASLR status
    if va_val == 0:
        status = "CRITICAL"
        issues.append(
            "Kernel ASLR is completely disabled (randomize_va_space=0); "
            "stack, heap, and library addresses are fixed, leaving binaries vulnerable to ROP/code execution"
        )
        recommendations.append("Enable full ASLR immediately: sysctl -w kernel.randomize_va_space=2")
    elif va_val == 1 and warn_on_conservative_aslr:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            "Kernel ASLR is operating in conservative mode (randomize_va_space=1); "
            "data/brk heap segments are unrandomized"
        )
        recommendations.append("Switch to full ASLR: sysctl -w kernel.randomize_va_space=2")

    # mmap_min_addr
    if mmap_min == 0:
        status = "CRITICAL"
        issues.append(
            "Kernel mmap_min_addr is 0; unprivileged processes can allocate page 0, "
            "enabling kernel NULL pointer dereference privilege escalation exploits"
        )
        recommendations.append("Harden minimum mmap address: sysctl -w vm.mmap_min_addr=65536")
    elif mmap_min < min_mmap_addr:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Kernel mmap_min_addr is unusually low ({mmap_min} < {min_mmap_addr} bytes)"
        )
        recommendations.append(f"Set sysctl -w vm.mmap_min_addr >= {min_mmap_addr}")

    # unprivileged_userfaultfd
    if warn_on_userfaultfd_enabled and userfaultfd == 1:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            "Unprivileged userfaultfd is enabled (unprivileged_userfaultfd=1); "
            "exposes kernel heap use-after-free and fault stalling race exploit primitives"
        )
        recommendations.append("Restrict userfaultfd: sysctl -w vm.unprivileged_userfaultfd=0")

    # legacy_va_layout
    if legacy_va == 1:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            "Legacy virtual address layout is enabled (legacy_va_layout=1); "
            "constrains mmap randomization entropy"
        )
        recommendations.append("Disable legacy layout: sysctl -w vm.legacy_va_layout=0")

    healthy = (status == "HEALTHY")
    is_hardened = (
        va_val == 2
        and mmap_min >= 65536
        and userfaultfd == 0
        and legacy_va == 0
    )

    return {
        "pattern": 315,
        "name": "aslr",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_hardened": is_hardened,
        "randomize_va_space": va_val,
        "aslr_mode": va_mode,
        "mmap_min_addr": mmap_min,
        "unprivileged_userfaultfd": userfaultfd == 1,
        "legacy_va_layout": legacy_va == 1,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux kernel ASLR and virtual memory space security parameters."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--kernel-dir", default=PROC_SYS_KERNEL, help=f"Path to /proc/sys/kernel (default: {PROC_SYS_KERNEL})")
    parser.add_argument("--vm-dir", default=PROC_SYS_VM, help=f"Path to /proc/sys/vm (default: {PROC_SYS_VM})")
    parser.add_argument("--min-mmap-addr", type=int, default=DEFAULT_MIN_MMAP_ADDR, help="Minimum mmap address bytes")

    args = parser.parse_args()

    result = evaluate_aslr(
        kernel_dir=args.kernel_dir,
        vm_dir=args.vm_dir,
        min_mmap_addr=args.min_mmap_addr,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 315 (aslr): {result['status']}")
        print(
            f"  ASLR: {result['randomize_va_space']} ({result['aslr_mode']}) | "
            f"mmap_min_addr: {result['mmap_min_addr']} B | Hardened: {result['is_hardened']}"
        )
        print(
            f"  Userfaultfd: {result['unprivileged_userfaultfd']} | Legacy VA: {result['legacy_va_layout']}"
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
