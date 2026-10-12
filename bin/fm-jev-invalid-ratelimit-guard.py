#!/usr/bin/env python3
"""
bin/fm-jev-invalid-ratelimit-guard.py - Host Network TCP Invalid Segment Rate Limiting & Blind Reset Mitigation Guard (Pattern 173)

Audits kernel TCP invalid segment rate limiting (tcp_invalid_ratelimit) alongside challenge ACK limit
(tcp_challenge_ack_limit), skipped challenge ACK counters (TCPACKSkippedChallenge, TCPACKSkippedSeq),
and reset generation metrics (EstabResets, EmbryonicRsts, InCsumErrors) to verify mitigation of blind
in-window RST injection attacks (RFC 5961) and prevent CPU/network exhaustion.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_netstat(path: str = "/proc/net/netstat") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(0, len(lines), 2):
            if i + 1 >= len(lines):
                break
            headers = lines[i].split()
            values = lines[i + 1].split()
            if len(headers) == len(values) and headers[0] == values[0]:
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def parse_snmp_tcp(path: str = "/proc/net/snmp") -> Dict[str, int]:
    counters: Dict[str, int] = {}
    if not os.path.exists(path):
        return counters
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for i in range(0, len(lines), 2):
            if i + 1 >= len(lines):
                break
            headers = lines[i].split()
            values = lines[i + 1].split()
            if len(headers) == len(values) and headers[0] == "Tcp:":
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return counters


def audit_invalid_ratelimit(
    invalid_ratelimit_file: str = "/proc/sys/net/ipv4/tcp_invalid_ratelimit",
    challenge_ack_file: str = "/proc/sys/net/ipv4/tcp_challenge_ack_limit",
    netstat_file: str = "/proc/net/netstat",
    snmp_file: str = "/proc/net/snmp",
) -> Dict[str, Any]:
    invalid_ratelimit = read_sysctl_int(invalid_ratelimit_file)
    challenge_ack_limit = read_sysctl_int(challenge_ack_file)
    netstat = parse_netstat(netstat_file)
    snmp = parse_snmp_tcp(snmp_file)

    challenge_acks = netstat.get("TCPChallengeACK", 0)
    syn_challenges = netstat.get("TCPSYNChallenge", 0)
    skipped_challenge = netstat.get("TCPACKSkippedChallenge", 0)
    skipped_seq = netstat.get("TCPACKSkippedSeq", 0)
    embryonic_rsts = netstat.get("EmbryonicRsts", 0)

    out_rsts = snmp.get("OutRsts", 0)
    estab_resets = snmp.get("EstabResets", 0)
    in_errs = snmp.get("InErrs", 0)
    in_csum_errors = snmp.get("InCsumErrors", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    # Health evaluation criteria:
    # 1. Check if rate limit is zero (completely unthrottled response to invalid segments)
    if invalid_ratelimit == 0:
        status = "WARNING"
        healthy = False
        issues.append("tcp_invalid_ratelimit is 0 (unthrottled responses to invalid packets, risk of amplification)")

    # 2. Check if excessive dropped challenge ACKs relative to total challenge ACKs
    total_challenges = challenge_acks + syn_challenges
    if total_challenges > 0 and skipped_challenge > total_challenges * 2:
        status = "WARNING"
        healthy = False
        issues.append(f"High challenge ACK drop ratio: {skipped_challenge} dropped vs {total_challenges} sent")

    # 3. Check for severe checksum degradation
    if in_csum_errors > 1000:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated TCP checksum errors: {in_csum_errors}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_invalid_ratelimit_ms": invalid_ratelimit,
        "tcp_challenge_ack_limit": challenge_ack_limit,
        "challenge_acks_sent": challenge_acks,
        "syn_challenges_sent": syn_challenges,
        "skipped_challenge_acks": skipped_challenge,
        "skipped_seq_acks": skipped_seq,
        "embryonic_resets": embryonic_rsts,
        "estab_resets": estab_resets,
        "out_rsts": out_rsts,
        "in_errs": in_errs,
        "in_csum_errors": in_csum_errors,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_invalid_ratelimit": invalid_ratelimit,
            "tcp_challenge_ack_limit": challenge_ack_limit,
        },
        "counters": {
            "TCPChallengeACK": challenge_acks,
            "TCPSYNChallenge": syn_challenges,
            "TCPACKSkippedChallenge": skipped_challenge,
            "TCPACKSkippedSeq": skipped_seq,
            "EmbryonicRsts": embryonic_rsts,
            "EstabResets": estab_resets,
            "OutRsts": out_rsts,
            "InErrs": in_errs,
            "InCsumErrors": in_csum_errors,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Invalid Segment Rate Limiting & Blind Reset Mitigation Guard (Pattern 173)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_invalid_ratelimit()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Invalid Segment Rate Limiting Guard (Pattern 173) - Status: {s['status']}")
    print(f"  tcp_invalid_ratelimit:        {s['tcp_invalid_ratelimit_ms']} ms (nominal: 500 ms)")
    print(f"  tcp_challenge_ack_limit:      {s['tcp_challenge_ack_limit']} / sec")
    print(f"  Challenge ACKs Sent:          {s['challenge_acks_sent']}")
    print(f"  SYN Challenge ACKs Sent:      {s['syn_challenges_sent']}")
    print(f"  Challenge ACKs Skipped:       {s['skipped_challenge_acks']}")
    print(f"  Sequence ACKs Skipped:        {s['skipped_seq_acks']}")
    print(f"  Established Resets:           {s['estab_resets']}")
    print(f"  Embryonic Resets:             {s['embryonic_resets']}")
    print(f"  Total Resets Out:             {s['out_rsts']}")
    print(f"  TCP In Errors:                {s['in_errs']}")
    print(f"  TCP Checksum Errors:          {s['in_csum_errors']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
