#!/usr/bin/env python3
"""
bin/fm-jev-mtu-probe-guard.py - Host Network TCP MTU Probing & Black Hole Detection Guard (Pattern 158)

Audits tcp_mtu_probing, tcp_base_mss, tcp_mtu_probe_floor sysctls and
netstat PLPMTUD counters (TCPMTUPFail, TCPMTUPSuccess) to verify RFC 4821
Packetization Layer Path MTU Discovery resilience, preventing silent ICMP-blocked
black hole packet loss across multi-agent egress tunnels.
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


def audit_mtu_probe(
    mtu_probing_file: str = "/proc/sys/net/ipv4/tcp_mtu_probing",
    base_mss_file: str = "/proc/sys/net/ipv4/tcp_base_mss",
    probe_floor_file: str = "/proc/sys/net/ipv4/tcp_mtu_probe_floor",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    mtu_probing = read_sysctl_int(mtu_probing_file)
    base_mss = read_sysctl_int(base_mss_file)
    probe_floor = read_sysctl_int(probe_floor_file)
    netstat = parse_netstat(netstat_file)

    mtup_fail = netstat.get("TCPMTUPFail", 0)
    mtup_success = netstat.get("TCPMTUPSuccess", 0)

    total_probes = mtup_fail + mtup_success
    fail_ratio_pct = 0.0
    if total_probes > 0:
        fail_ratio_pct = round((mtup_fail / total_probes) * 100.0, 3)

    issues = []
    status = "HEALTHY"
    healthy = True

    if base_mss > 0 and base_mss < 512:
        status = "WARNING"
        healthy = False
        issues.append(f"tcp_base_mss is abnormally low: {base_mss} (< 512 bytes)")

    if mtup_fail > 50 and fail_ratio_pct > 50.0:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated MTU probing failure ratio: {fail_ratio_pct}% (> 50%)")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_mtu_probing": mtu_probing,
        "tcp_base_mss": base_mss,
        "tcp_mtu_probe_floor": probe_floor,
        "mtup_fail": mtup_fail,
        "mtup_success": mtup_success,
        "total_probes": total_probes,
        "fail_ratio_pct": fail_ratio_pct,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "tcp_mtu_probing": mtu_probing,
            "tcp_base_mss": base_mss,
            "tcp_mtu_probe_floor": probe_floor,
            "mtup_fail": mtup_fail,
            "mtup_success": mtup_success,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP MTU Probing & Black Hole Detection Guard (Pattern 158)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_mtu_probe()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP MTU Probing Guard (Pattern 158) - Status: {s['status']}")
    print(f"  tcp_mtu_probing:           {s['tcp_mtu_probing']} (0=disabled, 1=on black hole, 2=always)")
    print(f"  tcp_base_mss:              {s['tcp_base_mss']} bytes")
    print(f"  tcp_mtu_probe_floor:       {s['tcp_mtu_probe_floor']} bytes")
    print(f"  MTU Probes Successful:     {s['mtup_success']:,}")
    print(f"  MTU Probes Failed:         {s['mtup_fail']:,} ({s['fail_ratio_pct']}%)")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
