#!/usr/bin/env python3
"""
bin/fm-jev-plpmtud-guard.py - Host Network TCP MTU Probing (PLPMTUD) & Blackhole Guard (Pattern 198)

Audits kernel Packetization Layer Path MTU Discovery (PLPMTUD) configuration (tcp_mtu_probing,
tcp_base_mss, tcp_mtu_probe_floor, tcp_probe_interval, tcp_probe_threshold) and MTU probing
counters from /proc/net/netstat (TCPMTUPFail, TCPMTUPSuccess, TCPTimeouts).
Ensures RFC 4821 path MTU probing avoids ICMP "Fragmentation Needed" filtering blackholes across
cloud VPCs, VPN tunnels, and container overlay networks without introducing spurious probe loss.
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


def audit_plpmtud(
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

    netstat = parse_netstat_ext(netstat_file)

    mtup_fail = netstat.get("TCPMTUPFail", 0)
    mtup_success = netstat.get("TCPMTUPSuccess", 0)
    timeouts = netstat.get("TCPTimeouts", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # Critical conditions
    if base_mss < 64 or base_mss > 9000:
        issues.append(f"tcp_base_mss ({base_mss}) is out of safe range [64, 9000]")
        status = "CRITICAL"
    if mtup_fail > 1000:
        issues.append(f"TCPMTUPFail ({mtup_fail}) > 1000: persistent MTU probe loss indicating middlebox blackholes")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if probe_interval > 0 and probe_interval < 60:
            issues.append(f"tcp_probe_interval ({probe_interval}s) < 60s: probe interval may cause spurious probe overhead")
            status = "WARNING"
        if probe_floor > 0 and probe_floor < 48:
            issues.append(f"tcp_mtu_probe_floor ({probe_floor}) < 48 bytes: floor is smaller than minimum IPv4/TCP header")
            status = "WARNING"

    probing_desc = {
        0: "disabled (standard ICMP PMTUD)",
        1: "opportunistic on blackhole detection",
        2: "always enabled (proactive PLPMTUD)",
    }.get(mtu_probing, f"unknown ({mtu_probing})")

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_mtu_probing": mtu_probing,
        "tcp_mtu_probing_mode": probing_desc,
        "tcp_base_mss": base_mss,
        "tcp_mtu_probe_floor": probe_floor,
        "tcp_probe_interval_sec": probe_interval,
        "tcp_probe_threshold": probe_threshold,
        "mtu_probes_failed": mtup_fail,
        "mtu_probes_successful": mtup_success,
        "tcp_timeouts": timeouts,
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
        "netstat_counters": {
            "TCPMTUPFail": mtup_fail,
            "TCPMTUPSuccess": mtup_success,
            "TCPTimeouts": timeouts,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP MTU Probing (PLPMTUD) & Blackhole Guard (Pattern 198)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_plpmtud()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP MTU Probing Guard (Pattern 198) - Status: {s['status']}")
    print(f"  tcp_mtu_probing:       {s['tcp_mtu_probing']} ({s['tcp_mtu_probing_mode']})")
    print(f"  tcp_base_mss:          {s['tcp_base_mss']} bytes")
    print(f"  tcp_mtu_probe_floor:   {s['tcp_mtu_probe_floor']} bytes")
    print(f"  tcp_probe_interval:    {s['tcp_probe_interval_sec']} seconds")
    print(f"  tcp_probe_threshold:   {s['tcp_probe_threshold']} timeouts")
    print(f"  MTU Probes Failed:     {s['mtu_probes_failed']:,}")
    print(f"  MTU Probes Succeeded:  {s['mtu_probes_successful']:,}")
    print(f"  Total RTO Timeouts:    {s['tcp_timeouts']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
