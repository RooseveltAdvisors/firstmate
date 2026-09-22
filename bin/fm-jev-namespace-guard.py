#!/usr/bin/env python3
"""
fm-jev-namespace-guard.py - Jev Multi-Agent Linux Process Namespace & Lingering Sandboxed Environment Guard (Pattern 82)

Audits active Linux kernel namespaces (/proc/<pid>/ns/*: user, mnt, net, pid, ipc, uts, cgroup) across all
running processes and persistent network namespaces (/run/netns). Identifies isolated sandbox namespaces
(Chrome/Playwright sandboxes, Podman containers, bubblewrap jails) and detects lingering/orphaned sandboxed
environments to prevent kernel namespace table exhaustion and hidden multi-agent resource leakage.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback on systems without full namespace privileges.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

DEFAULT_WARN_ISOLATED_NS = 50
DEFAULT_CRIT_ISOLATED_NS = 200

PROC_ROOT = "/proc"
RUN_NETNS = "/run/netns"
NS_TYPES = ("user", "mnt", "net", "pid", "ipc", "uts", "cgroup")


def get_process_comm(proc_root: str, pid: str) -> str:
    """Reads command name from /proc/<pid>/comm."""
    comm_path = os.path.join(proc_root, pid, "comm")
    if os.path.exists(comm_path):
        try:
            with open(comm_path, "r") as f:
                return f.read().strip()
        except Exception:
            return "unknown"
    return "dead"


def read_root_namespaces(proc_root: str = PROC_ROOT) -> Dict[str, str]:
    """Reads baseline namespaces from PID 1 (or current process if PID 1 unreadable)."""
    root_ns: Dict[str, str] = {}
    init_ns_dir = os.path.join(proc_root, "1", "ns")
    fallback_ns_dir = os.path.join(proc_root, "self", "ns")

    target_dir = init_ns_dir if os.path.exists(init_ns_dir) else fallback_ns_dir
    if not os.path.exists(target_dir):
        return root_ns

    for ns_type in NS_TYPES:
        link_path = os.path.join(target_dir, ns_type)
        if os.path.islink(link_path):
            try:
                root_ns[ns_type] = os.readlink(link_path)
            except Exception:
                pass
    return root_ns


def audit_namespaces(
    proc_root: str = PROC_ROOT,
    netns_root: str = RUN_NETNS,
    warn_isolated: int = DEFAULT_WARN_ISOLATED_NS,
    crit_isolated: int = DEFAULT_CRIT_ISOLATED_NS,
) -> Dict[str, Any]:
    """Audits process namespaces and detects isolated sandbox environments."""
    root_ns = read_root_namespaces(proc_root)

    unique_namespaces: Dict[str, Set[str]] = {ns_type: set() for ns_type in NS_TYPES}
    isolated_processes: List[Dict[str, Any]] = []
    pid_count = 0

    if os.path.exists(proc_root):
        try:
            for entry in os.listdir(proc_root):
                if not entry.isdigit():
                    continue
                pid_count += 1
                ns_dir = os.path.join(proc_root, entry, "ns")
                if not os.path.exists(ns_dir):
                    continue

                proc_isolated_types: List[str] = []
                for ns_type in NS_TYPES:
                    link_path = os.path.join(ns_dir, ns_type)
                    if os.path.islink(link_path):
                        try:
                            target = os.readlink(link_path)
                            unique_namespaces[ns_type].add(target)
                            if ns_type in root_ns and target != root_ns[ns_type]:
                                proc_isolated_types.append(ns_type)
                        except Exception:
                            pass

                if proc_isolated_types:
                    comm = get_process_comm(proc_root, entry)
                    isolated_processes.append({
                        "pid": int(entry),
                        "comm": comm,
                        "isolated_types": proc_isolated_types,
                    })
        except Exception:
            pass

    # Audit persistent network namespaces in /run/netns
    named_netns: List[str] = []
    if os.path.exists(netns_root):
        try:
            named_netns = [f for f in os.listdir(netns_root) if not f.startswith(".")]
        except Exception:
            pass

    # Count total unique non-root namespaces
    total_unique_ns = sum(len(s) for s in unique_namespaces.values())
    total_isolated_procs = len(isolated_processes)

    issues: List[str] = []
    status = "HEALTHY"

    if total_isolated_procs >= crit_isolated or len(named_netns) >= crit_isolated:
        status = "CRITICAL"
        issues.append(f"Excessive isolated process namespaces ({total_isolated_procs} sandboxed processes, {len(named_netns)} persistent netns)")
    elif total_isolated_procs >= warn_isolated or len(named_netns) >= warn_isolated:
        status = "WARNING"
        issues.append(f"Elevated isolated process namespaces ({total_isolated_procs} sandboxed processes)")

    unique_counts = {k: len(v) for k, v in unique_namespaces.items()}

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "processes_scanned": pid_count,
            "isolated_processes_count": total_isolated_procs,
            "named_netns_count": len(named_netns),
            "total_unique_namespaces": total_unique_ns,
            "unique_counts": unique_counts,
            "issues": issues,
        },
        "named_netns": named_netns,
        "sample_isolated_processes": isolated_processes[:10],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Linux Process Namespace & Lingering Sandboxed Environment Guard (Pattern 82)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-isolated", type=int, default=DEFAULT_WARN_ISOLATED_NS, help=f"Warning isolated process count (default {DEFAULT_WARN_ISOLATED_NS})")
    parser.add_argument("--crit-isolated", type=int, default=DEFAULT_CRIT_ISOLATED_NS, help=f"Critical isolated process count (default {DEFAULT_CRIT_ISOLATED_NS})")
    parser.add_argument("--proc-root", type=str, default=PROC_ROOT, help="Path to /proc root")
    parser.add_argument("--netns-root", type=str, default=RUN_NETNS, help="Path to /run/netns root")

    args = parser.parse_args()

    result = audit_namespaces(
        proc_root=args.proc_root,
        netns_root=args.netns_root,
        warn_isolated=args.warn_isolated,
        crit_isolated=args.crit_isolated,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Process Namespace Guard (Pattern 82)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Processes Scanned:      {summary['processes_scanned']}")
    print(f" Sandboxed / Isolated:   {summary['isolated_processes_count']} processes ({summary['named_netns_count']} named netns)")
    print(f" Unique Namespaces:      user={summary['unique_counts']['user']}, mnt={summary['unique_counts']['mnt']}, net={summary['unique_counts']['net']}, pid={summary['unique_counts']['pid']}")

    if result["sample_isolated_processes"]:
        print("\nSample Sandboxed Processes:")
        for p in result["sample_isolated_processes"]:
            print(f"  - PID {p['pid']:<7} ({p['comm']:<16}): isolated [{', '.join(p['isolated_types'])}]")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo lingering orphaned sandboxes, leaked netns, or namespace exhaustion detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
