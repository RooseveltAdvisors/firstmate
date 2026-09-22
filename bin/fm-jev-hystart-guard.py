#!/usr/bin/env python3
"""
fm-jev-hystart-guard.py - Jev Multi-Agent Host Network TCP HyStart++ Slow Start & Bufferbloat Prevention Guard (Pattern 136)

Audits Linux TCP HyStart++ (Hybrid Slow Start) congestion control metrics from /proc/net/netstat
(TCPHystartTrainDetect, TCPHystartTrainCwnd, TCPHystartDelayDetect, TCPHystartDelayCwnd, TCPSlowStartRetrans)
alongside congestion control policy (/proc/sys/net/ipv4/tcp_congestion_control) and slow start idle reset
policy (/proc/sys/net/ipv4/tcp_slow_start_after_idle).

In high-throughput multi-agent architectures transferring embeddings, token batches, and JSON payloads,
classic TCP exponential slow start overshoots link bottleneck capacity, causing massive packet drops
and multi-megabyte bufferbloat latency spikes. HyStart++ (RFC 9406) dynamically detects ACK train dispersion
and delay expansion, smoothly transitioning TCP into congestion avoidance before queues overflow.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_CC = "/proc/sys/net/ipv4/tcp_congestion_control"
SYSCTL_SS_IDLE = "/proc/sys/net/ipv4/tcp_slow_start_after_idle"
PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_str_file(path: Path) -> Optional[str]:
    """Reads a string from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return path.read_text().strip()
    except Exception:
        return None


def parse_proc_pairs(path: Path, section_name: str) -> Dict[str, int]:
    """Parses paired header/metric lines from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(0, len(lines) - 1):
            line = lines[i]
            if line.startswith(f"{section_name}:"):
                keys = line.split()[1:]
                next_line = lines[i + 1]
                if next_line.startswith(f"{section_name}:"):
                    vals = next_line.split()[1:]
                    for k, v in zip(keys, vals):
                        try:
                            metrics[k] = int(v)
                        except ValueError:
                            continue
                    break
    except Exception:
        return {}

    return metrics


def audit_hystart(
    cc_file: Optional[str] = None,
    ss_idle_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP HyStart++ slow start metrics and bufferbloat dampening."""
    cc_p = Path(cc_file or SYSCTL_CC)
    ss_idle_p = Path(ss_idle_file or SYSCTL_SS_IDLE)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    cc = read_str_file(cc_p) or "cubic"
    ss_idle = read_int_file(ss_idle_p)
    if ss_idle is None:
        ss_idle = 1  # Standard Linux default (1 = collapse cwnd after idle)

    tcpext = parse_proc_pairs(netstat_p, "TcpExt")
    train_detect = tcpext.get("TCPHystartTrainDetect", 0)
    train_cwnd = tcpext.get("TCPHystartTrainCwnd", 0)
    delay_detect = tcpext.get("TCPHystartDelayDetect", 0)
    delay_cwnd = tcpext.get("TCPHystartDelayCwnd", 0)
    ss_retrans = tcpext.get("TCPSlowStartRetrans", 0)
    delivered = tcpext.get("TCPDelivered", 0)

    total_detections = train_detect + delay_detect
    total_cwnd_bounded = train_cwnd + delay_cwnd

    ss_retrans_pct = (
        round((ss_retrans / total_detections * 100.0), 2) if total_detections > 0 else 0.0
    )
    delay_ratio = round((delay_detect / train_detect), 2) if train_detect > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    if ss_retrans_pct > 25.0 and ss_retrans > 500:
        issues.append(
            f"Elevated retransmission rate during slow start ({ss_retrans_pct}% > 25%); potential bufferbloat overshoot"
        )
        status = "WARNING"

    recommendations: List[str] = []
    if ss_retrans_pct > 25.0 and ss_idle == 1:
        recommendations.append(
            "Consider disabling slow start after idle for persistent agent mesh: sysctl -w net.ipv4.tcp_slow_start_after_idle=0"
        )
    if not recommendations:
        recommendations.append("TCP HyStart++ slow start bufferbloat dampening operating within optimal envelope")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_congestion_control": cc,
            "tcp_slow_start_after_idle": ss_idle,
            "total_hystart_detections": total_detections,
            "total_cwnd_bounded_packets": total_cwnd_bounded,
            "slow_start_retrans_pct": ss_retrans_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "train_detect": train_detect,
            "train_cwnd_bounded": train_cwnd,
            "delay_detect": delay_detect,
            "delay_cwnd_bounded": delay_cwnd,
            "slow_start_retrans": ss_retrans,
            "delay_vs_train_ratio": delay_ratio,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP HyStart++ Guard (Pattern 136)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--cc-file", type=str, help="Override path to tcp_congestion_control sysctl")
    parser.add_argument("--ss-idle-file", type=str, help="Override path to tcp_slow_start_after_idle sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_hystart(
        cc_file=args.cc_file,
        ss_idle_file=args.ss_idle_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP HyStart++ Guard (Pattern 136) ===")
    print(f"Status:                     {s['status']}")
    print(f"Congestion Control:         {s['tcp_congestion_control']}")
    print(f"Slow Start After Idle:      {s['tcp_slow_start_after_idle']} ({'Active' if s['tcp_slow_start_after_idle'] == 1 else 'Disabled'})")
    print(f"HyStart Detections:         {s['total_hystart_detections']:,}")
    print(f"  - Train Detect (Dispersion): {c['train_detect']:,} (Cwnd: {c['train_cwnd_bounded']:,})")
    print(f"  - Delay Detect (Latency):    {c['delay_detect']:,} (Cwnd: {c['delay_cwnd_bounded']:,})")
    print(f"  - Delay / Train Ratio:       {c['delay_vs_train_ratio']}")
    print(f"Total Cwnd Bounded Packets: {s['total_cwnd_bounded_packets']:,}")
    print(f"Slow Start Retransmissions: {c['slow_start_retrans']:,} ({s['slow_start_retrans_pct']}%)")
    print(f"Segments Delivered:         {c['tcp_delivered']:,}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
