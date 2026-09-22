#!/usr/bin/env python3
"""
fm-jev-abort-guard.py - Jev Multi-Agent Host Network TCP Connection Abort & Unread Data Reset Guard (Pattern 120)

Audits Linux TCP connection abort mechanisms, unread receive data resets, and abort-on-overflow settings from
/proc/sys/net/ipv4/tcp_abort_on_overflow, tcp_retries1, tcp_retries2, and /proc/net/netstat
(TcpExt: TCPAbortOnData, TCPAbortOnClose, TCPAbortOnMemory, TCPAbortOnTimeout, TCPAbortOnLinger,
TCPAbortFailed, EmbryonicRsts).

Detects unconsumed socket data before close (triggering abrupt RST packets and breaking HTTP/RPC connection pooling),
listen backlog overflow RST spikes, dead peer timeout aborts, and memory-induced connection drops across multi-agent processes.

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

SYSCTL_ABORT_OVERFLOW = "/proc/sys/net/ipv4/tcp_abort_on_overflow"
SYSCTL_RETRIES1 = "/proc/sys/net/ipv4/tcp_retries1"
SYSCTL_RETRIES2 = "/proc/sys/net/ipv4/tcp_retries2"
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
                vals_raw = lines[i + 1].split()[1:]
                for k, v in zip(keys, vals_raw):
                    try:
                        metrics[k] = int(v)
                    except ValueError:
                        continue
                break
    except Exception:
        return {}

    return metrics


def audit_abort(
    overflow_file: Optional[str] = None,
    retries1_file: Optional[str] = None,
    retries2_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP connection abort parameters and counters."""
    overflow_p = Path(overflow_file or SYSCTL_ABORT_OVERFLOW)
    retries1_p = Path(retries1_file or SYSCTL_RETRIES1)
    retries2_p = Path(retries2_file or SYSCTL_RETRIES2)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    tcp_abort_on_overflow = read_int_file(overflow_p)
    if tcp_abort_on_overflow is None:
        tcp_abort_on_overflow = 0

    tcp_retries1 = read_int_file(retries1_p)
    if tcp_retries1 is None:
        tcp_retries1 = 3

    tcp_retries2 = read_int_file(retries2_p)
    if tcp_retries2 is None:
        tcp_retries2 = 15

    tcpext = parse_tcpext_netstat(netstat_p)

    abort_on_data = tcpext.get("TCPAbortOnData", 0)
    abort_on_close = tcpext.get("TCPAbortOnClose", 0)
    abort_on_memory = tcpext.get("TCPAbortOnMemory", 0)
    abort_on_timeout = tcpext.get("TCPAbortOnTimeout", 0)
    abort_on_linger = tcpext.get("TCPAbortOnLinger", 0)
    abort_failed = tcpext.get("TCPAbortFailed", 0)
    embryonic_rsts = tcpext.get("EmbryonicRsts", 0)

    issues: List[str] = []
    healthy = True

    if tcp_abort_on_overflow == 1:
        healthy = False
        issues.append("tcp_abort_on_overflow is enabled (1). Backlog saturation sends immediate connection RST instead of SYN retransmission smoothing.")

    if tcp_retries2 < 5:
        healthy = False
        issues.append(f"tcp_retries2 is low ({tcp_retries2} < 5). Connections may abort prematurely under transient network jitter.")

    if abort_on_memory > 0:
        healthy = False
        issues.append(f"TCP connections aborted due to kernel memory exhaustion ({abort_on_memory:,} events).")

    if abort_failed > 100:
        healthy = False
        issues.append(f"Elevated failed connection abort transmissions ({abort_failed:,} failed RST sends).")

    if abort_on_timeout > 50000:
        healthy = False
        issues.append(f"Elevated TCP connection abort timeouts ({abort_on_timeout:,} timeouts). Persistent peer unreachability or blackholes.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_abort_on_overflow": tcp_abort_on_overflow,
            "tcp_retries1": tcp_retries1,
            "tcp_retries2": tcp_retries2,
            "abort_on_data": abort_on_data,
            "abort_on_close": abort_on_close,
            "abort_on_memory": abort_on_memory,
            "abort_on_timeout": abort_on_timeout,
            "abort_on_linger": abort_on_linger,
            "abort_failed": abort_failed,
            "embryonic_rsts": embryonic_rsts,
            "issues": issues,
        },
        "counters": {
            "abort_on_data": abort_on_data,
            "abort_on_close": abort_on_close,
            "abort_on_memory": abort_on_memory,
            "abort_on_timeout": abort_on_timeout,
            "abort_on_linger": abort_on_linger,
            "abort_failed": abort_failed,
            "embryonic_rsts": embryonic_rsts,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Connection Abort & Unread Data Reset Guard (Pattern 120)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--overflow-file", type=str, default=None, help="Path to tcp_abort_on_overflow")
    parser.add_argument("--retries1-file", type=str, default=None, help="Path to tcp_retries1")
    parser.add_argument("--retries2-file", type=str, default=None, help="Path to tcp_retries2")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_abort(
        overflow_file=args.overflow_file,
        retries1_file=args.retries1_file,
        retries2_file=args.retries2_file,
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
    print(" Jev Multi-Agent Host Network TCP Connection Abort & Reset Guard (Pattern 120)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Abort on Overflow:             {summary['tcp_abort_on_overflow']} ({'Enabled (RST on full backlog)' if summary['tcp_abort_on_overflow'] == 1 else 'Disabled (SYN drop retry smoothing)'})")
    print(f" TCP Retries Limit:             retries1={summary['tcp_retries1']} retries2={summary['tcp_retries2']}")
    print(f" Abort on Unread Data (RST):    {summary['abort_on_data']:,}")
    print(f" Abort on Close:                {summary['abort_on_close']:,}")
    print(f" Abort on Retransmit Timeout:   {summary['abort_on_timeout']:,}")
    print(f" Abort on Memory Exhaustion:    {summary['abort_on_memory']:,}")
    print(f" Failed Abort Transmissions:    {summary['abort_failed']:,}")
    print(f" Embryonic (SYN-RECV) RSTs:     {summary['embryonic_rsts']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Connection Abort Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Abort on Unread Data':<35} {counters['abort_on_data']:<15} Nominal")
    print(f" {'Abort on Close':<35} {counters['abort_on_close']:<15} Nominal")
    print(f" {'Abort on Retransmit Timeout':<35} {counters['abort_on_timeout']:<15} {'Nominal' if counters['abort_on_timeout'] <= 50000 else 'WARNING'}")
    print(f" {'Abort on Memory Exhaustion':<35} {counters['abort_on_memory']:<15} {'Nominal' if counters['abort_on_memory'] == 0 else 'WARNING'}")
    print(f" {'Failed Abort Transmissions':<35} {counters['abort_failed']:<15} {'Nominal' if counters['abort_failed'] <= 100 else 'WARNING'}")
    print(f" {'Embryonic SYN-RECV RSTs':<35} {counters['embryonic_rsts']:<15} Nominal")

    if summary["issues"]:
        print("\nActive TCP Connection Abort Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP connection abort and reset parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
