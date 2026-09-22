#!/usr/bin/env python3
"""
bin/fm-jev-dsack-guard.py - Host Network TCP SACK Renumbering & D-SACK Sequence Space Guard (Pattern 156)

Audits tcp_dsack sysctl and /proc/net/netstat Duplicate SACK counters
(TCPDSACKUndo, TCPDSACKOldSent, TCPDSACKOfoSent, TCPDSACKRecv, TCPDSACKOfoRecv,
TCPDSACKIgnoredDubious) to verify RFC 2883 D-SACK operation, preventing spurious
retransmission stalls and enabling accurate congestion window (CWND) recovery
across high-throughput agent token streams.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl(path: str = "/proc/sys/net/ipv4/tcp_dsack") -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_netstat(path: str = "/proc/net/netstat") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(0, len(lines), 2):
            if i + 1 >= len(lines):
                break
            headers = lines[i].split()
            values = lines[i + 1].split()
            if len(headers) == len(values) and headers[0] == values[0]:
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def audit_dsack(
    sysctl_file: str = "/proc/sys/net/ipv4/tcp_dsack",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    dsack_enabled = read_sysctl(sysctl_file)
    netstat = parse_netstat(netstat_file)

    dsack_undo = netstat.get("TCPDSACKUndo", 0)
    old_sent = netstat.get("TCPDSACKOldSent", 0)
    ofo_sent = netstat.get("TCPDSACKOfoSent", 0)
    dsack_recv = netstat.get("TCPDSACKRecv", 0)
    ofo_recv = netstat.get("TCPDSACKOfoRecv", 0)
    ignored_dubious = netstat.get("TCPDSACKIgnoredDubious", 0)
    ignored_old = netstat.get("TCPDSACKIgnoredOld", 0)
    ignored_no_undo = netstat.get("TCPDSACKIgnoredNoUndo", 0)

    total_sent = old_sent + ofo_sent
    total_recv = dsack_recv + ofo_recv

    dubious_ratio_pct = 0.0
    if total_recv > 0:
        dubious_ratio_pct = round((ignored_dubious / total_recv) * 100.0, 3)

    issues = []
    status = "HEALTHY"
    healthy = True

    if dsack_enabled == 0:
        status = "WARNING"
        healthy = False
        issues.append("tcp_dsack is disabled (0), duplicate SACK loss recovery inactive")
    elif dsack_enabled < 0:
        issues.append(f"Unable to read tcp_dsack from {sysctl_file}")

    if total_recv > 1000 and dubious_ratio_pct > 20.0:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated dubious D-SACK ratio: {dubious_ratio_pct}% (> 20.0%)")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_dsack": dsack_enabled,
        "dsack_undo": dsack_undo,
        "total_sent": total_sent,
        "old_sent": old_sent,
        "ofo_sent": ofo_sent,
        "total_recv": total_recv,
        "dsack_recv": dsack_recv,
        "ofo_recv": ofo_recv,
        "ignored_dubious": ignored_dubious,
        "dubious_ratio_pct": dubious_ratio_pct,
        "ignored_old": ignored_old,
        "ignored_no_undo": ignored_no_undo,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "tcp_dsack": dsack_enabled,
            "dsack_undo": dsack_undo,
            "old_sent": old_sent,
            "ofo_sent": ofo_sent,
            "dsack_recv": dsack_recv,
            "ofo_recv": ofo_recv,
            "ignored_dubious": ignored_dubious,
            "ignored_old": ignored_old,
            "ignored_no_undo": ignored_no_undo,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP SACK Renumbering & D-SACK Sequence Space Guard (Pattern 156)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_dsack()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP D-SACK Guard (Pattern 156) - Status: {s['status']}")
    print(f"  tcp_dsack Sysctl:            {s['tcp_dsack']} (1 = RFC 2883 D-SACK active)")
    print(f"  Total D-SACKs Sent:          {s['total_sent']:,} (Old: {s['old_sent']:,}, OFO: {s['ofo_sent']:,})")
    print(f"  Total D-SACKs Received:      {s['total_recv']:,} (Old: {s['dsack_recv']:,}, OFO: {s['ofo_recv']:,})")
    print(f"  D-SACK CWND Undos:           {s['dsack_undo']:,}")
    print(f"  Dubious D-SACK Blocks:       {s['ignored_dubious']:,} ({s['dubious_ratio_pct']}%)")
    print(f"  Ignored (No Undo/Old):       {s['ignored_no_undo']:,} / {s['ignored_old']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
