#!/usr/bin/env python3
"""
bin/fm-jev-pmtu-probe-guard.py - Host Network TCP Path MTU Discovery Probe Interval & Blackhole Recovery Guard (Pattern 175)

Audits kernel Packetization Layer Path MTU Discovery (PLPMTUD RFC 4821) configuration
(tcp_mtu_probing, tcp_probe_interval, tcp_probe_threshold, tcp_base_mss, tcp_mtu_probe_floor)
alongside netstat counters (TCPMTUPFail, TCPMTUPSuccess) to verify path MTU recovery and
prevent ICMP blackholing across multi-agent egress tunnels.
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


def audit_pmtu_probe(
    mtu_probing_file: str = "/proc/sys/net/ipv4/tcp_mtu_probing",
    base_mss_file: str = "/proc/sys/net/ipv4/tcp_base_mss",
    probe_floor_file: str = "/proc/sys/net/ipv4/tcp_mtu_probe_floor",
    probe_interval_file: str = "/proc/sys/net/ipv4/tcp_probe_interval",
    probe_threshold_file: str = "/proc/sys/net/ipv4/tcp_probe_threshold",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    mtu_probing = read_sysctl_int(mtu_probing_file)
    base_mss = read_sysctl_int(base_mss_file)
    probe_floor = read_sysctl_int(probe_floor_file)
    probe_interval = read_sysctl_int(probe_interval_file)
    probe_threshold = read_sysctl_int(probe_threshold_file)
    netstat = parse_netstat(netstat_file)

    mtu_fail = netstat.get("TCPMTUPFail", 0)
    mtu_success = netstat.get("TCPMTUPSuccess", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    # Health criteria:
    # If probe failures are elevated without successes
    if mtu_fail > 10 and mtu_fail > mtu_success * 2:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated Path MTU probe failures (fail={mtu_fail}, success={mtu_success})")

    if probe_floor > 0 and probe_floor > base_mss:
        status = "WARNING"
        healthy = False
        issues.append(f"Invalid MTU probe floor ({probe_floor}) greater than base MSS ({base_mss})")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_mtu_probing": mtu_probing,
        "tcp_base_mss": base_mss,
        "tcp_mtu_probe_floor": probe_floor,
        "tcp_probe_interval_sec": probe_interval,
        "tcp_probe_threshold": probe_threshold,
        "mtup_fail": mtu_fail,
        "mtup_success": mtu_success,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_mtu_probing": mtu_probing,
            "tcp_base_mss": base_mss,
            "tcp_mtu_probe_floor": probe_floor,
            "tcp_probe_interval": probe_interval,
            "tcp_probe_threshold": probe_threshold,
        },
        "counters": {
            "TCPMTUPFail": mtu_fail,
            "TCPMTUPSuccess": mtu_success,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Path MTU Discovery Probe Interval & Blackhole Recovery Guard (Pattern 175)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_pmtu_probe()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Path MTU Discovery Probe Guard (Pattern 175) - Status: {s['status']}")
    print(f"  tcp_mtu_probing:              {s['tcp_mtu_probing']} (0 = disabled, 1 = on blackhole, 2 = always)")
    print(f"  tcp_base_mss:                 {s['tcp_base_mss']} bytes")
    print(f"  tcp_mtu_probe_floor:          {s['tcp_mtu_probe_floor']} bytes")
    print(f"  tcp_probe_interval:           {s['tcp_probe_interval_sec']} s (nominal: 600s)")
    print(f"  tcp_probe_threshold:          {s['tcp_probe_threshold']} packets (nominal: 8)")
    print(f"  MTU Probe Successes:          {s['mtup_success']}")
    print(f"  MTU Probe Failures:           {s['mtup_fail']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
