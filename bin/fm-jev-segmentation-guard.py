#!/usr/bin/env python3
"""
fm-jev-segmentation-guard.py - Jev Multi-Agent Host Network TCP TSO/GSO Segmentation Slicing & Burst Microburst Guard (Pattern 141)

Audits Linux TCP output segmentation pacing and queue burst parameters
(/proc/sys/net/ipv4/tcp_limit_output_bytes, /proc/sys/net/ipv4/tcp_min_tso_segs,
/proc/sys/net/ipv4/tcp_tso_win_divisor, /proc/sys/net/core/default_qdisc) and
driver queue delay retransmission counters from /proc/net/netstat (TCPSpuriousRtxHostQueues,
TCPWqueueTooBig, TCPAutoCorking, TCPDelivered).

In multi-agent environments where high-bandwidth LLM responses and artifact payloads are
streamed across local sockets, loopback interfaces, and external API gateways, oversized
TCP Segmentation Offload (TSO) frames can inject microbursts into host network device queues.
When packets sit in qdisc queues longer than the smoothed RTT, the TCP stack prematurely triggers
spurious retransmissions (TCPSpuriousRtxHostQueues), wasting CPU cycles and causing queue jitter.

This guard monitors output byte pacing limits, TSO burst slicing factors, and host queue
delay retransmissions, ensuring bursty multi-agent traffic remains smoothly paced.

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

SYSCTL_LIMIT_OUTPUT_BYTES = "/proc/sys/net/ipv4/tcp_limit_output_bytes"
SYSCTL_MIN_TSO_SEGS = "/proc/sys/net/ipv4/tcp_min_tso_segs"
SYSCTL_TSO_WIN_DIVISOR = "/proc/sys/net/ipv4/tcp_tso_win_divisor"
SYSCTL_DEFAULT_QDISC = "/proc/sys/net/core/default_qdisc"
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
        pass
    return metrics


def audit_segmentation_guard(
    limit_output_bytes_file: Optional[str] = None,
    min_tso_segs_file: Optional[str] = None,
    tso_win_divisor_file: Optional[str] = None,
    default_qdisc_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP segmentation offload pacing and host queue retransmissions."""
    limit_path = Path(limit_output_bytes_file or SYSCTL_LIMIT_OUTPUT_BYTES)
    min_tso_path = Path(min_tso_segs_file or SYSCTL_MIN_TSO_SEGS)
    divisor_path = Path(tso_win_divisor_file or SYSCTL_TSO_WIN_DIVISOR)
    qdisc_path = Path(default_qdisc_file or SYSCTL_DEFAULT_QDISC)
    netstat_path = Path(netstat_file or PROC_NETSTAT)

    limit_output_bytes = read_int_file(limit_path)
    if limit_output_bytes is None:
        limit_output_bytes = 4194304  # Safe default 4MB

    min_tso_segs = read_int_file(min_tso_path)
    if min_tso_segs is None:
        min_tso_segs = 2

    tso_win_divisor = read_int_file(divisor_path)
    if tso_win_divisor is None:
        tso_win_divisor = 3

    default_qdisc = read_str_file(qdisc_path) or "fq_codel"

    netstat_metrics = parse_proc_pairs(netstat_path, "TcpExt")

    spurious_host_queues = netstat_metrics.get("TCPSpuriousRtxHostQueues", 0)
    wqueue_too_big = netstat_metrics.get("TCPWqueueTooBig", 0)
    auto_corking = netstat_metrics.get("TCPAutoCorking", 0)
    delivered = netstat_metrics.get("TCPDelivered", 0)

    base_delivered = max(delivered, 1)
    spurious_ratio_pct = round((spurious_host_queues / base_delivered) * 100, 4)

    status = "HEALTHY"
    issues: List[str] = []
    recommendations: List[str] = []

    # Evaluation Rules
    if limit_output_bytes > 33554432:  # > 32MB
        status = "CRITICAL"
        issues.append(f"Excessively large TCP output pacing limit ({limit_output_bytes:,} bytes > 32MiB)")
        recommendations.append("Reduce net.ipv4.tcp_limit_output_bytes to 4194304 (4MiB) or lower to prevent bufferbloat")
    elif limit_output_bytes > 16777216:  # > 16MB
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated TCP output pacing limit ({limit_output_bytes:,} bytes > 16MiB)")
        recommendations.append("Consider setting net.ipv4.tcp_limit_output_bytes to 4194304 or 1048576")

    if tso_win_divisor < 1:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Invalid TSO window divisor ({tso_win_divisor} < 1)")
        recommendations.append("Restore net.ipv4.tcp_tso_win_divisor to standard 3")

    if spurious_ratio_pct > 0.5 and spurious_host_queues > 100000:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated host queue spurious retransmissions ({spurious_host_queues:,}, {spurious_ratio_pct}%)")
        recommendations.append("Evaluate qdisc pacing configuration and check driver queue depth")

    if wqueue_too_big > 500:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Multiple sockets exceeded maximum write queue size ({wqueue_too_big:,})")
        recommendations.append("Inspect application send buffer configuration and socket write timeouts")

    if not recommendations:
        recommendations.append("TCP output pacing, TSO burst slicing, and host qdisc delay operating within optimal envelope")

    limit_output_mb = round(limit_output_bytes / (1024 * 1024), 2)

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "limit_output_bytes": limit_output_bytes,
            "limit_output_mb": limit_output_mb,
            "min_tso_segs": min_tso_segs,
            "tso_win_divisor": tso_win_divisor,
            "default_qdisc": default_qdisc,
            "spurious_host_queues": spurious_host_queues,
            "wqueue_too_big": wqueue_too_big,
            "auto_corking": auto_corking,
            "spurious_ratio_pct": spurious_ratio_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "spurious_host_queues": spurious_host_queues,
            "wqueue_too_big": wqueue_too_big,
            "auto_corking": auto_corking,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Segmentation Guard (Pattern 141)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--limit-output-bytes-file", type=str, help="Override path to tcp_limit_output_bytes sysctl")
    parser.add_argument("--min-tso-segs-file", type=str, help="Override path to tcp_min_tso_segs sysctl")
    parser.add_argument("--tso-win-divisor-file", type=str, help="Override path to tcp_tso_win_divisor sysctl")
    parser.add_argument("--default-qdisc-file", type=str, help="Override path to default_qdisc sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_segmentation_guard(
        limit_output_bytes_file=args.limit_output_bytes_file,
        min_tso_segs_file=args.min_tso_segs_file,
        tso_win_divisor_file=args.tso_win_divisor_file,
        default_qdisc_file=args.default_qdisc_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP Segmentation Guard (Pattern 141) ===")
    print(f"Status:                    {s['status']}")
    print(f"TCP Limit Output Bytes:    {s['limit_output_bytes']:,} bytes ({s['limit_output_mb']} MiB)")
    print(f"Min TSO Segments:          {s['min_tso_segs']}")
    print(f"TSO Window Divisor:        {s['tso_win_divisor']}")
    print(f"Default Host Qdisc:        {s['default_qdisc']}")
    print(f"Spurious Host Queue Rtx:   {c['spurious_host_queues']:,} ({s['spurious_ratio_pct']}%)")
    print(f"Write Queue Oversized:     {c['wqueue_too_big']:,} sockets")
    print(f"Auto-Corking Events:       {c['auto_corking']:,}")
    print(f"Total Segments Delivered:  {c['tcp_delivered']:,}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
