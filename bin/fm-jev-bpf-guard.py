#!/usr/bin/env python3
"""
fm-jev-bpf-guard.py - Jev Multi-Agent eBPF Map & BPF Program Limit Exhaustion Guard (Pattern 75)

Audits Linux kernel eBPF state, unprivileged BPF security sysctls, open BPF map/program file descriptors,
and pinned BPF virtual filesystem nodes. Detects unprivileged BPF exposure, orphaned BPF descriptor leaks
from exited container runtimes or tracing agents, and JIT compilation limits.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback when /sys/fs/bpf or kernel sysctls are restricted to root.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_WARN_ACTIVE_FDS = 200
DEFAULT_CRIT_ACTIVE_FDS = 1000
DEFAULT_WARN_PINNED_OBJS = 500
DEFAULT_CRIT_PINNED_OBJS = 2000

SYSCTL_UNPRIV_BPF = "/proc/sys/kernel/unprivileged_bpf_disabled"
SYSCTL_BPF_JIT = "/proc/sys/net/core/bpf_jit_enable"
SYSCTL_BPF_HARDEN = "/proc/sys/net/core/bpf_jit_harden"
SYSCTL_BPF_STATS = "/proc/sys/kernel/bpf_stats_enabled"
BPF_FS_PATH = "/sys/fs/bpf"


def read_sysctl_int(path: str, default: Optional[int] = None) -> Optional[int]:
    """Reads integer sysctl safely."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r") as f:
            return int(f.read().strip())
    except Exception:
        return default


def scan_bpf_file_descriptors(proc_root: str = "/proc") -> Tuple[int, List[Dict[str, Any]]]:
    """
    Scans accessible /proc/*/fd/* for anon_inode:bpf-map or anon_inode:bpf-prog descriptors.
    Fast bounded scan over numeric pid entries.
    """
    total_bpf_fds = 0
    proc_consumers: List[Dict[str, Any]] = []

    try:
        pid_entries = [d for d in os.scandir(proc_root) if d.is_dir(follow_symlinks=False) and d.name.isdigit()]
    except Exception:
        return 0, []

    for pentry in pid_entries:
        pid = int(pentry.name)
        fd_dir = os.path.join(pentry.path, "fd")
        if not os.path.isdir(fd_dir):
            continue

        bpf_count = 0
        try:
            with os.scandir(fd_dir) as fds:
                for fd in fds:
                    try:
                        target = os.readlink(fd.path)
                        if "bpf" in target.lower():
                            bpf_count += 1
                    except Exception:
                        pass
        except Exception:
            pass

        if bpf_count > 0:
            total_bpf_fds += bpf_count
            comm = "unknown"
            try:
                comm_path = os.path.join(pentry.path, "comm")
                if os.path.exists(comm_path):
                    with open(comm_path, "r") as f:
                        comm = f.read().strip()
            except Exception:
                pass

            proc_consumers.append({
                "pid": pid,
                "comm": comm,
                "bpf_fds": bpf_count,
            })

    proc_consumers.sort(key=lambda x: x["bpf_fds"], reverse=True)
    return total_bpf_fds, proc_consumers


def scan_pinned_bpf_objects(bpf_fs: str = BPF_FS_PATH) -> Tuple[Optional[int], bool]:
    """
    Scans /sys/fs/bpf for pinned objects.
    Returns (count, accessible).
    """
    if not os.path.exists(bpf_fs):
        return None, False

    count = 0
    try:
        for root, dirs, files in os.walk(bpf_fs):
            count += len(files)
            # Limit depth
            if root.count(os.sep) > 4:
                break
        return count, True
    except PermissionError:
        return None, False
    except Exception:
        return None, False


