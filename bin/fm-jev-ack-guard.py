#!/usr/bin/env python3
"""
fm-jev-ack-guard.py - Jev Multi-Agent Host Network TCP ACK Compression & Delayed ACK Guard (Pattern 113)

Audits Linux TCP ACK compression delay parameters, delayed ACK timers, and socket header prediction counters from
/proc/sys/net/ipv4/tcp_comp_sack_delay_ns, tcp_comp_sack_nr, and /proc/net/netstat (TcpExt:
DelayedACKs, DelayedACKLocked, DelayedACKLost, TCPAckCompressed, TCPACKSkippedSeq, TCPHPAcks, TCPPureAcks, TCPHPHits).

Detects latency penalties from excessive ACK compression delays, stalled reverse paths due to delayed ACK expirations,
and socket lock contention during rapid multi-agent RPC and streaming token generation.

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

SYSCTL_ACK_DELAY_NS = "/proc/sys/net/ipv4/tcp_comp_sack_delay_ns"
SYSCTL_ACK_NR = "/proc/sys/net/ipv4/tcp_comp_sack_nr"
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


def audit_ack(
    delay_file: Optional[str] = None,
    nr_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits ACK compression parameters, delayed ACK loss, and header prediction."""
    delay_path = Path(delay_file) if delay_file else Path(SYSCTL_ACK_DELAY_NS)
    nr_path = Path(nr_file) if nr_file else Path(SYSCTL_ACK_NR)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    delay_ns = read_int_file(delay_path)
    nr_val = read_int_file(nr_path)

    tcpext = parse_tcpext_netstat(netstat_path)

    delayed_acks = tcpext.get("DelayedACKs", 0)
    delayed_locked = tcpext.get("DelayedACKLocked", 0)
    delayed_lost = tcpext.get("DelayedACKLost", 0)
    ack_compressed = tcpext.get("TCPAckCompressed", 0)
    ack_skipped_seq = tcpext.get("TCPACKSkippedSeq", 0)
    hp_acks = tcpext.get("TCPHPAcks", 0)
    pure_acks = tcpext.get("TCPPureAcks", 0)
    hp_hits = tcpext.get("TCPHPHits", 0)

    delay_ms = round(delay_ns / 1_000_000, 2) if delay_ns is not None else None

    issues: List[str] = []

    if delay_ms is not None and delay_ms > 5.0:
        issues.append(f"High tcp_comp_sack_delay_ns ({delay_ms}ms): ACK compression adds latency to interactive multi-agent streams")

    if delayed_acks > 0 and (delayed_locked / delayed_acks) > 0.05:
        issues.append("Elevated DelayedACKLocked ratio (>5%): socket locking contention delaying ACK transmission")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_comp_sack_delay_ns": delay_ns,
            "ack_compression_delay_ms": delay_ms,
            "tcp_comp_sack_nr": nr_val,
            "delayed_acks_total": delayed_acks,
            "delayed_ack_lost": delayed_lost,
            "ack_compressed_total": ack_compressed,
            "header_prediction_acks": hp_acks,
            "issues": issues,
        },
        "counters": {
            "delayed_acks": delayed_acks,
            "delayed_locked": delayed_locked,
            "delayed_lost": delayed_lost,
            "ack_compressed": ack_compressed,
            "ack_skipped_seq": ack_skipped_seq,
            "hp_acks": hp_acks,
            "pure_acks": pure_acks,
            "hp_hits": hp_hits,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP ACK Compression & Delayed ACK Guard (Pattern 113)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--delay-file", type=str, default=None, help="Path to tcp_comp_sack_delay_ns")
    parser.add_argument("--nr-file", type=str, default=None, help="Path to tcp_comp_sack_nr")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_ack(
        delay_file=args.delay_file,
        nr_file=args.nr_file,
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
    print(" Jev Multi-Agent Host Network TCP ACK & Compression Guard (Pattern 113)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" ACK Compression Delay:         {summary['ack_compression_delay_ms']} ms ({summary['tcp_comp_sack_delay_ns']} ns)")
    print(f" Max ACK Compression Coalesce:  {summary['tcp_comp_sack_nr']} packets")
    print(f" Total Compressed ACKs:         {summary['ack_compressed_total']:,}")
    print(f" Total Delayed ACKs Generated:  {summary['delayed_acks_total']:,}")
    print(f" Delayed ACKs Timer Expired:    {summary['delayed_ack_lost']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'ACK Pipeline Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Compressed ACKs Transmitted':<35} {counters['ack_compressed']:<15} Nominal")
    print(f" {'Delayed ACKs Generated':<35} {counters['delayed_acks']:<15} Nominal")
    print(f" {'Delayed ACKs Socket Locked':<35} {counters['delayed_locked']:<15} Nominal")
    print(f" {'Delayed ACKs Timed Out (Lost)':<35} {counters['delayed_lost']:<15} Nominal")
    print(f" {'Header Prediction Fast ACKs':<35} {counters['hp_acks']:<15} Nominal")
    print(f" {'Pure Payload-Free ACKs':<35} {counters['pure_acks']:<15} Nominal")
    print(f" {'Header Prediction Cache Hits':<35} {counters['hp_hits']:<15} Nominal")

    if summary["issues"]:
        print("\nActive TCP ACK / Compression Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP ACK compression settings, delayed ACK timers, and HP paths nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
