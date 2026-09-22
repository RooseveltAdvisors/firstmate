#!/usr/bin/env python3
"""
fm-jev-sack-compression-guard.py - Jev Multi-Agent Host Network TCP SACK Compression & ACK Decimation Guard (Pattern 137)

Audits Linux TCP SACK compression policy (/proc/sys/net/ipv4/tcp_comp_sack_nr,
/proc/sys/net/ipv4/tcp_comp_sack_delay_ns) and ACK decimation / delayed ACK counters from
/proc/net/netstat (TCPAckCompressed, DelayedACKs, DelayedACKLocked, DelayedACKLost).

In high-throughput multi-agent architectures streaming tokens and streaming RPC frames,
individual ACKs generate massive interrupt and CPU overhead. TCP SACK compression (RFC 6675 extension)
coalesces consecutive selective ACKs within a bounded micro-delay (default 1ms), dramatically
reducing reverse-path network congestion while preventing premature RTO timeouts.

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

SYSCTL_COMP_SACK_NR = "/proc/sys/net/ipv4/tcp_comp_sack_nr"
SYSCTL_COMP_SACK_DELAY = "/proc/sys/net/ipv4/tcp_comp_sack_delay_ns"
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


def audit_sack_compression(
    comp_sack_nr_file: Optional[str] = None,
    comp_sack_delay_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP SACK compression configuration and ACK efficiency."""
    nr_p = Path(comp_sack_nr_file or SYSCTL_COMP_SACK_NR)
    delay_p = Path(comp_sack_delay_file or SYSCTL_COMP_SACK_DELAY)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    comp_sack_nr = read_int_file(nr_p)
    if comp_sack_nr is None:
        comp_sack_nr = 44  # Standard Linux default

    comp_sack_delay_ns = read_int_file(delay_p)
    if comp_sack_delay_ns is None:
        comp_sack_delay_ns = 1000000  # Standard Linux default (1ms = 1,000,000 ns)

    comp_sack_delay_ms = round(comp_sack_delay_ns / 1_000_000.0, 3)

    tcpext = parse_proc_pairs(netstat_p, "TcpExt")
    ack_compressed = tcpext.get("TCPAckCompressed", 0)
    delayed_acks = tcpext.get("DelayedACKs", 0)
    delayed_locked = tcpext.get("DelayedACKLocked", 0)
    delayed_lost = tcpext.get("DelayedACKLost", 0)
    delivered = tcpext.get("TCPDelivered", 0)

    total_acks = ack_compressed + delayed_acks
    compression_ratio_pct = (
        round((ack_compressed / total_acks * 100.0), 2) if total_acks > 0 else 0.0
    )
    delayed_loss_pct = (
        round((delayed_lost / delayed_acks * 100.0), 2) if delayed_acks > 0 else 0.0
    )

    issues: List[str] = []
    status = "HEALTHY"

    if comp_sack_nr == 0:
        issues.append("TCP SACK compression is disabled (tcp_comp_sack_nr=0); individual SACK packets will flood link")
        status = "WARNING"

    if comp_sack_delay_ms > 10.0:
        issues.append(f"SACK compression delay is excessively high ({comp_sack_delay_ms}ms > 10ms); introduces RTT latency")
        status = "WARNING"

    if delayed_loss_pct > 25.0 and delayed_acks > 10000:
        issues.append(f"Elevated delayed ACK timer expirations ({delayed_loss_pct}% > 25%); reverse path traffic delayed")
        status = "WARNING"

    recommendations: List[str] = []
    if comp_sack_nr == 0:
        recommendations.append("Enable TCP SACK compression: sysctl -w net.ipv4.tcp_comp_sack_nr=44")
    if comp_sack_delay_ms > 10.0:
        recommendations.append("Restore standard SACK delay: sysctl -w net.ipv4.tcp_comp_sack_delay_ns=1000000")
    if not recommendations:
        recommendations.append("TCP SACK compression and delayed ACK decimation operating within optimal envelope")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_comp_sack_nr": comp_sack_nr,
            "tcp_comp_sack_delay_ms": comp_sack_delay_ms,
            "ack_compressed": ack_compressed,
            "delayed_acks": delayed_acks,
            "compression_ratio_pct": compression_ratio_pct,
            "delayed_loss_pct": delayed_loss_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "tcp_ack_compressed": ack_compressed,
            "delayed_acks": delayed_acks,
            "delayed_ack_locked": delayed_locked,
            "delayed_ack_lost": delayed_lost,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SACK Compression Guard (Pattern 137)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--comp-sack-nr-file", type=str, help="Override path to tcp_comp_sack_nr sysctl")
    parser.add_argument("--comp-sack-delay-file", type=str, help="Override path to tcp_comp_sack_delay_ns sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_sack_compression(
        comp_sack_nr_file=args.comp_sack_nr_file,
        comp_sack_delay_file=args.comp_sack_delay_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP SACK Compression Guard (Pattern 137) ===")
    print(f"Status:                    {s['status']}")
    print(f"Max SACK Blocks:           {s['tcp_comp_sack_nr']}")
    print(f"SACK Compression Delay:    {s['tcp_comp_sack_delay_ms']} ms")
    print(f"Compressed ACKs:           {s['ack_compressed']:,}")
    print(f"Delayed ACKs:              {s['delayed_acks']:,}")
    print(f"ACK Compression Ratio:     {s['compression_ratio_pct']}%")
    print(f"Delayed ACK Timer Losses:  {c['delayed_ack_lost']:,} ({s['delayed_loss_pct']}%)")
    print(f"Socket Locked Delays:      {c['delayed_ack_locked']:,}")
    print(f"Segments Delivered:        {c['tcp_delivered']:,}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
