#!/usr/bin/env python3
"""
fm-jev-paws-guard.py - Jev Multi-Agent Host Network TCP Timestamp Space & PAWS Clock Drift Guard (Pattern 142)

Audits Linux TCP timestamp configuration (/proc/sys/net/ipv4/tcp_timestamps,
/proc/sys/net/ipv4/tcp_rfc1337) and Protection Against Wrapped Sequence Numbers (PAWS)
rejection counters from /proc/net/netstat (PAWSActive, PAWSEstab, PAWSOldAck, PAWSTimewait,
TSEcrRejected, TCPDelivered).

In multi-agent architectures where high-throughput token streams, file synchronizations, and
continuous RPC connections generate gigabytes of network traffic, TCP sequence numbers
wrap around rapidly. RFC 7323 TCP Timestamps and PAWS prevent old duplicate segments from
corrupting live connections. If peer clocks drift or timestamps become desynchronized,
the kernel may discard valid segments (PAWSEstab / TSEcrRejected), triggering packet drops
and spurious retransmission loops.

This guard monitors timestamp health, PAWS drop ratios, and RFC 1337 TIME-WAIT protections,
ensuring multi-agent streaming links maintain high throughput without desynchronization stalls.

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

SYSCTL_TCP_TIMESTAMPS = "/proc/sys/net/ipv4/tcp_timestamps"
SYSCTL_TCP_RFC1337 = "/proc/sys/net/ipv4/tcp_rfc1337"
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
        pass
    return metrics


def audit_paws_guard(
    timestamps_file: Optional[str] = None,
    rfc1337_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP timestamps, PAWS drops, and timestamp rejection metrics."""
    ts_path = Path(timestamps_file or SYSCTL_TCP_TIMESTAMPS)
    rfc_path = Path(rfc1337_file or SYSCTL_TCP_RFC1337)
    netstat_path = Path(netstat_file or PROC_NETSTAT)

    tcp_timestamps = read_int_file(ts_path)
    if tcp_timestamps is None:
        tcp_timestamps = 1  # Standard Linux default

    tcp_rfc1337 = read_int_file(rfc_path)
    if tcp_rfc1337 is None:
        tcp_rfc1337 = 0

    netstat_metrics = parse_proc_pairs(netstat_path, "TcpExt")

    paws_active = netstat_metrics.get("PAWSActive", 0)
    paws_estab = netstat_metrics.get("PAWSEstab", 0)
    paws_old_ack = netstat_metrics.get("PAWSOldAck", 0)
    paws_timewait = netstat_metrics.get("PAWSTimewait", 0)
    tsecr_rejected = netstat_metrics.get("TSEcrRejected", 0)
    delivered = netstat_metrics.get("TCPDelivered", 0)

    total_paws_drops = paws_active + paws_estab + paws_old_ack + paws_timewait + tsecr_rejected
    base_delivered = max(delivered, 1)
    paws_drop_ratio_pct = round((total_paws_drops / base_delivered) * 100, 6)

    status = "HEALTHY"
    issues: List[str] = []
    recommendations: List[str] = []

    # Evaluation Rules
    if tcp_timestamps == 0:
        status = "CRITICAL"
        issues.append("TCP timestamps are disabled (net.ipv4.tcp_timestamps=0)")
        recommendations.append("Enable TCP timestamps: sysctl -w net.ipv4.tcp_timestamps=1 to enable PAWS and RTTM")

    if paws_drop_ratio_pct > 0.5 and total_paws_drops > 50000:
        status = "CRITICAL"
        issues.append(f"Severe PAWS packet drop ratio ({total_paws_drops:,} drops, {paws_drop_ratio_pct}%)")
        recommendations.append("Investigate peer clock drift or asymmetric routing timestamp clobbering")
    elif paws_drop_ratio_pct > 0.05 and total_paws_drops > 10000:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated PAWS packet drops ({total_paws_drops:,} drops, {paws_drop_ratio_pct}%)")
        recommendations.append("Inspect NAT device timestamp rewrites or NTP clock synchronization")

    if tsecr_rejected > 1000:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated echoed timestamp rejections (TSEcrRejected={tsecr_rejected:,})")
        recommendations.append("Verify proxy and tunnel middleware timestamp pass-through behavior")

    if not recommendations:
        recommendations.append("TCP timestamps, PAWS sequence wrapping protection, and clock spacing operating nominally")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_timestamps": tcp_timestamps,
            "tcp_rfc1337": tcp_rfc1337,
            "paws_active": paws_active,
            "paws_estab": paws_estab,
            "paws_old_ack": paws_old_ack,
            "paws_timewait": paws_timewait,
            "tsecr_rejected": tsecr_rejected,
            "total_paws_drops": total_paws_drops,
            "paws_drop_ratio_pct": paws_drop_ratio_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "paws_active": paws_active,
            "paws_estab": paws_estab,
            "paws_old_ack": paws_old_ack,
            "paws_timewait": paws_timewait,
            "tsecr_rejected": tsecr_rejected,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP PAWS & Timestamp Guard (Pattern 142)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--timestamps-file", type=str, help="Override path to tcp_timestamps sysctl")
    parser.add_argument("--rfc1337-file", type=str, help="Override path to tcp_rfc1337 sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_paws_guard(
        timestamps_file=args.timestamps_file,
        rfc1337_file=args.rfc1337_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP PAWS & Timestamp Guard (Pattern 142) ===")
    print(f"Status:                    {s['status']}")
    print(f"TCP Timestamps:            {'Enabled (1)' if s['tcp_timestamps'] == 1 else ('Reflected (2)' if s['tcp_timestamps'] == 2 else 'Disabled (0)')}")
    print(f"RFC 1337 TIME-WAIT Protect:{' Enabled (1)' if s['tcp_rfc1337'] == 1 else ' Disabled (0)'}")
    print(f"PAWS Established Drops:    {c['paws_estab']:,}")
    print(f"PAWS Old ACK Drops:        {c['paws_old_ack']:,}")
    print(f"PAWS TIME-WAIT Drops:      {c['paws_timewait']:,}")
    print(f"Echoed TS Rejected:        {c['tsecr_rejected']:,}")
    print(f"Total PAWS Drops:          {s['total_paws_drops']:,} ({s['paws_drop_ratio_pct']}%)")
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
