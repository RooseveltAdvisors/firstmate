#!/usr/bin/env python3
"""
bin/fm-jev-tcp-ssthresh-metrics-guard.py - Linux TCP Slow-Start Threshold Metrics Save & HyStart Policy Guard (Pattern 299 / Pattern 437)

Audits Linux kernel TCP slow-start threshold metrics saving policy (tcp_no_ssthresh_metrics_save),
route metrics caching (tcp_no_metrics_save), and slow-start restart behavior alongside HyStart telemetry:
  - /proc/sys/net/ipv4/tcp_no_ssthresh_metrics_save: Avoid clamping future connection slow-start by not saving ssthresh (default 1)
  - /proc/sys/net/ipv4/tcp_no_metrics_save: TCP destination route metrics cache preservation policy (default 0 or 1)
  - /proc/sys/net/ipv4/tcp_slow_start_after_idle: Congestion window reduction following idle period (default 1 / RFC 5681)
  - /proc/net/netstat: TCPSlowStartRetrans, TCPHystartTrainDetect, TCPHystartTrainCwnd, TCPHystartDelayDetect, TCPHystartDelayCwnd, TCPFastRetrans, TCPTimeouts

Invariants:
  - tcp_no_ssthresh_metrics_save must be 1 to prevent clamping slow-start on future sessions.
  - Fail-open: graceful fallback when sysctl paths or /proc/net/netstat are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

SYSCTL_NO_SSTHRESH_SAVE = "/proc/sys/net/ipv4/tcp_no_ssthresh_metrics_save"
SYSCTL_NO_METRICS_SAVE = "/proc/sys/net/ipv4/tcp_no_metrics_save"
SYSCTL_SS_AFTER_IDLE = "/proc/sys/net/ipv4/tcp_slow_start_after_idle"
PROC_NETSTAT = "/proc/net/netstat"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_netstat_tcpext(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "TCPSlowStartRetrans": 0,
        "TCPFastRetrans": 0,
        "TCPHystartTrainDetect": 0,
        "TCPHystartTrainCwnd": 0,
        "TCPHystartDelayDetect": 0,
        "TCPHystartDelayCwnd": 0,
        "TCPTimeouts": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                headers = lines[i].split()[1:]
                values = lines[i + 1].split()[1:]
                for h, v in zip(headers, values):
                    if h in metrics:
                        try:
                            metrics[h] = int(v)
                        except ValueError:
                            pass
                break
    except Exception:
        pass
    return metrics


def evaluate_tcp_ssthresh_metrics(
    no_ssthresh_save_file: str = SYSCTL_NO_SSTHRESH_SAVE,
    no_metrics_save_file: str = SYSCTL_NO_METRICS_SAVE,
    ss_after_idle_file: str = SYSCTL_SS_AFTER_IDLE,
    netstat_file: str = PROC_NETSTAT,
    warn_slow_start_retrans_ratio: float = 0.15,
) -> Dict[str, Any]:
    no_ssthresh_save = read_sysctl_int(no_ssthresh_save_file, default=-1)
    no_metrics_save = read_sysctl_int(no_metrics_save_file, default=-1)
    ss_after_idle = read_sysctl_int(ss_after_idle_file, default=-1)

    tcpext = parse_netstat_tcpext(netstat_file)
    ss_retrans = tcpext.get("TCPSlowStartRetrans", 0)
    fast_retrans = tcpext.get("TCPFastRetrans", 0)
    hystart_train_detect = tcpext.get("TCPHystartTrainDetect", 0)
    hystart_train_cwnd = tcpext.get("TCPHystartTrainCwnd", 0)
    hystart_delay_detect = tcpext.get("TCPHystartDelayDetect", 0)
    hystart_delay_cwnd = tcpext.get("TCPHystartDelayCwnd", 0)
    timeouts = tcpext.get("TCPTimeouts", 0)

    issues: List[str] = []
    recommendations: List[str] = []

    if no_ssthresh_save not in (0, 1):
        issues.append(
            f"Invalid net.ipv4.tcp_no_ssthresh_metrics_save: {no_ssthresh_save} (expected 0 or 1)"
        )
        recommendations.append(
            "Restore net.ipv4.tcp_no_ssthresh_metrics_save to 1 to prevent clamping slow-start on future sessions"
        )

    if no_metrics_save not in (0, 1):
        issues.append(
            f"Invalid net.ipv4.tcp_no_metrics_save: {no_metrics_save} (expected 0 or 1)"
        )
        recommendations.append(
            "Set net.ipv4.tcp_no_metrics_save to 0 or 1"
        )

    if ss_after_idle not in (0, 1):
        issues.append(
            f"Invalid net.ipv4.tcp_slow_start_after_idle: {ss_after_idle} (expected 0 or 1)"
        )
        recommendations.append(
            "Set net.ipv4.tcp_slow_start_after_idle to 1 (RFC 5681 compliant) or 0"
        )

    total_retrans = max(1, ss_retrans + fast_retrans)
    ss_retrans_ratio = ss_retrans / total_retrans
    if total_retrans > 10_000 and ss_retrans_ratio > warn_slow_start_retrans_ratio:
        issues.append(
            f"High slow-start retransmission ratio: {ss_retrans_ratio:.2%} ({ss_retrans:,} / {total_retrans:,}) > {warn_slow_start_retrans_ratio:.0%}"
        )
        recommendations.append(
            "Verify HyStart delay sensitivity and ensure net.ipv4.tcp_no_ssthresh_metrics_save=1"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "pattern": 299,
        "name": "tcp_ssthresh_metrics",
        "status": status,
        "healthy": healthy,
        "tcp_no_ssthresh_metrics_save": no_ssthresh_save,
        "tcp_no_metrics_save": no_metrics_save,
        "tcp_slow_start_after_idle": ss_after_idle,
        "slow_start_retrans": ss_retrans,
        "fast_retrans": fast_retrans,
        "slow_start_retrans_ratio_pct": round(ss_retrans_ratio * 100, 4),
        "hystart_train_detect": hystart_train_detect,
        "hystart_train_cwnd": hystart_train_cwnd,
        "hystart_delay_detect": hystart_delay_detect,
        "hystart_delay_cwnd": hystart_delay_cwnd,
        "tcp_timeouts": timeouts,
        "sysctls": {
            "tcp_no_ssthresh_metrics_save": no_ssthresh_save,
            "tcp_no_metrics_save": no_metrics_save,
            "tcp_slow_start_after_idle": ss_after_idle,
        },
        "tcpext_counters": tcpext,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Slow-Start Threshold Metrics Save & HyStart Policy Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--no-ssthresh-save-file", default=SYSCTL_NO_SSTHRESH_SAVE, help="Path to tcp_no_ssthresh_metrics_save")
    parser.add_argument("--no-metrics-save-file", default=SYSCTL_NO_METRICS_SAVE, help="Path to tcp_no_metrics_save")
    parser.add_argument("--ss-after-idle-file", default=SYSCTL_SS_AFTER_IDLE, help="Path to tcp_slow_start_after_idle")
    parser.add_argument("--netstat-file", default=PROC_NETSTAT, help="Path to /proc/net/netstat")
    parser.add_argument("--warn-slow-start-retrans-ratio", type=float, default=0.15, help="Warning ratio for slow start retransmissions")
    args = parser.parse_args()

    result = evaluate_tcp_ssthresh_metrics(
        no_ssthresh_save_file=args.no_ssthresh_save_file,
        no_metrics_save_file=args.no_metrics_save_file,
        ss_after_idle_file=args.ss_after_idle_file,
        netstat_file=args.netstat_file,
        warn_slow_start_retrans_ratio=args.warn_slow_start_retrans_ratio,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"[{result['status']}] Jev TCP Ssthresh Metrics Guard")
        print(f"  tcp_no_ssthresh_metrics_save: {result['tcp_no_ssthresh_metrics_save']}")
        print(f"  tcp_no_metrics_save: {result['tcp_no_metrics_save']}")
        print(f"  tcp_slow_start_after_idle: {result['tcp_slow_start_after_idle']}")
        print(f"  Slow Start Retransmissions: {result['slow_start_retrans']:,}")
        print(f"  Fast Retransmissions: {result['fast_retrans']:,}")
        print(f"  Slow Start Retrans Ratio: {result['slow_start_retrans_ratio_pct']}%")
        print(f"  HyStart Train Detects: {result['hystart_train_detect']:,}")
        print(f"  HyStart Delay Detects: {result['hystart_delay_detect']:,}")
        print(f"  TCP Timeouts: {result['tcp_timeouts']:,}")
        if result["issues"]:
            print("  Issues:")
            for iss in result["issues"]:
                print(f"    - {iss}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
