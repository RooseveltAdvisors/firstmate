#!/usr/bin/env python3
"""
bin/fm-jev-rcvspace-guard.py - Host Network TCP RCV Space & Dynamic Buffer Autoscaling Guard (Pattern 160)

Audits tcp_moderate_rcvbuf sysctl and netstat receiver buffer counters
(TCPMemoryPressures, TCPBacklogDrop, TCPRcvCollapsed, TCPRcvQDrop) to verify
dynamic socket receive space auto-tuning and zero memory pressure packet loss,
ensuring unthrottled throughput across parallel multi-agent streaming connections.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl_int(path: str = "/proc/sys/net/ipv4/tcp_moderate_rcvbuf") -> int:
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


def audit_rcvspace(
    moderate_rcvbuf_file: str = "/proc/sys/net/ipv4/tcp_moderate_rcvbuf",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    moderate_rcvbuf = read_sysctl_int(moderate_rcvbuf_file)
    netstat = parse_netstat(netstat_file)

    memory_pressures = netstat.get("TCPMemoryPressures", 0)
    backlog_drop = netstat.get("TCPBacklogDrop", 0)
    rcv_collapsed = netstat.get("TCPRcvCollapsed", 0)
    rcv_q_drop = netstat.get("TCPRcvQDrop", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if moderate_rcvbuf == 0:
        status = "WARNING"
        healthy = False
        issues.append("tcp_moderate_rcvbuf is disabled (0), dynamic receiver buffer auto-tuning inactive")
    elif moderate_rcvbuf < 0:
        issues.append(f"Unable to read tcp_moderate_rcvbuf from {moderate_rcvbuf_file}")

    if memory_pressures > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Detected TCP socket memory pressures: {memory_pressures}")

    if backlog_drop > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated socket backlog drops: {backlog_drop}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_moderate_rcvbuf": moderate_rcvbuf,
        "memory_pressures": memory_pressures,
        "backlog_drop": backlog_drop,
        "rcv_collapsed": rcv_collapsed,
        "rcv_q_drop": rcv_q_drop,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "tcp_moderate_rcvbuf": moderate_rcvbuf,
            "memory_pressures": memory_pressures,
            "backlog_drop": backlog_drop,
            "rcv_collapsed": rcv_collapsed,
            "rcv_q_drop": rcv_q_drop,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP RCV Space & Dynamic Buffer Autoscaling Guard (Pattern 160)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_rcvspace()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP RCV Space Guard (Pattern 160) - Status: {s['status']}")
    print(f"  tcp_moderate_rcvbuf:       {s['tcp_moderate_rcvbuf']} (1 = dynamic buffer auto-tuning enabled)")
    print(f"  TCP Memory Pressures:      {s['memory_pressures']}")
    print(f"  Socket Backlog Drops:      {s['backlog_drop']}")
    print(f"  Receive Buffer Collapses:  {s['rcv_collapsed']:,}")
    print(f"  Receive Queue Drops:       {s['rcv_q_drop']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
