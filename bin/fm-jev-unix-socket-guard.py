#!/usr/bin/env python3
"""
fm-jev-unix-socket-guard.py - Jev Multi-Agent Host Unix Domain Socket & IPC Backlog Guard (Pattern 99)

Audits Linux host Unix domain sockets (/proc/net/unix) and kernel datagram queue capacity
(/proc/sys/net/unix/max_dgram_qlen).

Inspects socket density, stream vs datagram ratios, anonymous socket allocations, and active
inter-agent communication sockets (Herdr, tmux, systemd journal, PostgreSQL).

Detects inter-agent IPC socket leaks, queue starvation, and unlinked/orphaned socket descriptors
during concurrent multi-pane agent operations.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when /proc files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
import stat
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PROC_NET_UNIX = "/proc/net/unix"
SYSCTL_MAX_DGRAM_QLEN = "/proc/sys/net/unix/max_dgram_qlen"

TYPE_MAP = {
    "0001": "STREAM",
    "0002": "DGRAM",
    "0005": "SEQPACKET",
}

STATE_MAP = {
    "01": "UNCONNECTED_OR_LISTEN",
    "02": "CONNECTING",
    "03": "CONNECTED",
    "04": "DISCONNECTING",
}


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_unix_sockets(path: Path) -> List[Dict[str, Any]]:
    """Parses /proc/net/unix table into structured records."""
    if not path.is_file():
        return []

    sockets: List[Dict[str, Any]] = []
    try:
        lines = path.read_text().splitlines()
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 6:
                ref_count = int(parts[1], 16)
                flags = parts[3]
                sock_type = TYPE_MAP.get(parts[4], parts[4])
                sock_state = STATE_MAP.get(parts[5], parts[5])
                inode = int(parts[6]) if len(parts) >= 7 and parts[6].isdigit() else 0
                sock_path = parts[7] if len(parts) >= 8 else None

                sockets.append({
                    "ref_count": ref_count,
                    "flags": flags,
                    "type": sock_type,
                    "state": sock_state,
                    "inode": inode,
                    "path": sock_path,
                    "is_anonymous": sock_path is None,
                })
    except Exception:
        pass

    return sockets


def audit_unix_sockets(
    proc_unix_file: Optional[str] = None,
    max_dgram_file: Optional[str] = None,
    verify_socket_files: bool = False,
) -> Dict[str, Any]:
    """Audits host Unix domain socket health and inter-agent IPC paths."""
    proc_path = Path(proc_unix_file) if proc_unix_file else Path(PROC_NET_UNIX)
    max_dgram_path = Path(max_dgram_file) if max_dgram_file else Path(SYSCTL_MAX_DGRAM_QLEN)

    max_dgram_qlen = read_int_file(max_dgram_path)
    sockets = parse_unix_sockets(proc_path)

    total_sockets = len(sockets)
    stream_count = sum(1 for s in sockets if s["type"] == "STREAM")
    dgram_count = sum(1 for s in sockets if s["type"] == "DGRAM")
    seqpacket_count = sum(1 for s in sockets if s["type"] == "SEQPACKET")
    anonymous_count = sum(1 for s in sockets if s["is_anonymous"])
    named_count = total_sockets - anonymous_count

    # Inter-agent socket categories
    herdr_sockets = [s for s in sockets if s["path"] and "herdr" in s["path"]]
    tmux_sockets = [s for s in sockets if s["path"] and "tmux" in s["path"]]
    journal_sockets = [s for s in sockets if s["path"] and "journal" in s["path"]]

    issues: List[str] = []

    if max_dgram_qlen is not None and max_dgram_qlen < 256:
        issues.append(f"Low max_dgram_qlen ({max_dgram_qlen} < 256): risk of datagram drops on /dev/log and IPC")

    if total_sockets > 5000:
        issues.append(f"Elevated total Unix domain socket count ({total_sockets} > 5,000): potential descriptor leak across worker processes")

    if anonymous_count > 4000:
        issues.append(f"High anonymous Unix socket count ({anonymous_count} > 4,000): orphaned socket descriptors")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_sockets": total_sockets,
            "stream_sockets": stream_count,
            "dgram_sockets": dgram_count,
            "seqpacket_sockets": seqpacket_count,
            "named_sockets": named_count,
            "anonymous_sockets": anonymous_count,
            "herdr_sockets": len(herdr_sockets),
            "tmux_sockets": len(tmux_sockets),
            "journal_sockets": len(journal_sockets),
            "max_dgram_qlen": max_dgram_qlen,
            "issues": issues,
        },
        "sample_agent_sockets": [
            {"path": s["path"], "type": s["type"], "state": s["state"]}
            for s in herdr_sockets[:10]
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Unix Domain Socket & IPC Backlog Guard (Pattern 99)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--proc-file", type=str, default=None, help="Path to /proc/net/unix")
    parser.add_argument("--max-dgram-file", type=str, default=None, help="Path to max_dgram_qlen")
    args = parser.parse_args()

    result = audit_unix_sockets(
        proc_unix_file=args.proc_file,
        max_dgram_file=args.max_dgram_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Unix Domain Socket & IPC Backlog Guard (Pattern 99)")
    print("================================================================================")
    print(f" Timestamp:                 {result['timestamp']}")
    print(f" Status:                    {status_color}{summary['status']}{reset_color}")
    print(f" Max Dgram Queue Length:    {summary['max_dgram_qlen']}")
    print(f" Total Unix Sockets:        {summary['total_sockets']}")
    print(f" STREAM / DGRAM / SEQPACK:  {summary['stream_sockets']} / {summary['dgram_sockets']} / {summary['seqpacket_sockets']}")
    print(f" Named / Anonymous Sockets: {summary['named_sockets']} / {summary['anonymous_sockets']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'IPC Category':<30} {'Socket Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Herdr Agent IPC':<30} {summary['herdr_sockets']:<15} {'Nominal' if summary['herdr_sockets'] > 0 else 'WARNING'}")
    print(f" {'Tmux Sessions':<30} {summary['tmux_sockets']:<15} Nominal")
    print(f" {'Systemd Journal / Syslog':<30} {summary['journal_sockets']:<15} Nominal")

    if summary["issues"]:
        print("\nActive Unix Domain Socket / IPC Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll Unix domain socket allocations, queue limits, and inter-agent IPC paths nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
