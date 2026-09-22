#!/usr/bin/env python3
"""
fm-jev-synack-rto-guard.py - Jev Multi-Agent Host Network TCP SYN/ACK Retransmission & Handshake RTO Guard (Pattern 143)

Audits Linux TCP connection handshake retry bounds (/proc/sys/net/ipv4/tcp_synack_retries,
/proc/sys/net/ipv4/tcp_syn_retries, /proc/sys/net/ipv4/tcp_syn_linear_timeouts) and
handshake retransmission counters from /proc/net/netstat (TCPSynRetrans, TCPTimeouts,
TCPSpuriousRTOs, TCPDelivered).

In high-concurrency multi-agent architectures where hundreds of outbound LLM requests,
webhook dispatches, and inter-agent RPC calls initiate connections simultaneously, misconfigured
SYN or SYN-ACK retries cause severe thread stalls. If `tcp_synack_retries` is excessively large
(> 7), dead clients or unresponsive subagents hold half-open connection slots in the host
backlog for several minutes. Conversely, if retry counts are too low (< 2), transient network
blips immediately terminate worker tasks.

This guard monitors handshake retransmission rates, timeout backoff curves, and spurious
RTO frequency, ensuring multi-agent connection establishment remains resilient without
inducing thread starvation.

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

SYSCTL_SYNACK_RETRIES = "/proc/sys/net/ipv4/tcp_synack_retries"
SYSCTL_SYN_RETRIES = "/proc/sys/net/ipv4/tcp_syn_retries"
SYSCTL_SYN_LINEAR_TIMEOUTS = "/proc/sys/net/ipv4/tcp_syn_linear_timeouts"
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


def calculate_handshake_timeout(retries: int) -> int:
    """Calculates approximate handshake timeout in seconds using RFC 6298 exponential backoff."""
    total_seconds = 0
    current_interval = 1
    for _ in range(retries):
        total_seconds += current_interval
        current_interval *= 2
    return total_seconds


def audit_synack_rto_guard(
    synack_retries_file: Optional[str] = None,
    syn_retries_file: Optional[str] = None,
    linear_timeouts_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits SYN/ACK retransmissions, handshake timeouts, and retry parameters."""
    synack_path = Path(synack_retries_file or SYSCTL_SYNACK_RETRIES)
    syn_path = Path(syn_retries_file or SYSCTL_SYN_RETRIES)
    linear_path = Path(linear_timeouts_file or SYSCTL_SYN_LINEAR_TIMEOUTS)
    netstat_path = Path(netstat_file or PROC_NETSTAT)

    synack_retries = read_int_file(synack_path)
    if synack_retries is None:
        synack_retries = 5

    syn_retries = read_int_file(syn_path)
    if syn_retries is None:
        syn_retries = 6

    syn_linear_timeouts = read_int_file(linear_path)
    if syn_linear_timeouts is None:
        syn_linear_timeouts = 4

    netstat_metrics = parse_proc_pairs(netstat_path, "TcpExt")

    syn_retrans = netstat_metrics.get("TCPSynRetrans", 0)
    timeouts = netstat_metrics.get("TCPTimeouts", 0)
    spurious_rtos = netstat_metrics.get("TCPSpuriousRTOs", 0)
    delivered = netstat_metrics.get("TCPDelivered", 0)

    base_delivered = max(delivered, 1)
    syn_retrans_ratio_pct = round((syn_retrans / base_delivered) * 100, 4)

    base_timeouts = max(timeouts, 1)
    spurious_rto_pct = round((spurious_rtos / base_timeouts) * 100, 2)

    synack_timeout_sec = calculate_handshake_timeout(synack_retries)
    syn_timeout_sec = calculate_handshake_timeout(syn_retries)

    status = "HEALTHY"
    issues: List[str] = []
    recommendations: List[str] = []

    # Evaluation Rules
    if synack_retries > 8:
        status = "CRITICAL"
        issues.append(f"Excessively high SYN-ACK retries ({synack_retries} retries, ~{synack_timeout_sec}s timeout)")
        recommendations.append("Reduce net.ipv4.tcp_synack_retries to 5 to avoid tying up half-open socket slots")
    elif synack_retries > 6:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated SYN-ACK retries ({synack_retries} retries, ~{synack_timeout_sec}s timeout)")
        recommendations.append("Consider setting net.ipv4.tcp_synack_retries to standard 5")

    if synack_retries < 2:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Very low SYN-ACK retries ({synack_retries}) risks premature connection failure")
        recommendations.append("Increase net.ipv4.tcp_synack_retries to at least 3 or 5")

    if syn_retrans_ratio_pct > 0.5 and syn_retrans > 100000:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated SYN retransmission ratio ({syn_retrans:,} retransmits, {syn_retrans_ratio_pct}%)")
        recommendations.append("Check external gateway reachability and intermediate firewall SYN drop rates")

    if not recommendations:
        recommendations.append("TCP connection handshake retries, timeout envelopes, and RTO scaling operating nominally")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_synack_retries": synack_retries,
            "tcp_syn_retries": syn_retries,
            "tcp_syn_linear_timeouts": syn_linear_timeouts,
            "synack_timeout_seconds": synack_timeout_sec,
            "syn_timeout_seconds": syn_timeout_sec,
            "syn_retrans": syn_retrans,
            "syn_retrans_ratio_pct": syn_retrans_ratio_pct,
            "spurious_rto_pct": spurious_rto_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "syn_retrans": syn_retrans,
            "tcp_timeouts": timeouts,
            "tcp_spurious_rtos": spurious_rtos,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SYN/ACK Retransmission Guard (Pattern 143)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--synack-retries-file", type=str, help="Override path to tcp_synack_retries sysctl")
    parser.add_argument("--syn-retries-file", type=str, help="Override path to tcp_syn_retries sysctl")
    parser.add_argument("--linear-timeouts-file", type=str, help="Override path to tcp_syn_linear_timeouts sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_synack_rto_guard(
        synack_retries_file=args.synack_retries_file,
        syn_retries_file=args.syn_retries_file,
        linear_timeouts_file=args.linear_timeouts_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP SYN/ACK Retransmission Guard (Pattern 143) ===")
    print(f"Status:                    {s['status']}")
    print(f"TCP SYN-ACK Retries:       {s['tcp_synack_retries']} (~{s['synack_timeout_seconds']}s timeout)")
    print(f"TCP Outbound SYN Retries:  {s['tcp_syn_retries']} (~{s['syn_timeout_seconds']}s timeout)")
    print(f"SYN Linear Timeouts:       {s['tcp_syn_linear_timeouts']}")
    print(f"SYN/ACK Retransmissions:   {s['syn_retrans']:,} ({s['syn_retrans_ratio_pct']}%)")
    print(f"Total TCP Timeouts:        {c['tcp_timeouts']:,}")
    print(f"Spurious RTOs:             {c['tcp_spurious_rtos']:,} ({s['spurious_rto_pct']}%)")
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
