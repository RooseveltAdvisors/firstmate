#!/usr/bin/env python3
"""
fm-jev-autocork-guard.py - Jev Multi-Agent Host Network TCP Auto Corking & Packet Coalescing Guard (Pattern 135)

Audits Linux TCP auto-corking policy (/proc/sys/net/ipv4/tcp_autocorking) and socket write
coalescing efficiency counters from /proc/net/netstat (TCPAutoCorking, TCPOrigDataSent).

When applications perform consecutive small write() or sendmsg() calls (common in LLM token streaming,
JSON-RPC serialization, and chat telemetry streams), TCP auto-corking automatically coalesces
sub-MSS chunks into full frames if prior packets are still traversing device or qdisc queues.
If disabled (tcp_autocorking=0), every micro-write generates redundant 40-60 byte IP/TCP headers,
saturating host softirq CPU and degrading throughput across multi-agent connections.

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

SYSCTL_AUTOCORKING = "/proc/sys/net/ipv4/tcp_autocorking"
PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
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


def audit_autocork(
    autocorking_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP auto-corking configuration and write coalescing metrics."""
    cork_p = Path(autocorking_file or SYSCTL_AUTOCORKING)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    autocorking = read_int_file(cork_p)
    if autocorking is None:
        autocorking = 1  # Standard Linux default (1 = enabled)

    tcpext = parse_proc_pairs(netstat_p, "TcpExt")
    autocork_events = tcpext.get("TCPAutoCorking", 0)
    orig_data_sent = tcpext.get("TCPOrigDataSent", 0)
    delivered = tcpext.get("TCPDelivered", 0)

    coalesce_ratio_pct = (
        round((autocork_events / orig_data_sent * 100.0), 3) if orig_data_sent > 0 else 0.0
    )

    issues: List[str] = []
    status = "HEALTHY"

    if autocorking == 0:
        issues.append("TCP auto-corking is disabled (tcp_autocorking=0); small writes will not be coalesced into MSS frames")
        status = "WARNING"

    recommendations: List[str] = []
    if autocorking == 0:
        recommendations.append("Enable TCP auto-corking: sysctl -w net.ipv4.tcp_autocorking=1")
    else:
        recommendations.append("TCP auto-corking and socket write coalescing operating within optimal envelope")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_autocorking": autocorking,
            "autocork_events": autocork_events,
            "orig_data_sent": orig_data_sent,
            "coalesce_ratio_pct": coalesce_ratio_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "tcp_autocorking": autocork_events,
            "tcp_orig_data_sent": orig_data_sent,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Auto Corking & Coalescing Guard (Pattern 135)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--autocorking-file", type=str, help="Override path to tcp_autocorking sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_autocork(
        autocorking_file=args.autocorking_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP Auto Corking Guard (Pattern 135) ===")
    print(f"Status:                 {s['status']}")
    print(f"TCP Auto Corking:       {s['tcp_autocorking']} ({'Enabled' if s['tcp_autocorking'] == 1 else 'Disabled'})")
    print(f"Auto Corking Events:    {s['autocork_events']:,}")
    print(f"Original Data Sent:     {s['orig_data_sent']:,} segments")
    print(f"Write Coalesce Ratio:   {s['coalesce_ratio_pct']}%")
    print(f"Segments Delivered:     {c['tcp_delivered']:,}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
