#!/usr/bin/env python3
"""
bin/fm-jev-rto-bounds-guard.py - Host Network TCP RTO Bounds & Backoff Clamp Guard (Pattern 170 Milestone)

Audits kernel TCP minimum and maximum retransmission timeout boundaries (tcp_rto_min_us, tcp_rto_max_ms)
alongside netstat RTO counters (TCPTimeouts, TCPSpuriousRTOs) to verify RFC 6298 retransmission clamp
margins and prevent both aggressive false timeouts and catastrophic connection stall blackouts.
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


def audit_rto_bounds(
    rto_min_us_file: str = "/proc/sys/net/ipv4/tcp_rto_min_us",
    rto_max_ms_file: str = "/proc/sys/net/ipv4/tcp_rto_max_ms",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    rto_min_us = read_sysctl_int(rto_min_us_file)
    rto_max_ms = read_sysctl_int(rto_max_ms_file)
    netstat = parse_netstat(netstat_file)

    timeouts = netstat.get("TCPTimeouts", 0)
    spurious_rtos = netstat.get("TCPSpuriousRTOs", 0)
    loss_probes = netstat.get("TCPLossProbes", 0)
    loss_probe_recovery = netstat.get("TCPLossProbeRecovery", 0)

    spurious_ratio = (spurious_rtos / (timeouts + 1)) if timeouts > 0 else 0.0

    issues = []
    status = "HEALTHY"
    healthy = True

    if rto_min_us > 0 and rto_min_us < 50000:
        status = "WARNING"
        healthy = False
        issues.append(f"Dangerously low tcp_rto_min_us ({rto_min_us} us), risk of spurious timeout storms")
    elif rto_min_us > 1000000:
        status = "WARNING"
        healthy = False
        issues.append(f"Excessively high tcp_rto_min_us ({rto_min_us} us), sluggish loss recovery")

    if rto_max_ms > 0 and rto_max_ms > 300000:
        status = "WARNING"
        healthy = False
        issues.append(f"Excessively high tcp_rto_max_ms ({rto_max_ms} ms), stalls dead peer detection")

    if spurious_ratio > 0.05:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated spurious RTO ratio: {spurious_ratio:.2%}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_rto_min_us": rto_min_us,
        "tcp_rto_min_ms": round(rto_min_us / 1000, 1) if rto_min_us > 0 else -1,
        "tcp_rto_max_ms": rto_max_ms,
        "tcp_rto_max_sec": round(rto_max_ms / 1000, 1) if rto_max_ms > 0 else -1,
        "timeouts": timeouts,
        "spurious_rtos": spurious_rtos,
        "spurious_rto_pct": round(spurious_ratio * 100, 3),
        "loss_probes": loss_probes,
        "loss_probe_recovery": loss_probe_recovery,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_rto_min_us": rto_min_us,
            "tcp_rto_max_ms": rto_max_ms,
        },
        "counters": {
            "TCPTimeouts": timeouts,
            "TCPSpuriousRTOs": spurious_rtos,
            "TCPLossProbes": loss_probes,
            "TCPLossProbeRecovery": loss_probe_recovery,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP RTO Bounds & Backoff Clamp Guard (Pattern 170 Milestone)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_rto_bounds()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP RTO Bounds Guard (Pattern 170 Milestone) - Status: {s['status']}")
    print(f"  tcp_rto_min_us:            {s['tcp_rto_min_us']:,} us ({s['tcp_rto_min_ms']} ms floor)")
    print(f"  tcp_rto_max_ms:            {s['tcp_rto_max_ms']:,} ms ({s['tcp_rto_max_sec']} s ceiling)")
    print(f"  Total Timeouts:            {s['timeouts']:,}")
    print(f"  Spurious RTOs:             {s['spurious_rtos']:,} ({s['spurious_rto_pct']}%)")
    print(f"  Tail Loss Probes:          {s['loss_probes']:,} ({s['loss_probe_recovery']:,} recovered)")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
