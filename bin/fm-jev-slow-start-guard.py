#!/usr/bin/env python3
"""
bin/fm-jev-slow-start-guard.py - Host Network TCP Slow Start After Idle & Congestion Control Guard (Pattern 199)

Audits kernel TCP congestion control algorithm (tcp_congestion_control, tcp_available_congestion_control),
slow start idle behavior (tcp_slow_start_after_idle), and slow start / fast retransmit metrics from
/proc/net/netstat (TCPSlowStartRetrans, TCPFastRetrans, TCPHystartTrainDetect, TCPHystartDelayDetect).
Prevents artificial congestion window collapse on idle keepalive connections, monitors cubic/bbr
convergence, and ensures high-throughput streaming and RPC pipelining across multi-agent microservices.
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


def read_sysctl_str(path: str) -> str:
    if not os.path.exists(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return ""


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


def audit_slow_start(
    slow_start_after_idle_file: str = "/proc/sys/net/ipv4/tcp_slow_start_after_idle",
    congestion_control_file: str = "/proc/sys/net/ipv4/tcp_congestion_control",
    available_cc_file: str = "/proc/sys/net/ipv4/tcp_available_congestion_control",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    ss_after_idle = read_sysctl_int(slow_start_after_idle_file)
    cc_algo = read_sysctl_str(congestion_control_file)
    available_cc = read_sysctl_str(available_cc_file).split()

    netstat = parse_netstat_ext(netstat_file)

    ss_retrans = netstat.get("TCPSlowStartRetrans", 0)
    fast_retrans = netstat.get("TCPFastRetrans", 0)
    hystart_train = netstat.get("TCPHystartTrainDetect", 0)
    hystart_delay = netstat.get("TCPHystartDelayDetect", 0)

    total_retrans = ss_retrans + fast_retrans
    ss_retrans_ratio = round((ss_retrans / total_retrans * 100.0), 4) if total_retrans > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    # Critical conditions
    if not cc_algo:
        issues.append("tcp_congestion_control is unreadable or empty: unknown kernel transport state")
        status = "CRITICAL"
    if total_retrans > 10000 and ss_retrans > (fast_retrans * 2):
        issues.append(f"Slow start retransmissions ({ss_retrans}) exceed fast retransmissions ({fast_retrans}) by > 2x: severe initial window collapse")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if ss_after_idle == 1:
            # Informative / diagnostic note on standard Linux RFC 5681 default
            pass
        if cc_algo == "reno":
            issues.append("tcp_congestion_control is reno: legacy loss-based algorithm, cubic or bbr recommended")
            status = "WARNING"

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_congestion_control": cc_algo,
        "available_congestion_control": available_cc,
        "tcp_slow_start_after_idle": ss_after_idle,
        "slow_start_retrans": ss_retrans,
        "fast_retrans": fast_retrans,
        "slow_start_retrans_ratio_pct": ss_retrans_ratio,
        "hystart_train_detect": hystart_train,
        "hystart_delay_detect": hystart_delay,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_congestion_control": cc_algo,
            "tcp_available_congestion_control": available_cc,
            "tcp_slow_start_after_idle": ss_after_idle,
        },
        "netstat_counters": {
            "TCPSlowStartRetrans": ss_retrans,
            "TCPFastRetrans": fast_retrans,
            "TCPHystartTrainDetect": hystart_train,
            "TCPHystartDelayDetect": hystart_delay,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Slow Start After Idle & Congestion Control Guard (Pattern 199)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_slow_start()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Slow Start & Congestion Control Guard (Pattern 199) - Status: {s['status']}")
    print(f"  Congestion Algorithm:    {s['tcp_congestion_control']} (available: {', '.join(s['available_congestion_control'])})")
    print(f"  Slow Start After Idle:   {s['tcp_slow_start_after_idle']} ({'reset cwnd after idle' if s['tcp_slow_start_after_idle'] == 1 else 'preserve cwnd'})")
    print(f"  Slow Start Retransmits:  {s['slow_start_retrans']:,} ({s['slow_start_retrans_ratio_pct']}% of retrans)")
    print(f"  Fast Retransmissions:    {s['fast_retrans']:,}")
    print(f"  HyStart Train Detections: {s['hystart_train_detect']:,}")
    print(f"  HyStart Delay Detections: {s['hystart_delay_detect']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
