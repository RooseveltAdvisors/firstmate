#!/usr/bin/env python3
"""
bin/fm-jev-keepalive-guard.py - Host Network TCP Keepalive Probing & Dead Peer Reclamation Guard (Pattern 195)

Audits kernel TCP socket keepalive parameters (tcp_keepalive_time, tcp_keepalive_intvl,
tcp_keepalive_probes) and live probe activity from /proc/net/netstat (TCPKeepAlive, TCPTimeouts).
Calculates total dead peer detection latency, prevents zombie connection retention from orphaned
subagents, severed WebSocket subscriptions, or dead VPN tunnels, and ensures prompt socket release.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_netstat_ext(path: str = "/proc/net/netstat") -> Dict[str, int]:
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
            if len(headers) == len(values) and headers[0] == "TcpExt:" and values[0] == "TcpExt:":
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        continue
    except Exception as e:
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_keepalive(
    keepalive_time_file: str = "/proc/sys/net/ipv4/tcp_keepalive_time",
    keepalive_intvl_file: str = "/proc/sys/net/ipv4/tcp_keepalive_intvl",
    keepalive_probes_file: str = "/proc/sys/net/ipv4/tcp_keepalive_probes",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    ka_time = read_sysctl_int(keepalive_time_file)
    ka_intvl = read_sysctl_int(keepalive_intvl_file)
    ka_probes = read_sysctl_int(keepalive_probes_file)

    netstat = parse_netstat_ext(netstat_file)

    probes_sent = netstat.get("TCPKeepAlive", 0)
    timeouts = netstat.get("TCPTimeouts", 0)

    total_detect_sec = (ka_time + (ka_intvl * ka_probes)) if (ka_time > 0 and ka_intvl > 0 and ka_probes > 0) else -1

    issues: List[str] = []
    status = "HEALTHY"

    # Critical conditions
    if ka_probes == 0:
        issues.append("tcp_keepalive_probes is 0: TCP keepalive probes are disabled, dead peer sockets will never abort")
        status = "CRITICAL"
    if ka_time == 0:
        issues.append("tcp_keepalive_time is 0: invalid keepalive idle threshold")
        status = "CRITICAL"
    if total_detect_sec > 14400:
        issues.append(f"Total dead peer detection latency ({total_detect_sec}s / {round(total_detect_sec/3600, 1)}h) exceeds 4 hours: severe zombie socket accumulation risk")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if ka_time > 7200:
            issues.append(f"tcp_keepalive_time ({ka_time}s) exceeds standard 7200s ceiling: slow recovery on disconnected peers")
            status = "WARNING"
        if ka_time > 0 and ka_time < 30:
            issues.append(f"tcp_keepalive_time ({ka_time}s) < 30s: overly aggressive keepalive may flood local network")
            status = "WARNING"
        if ka_probes > 20:
            issues.append(f"tcp_keepalive_probes ({ka_probes}) > 20: excessive probe count delays dead socket teardown")
            status = "WARNING"

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_keepalive_time_sec": ka_time,
        "tcp_keepalive_intvl_sec": ka_intvl,
        "tcp_keepalive_probes": ka_probes,
        "total_dead_peer_detect_sec": total_detect_sec,
        "total_dead_peer_detect_min": round(total_detect_sec / 60.0, 1) if total_detect_sec > 0 else -1,
        "keepalive_probes_sent": probes_sent,
        "tcp_timeouts": timeouts,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_keepalive_time": ka_time,
            "tcp_keepalive_intvl": ka_intvl,
            "tcp_keepalive_probes": ka_probes,
            "total_dead_peer_detect_sec": total_detect_sec,
        },
        "netstat_counters": {
            "TCPKeepAlive": probes_sent,
            "TCPTimeouts": timeouts,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Keepalive Probing & Dead Peer Reclamation Guard (Pattern 195)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_keepalive()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Keepalive Guard (Pattern 195) - Status: {s['status']}")
    print(f"  tcp_keepalive_time:    {s['tcp_keepalive_time_sec']} seconds ({round(s['tcp_keepalive_time_sec']/60, 1)} min)")
    print(f"  tcp_keepalive_intvl:   {s['tcp_keepalive_intvl_sec']} seconds")
    print(f"  tcp_keepalive_probes:  {s['tcp_keepalive_probes']} probes")
    print(f"  Dead Peer Teardown:    {s['total_dead_peer_detect_sec']} seconds ({s['total_dead_peer_detect_min']} min)")
    print(f"  Probes Sent:           {s['keepalive_probes_sent']:,}")
    print(f"  RTO Timeouts:          {s['tcp_timeouts']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
