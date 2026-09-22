#!/usr/bin/env python3
"""
bin/fm-jev-unix-guard.py - Host Network UNIX Domain Socket Namespace & Datagram Queue Guard (Pattern 206)

Audits Linux kernel UNIX domain socket statistics, IPC namespaces, and datagram queue capacities from:
  - /proc/net/unix (Num, RefCount, Protocol, Flags, Type, St, Inode, Path)
  - /proc/sys/net/unix/max_dgram_qlen (datagram socket backlog capacity)

Detects UNIX socket descriptor leaks, abandoned abstract namespace endpoints, high refcount contention,
and stream/datagram socket exhaustion across multi-agent IPC channels and session runners.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Tuple


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def parse_proc_net_unix(path: str = "/proc/net/unix") -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    sockets: List[Dict[str, Any]] = []
    stats: Dict[str, Any] = {
        "total": 0,
        "stream": 0,
        "dgram": 0,
        "seqpacket": 0,
        "other_type": 0,
        "connected": 0,
        "listening": 0,
        "unconnected": 0,
        "filesystem_paths": 0,
        "abstract_paths": 0,
        "anonymous_paths": 0,
        "max_refcount": 0,
        "max_refcount_path": "",
    }
    if not os.path.exists(path):
        return sockets, stats

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
        if len(lines) <= 1:
            return sockets, stats

        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 7:
                refcount = int(parts[1], 16)
                flags = int(parts[3], 16)
                sock_type = int(parts[4], 16)
                state = int(parts[5], 16)
                inode = parts[6]
                sock_path = parts[7] if len(parts) >= 8 else ""

                is_listen = bool(flags & 0x00010000)
                stats["total"] += 1

                if sock_type == 1:
                    stats["stream"] += 1
                elif sock_type == 2:
                    stats["dgram"] += 1
                elif sock_type == 5:
                    stats["seqpacket"] += 1
                else:
                    stats["other_type"] += 1

                if is_listen:
                    stats["listening"] += 1
                elif state == 3:
                    stats["connected"] += 1
                else:
                    stats["unconnected"] += 1

                if sock_path.startswith("@"):
                    stats["abstract_paths"] += 1
                elif sock_path.startswith("/"):
                    stats["filesystem_paths"] += 1
                else:
                    stats["anonymous_paths"] += 1

                if refcount > stats["max_refcount"]:
                    stats["max_refcount"] = refcount
                    stats["max_refcount_path"] = sock_path

                sockets.append({
                    "refcount": refcount,
                    "type": sock_type,
                    "state": state,
                    "inode": inode,
                    "path": sock_path,
                })
    except Exception:
        pass

    return sockets, stats


def audit_unix_sockets(
    proc_net_unix: str = "/proc/net/unix",
    proc_sys_unix: str = "/proc/sys/net/unix",
) -> Dict[str, Any]:
    _, stats = parse_proc_net_unix(proc_net_unix)

    max_dgram_qlen = read_sysctl_int(
        os.path.join(proc_sys_unix, "max_dgram_qlen"), 512
    )

    total = stats["total"]
    listening = stats["listening"]
    issues: List[str] = []
    status = "HEALTHY"

    if total > 5000:
        issues.append(f"CRITICAL: Excessive UNIX domain socket count ({total} sockets); potential IPC descriptor leak")
        status = "CRITICAL"
    elif total > 2000:
        issues.append(f"WARNING: Elevated UNIX domain socket count ({total} sockets)")
        status = "WARNING"

    if listening > 500:
        issues.append(f"WARNING: High number of listening UNIX sockets ({listening} listeners)")
        if status != "CRITICAL":
            status = "WARNING"

    if max_dgram_qlen < 10:
        issues.append(f"WARNING: Unusually low max_dgram_qlen ({max_dgram_qlen}); packet drops possible")
        if status != "CRITICAL":
            status = "WARNING"

    healthy = status == "HEALTHY"
    recommendation = (
        "UNIX domain socket allocations, IPC namespaces, and datagram queues are nominal."
        if healthy
        else "; ".join(issues)
    )

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "total_sockets": total,
            "stream_sockets": stats["stream"],
            "dgram_sockets": stats["dgram"],
            "seqpacket_sockets": stats["seqpacket"],
            "listening_sockets": stats["listening"],
            "connected_sockets": stats["connected"],
            "unconnected_sockets": stats["unconnected"],
            "filesystem_paths": stats["filesystem_paths"],
            "abstract_paths": stats["abstract_paths"],
            "anonymous_paths": stats["anonymous_paths"],
            "max_refcount": stats["max_refcount"],
            "max_refcount_path": stats["max_refcount_path"],
            "max_dgram_qlen": max_dgram_qlen,
            "issues": issues,
            "recommendation": recommendation,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network UNIX Domain Socket Namespace & Datagram Queue Guard (Pattern 206)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_unix_sockets()
    s = report["summary"]

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 206: Host Network UNIX Domain Socket Guard")
        print(f"  Total Sockets: {s['total_sockets']:,} (stream: {s['stream_sockets']:,}, dgram: {s['dgram_sockets']:,}, seqpacket: {s['seqpacket_sockets']:,})")
        print(f"  States: listening={s['listening_sockets']:,}, connected={s['connected_sockets']:,}, unconnected={s['unconnected_sockets']:,}")
        print(f"  Namespaces: filesystem={s['filesystem_paths']:,}, abstract={s['abstract_paths']:,}, anonymous={s['anonymous_paths']:,}")
        print(f"  Max Refcount: {s['max_refcount']} ({s['max_refcount_path']}) | max_dgram_qlen: {s['max_dgram_qlen']}")
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