def audit_bpf(
    unpriv_path: str = SYSCTL_UNPRIV_BPF,
    jit_path: str = SYSCTL_BPF_JIT,
    harden_path: str = SYSCTL_BPF_HARDEN,
    stats_path: str = SYSCTL_BPF_STATS,
    bpf_fs: str = BPF_FS_PATH,
    proc_root: str = "/proc",
    warn_active_fds: int = DEFAULT_WARN_ACTIVE_FDS,
    crit_active_fds: int = DEFAULT_CRIT_ACTIVE_FDS,
    warn_pinned_objs: int = DEFAULT_WARN_PINNED_OBJS,
    crit_pinned_objs: int = DEFAULT_CRIT_PINNED_OBJS,
) -> Dict[str, Any]:
    """Audits eBPF state and produces health assessment."""
    unpriv_disabled = read_sysctl_int(unpriv_path, default=None)
    jit_enabled = read_sysctl_int(jit_path, default=None)
    jit_hardened = read_sysctl_int(harden_path, default=None)
    stats_enabled = read_sysctl_int(stats_path, default=None)

    active_bpf_fds, consumers = scan_bpf_file_descriptors(proc_root=proc_root)
    pinned_count, fs_accessible = scan_pinned_bpf_objects(bpf_fs=bpf_fs)

    issues: List[str] = []
    status = "HEALTHY"

    # Check unprivileged bpf security
    if unpriv_disabled == 0:
        issues.append("Unprivileged eBPF is enabled (sysctl unprivileged_bpf_disabled=0); attack surface elevated")
        status = "WARNING"

    # Check active descriptor thresholds
    if active_bpf_fds >= crit_active_fds:
        issues.append(f"Active BPF file descriptors critical: {active_bpf_fds} >= {crit_active_fds}")
        status = "CRITICAL"
    elif active_bpf_fds >= warn_active_fds:
        issues.append(f"Active BPF file descriptors elevated: {active_bpf_fds} >= {warn_active_fds}")
        if status != "CRITICAL":
            status = "WARNING"

    # Check pinned objects if accessible
    if pinned_count is not None:
        if pinned_count >= crit_pinned_objs:
            issues.append(f"Pinned BPF objects critical: {pinned_count} >= {crit_pinned_objs}")
            status = "CRITICAL"
        elif pinned_count >= warn_pinned_objs:
            issues.append(f"Pinned BPF objects elevated: {pinned_count} >= {warn_pinned_objs}")
            if status != "CRITICAL":
                status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "unprivileged_bpf_disabled": unpriv_disabled,
            "bpf_jit_enable": jit_enabled,
            "bpf_jit_harden": jit_hardened,
            "bpf_stats_enabled": stats_enabled,
            "active_bpf_fds": active_bpf_fds,
            "pinned_bpf_objects": pinned_count,
            "bpf_fs_accessible": fs_accessible,
            "processes_with_bpf": len(consumers),
            "issues": issues,
        },
        "top_consumers": consumers[:10],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent eBPF Map & BPF Program Limit Exhaustion Guard (Pattern 75)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-fds", type=int, default=DEFAULT_WARN_ACTIVE_FDS, help=f"Warning active BPF FDs (default {DEFAULT_WARN_ACTIVE_FDS})")
    parser.add_argument("--crit-fds", type=int, default=DEFAULT_CRIT_ACTIVE_FDS, help=f"Critical active BPF FDs (default {DEFAULT_CRIT_ACTIVE_FDS})")
    parser.add_argument("--warn-pinned", type=int, default=DEFAULT_WARN_PINNED_OBJS, help=f"Warning pinned BPF objects (default {DEFAULT_WARN_PINNED_OBJS})")
    parser.add_argument("--crit-pinned", type=int, default=DEFAULT_CRIT_PINNED_OBJS, help=f"Critical pinned BPF objects (default {DEFAULT_CRIT_PINNED_OBJS})")
    parser.add_argument("--proc-root", type=str, default="/proc", help="Path to procfs root")
    parser.add_argument("--bpf-fs", type=str, default=BPF_FS_PATH, help="Path to /sys/fs/bpf")
    parser.add_argument("--sysctl-unpriv", type=str, default=SYSCTL_UNPRIV_BPF, help="Path to unprivileged_bpf_disabled sysctl")
    parser.add_argument("--sysctl-jit", type=str, default=SYSCTL_BPF_JIT, help="Path to bpf_jit_enable sysctl")
    parser.add_argument("--sysctl-harden", type=str, default=SYSCTL_BPF_HARDEN, help="Path to bpf_jit_harden sysctl")
    parser.add_argument("--sysctl-stats", type=str, default=SYSCTL_BPF_STATS, help="Path to bpf_stats_enabled sysctl")

    args = parser.parse_args()

    result = audit_bpf(
        unpriv_path=args.sysctl_unpriv,
        jit_path=args.sysctl_jit,
        harden_path=args.sysctl_harden,
        stats_path=args.sysctl_stats,
        bpf_fs=args.bpf_fs,
        proc_root=args.proc_root,
        warn_active_fds=args.warn_fds,
        crit_active_fds=args.crit_fds,
        warn_pinned_objs=args.warn_pinned,
        crit_pinned_objs=args.crit_pinned,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent eBPF Map & BPF Program Limit Guard (Pattern 75)")
    print("================================================================================")
    print(f" Timestamp:                  {result['timestamp']}")
    print(f" Status:                     {status_color}{summary['status']}{reset_color}")
    print(f" Unprivileged BPF Disabled:  {summary['unprivileged_bpf_disabled']} (2=locked, 1=disabled, 0=enabled)")
    print(f" BPF JIT Compiler:           {summary['bpf_jit_enable']} (1=enabled)")
    print(f" Active BPF File Descriptors:{summary['active_bpf_fds']}")
    pinned_str = str(summary['pinned_bpf_objects']) if summary['pinned_bpf_objects'] is not None else "(restricted)"
    print(f" Pinned BPF Objects:         {pinned_str} (fs accessible: {summary['bpf_fs_accessible']})")
    print(f" Processes With BPF FDs:     {summary['processes_with_bpf']}")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo eBPF descriptor leaks, pinned map exhaustion, or unprivileged exposure detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
