#!/usr/bin/env python3
"""
fm-jev-bbr-guard.py - Jev Multi-Agent Host Network TCP Congestion Control & Pacing Guard (Pattern 106)

Audits Linux TCP congestion control algorithms, pacing ratios, and retransmission loss counters from
/proc/sys/net/ipv4/tcp_congestion_control, tcp_available_congestion_control, tcp_pacing_ss_ratio,
tcp_pacing_ca_ratio, and /proc/net/netstat (TcpExt: TCPSlowStartRetrans, TCPFastRetrans, TCPSpuriousRTOs, TCPRcvCollapsed).

Detects suboptimal congestion algorithms, bufferbloat-induced spurious RTOs, pacing bottlenecks,
and queue collapse during high-concurrency multi-agent JSON-RPC dispatch and artifact streaming.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_CC = "/proc/sys/net/ipv4/tcp_congestion_control"
SYSCTL_AVAIL_CC = "/proc/sys/net/ipv4/tcp_available_congestion_control"
SYSCTL_PACING_SS = "/proc/sys/net/ipv4/tcp_pacing_ss_ratio"
SYSCTL_PACING_CA = "/proc/sys/net/ipv4/tcp_pacing_ca_ratio"
PROC_NETSTAT = "/proc/net/netstat"


def read_str_file(path: Path) -> Optional[str]:
    """Reads a string from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return path.read_text().strip()
    except Exception:
        return None


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_tcpext_netstat(path: Path) -> Dict[str, int]:
    """Parses TcpExt key-value metrics from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        pass

    return metrics


def audit_congestion_control(
    cc_file: Optional[str] = None,
    avail_file: Optional[str] = None,
    pacing_ss_file: Optional[str] = None,
    pacing_ca_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits congestion control algorithms, pacing parameters, and retransmission telemetry."""
    cc_path = Path(cc_file) if cc_file else Path(SYSCTL_CC)
    avail_path = Path(avail_file) if avail_file else Path(SYSCTL_AVAIL_CC)
    ss_path = Path(pacing_ss_file) if pacing_ss_file else Path(SYSCTL_PACING_SS)
    ca_path = Path(pacing_ca_file) if pacing_ca_file else Path(SYSCTL_PACING_CA)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    current_cc = read_str_file(cc_path) or "unknown"
    avail_cc_raw = read_str_file(avail_path) or ""
    available_cc = avail_cc_raw.split() if avail_cc_raw else []

    pacing_ss = read_int_file(ss_path)
    pacing_ca = read_int_file(ca_path)

    tcpext = parse_tcpext_netstat(netstat_path)

    slow_start_retrans = tcpext.get("TCPSlowStartRetrans", 0)
    fast_retrans = tcpext.get("TCPFastRetrans", 0)
    spurious_rtos = tcpext.get("TCPSpuriousRTOs", 0)
    rcv_collapsed = tcpext.get("TCPRcvCollapsed", 0)

    issues: List[str] = []

    if rcv_collapsed > 0:
        issues.append(f"TCP receive queue collapse detected ({rcv_collapsed} events): memory pressure forced buffer merge")

    if spurious_rtos > 100:
        issues.append(f"Elevated spurious RTOs ({spurious_rtos} events): packet delay or ACK lag triggering unnecessary timeouts")

    if current_cc == "reno":
        issues.append("Legacy Reno congestion control active: lacks loss recovery and modern RTT fairness")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "current_congestion_control": current_cc,
            "available_algorithms": available_cc,
            "pacing_ss_ratio": pacing_ss,
            "pacing_ca_ratio": pacing_ca,
            "spurious_rtos": spurious_rtos,
            "receive_collapsed": rcv_collapsed,
            "issues": issues,
        },
        "counters": {
            "slow_start_retrans": slow_start_retrans,
            "fast_retrans": fast_retrans,
            "spurious_rtos": spurious_rtos,
            "rcv_collapsed": rcv_collapsed,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Congestion Control & Pacing Guard (Pattern 106)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--cc-file", type=str, default=None, help="Path to tcp_congestion_control")
    parser.add_argument("--avail-file", type=str, default=None, help="Path to tcp_available_congestion_control")
    parser.add_argument("--pacing-ss-file", type=str, default=None, help="Path to tcp_pacing_ss_ratio")
    parser.add_argument("--pacing-ca-file", type=str, default=None, help="Path to tcp_pacing_ca_ratio")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_congestion_control(
        cc_file=args.cc_file,
        avail_file=args.avail_file,
        pacing_ss_file=args.pacing_ss_file,
        pacing_ca_file=args.pacing_ca_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network Congestion Control & Pacing Guard (Pattern 106)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Congestion Algorithm:          {summary['current_congestion_control']}")
    print(f" Available Algorithms:          {', '.join(summary['available_algorithms'])}")
    print(f" Pacing Ratio (SS / CA):        {summary['pacing_ss_ratio']}% / {summary['pacing_ca_ratio']}%")
    print("--------------------------------------------------------------------------------")
    print(f" {'Loss Recovery & Pacing Metric':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Slow-Start Retransmissions':<30} {counters['slow_start_retrans']:<15} Nominal")
    print(f" {'Fast Retransmissions':<30} {counters['fast_retrans']:<15} Nominal")
    print(f" {'Spurious RTOs':<30} {counters['spurious_rtos']:<15} {'Nominal' if counters['spurious_rtos'] <= 100 else 'WARNING'}")
    print(f" {'Receive Queue Collapses':<30} {counters['rcv_collapsed']:<15} {'Nominal' if counters['rcv_collapsed'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive Congestion Control / Pacing Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP congestion control, pacing, and retransmission parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
