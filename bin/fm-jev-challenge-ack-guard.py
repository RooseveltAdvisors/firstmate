#!/usr/bin/env python3
"""
fm-jev-challenge-ack-guard.py - Jev Multi-Agent Host Network TCP Challenge ACK Guard (Pattern 115)

Audits Linux TCP Challenge ACK rate limiting parameters and out-of-window packet challenge counters from
/proc/sys/net/ipv4/tcp_challenge_ack_limit and /proc/net/netstat (TcpExt: TCPChallengeACK, TCPSYNChallenge,
TCPACKSkippedChallenge).

Detects suppressed challenge ACKs (RFC 5961 blind in-window RST/SYN attacks), connection validation freezes,
and low rate-limiting thresholds stalling multi-agent connection recovery.

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

SYSCTL_CHALLENGE_LIMIT = "/proc/sys/net/ipv4/tcp_challenge_ack_limit"
PROC_NETSTAT = "/proc/net/netstat"


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


def audit_challenge_ack(
    limit_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits Challenge ACK limit and skipped challenge counters."""
    limit_path = Path(limit_file) if limit_file else Path(SYSCTL_CHALLENGE_LIMIT)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    limit_val = read_int_file(limit_path)
    tcpext = parse_tcpext_netstat(netstat_path)

    challenge_ack = tcpext.get("TCPChallengeACK", 0)
    syn_challenge = tcpext.get("TCPSYNChallenge", 0)
    skipped_challenge = tcpext.get("TCPACKSkippedChallenge", 0)

    issues: List[str] = []

    if limit_val is not None and limit_val < 1000:
        issues.append(f"Low tcp_challenge_ack_limit ({limit_val}): risk of challenge ACK suppression and CVE-2016-5696 side-channel leak")

    if skipped_challenge > 100:
        issues.append(f"Elevated TCPACKSkippedChallenge ({skipped_challenge} events): challenge ACKs dropped due to rate limit, potentially stalling connection reset validation")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_challenge_ack_limit": limit_val,
            "challenge_acks_sent": challenge_ack,
            "syn_challenges_sent": syn_challenge,
            "skipped_challenges": skipped_challenge,
            "issues": issues,
        },
        "counters": {
            "challenge_ack": challenge_ack,
            "syn_challenge": syn_challenge,
            "skipped_challenge": skipped_challenge,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Challenge ACK Guard (Pattern 115)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--limit-file", type=str, default=None, help="Path to tcp_challenge_ack_limit")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_challenge_ack(
        limit_file=args.limit_file,
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
    print(" Jev Multi-Agent Host Network TCP Challenge ACK Guard (Pattern 115)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Challenge ACK Rate Limit:      {summary['tcp_challenge_ack_limit']:,} / sec")
    print(f" Total Challenge ACKs Sent:     {summary['challenge_acks_sent']:,}")
    print(f" Total SYN Challenges Sent:     {summary['syn_challenges_sent']:,}")
    print(f" Skipped Challenge ACKs:        {summary['skipped_challenges']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Challenge ACK Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'TCP Challenge ACKs Sent':<35} {counters['challenge_ack']:<15} Nominal")
    print(f" {'TCP SYN Challenges Sent':<35} {counters['syn_challenge']:<15} Nominal")
    print(f" {'Challenge ACKs Skipped (Rate Limit)':<35} {counters['skipped_challenge']:<15} {'Nominal' if counters['skipped_challenge'] <= 100 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Challenge ACK Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP Challenge ACK limits and connection validation counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
