#!/usr/bin/env python3
"""
fm-jev-unix-socket-guard.py - Jev Multi-Agent Unix Domain Socket & Abstract Namespace Leak Guard (Pattern 74)

Audits Linux Unix domain sockets (/proc/net/unix), abstract namespace bindings, and filesystem socket nodes.
Detects unlinked socket file descriptors, excessive socket allocations from crashed worker agents or language
servers, and orphaned socket nodes.

Invariants:
  - Read-only diagnostics. Non-destructive.
  - Fail-open: graceful fallback when /proc/net/unix is restricted or unavailable.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import stat
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

DEFAULT_WARN_SOCKET_COUNT = 2500
DEFAULT_CRIT_SOCKET_COUNT = 10000
DEFAULT_WARN_UNLINKED_COUNT = 50
DEFAULT_CRIT_UNLINKED_COUNT = 200

PROC_NET_UNIX_PATH = "/proc/net/unix"

# Socket types mapping in /proc/net/unix
SOCKET_TYPES = {
    1: "STREAM",
    2: "DGRAM",
    5: "SEQPACKET",
}

# Socket states mapping in /proc/net/unix
SOCKET_STATES = {
    1: "UNCONNECTED",  # or LISTEN for stream sockets
    2: "CONNECTING",
    3: "CONNECTED",
    4: "DISCONNECTING",
}


def parse_proc_net_unix(
    proc_unix_path: str = PROC_NET_UNIX_PATH,
    check_fs: bool = True,
) -> List[Dict[str, Any]]:
    """
    Parses /proc/net/unix.
    Header: Num RefCount Protocol Flags Type St Inode Path
    """
    sockets: List[Dict[str, Any]] = []
    if not os.path.exists(proc_unix_path):
        return sockets

    try:
        with open(proc_unix_path, "r") as f:
            lines = f.readlines()
        if len(lines) <= 1:
            return sockets

        for line in lines[1:]:
            parts = line.strip().split(maxsplit=7)
            if len(parts) < 7:
                continue

            try:
                num = parts[0].rstrip(":")
                ref_count = int(parts[1], 16)
                protocol = int(parts[2], 16)
                flags = int(parts[3], 16)
                type_code = int(parts[4], 16)
                st_code = int(parts[5], 16)
                inode = int(parts[6])
                path = parts[7] if len(parts) >= 8 else ""

                type_name = SOCKET_TYPES.get(type_code, f"UNKNOWN_{type_code}")
                state_name = SOCKET_STATES.get(st_code, f"UNKNOWN_{st_code}")

                # Namespace classification
                is_abstract = False
                is_filesystem = False
                is_unnamed = False
                path_exists = None

                if not path:
                    is_unnamed = True
                elif path.startswith("@") or path.startswith("\0"):
                    is_abstract = True
                elif path.startswith("/"):
                    is_filesystem = True
                    if check_fs:
                        try:
                            path_exists = os.path.exists(path)
                        except Exception:
                            path_exists = False
                else:
                    # Non-standard or relative
                    is_filesystem = True
                    if check_fs:
                        try:
                            path_exists = os.path.exists(path)
                        except Exception:
                            path_exists = False

                sockets.append({
                    "num": num,
                    "ref_count": ref_count,
                    "protocol": protocol,
                    "flags": flags,
                    "type": type_name,
                    "state": state_name,
                    "inode": inode,
                    "path": path,
                    "is_abstract": is_abstract,
                    "is_filesystem": is_filesystem,
                    "is_unnamed": is_unnamed,
                    "path_exists": path_exists,
                })
            except (ValueError, IndexError):
                continue
    except Exception:
        pass

    return sockets


def scan_top_level_socket_files(dirs: List[str]) -> List[Dict[str, Any]]:
    """Fast bounded non-recursive scan of directories for socket files."""
    found_sockets: List[Dict[str, Any]] = []
    for d in dirs:
        if not os.path.isdir(d):
            continue
        try:
            with os.scandir(d) as it:
                for entry in it:
                    try:
                        if entry.is_socket(follow_symlinks=False):
                            st = entry.stat(follow_symlinks=False)
                            found_sockets.append({
                                "path": entry.path,
                                "inode": st.st_ino,
                                "size": st.st_size,
                            })
                    except Exception:
                        pass
        except Exception:
            pass
    return found_sockets


def audit_unix_sockets(
    proc_unix_path: str = PROC_NET_UNIX_PATH,
    scan_dirs: Optional[List[str]] = None,
    check_fs: bool = True,
    warn_total: int = DEFAULT_WARN_SOCKET_COUNT,
    crit_total: int = DEFAULT_CRIT_SOCKET_COUNT,
    warn_unlinked: int = DEFAULT_WARN_UNLINKED_COUNT,
    crit_unlinked: int = DEFAULT_CRIT_UNLINKED_COUNT,
) -> Dict[str, Any]:
    """Audits Unix domain sockets and determines health status."""
    sockets = parse_proc_net_unix(proc_unix_path, check_fs=check_fs)

    total_count = len(sockets)
    stream_count = sum(1 for s in sockets if s["type"] == "STREAM")
    dgram_count = sum(1 for s in sockets if s["type"] == "DGRAM")
    seqpacket_count = sum(1 for s in sockets if s["type"] == "SEQPACKET")

    listening_count = sum(1 for s in sockets if s["state"] == "UNCONNECTED" and s["path"])
    connected_count = sum(1 for s in sockets if s["state"] == "CONNECTED")

    abstract_count = sum(1 for s in sockets if s["is_abstract"])
    filesystem_count = sum(1 for s in sockets if s["is_filesystem"])
    unnamed_count = sum(1 for s in sockets if s["is_unnamed"])

    # Unlinked sockets: filesystem sockets whose file path no longer exists on disk
    unlinked_sockets = [s for s in sockets if s["is_filesystem"] and s["path_exists"] is False]
    unlinked_count = len(unlinked_sockets)

    # Scan for orphaned socket files on disk
    scanned_socket_files: List[Dict[str, Any]] = []
    if scan_dirs:
        scanned_socket_files = scan_top_level_socket_files(scan_dirs)

    active_inodes: Set[int] = {s["inode"] for s in sockets if s["inode"] > 0}
    dead_socket_files = [sf for sf in scanned_socket_files if sf["inode"] not in active_inodes]

    # Health assessment
    issues: List[str] = []
    status = "HEALTHY"

    if total_count >= crit_total or unlinked_count >= crit_unlinked:
        status = "CRITICAL"
        if total_count >= crit_total:
            issues.append(f"Unix socket count critical: {total_count} >= {crit_total}")
        if unlinked_count >= crit_unlinked:
            issues.append(f"Unlinked socket count critical: {unlinked_count} >= {crit_unlinked}")
    elif total_count >= warn_total or unlinked_count >= warn_unlinked:
        status = "WARNING"
        if total_count >= warn_total:
            issues.append(f"Unix socket count elevated: {total_count} >= {warn_total}")
        if unlinked_count >= warn_unlinked:
            issues.append(f"Unlinked socket count elevated: {unlinked_count} >= {warn_unlinked}")

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_unix_sockets": total_count,
            "stream_sockets": stream_count,
            "dgram_sockets": dgram_count,
            "seqpacket_sockets": seqpacket_count,
            "listening_sockets": listening_count,
            "connected_sockets": connected_count,
            "abstract_sockets": abstract_count,
            "filesystem_sockets": filesystem_count,
            "unnamed_sockets": unnamed_count,
            "unlinked_sockets": unlinked_count,
            "dead_socket_files": len(dead_socket_files),
            "issues": issues,
        },
        "unlinked_samples": [s["path"] for s in unlinked_sockets[:10]],
        "top_listening_sockets": [s["path"] for s in sockets if s["state"] == "UNCONNECTED" and s["path"]][:15],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Unix Domain Socket & Abstract Namespace Leak Guard (Pattern 74)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--warn-total", type=int, default=DEFAULT_WARN_SOCKET_COUNT, help=f"Warning total socket count (default {DEFAULT_WARN_SOCKET_COUNT})")
    parser.add_argument("--crit-total", type=int, default=DEFAULT_CRIT_SOCKET_COUNT, help=f"Critical total socket count (default {DEFAULT_CRIT_SOCKET_COUNT})")
    parser.add_argument("--warn-unlinked", type=int, default=DEFAULT_WARN_UNLINKED_COUNT, help=f"Warning unlinked socket count (default {DEFAULT_WARN_UNLINKED_COUNT})")
    parser.add_argument("--crit-unlinked", type=int, default=DEFAULT_CRIT_UNLINKED_COUNT, help=f"Critical unlinked socket count (default {DEFAULT_CRIT_UNLINKED_COUNT})")
    parser.add_argument("--proc-unix", type=str, default=PROC_NET_UNIX_PATH, help="Path to /proc/net/unix")
    parser.add_argument("--scan-dirs", type=str, default="", help="Comma-separated directories to scan for socket files")
    parser.add_argument("--no-check-fs", action="store_true", help="Disable filesystem path existence checks")

    args = parser.parse_args()
    scan_dir_list = [d.strip() for d in args.scan_dirs.split(",") if d.strip()] if args.scan_dirs else ["/tmp"]

    result = audit_unix_sockets(
        proc_unix_path=args.proc_unix,
        scan_dirs=scan_dir_list,
        check_fs=not args.no_check_fs,
        warn_total=args.warn_total,
        crit_total=args.crit_total,
        warn_unlinked=args.warn_unlinked,
        crit_unlinked=args.crit_unlinked,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else ("\033[31m" if summary["status"] == "CRITICAL" else "\033[33m")
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Unix Domain Socket & Abstract Namespace Guard (Pattern 74)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Total Unix Sockets:     {summary['total_unix_sockets']}")
    print(f"   - Stream:             {summary['stream_sockets']}")
    print(f"   - Datagram:           {summary['dgram_sockets']}")
    print(f"   - Seqpacket:          {summary['seqpacket_sockets']}")
    print(f" State Breakdown:")
    print(f"   - Listening/Unconn:   {summary['listening_sockets']}")
    print(f"   - Connected:          {summary['connected_sockets']}")
    print(f" Namespace Breakdown:")
    print(f"   - Filesystem Paths:   {summary['filesystem_sockets']} ({summary['unlinked_sockets']} unlinked)")
    print(f"   - Abstract Namespace: {summary['abstract_sockets']}")
    print(f"   - Unnamed Sockets:    {summary['unnamed_sockets']}")

    if summary["issues"]:
        print("\nActive Issues:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nNo Unix domain socket leaks or descriptor exhaustion detected.")
    print("================================================================================")


if __name__ == "__main__":
    main()
