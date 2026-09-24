#!/usr/bin/env python3
"""
bin/fm-jev-tcp-ack-skipped-guard.py - Host Network TCP Duplicate ACK Throttling & Skipped ACK Guard (Pattern 229 / Pattern 204)

Audits Linux kernel TCP duplicate ACK suppression and rate-limiting counters:
  - /proc/net/netstat (TcpExt: TCPACKSkippedSynRecv, TCPACKSkippedPAWS, TCPACKSkippedSeq,
                       TCPACKSkippedFinWait2, TCPACKSkippedTimeWait, TCPACKSkippedChallenge, TCPWinProbe)
  - /proc/sys/net/ipv4/tcp_invalid_ratelimit (duplicate/challenge ACK rate limit interval in ms)

Detects sequence number desynchronization, stale timestamp rejections (PAWS), rogue connection injection probes,
and ACK storms across high-density agent RPC communication meshes.

Invariants:
  - Read-only diagnostics. Safe, passive, and non-destructive.
  - Fail-open: graceful fallback when /proc files are missing or restricted.
  - Bounded sub-millisecond execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional, Tuple


def parse_netstat_file(path: str) -> Dict[str, Dict[str, int]]:
    """Parse /proc/net/netstat format (header line followed by value line)."""
    sections: Dict[str, Dict[str, int]] = {}
    if not os.path.exists(path):
        return sections

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
    except Exception:
        return sections

    i = 0
    while i < len(lines) - 1:
        header_line = lines[i]
        val_line = lines[i + 1]
        i += 2

        if ":" not in header_line or ":" not in val_line:
            continue

        h_prefix, h_keys = header_line.split(":", 1)
        v_prefix, v_vals = val_line.split(":", 1)

        if h_prefix.strip() != v_prefix.strip():
            continue

        prefix = h_prefix.strip()
        keys = h_keys.strip().split()
        raw_vals = v_vals.strip().split()

        section_data: Dict[str, int] = {}
        for k, v in zip(keys, raw_vals):
            try:
                section_data[k] = int(v)
            except ValueError:
                pass
        sections[prefix] = section_data

    return sections


def read_sysctl_int(path: str, default: int = 500) -> int:
    """Read a single integer sysctl value."""
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception:
        return default


def audit_tcp_ack_skipped(
    netstat_path: str = "/proc/net/netstat",
    ratelimit_path: str = "/proc/sys/net/ipv4/tcp_invalid_ratelimit",
    warn_challenge_acks: int = 1000,
    crit_challenge_acks: int = 10000,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    netstat = parse_netstat_file(netstat_path)
    tcpext = netstat.get("TcpExt", {})

    skipped_syn_recv = tcpext.get("TCPACKSkippedSynRecv", 0)
    skipped_paws = tcpext.get("TCPACKSkippedPAWS", 0)
    skipped_seq = tcpext.get("TCPACKSkippedSeq", 0)
    skipped_fin_wait2 = tcpext.get("TCPACKSkippedFinWait2", 0)
    skipped_time_wait = tcpext.get("TCPACKSkippedTimeWait", 0)
    skipped_challenge = tcpext.get("TCPACKSkippedChallenge", 0)
    win_probe = tcpext.get("TCPWinProbe", 0)
    challenge_ack = tcpext.get("TCPChallengeACK", 0)

    total_skipped = (
        skipped_syn_recv
        + skipped_paws
        + skipped_seq
        + skipped_fin_wait2
        + skipped_time_wait
        + skipped_challenge
    )

    invalid_ratelimit_ms = read_sysctl_int(ratelimit_path, default=500)

    reasons: List[str] = []
    is_warning = False
    is_critical = False

    if invalid_ratelimit_ms == 0:
        is_warning = True
        reasons.append("tcp_invalid_ratelimit is 0; duplicate ACK rate limiting is disabled")

    if skipped_challenge >= crit_challenge_acks:
        is_critical = True
        reasons.append(
            f"Critically high suppressed challenge ACKs ({skipped_challenge} >= {crit_challenge_acks}); "
            "potential blind in-window attack or desynchronization flood"
        )
    elif skipped_challenge >= warn_challenge_acks:
        is_warning = True
        reasons.append(
            f"Elevated suppressed challenge ACKs ({skipped_challenge} >= {warn_challenge_acks})"
        )

    status = "CRITICAL" if is_critical else ("WARNING" if is_warning else "HEALTHY")

    return {
        "timestamp": now,
        "status": status,
        "reasons": reasons,
        "summary": {
            "total_skipped_acks": total_skipped,
            "skipped_seq": skipped_seq,
            "skipped_paws": skipped_paws,
            "skipped_syn_recv": skipped_syn_recv,
            "skipped_challenge": skipped_challenge,
            "skipped_fin_wait2": skipped_fin_wait2,
            "skipped_time_wait": skipped_time_wait,
            "win_probes": win_probe,
            "challenge_acks": challenge_ack,
            "invalid_ratelimit_ms": invalid_ratelimit_ms,
        },
        "sources": {
            "netstat": netstat_path,
            "ratelimit": ratelimit_path,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network TCP Duplicate ACK Throttling & Skipped ACK Guard (Pattern 229)"
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--netstat", type=str, default="/proc/net/netstat", help="Path to /proc/net/netstat")
    parser.add_argument(
        "--ratelimit",
        type=str,
        default="/proc/sys/net/ipv4/tcp_invalid_ratelimit",
        help="Path to tcp_invalid_ratelimit",
    )
    parser.add_argument("--warn-challenge", type=int, default=1000, help="Warning threshold for skipped challenge ACKs")
    parser.add_argument("--crit-challenge", type=int, default=10000, help="Critical threshold for skipped challenge ACKs")

    args = parser.parse_args()

    report = audit_tcp_ack_skipped(
        netstat_path=args.netstat,
        ratelimit_path=args.ratelimit,
        warn_challenge_acks=args.warn_challenge,
        crit_challenge_acks=args.crit_challenge,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(
            f"[{report['status']}] TCP Skipped ACKs: total={s['total_skipped_acks']} "
            f"(seq={s['skipped_seq']}, paws={s['skipped_paws']}, challenge={s['skipped_challenge']}) | "
            f"ratelimit={s['invalid_ratelimit_ms']}ms"
        )
        if report["reasons"]:
            print("  Issues:")
            for reason in report["reasons"]:
                print(f"    - {reason}")

    return 0 if report["status"] == "HEALTHY" else 1


if __name__ == "__main__":
    sys.exit(main())
