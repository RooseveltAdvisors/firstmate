#!/usr/bin/env python3
"""
fm-jev-challenge-ack-guard.py - Jev Multi-Agent Host Network TCP Challenge ACK Rate Limiter & Blind In-Window Reset Guard (Pattern 134)

Audits Linux TCP Challenge ACK rate limiting policy (/proc/sys/net/ipv4/tcp_challenge_ack_limit)
and blind in-window attack defense counters from /proc/net/netstat (TCPChallengeACK,
TCPSYNChallenge, TCPACKSkippedChallenge).

RFC 5961 establishes Challenge ACKs to verify whether received RST, SYN, or out-of-order data
packets legitimately belong to an established connection or represent spoofed/off-path injection.
When tcp_challenge_ack_limit is set too low (< 100/s) or exhausted under burst traffic,
the kernel drops Challenge ACKs (incrementing TCPACKSkippedChallenge), causing legitimate
reconnection handshakes or container restart recoveries to hang in half-open states.

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

SYSCTL_CHALLENGE_ACK_LIMIT = "/proc/sys/net/ipv4/tcp_challenge_ack_limit"
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


def audit_challenge_ack(
    challenge_ack_limit_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP Challenge ACK rate limit and dropped challenge counters."""
    limit_p = Path(challenge_ack_limit_file or SYSCTL_CHALLENGE_ACK_LIMIT)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    limit = read_int_file(limit_p)
    if limit is None:
        limit = 1000  # Default RFC 5961 limit if file unreadable

    tcpext = parse_proc_pairs(netstat_p, "TcpExt")
    challenge_acks = tcpext.get("TCPChallengeACK", 0)
    syn_challenges = tcpext.get("TCPSYNChallenge", 0)
    skipped_challenges = tcpext.get("TCPACKSkippedChallenge", 0)
    delivered = tcpext.get("TCPDelivered", 0)

    total_challenges = challenge_acks + skipped_challenges
    skip_ratio_pct = round((skipped_challenges / total_challenges * 100.0), 2) if total_challenges > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    if limit == 0:
        issues.append("Challenge ACKs completely disabled (tcp_challenge_ack_limit=0); RFC 5961 protection absent")
        status = "CRITICAL"
    elif limit < 100:
        issues.append(f"TCP Challenge ACK rate limit is overly restrictive ({limit}/s < 100/s); risks dropping legitimate resets")
        status = "WARNING"

    if skipped_challenges > 100 and skip_ratio_pct > 10.0:
        issues.append(
            f"Elevated Challenge ACK drops detected ({skip_ratio_pct}% skipped, {skipped_challenges} dropped); connections risk wedging"
        )
        status = "WARNING"

    recommendations: List[str] = []
    if limit == 0 or limit < 100:
        recommendations.append("Restore safe Challenge ACK rate limit: sysctl -w net.ipv4.tcp_challenge_ack_limit=1000")
    if skipped_challenges > 100 and skip_ratio_pct > 10.0:
        recommendations.append("Increase challenge ACK burst headroom: sysctl -w net.ipv4.tcp_challenge_ack_limit=2147483647")
    if not recommendations:
        recommendations.append("TCP Challenge ACK rate limiter and blind in-window reset protection operating nominally")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_challenge_ack_limit": limit,
            "challenge_acks_sent": challenge_acks,
            "syn_challenges_sent": syn_challenges,
            "challenges_skipped": skipped_challenges,
            "skip_ratio_pct": skip_ratio_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "tcp_challenge_ack": challenge_acks,
            "tcp_syn_challenge": syn_challenges,
            "tcp_ack_skipped_challenge": skipped_challenges,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Challenge ACK Rate Limiter & Reset Guard (Pattern 134)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--challenge-ack-limit-file", type=str, help="Override path to tcp_challenge_ack_limit sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_challenge_ack(
        challenge_ack_limit_file=args.challenge_ack_limit_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP Challenge ACK Guard (Pattern 134) ===")
    print(f"Status:                    {s['status']}")
    print(f"Challenge ACK Rate Limit:  {s['tcp_challenge_ack_limit']}/sec")
    print(f"Challenge ACKs Sent:       {s['challenge_acks_sent']}")
    print(f"SYN Challenges Sent:       {s['syn_challenges_sent']}")
    print(f"Challenges Skipped/Dropped: {s['challenges_skipped']} ({s['skip_ratio_pct']}%)")
    print(f"Segments Delivered:        {c['tcp_delivered']}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
