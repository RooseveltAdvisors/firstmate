#!/usr/bin/env python3
"""
bin/fm-jev-ecn-guard.py - Host Network TCP Explicit Congestion Notification (ECN) Negotiation & CE Mark Guard (Pattern 191)

Audits kernel TCP Explicit Congestion Notification configuration (tcp_ecn, tcp_ecn_fallback)
and real-time transport telemetry from /proc/net/netstat (TCPDelivered, TCPDeliveredCE,
TCPHystartTrainDetect, TCPHystartDelayDetect, TCPHystartTrainCwnd, TCPHystartDelayCwnd).
Ensures RFC 3168 ECN negotiation across cloud and edge routers, prevents blackhole connection stalls
from hostile middleboxes via fallback enforcement, and detects bufferbloat congestion feedback marks.
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


def audit_ecn(
    tcp_ecn_file: str = "/proc/sys/net/ipv4/tcp_ecn",
    tcp_ecn_fallback_file: str = "/proc/sys/net/ipv4/tcp_ecn_fallback",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    tcp_ecn = read_sysctl_int(tcp_ecn_file)
    tcp_ecn_fallback = read_sysctl_int(tcp_ecn_fallback_file)

    netstat = parse_netstat_ext(netstat_file)

    delivered = netstat.get("TCPDelivered", 0)
    delivered_ce = netstat.get("TCPDeliveredCE", 0)
    ce_ratio = round((delivered_ce / delivered * 100.0), 6) if delivered > 0 else 0.0

    hystart_train = netstat.get("TCPHystartTrainDetect", 0)
    hystart_delay = netstat.get("TCPHystartDelayDetect", 0)
    hystart_train_cwnd = netstat.get("TCPHystartTrainCwnd", 0)
    hystart_delay_cwnd = netstat.get("TCPHystartDelayCwnd", 0)

    issues: List[str] = []
    status = "HEALTHY"

    # Critical check: ECN enabled client-side but fallback disabled -> middlebox blackholes
    if tcp_ecn == 1 and tcp_ecn_fallback == 0:
        issues.append("tcp_ecn is 1 (full client/server) but tcp_ecn_fallback is 0: severe risk of blackhole connection hangs on hostile middleboxes")
        status = "CRITICAL"

    # Warning checks
    if status != "CRITICAL":
        if tcp_ecn == 0:
            issues.append("tcp_ecn is 0: Explicit Congestion Notification is completely disabled; routers must drop packets to signal congestion")
            status = "WARNING"
        if ce_ratio >= 5.0:
            issues.append(f"Congestion Experienced mark ratio ({ce_ratio}%) exceeds 5.0% warning threshold: intermediate routers suffering severe bufferbloat")
            status = "WARNING"

    ecn_mode_desc = {
        0: "disabled",
        1: "enabled (client and server)",
        2: "server-only (respond to incoming requests)",
    }.get(tcp_ecn, f"unknown ({tcp_ecn})")

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_ecn": tcp_ecn,
        "tcp_ecn_mode": ecn_mode_desc,
        "tcp_ecn_fallback": tcp_ecn_fallback,
        "delivered_segments": delivered,
        "delivered_ce_marks": delivered_ce,
        "ce_ratio_pct": ce_ratio,
        "hystart_train_detect": hystart_train,
        "hystart_delay_detect": hystart_delay,
        "hystart_train_cwnd": hystart_train_cwnd,
        "hystart_delay_cwnd": hystart_delay_cwnd,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_ecn": tcp_ecn,
            "tcp_ecn_fallback": tcp_ecn_fallback,
        },
        "netstat_counters": {
            "TCPDelivered": delivered,
            "TCPDeliveredCE": delivered_ce,
            "TCPHystartTrainDetect": hystart_train,
            "TCPHystartDelayDetect": hystart_delay,
            "TCPHystartTrainCwnd": hystart_train_cwnd,
            "TCPHystartDelayCwnd": hystart_delay_cwnd,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Explicit Congestion Notification (ECN) Negotiation & CE Mark Guard (Pattern 191)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_ecn()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP ECN & CE Mark Guard (Pattern 191) - Status: {s['status']}")
    print(f"  tcp_ecn:               {s['tcp_ecn']} ({s['tcp_ecn_mode']})")
    print(f"  tcp_ecn_fallback:      {s['tcp_ecn_fallback']} ({'fallback enabled' if s['tcp_ecn_fallback'] == 1 else 'disabled'})")
    print(f"  Delivered Segments:    {s['delivered_segments']:,}")
    print(f"  CE Marked Segments:    {s['delivered_ce_marks']:,} ({s['ce_ratio_pct']}%)")
    print(f"  HyStart Train Detect:  {s['hystart_train_detect']:,}")
    print(f"  HyStart Delay Detect:  {s['hystart_delay_detect']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
