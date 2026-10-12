#!/usr/bin/env python3
"""
fm-jev-syn-scramble-guard.py - Jev Multi-Agent Host Network TCP SYN/FIN Scrambling Guard (Pattern 125)

Audits Linux TCP TIME-WAIT assassination protection (/proc/sys/net/ipv4/tcp_rfc1337),
Protection Against Wrapped Sequences (PAWS) timestamps (/proc/sys/net/ipv4/tcp_timestamps),
listen queue abort-on-overflow (/proc/sys/net/ipv4/tcp_abort_on_overflow),
and kernel TCP reset / embryonic connection counters from /proc/net/snmp and /proc/net/netstat.

In multi-agent telemetry and RPC grids with high connection churn across ephemeral ports,
protects against out-of-order segment corruption, TIME-WAIT socket assassination by stray RSTs,
and listen backlog reset storms.

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

SYSCTL_RFC1337 = "/proc/sys/net/ipv4/tcp_rfc1337"
SYSCTL_TIMESTAMPS = "/proc/sys/net/ipv4/tcp_timestamps"
SYSCTL_ABORT_OVERFLOW = "/proc/sys/net/ipv4/tcp_abort_on_overflow"
SYSCTL_SYN_RETRIES = "/proc/sys/net/ipv4/tcp_syn_retries"
SYSCTL_SYNACK_RETRIES = "/proc/sys/net/ipv4/tcp_synack_retries"

PROC_SNMP = "/proc/net/snmp"
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
    """Parses paired header/metric lines from /proc/net/snmp or /proc/net/netstat."""
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


def audit_syn_scramble(
    rfc1337_file: Optional[str] = None,
    timestamps_file: Optional[str] = None,
    abort_overflow_file: Optional[str] = None,
    syn_retries_file: Optional[str] = None,
    synack_retries_file: Optional[str] = None,
    snmp_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP SYN/FIN scrambling and connection reset parameters."""
    rfc1337_p = Path(rfc1337_file or SYSCTL_RFC1337)
    timestamps_p = Path(timestamps_file or SYSCTL_TIMESTAMPS)
    abort_overflow_p = Path(abort_overflow_file or SYSCTL_ABORT_OVERFLOW)
    syn_retries_p = Path(syn_retries_file or SYSCTL_SYN_RETRIES)
    synack_retries_p = Path(synack_retries_file or SYSCTL_SYNACK_RETRIES)

    snmp_p = Path(snmp_file or PROC_SNMP)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    rfc1337 = read_int_file(rfc1337_p)
    if rfc1337 is None:
        rfc1337 = 0

    timestamps = read_int_file(timestamps_p)
    if timestamps is None:
        timestamps = 1

    abort_overflow = read_int_file(abort_overflow_p)
    if abort_overflow is None:
        abort_overflow = 0

    syn_retries = read_int_file(syn_retries_p)
    if syn_retries is None:
        syn_retries = 6

    synack_retries = read_int_file(synack_retries_p)
    if synack_retries is None:
        synack_retries = 5

    snmp_tcp = parse_proc_pairs(snmp_p, "Tcp")
    netstat_tcp = parse_proc_pairs(netstat_p, "TcpExt")

    attempt_fails = snmp_tcp.get("AttemptFails", 0)
    estab_resets = snmp_tcp.get("EstabResets", 0)
    in_errs = snmp_tcp.get("InErrs", 0)
    out_rsts = snmp_tcp.get("OutRsts", 0)
    curr_estab = snmp_tcp.get("CurrEstab", 0)

    embryonic_rsts = netstat_tcp.get("EmbryonicRsts", 0)
    abort_on_timeout = netstat_tcp.get("TCPAbortOnTimeout", 0)
    abort_failed = netstat_tcp.get("TCPAbortFailed", 0)
    abort_on_memory = netstat_tcp.get("TCPAbortOnMemory", 0)

    issues: List[str] = []
    healthy = True

    if timestamps == 0:
        healthy = False
        issues.append("TCP timestamps (PAWS) disabled (tcp_timestamps = 0). Sequence number wrapping can corrupt long-lived or recycled connections.")

    if abort_overflow == 1:
        issues.append("tcp_abort_on_overflow is enabled (1). Full listen queues trigger abrupt RST drops rather than SYN exponential backoff.")

    if abort_on_memory > 0:
        healthy = False
        issues.append(f"Kernel aborted {abort_on_memory:,} TCP sockets due to memory pressure (TCPAbortOnMemory).")

    if abort_failed > 500:
        healthy = False
        issues.append(f"High TCP abort failures ({abort_failed:,} failures). Kernel unable to send reset or free socket state.")

    if embryonic_rsts > 5000:
        issues.append(f"Elevated embryonic connection resets ({embryonic_rsts:,} embryonic RSTs). Port probe or half-open flood detected.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "rfc1337": rfc1337,
            "timestamps": timestamps,
            "abort_on_overflow": abort_overflow,
            "syn_retries": syn_retries,
            "synack_retries": synack_retries,
            "estab_resets": estab_resets,
            "attempt_fails": attempt_fails,
            "out_rsts": out_rsts,
            "embryonic_rsts": embryonic_rsts,
            "abort_on_timeout": abort_on_timeout,
            "abort_failed": abort_failed,
            "issues": issues,
        },
        "counters": {
            "attempt_fails": attempt_fails,
            "estab_resets": estab_resets,
            "in_errs": in_errs,
            "out_rsts": out_rsts,
            "curr_estab": curr_estab,
            "embryonic_rsts": embryonic_rsts,
            "abort_on_timeout": abort_on_timeout,
            "abort_failed": abort_failed,
            "abort_on_memory": abort_on_memory,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP SYN/FIN Scrambling Guard (Pattern 125)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--rfc1337-file", type=str, default=None, help="Path to tcp_rfc1337")
    parser.add_argument("--timestamps-file", type=str, default=None, help="Path to tcp_timestamps")
    parser.add_argument("--abort-overflow-file", type=str, default=None, help="Path to tcp_abort_on_overflow")
    parser.add_argument("--syn-retries-file", type=str, default=None, help="Path to tcp_syn_retries")
    parser.add_argument("--synack-retries-file", type=str, default=None, help="Path to tcp_synack_retries")
    parser.add_argument("--snmp-file", type=str, default=None, help="Path to /proc/net/snmp")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_syn_scramble(
        rfc1337_file=args.rfc1337_file,
        timestamps_file=args.timestamps_file,
        abort_overflow_file=args.abort_overflow_file,
        syn_retries_file=args.syn_retries_file,
        synack_retries_file=args.synack_retries_file,
        snmp_file=args.snmp_file,
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
    print(" Jev Multi-Agent Host Network TCP SYN/FIN Scrambling Guard (Pattern 125)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" RFC 1337 TIME-WAIT Protect:    {summary['rfc1337']} ({'Disabled (Linux Default)' if summary['rfc1337'] == 0 else 'Enabled (Drop RST in TIME-WAIT)'})")
    print(f" TCP Timestamps (PAWS):         {summary['timestamps']} ({'Enabled (PAWS Active)' if summary['timestamps'] == 1 else 'Disabled (Danger of Scrambled Segments)'})")
    print(f" Abort on Overflow:             {summary['abort_on_overflow']} ({'Disabled (SYN Retry)' if summary['abort_on_overflow'] == 0 else 'Enabled (Immediate RST)'})")
    print(f" SYN / SYN-ACK Retries:         {summary['syn_retries']} / {summary['synack_retries']}")
    print(f" Established Connections:       {counters['curr_estab']}")
    print(f" Established Resets (EstabReset): {counters['estab_resets']:,}")
    print(f" Attempt Failures (AttemptFail): {counters['attempt_fails']:,}")
    print(f" Total Outgoing Resets (OutRsts): {counters['out_rsts']:,}")
    print(f" Embryonic Resets:              {counters['embryonic_rsts']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'TCP Scrambling / Reset Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'tcp_timestamps (PAWS)':<35} {summary['timestamps']:<15} {'Nominal' if summary['timestamps'] == 1 else 'WARNING'}")
    print(f" {'tcp_abort_on_overflow':<35} {summary['abort_on_overflow']:<15} {'Nominal' if summary['abort_on_overflow'] == 0 else 'Notice'}")
    print(f" {'tcp_rfc1337':<35} {summary['rfc1337']:<15} Nominal")
    print(f" {'Abort on Memory Pressure':<35} {counters['abort_on_memory']:<15} {'Nominal' if counters['abort_on_memory'] == 0 else 'WARNING'}")
    print(f" {'Abort Failures':<35} {counters['abort_failed']:<15} {'Nominal' if counters['abort_failed'] <= 500 else 'WARNING'}")
    print(f" {'Embryonic Resets':<35} {counters['embryonic_rsts']:<15} {'Nominal' if counters['embryonic_rsts'] <= 5000 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP Reset / Scrambling Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP SYN/FIN scrambling parameters, PAWS timestamps, and reset counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
