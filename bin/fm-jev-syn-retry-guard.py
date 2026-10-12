#!/usr/bin/env python3
"""
bin/fm-jev-syn-retry-guard.py - Host Network TCP Retransmission Collapse & SYN Retry Budget Guard (Pattern 189)

Audits kernel TCP connection establishment retry budgets (tcp_syn_retries, tcp_synack_retries),
retransmission thresholds (tcp_retries1, tcp_retries2, tcp_orphan_retries), and live transport
loss/retransmit telemetry from /proc/net/snmp and /proc/net/netstat (RetransSegs, OutSegs,
TCPSynRetrans, TCPTimeouts, TCPSpuriousRTOs, TCPRcvCollapsed, TCPLostRetransmit, TCPRetransFail).
Prevents SYN flood starvation, ensures swift timeout recovery without lingering zombie sockets,
and detects TCP retransmission collapse across high-density agent microservices.
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


def parse_snmp_tcp(path: str = "/proc/net/snmp") -> Dict[str, int]:
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
            if len(headers) == len(values) and headers[0] == "Tcp:" and values[0] == "Tcp:":
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        continue
    except Exception as e:
        print(f"Warning: unable to parse snmp {path}: {e}", file=sys.stderr)
    return counters


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


def audit_syn_retries(
    syn_retries_file: str = "/proc/sys/net/ipv4/tcp_syn_retries",
    synack_retries_file: str = "/proc/sys/net/ipv4/tcp_synack_retries",
    retries1_file: str = "/proc/sys/net/ipv4/tcp_retries1",
    retries2_file: str = "/proc/sys/net/ipv4/tcp_retries2",
    orphan_retries_file: str = "/proc/sys/net/ipv4/tcp_orphan_retries",
    snmp_file: str = "/proc/net/snmp",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    syn_retries = read_sysctl_int(syn_retries_file)
    synack_retries = read_sysctl_int(synack_retries_file)
    retries1 = read_sysctl_int(retries1_file)
    retries2 = read_sysctl_int(retries2_file)
    orphan_retries = read_sysctl_int(orphan_retries_file)

    snmp = parse_snmp_tcp(snmp_file)
    netstat = parse_netstat_ext(netstat_file)

    out_segs = snmp.get("OutSegs", 0)
    retrans_segs = snmp.get("RetransSegs", 0)
    retrans_pct = round((retrans_segs / out_segs * 100.0), 4) if out_segs > 0 else 0.0

    syn_retrans = netstat.get("TCPSynRetrans", 0)
    timeouts = netstat.get("TCPTimeouts", 0)
    spurious_rtos = netstat.get("TCPSpuriousRTOs", 0)
    rcv_collapsed = netstat.get("TCPRcvCollapsed", 0)
    lost_retransmit = netstat.get("TCPLostRetransmit", 0)
    retrans_fail = netstat.get("TCPRetransFail", 0)

    retrans_fail_ratio = round((retrans_fail / retrans_segs * 100.0), 2) if retrans_segs > 0 else 0.0
    rcv_collapsed_ratio = round((rcv_collapsed / out_segs * 100.0), 4) if out_segs > 0 else 0.0

    issues = []
    status = "HEALTHY"

    # Critical conditions
    if syn_retries == 0:
        issues.append(f"tcp_syn_retries is 0: active connection attempts will fail on any initial SYN drop")
        status = "CRITICAL"
    if retries2 > 0 and retries2 < 3:
        issues.append(f"tcp_retries2 ({retries2}) is dangerously low (< 3): premature connection drops under transient jitter")
        status = "CRITICAL"
    if retrans_pct >= 10.0:
        issues.append(f"TCP retransmission rate ({retrans_pct}%) exceeds 10.0% critical threshold")
        status = "CRITICAL"
    if retrans_fail_ratio >= 25.0 and retrans_pct >= 3.0:
        issues.append(f"TCPRetransFail ratio ({retrans_fail_ratio}%) indicates severe retransmission failure under load")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if syn_retries > 8:
            issues.append(f"tcp_syn_retries ({syn_retries}) > 8: excessive SYN backoff timeout stalls failed connections (> 2 min)")
            status = "WARNING"
        if synack_retries > 8:
            issues.append(f"tcp_synack_retries ({synack_retries}) > 8: half-open embryonic connections held too long against SYN floods")
            status = "WARNING"
        if retries2 > 20:
            issues.append(f"tcp_retries2 ({retries2}) > 20: dead connections persist for hours, exhausting socket descriptors")
            status = "WARNING"
        if retrans_pct >= 3.0:
            issues.append(f"TCP retransmission rate ({retrans_pct}%) exceeds 3.0% warning threshold")
            status = "WARNING"
        if rcv_collapsed_ratio >= 1.0:
            issues.append(f"TCPRcvCollapsed ratio ({rcv_collapsed_ratio}%) indicates persistent socket buffer collapse under memory pressure")
            status = "WARNING"

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_syn_retries": syn_retries,
        "tcp_synack_retries": synack_retries,
        "tcp_retries1": retries1,
        "tcp_retries2": retries2,
        "tcp_orphan_retries": orphan_retries,
        "out_segs": out_segs,
        "retrans_segs": retrans_segs,
        "retrans_pct": retrans_pct,
        "syn_retrans": syn_retrans,
        "timeouts": timeouts,
        "spurious_rtos": spurious_rtos,
        "rcv_collapsed": rcv_collapsed,
        "lost_retransmit": lost_retransmit,
        "retrans_fail": retrans_fail,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_syn_retries": syn_retries,
            "tcp_synack_retries": synack_retries,
            "tcp_retries1": retries1,
            "tcp_retries2": retries2,
            "tcp_orphan_retries": orphan_retries,
        },
        "snmp_tcp": {
            "OutSegs": out_segs,
            "RetransSegs": retrans_segs,
            "RetransRatePct": retrans_pct,
        },
        "netstat_counters": {
            "TCPSynRetrans": syn_retrans,
            "TCPTimeouts": timeouts,
            "TCPSpuriousRTOs": spurious_rtos,
            "TCPRcvCollapsed": rcv_collapsed,
            "TCPLostRetransmit": lost_retransmit,
            "TCPRetransFail": retrans_fail,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Retransmission Collapse & SYN Retry Budget Guard (Pattern 189)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_syn_retries()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP SYN Retry & Retransmission Guard (Pattern 189) - Status: {s['status']}")
    print(f"  tcp_syn_retries:       {s['tcp_syn_retries']} attempts (client initial SYN)")
    print(f"  tcp_synack_retries:    {s['tcp_synack_retries']} attempts (server SYN-ACK)")
    print(f"  tcp_retries1:          {s['tcp_retries1']} attempts (IP layer signal threshold)")
    print(f"  tcp_retries2:          {s['tcp_retries2']} attempts (hard connection abort threshold)")
    print(f"  tcp_orphan_retries:    {s['tcp_orphan_retries']} attempts (orphaned socket abort)")
    print(f"  Total Out Segments:    {s['out_segs']:,}")
    print(f"  Retransmitted Segs:    {s['retrans_segs']:,} ({s['retrans_pct']}%)")
    print(f"  SYN Retransmissions:   {s['syn_retrans']:,}")
    print(f"  RTO Timeouts:          {s['timeouts']:,}")
    print(f"  Spurious RTOs:         {s['spurious_rtos']:,}")
    print(f"  Rcv Window Collapses:  {s['rcv_collapsed']:,}")
    print(f"  Retransmissions Lost:  {s['lost_retransmit']:,}")
    print(f"  Retransmit Failures:   {s['retrans_fail']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
