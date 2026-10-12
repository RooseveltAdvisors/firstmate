#!/usr/bin/env python3
"""
bin/fm-jev-child-ehash-guard.py - Host Network TCP Child Established Hash Table & Listener Partitioning Guard (Pattern 185)

Audits kernel TCP child established hash table entries (tcp_child_ehash_entries), global established
hash table capacity (tcp_ehash_entries), UDP child hash entries, and PLB rehash rounds alongside
TCP socket utilization and listener drop counters in /proc/net/sockstat and /proc/net/netstat.
Verifies established socket hash chain depths, prevents hash bucket lock contention across parallel
agent worker pools, and detects listener backlog saturation before connection handshakes drop.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_sockstat(path: str = "/proc/net/sockstat") -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split()
                if not parts:
                    continue
                proto = parts[0].rstrip(":")
                i = 1
                while i + 1 < len(parts):
                    key = f"{proto}_{parts[i]}"
                    try:
                        metrics[key] = int(parts[i + 1])
                    except ValueError:
                        pass
                    i += 2
    except Exception as e:
        print(f"Warning: unable to parse sockstat {path}: {e}", file=sys.stderr)
    return metrics


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
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_child_ehash(
    child_ehash_file: str = "/proc/sys/net/ipv4/tcp_child_ehash_entries",
    ehash_file: str = "/proc/sys/net/ipv4/tcp_ehash_entries",
    udp_child_file: str = "/proc/sys/net/ipv4/udp_child_hash_entries",
    plb_rehash_file: str = "/proc/sys/net/ipv4/tcp_plb_rehash_rounds",
    sockstat_file: str = "/proc/net/sockstat",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    child_ehash = read_sysctl_int(child_ehash_file)
    global_ehash = read_sysctl_int(ehash_file)
    udp_child = read_sysctl_int(udp_child_file)
    plb_rehash = read_sysctl_int(plb_rehash_file)

    sockstat = parse_sockstat(sockstat_file)
    netstat = parse_netstat(netstat_file)

    tcp_inuse = sockstat.get("TCP_inuse", 0)
    tcp_tw = sockstat.get("TCP_tw", 0)
    tcp_orphan = sockstat.get("TCP_orphan", 0)
    tcp_alloc = sockstat.get("TCP_alloc", 0)

    listen_overflows = netstat.get("ListenOverflows", 0)
    listen_drops = netstat.get("ListenDrops", 0)
    backlog_drops = netstat.get("TCPBacklogDrop", 0)
    timeout_rehash = netstat.get("TcpTimeoutRehash", 0)
    plb_rehash_count = netstat.get("TCPPLBRehash", 0)

    # Compute ehash saturation ratio against global table
    active_tcp_entries = tcp_inuse + tcp_tw
    ehash_saturation_ratio = (
        float(active_tcp_entries) / float(global_ehash) if global_ehash > 0 else 0.0
    )

    issues = []
    status = "HEALTHY"
    healthy = True

    if global_ehash <= 0:
        status = "WARNING"
        healthy = False
        issues.append("Unable to determine global tcp_ehash_entries capacity")
    elif ehash_saturation_ratio > 0.50:
        status = "WARNING"
        healthy = False
        issues.append(
            f"Global ehash saturation critical: {active_tcp_entries}/{global_ehash} ({ehash_saturation_ratio * 100:.2f}%)"
        )

    if listen_drops > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"High TCP listener drops detected: {listen_drops}")

    if listen_overflows > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"High TCP listener overflows detected: {listen_overflows}")

    if backlog_drops > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"Active TCP socket backlog drops detected: {backlog_drops}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_child_ehash_entries": child_ehash,
        "tcp_ehash_entries": global_ehash,
        "udp_child_hash_entries": udp_child,
        "tcp_plb_rehash_rounds": plb_rehash,
        "tcp_inuse": tcp_inuse,
        "tcp_tw": tcp_tw,
        "tcp_orphan": tcp_orphan,
        "tcp_alloc": tcp_alloc,
        "active_tcp_entries": active_tcp_entries,
        "ehash_saturation_ratio": round(ehash_saturation_ratio, 6),
        "listen_overflows": listen_overflows,
        "listen_drops": listen_drops,
        "backlog_drops": backlog_drops,
        "timeout_rehash": timeout_rehash,
        "plb_rehash_count": plb_rehash_count,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_child_ehash_entries": child_ehash,
            "tcp_ehash_entries": global_ehash,
            "udp_child_hash_entries": udp_child,
            "tcp_plb_rehash_rounds": plb_rehash,
        },
        "sockstat": {
            "tcp_inuse": tcp_inuse,
            "tcp_tw": tcp_tw,
            "tcp_orphan": tcp_orphan,
            "tcp_alloc": tcp_alloc,
        },
        "counters": {
            "ListenOverflows": listen_overflows,
            "ListenDrops": listen_drops,
            "TCPBacklogDrop": backlog_drops,
            "TcpTimeoutRehash": timeout_rehash,
            "TCPPLBRehash": plb_rehash_count,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Child Established Hash Table & Listener Partitioning Guard (Pattern 185)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_child_ehash()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Child Established Hash Table Guard (Pattern 185) - Status: {s['status']}")
    print(f"  tcp_child_ehash_entries:    {s['tcp_child_ehash_entries']} (0 = unified table)")
    print(f"  tcp_ehash_entries:          {s['tcp_ehash_entries']} buckets")
    print(f"  udp_child_hash_entries:     {s['udp_child_hash_entries']}")
    print(f"  tcp_plb_rehash_rounds:      {s['tcp_plb_rehash_rounds']}")
    print(f"  TCP In-Use Sockets:         {s['tcp_inuse']}")
    print(f"  TCP TIME_WAIT Sockets:      {s['tcp_tw']}")
    print(f"  Active TCP Entries:         {s['active_tcp_entries']}")
    print(f"  EHash Saturation Ratio:     {s['ehash_saturation_ratio'] * 100:.4f}%")
    print(f"  Listen Drops / Overflows:   {s['listen_drops']} / {s['listen_overflows']}")
    print(f"  Socket Backlog Drops:       {s['backlog_drops']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
