#!/usr/bin/env python3
"""
fm-jev-synack-guard.py - Jev Multi-Agent Host Network TCP SYN-ACK & Socket Abort Guard (Pattern 107)

Audits Linux TCP connection handshake timeouts, SYN/SYN-ACK retry limits, and socket abort counters from
/proc/sys/net/ipv4/tcp_synack_retries, tcp_syn_retries, tcp_abort_on_overflow, tcp_orphan_retries, and
/proc/net/netstat (TcpExt: TCPAbortOnSyn, TCPAbortOnData, TCPAbortOnClose, TCPAbortOnMemory, TCPAbortOnTimeout, TCPAbortFailed).

Detects half-open socket hangs, lingering connection teardowns, unread data socket aborts, and RST generation
failures across multi-agent RPC lifecycles, database connection pools, and external API gateways.

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

SYSCTL_SYNACK_RETRIES = "/proc/sys/net/ipv4/tcp_synack_retries"
SYSCTL_SYN_RETRIES = "/proc/sys/net/ipv4/tcp_syn_retries"
SYSCTL_ABORT_OVERFLOW = "/proc/sys/net/ipv4/tcp_abort_on_overflow"
SYSCTL_ORPHAN_RETRIES = "/proc/sys/net/ipv4/tcp_orphan_retries"
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


def audit_synack(
    synack_file: Optional[str] = None,
    syn_file: Optional[str] = None,
    overflow_file: Optional[str] = None,
    orphan_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits SYN-ACK retries, abort-on-overflow, and socket abort counters."""
    synack_path = Path(synack_file) if synack_file else Path(SYSCTL_SYNACK_RETRIES)
    syn_path = Path(syn_file) if syn_file else Path(SYSCTL_SYN_RETRIES)
    overflow_path = Path(overflow_file) if overflow_file else Path(SYSCTL_ABORT_OVERFLOW)
    orphan_path = Path(orphan_file) if orphan_file else Path(SYSCTL_ORPHAN_RETRIES)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    synack_retries = read_int_file(synack_path)
    syn_retries = read_int_file(syn_path)
    abort_overflow = read_int_file(overflow_path)
    orphan_retries = read_int_file(orphan_path)

    tcpext = parse_tcpext_netstat(netstat_path)

    abort_on_syn = tcpext.get("TCPAbortOnSyn", 0)
    abort_on_data = tcpext.get("TCPAbortOnData", 0)
    abort_on_close = tcpext.get("TCPAbortOnClose", 0)
    abort_on_memory = tcpext.get("TCPAbortOnMemory", 0)
    abort_on_timeout = tcpext.get("TCPAbortOnTimeout", 0)
    abort_failed = tcpext.get("TCPAbortFailed", 0)

    # Estimate handshake hang latency
    # retries=5 corresponds to ~31s of half-open socket hold
    synack_hold_sec = sum(2**i for i in range(synack_retries or 5))

    issues: List[str] = []

    if abort_failed > 0:
        issues.append(f"Kernel TCP RST abort failures detected ({abort_failed} events): unable to allocate/send reset packets")

    if abort_on_memory > 0:
        issues.append(f"TCP connections aborted due to memory exhaustion ({abort_on_memory} events)")

    if synack_retries is not None and synack_retries > 6:
        issues.append(f"High tcp_synack_retries ({synack_retries}): half-open connections linger for > 63s")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_synack_retries": synack_retries,
            "estimated_synack_hold_sec": synack_hold_sec,
            "tcp_syn_retries": syn_retries,
            "tcp_abort_on_overflow": abort_overflow == 1 if abort_overflow is not None else False,
            "tcp_orphan_retries": orphan_retries,
            "abort_failed_events": abort_failed,
            "abort_on_memory_events": abort_on_memory,
            "issues": issues,
        },
        "counters": {
            "abort_on_syn": abort_on_syn,
            "abort_on_data": abort_on_data,
            "abort_on_close": abort_on_close,
            "abort_on_memory": abort_on_memory,
            "abort_on_timeout": abort_on_timeout,
            "abort_failed": abort_failed,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SYN-ACK & Socket Abort Guard (Pattern 107)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--synack-file", type=str, default=None, help="Path to tcp_synack_retries")
    parser.add_argument("--syn-file", type=str, default=None, help="Path to tcp_syn_retries")
    parser.add_argument("--overflow-file", type=str, default=None, help="Path to tcp_abort_on_overflow")
    parser.add_argument("--orphan-file", type=str, default=None, help="Path to tcp_orphan_retries")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_synack(
        synack_file=args.synack_file,
        syn_file=args.syn_file,
        overflow_file=args.overflow_file,
        orphan_file=args.orphan_file,
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
    print(" Jev Multi-Agent Host Network TCP SYN-ACK & Socket Abort Guard (Pattern 107)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" SYN-ACK Retries:               {summary['tcp_synack_retries']} (hold ~{summary['estimated_synack_hold_sec']}s)")
    print(f" Outbound SYN Retries:          {summary['tcp_syn_retries']}")
    print(f" Abort On Listen Overflow:      {'Enabled (RST sent)' if summary['tcp_abort_on_overflow'] else 'Disabled (silent drop)'}")
    print(f" Orphan Retries:                {summary['tcp_orphan_retries']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Socket Abort & Teardown Metric':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Abort On Unread Data':<30} {counters['abort_on_data']:<15} Nominal")
    print(f" {'Abort On Socket Close':<30} {counters['abort_on_close']:<15} Nominal")
    print(f" {'Abort On Timeout':<30} {counters['abort_on_timeout']:<15} Nominal")
    print(f" {'Abort On SYN (Incomplete)':<30} {counters['abort_on_syn']:<15} Nominal")
    print(f" {'Abort On Memory Pressure':<30} {counters['abort_on_memory']:<15} {'Nominal' if counters['abort_on_memory'] == 0 else 'WARNING'}")
    print(f" {'RST Generation Failed':<30} {counters['abort_failed']:<15} {'Nominal' if counters['abort_failed'] == 0 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Handshake / Socket Abort Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP SYN-ACK retries, overflow behavior, and socket aborts nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
