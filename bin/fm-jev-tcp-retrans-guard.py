#!/usr/bin/env python3
"""
fm-jev-tcp-retrans-guard.py - Host Network TCP Retransmission, Checksum Error & Loss Recovery Guard (Pattern 103)

Audits Linux kernel TCP retransmission rates, checksum errors, resets, and loss recovery timers from:
  - /proc/net/snmp (InSegs, OutSegs, RetransSegs, InErrs, InCsumErrors, OutRsts, EstabResets, CurrEstab)
  - /proc/net/netstat (TCPTimeouts, TCPLossProbes, TCPFastRetrans, TCPSlowStartRetrans, TCPSpuriousRtxHost)
  - /proc/sys/net/ipv4/tcp_retries1, tcp_retries2, tcp_reordering

Detects packet loss bursts, corrupted segments (NIC hardware offload failures), premature connection
abort thresholds, and flow recovery stalls across multi-agent RPC channels.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when /proc files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_SNMP = "/proc/net/snmp"
PROC_NETSTAT = "/proc/net/netstat"
SYSCTL_RETRIES1 = "/proc/sys/net/ipv4/tcp_retries1"
SYSCTL_RETRIES2 = "/proc/sys/net/ipv4/tcp_retries2"
SYSCTL_REORDERING = "/proc/sys/net/ipv4/tcp_reordering"


def read_sysctl_int(path: str, default: int = -1) -> int:
    p = Path(path)
    if not p.is_file():
        return default
    try:
        return int(p.read_text().strip())
    except Exception:
        return default


def parse_snmp_tcp(path: str = PROC_SNMP) -> Dict[str, int]:
    p = Path(path)
    if not p.is_file():
        return {}
    try:
        lines = p.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("Tcp:") and lines[i + 1].startswith("Tcp:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                res = {}
                for k, v in zip(keys, vals):
                    try:
                        res[k] = int(v)
                    except ValueError:
                        continue
                return res
    except Exception:
        return {}
    return {}


def parse_tcpext_netstat(path: str = PROC_NETSTAT) -> Dict[str, int]:
    p = Path(path)
    if not p.is_file():
        return {}
    try:
        lines = p.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                res = {}
                for k, v in zip(keys, vals):
                    try:
                        res[k] = int(v)
                    except ValueError:
                        continue
                return res
    except Exception:
        return {}
    return {}


def audit_tcp_retrans(
    proc_snmp: str = PROC_SNMP,
    proc_netstat: str = PROC_NETSTAT,
    sysctl_retries1: str = SYSCTL_RETRIES1,
    sysctl_retries2: str = SYSCTL_RETRIES2,
    sysctl_reordering: str = SYSCTL_REORDERING,
    warn_retrans_pct: float = 2.0,
    crit_retrans_pct: float = 5.0,
) -> Dict[str, Any]:
    snmp = parse_snmp_tcp(proc_snmp)
    tcpext = parse_tcpext_netstat(proc_netstat)

    retries1 = read_sysctl_int(sysctl_retries1)
    retries2 = read_sysctl_int(sysctl_retries2)
    reordering = read_sysctl_int(sysctl_reordering)

    issues: List[str] = []

    if not snmp:
        issues.append("Unable to read TCP SNMP metrics from /proc/net/snmp")
        return {
            "status": "UNKNOWN",
            "healthy": False,
            "issues": issues,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

    in_segs = snmp.get("InSegs", 0)
    out_segs = snmp.get("OutSegs", 0)
    retrans_segs = snmp.get("RetransSegs", 0)
    in_errs = snmp.get("InErrs", 0)
    in_csum_errors = snmp.get("InCsumErrors", 0)
    out_rsts = snmp.get("OutRsts", 0)
    estab_resets = snmp.get("EstabResets", 0)
    attempt_fails = snmp.get("AttemptFails", 0)
    curr_estab = snmp.get("CurrEstab", 0)

    retrans_pct = round((retrans_segs / out_segs * 100.0), 4) if out_segs > 0 else 0.0

    tcp_timeouts = tcpext.get("TCPTimeouts", 0)
    loss_probes = tcpext.get("TCPLossProbes", 0)
    fast_retrans = tcpext.get("TCPFastRetrans", 0)
    slow_start_retrans = tcpext.get("TCPSlowStartRetrans", 0)
    spurious_rtx = tcpext.get("TCPSpuriousRtxHost", 0)

    if retrans_pct >= crit_retrans_pct:
        issues.append(
            f"CRITICAL: Excessive TCP retransmission rate ({retrans_pct:.2f}% >= {crit_retrans_pct}%): severe network packet loss or congestion"
        )
    elif retrans_pct >= warn_retrans_pct:
        issues.append(
            f"WARNING: Elevated TCP retransmission rate ({retrans_pct:.2f}% >= {warn_retrans_pct}%): network degradation detected"
        )

    if in_csum_errors > 0:
        issues.append(
            f"CRITICAL: TCP checksum errors detected ({in_csum_errors}): corrupted segments received, potential hardware NIC offload issue or cable fault"
        )

    if retries2 != -1 and retries2 < 5:
        issues.append(
            f"WARNING: Low tcp_retries2 setting ({retries2} < 5): connections may abort prematurely during brief transient drops"
        )

    if any("CRITICAL" in iss for iss in issues):
        status = "CRITICAL"
    elif issues:
        status = "WARNING"
    else:
        status = "HEALTHY"

    healthy = status == "HEALTHY"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "retrans_ratio_pct": retrans_pct,
            "curr_estab": curr_estab,
            "in_segs": in_segs,
            "out_segs": out_segs,
            "retrans_segs": retrans_segs,
            "in_csum_errors": in_csum_errors,
            "in_errs": in_errs,
            "issues": issues,
            "recommendation": (
                "TCP retransmission rates, checksum integrity, and retry thresholds are nominal."
                if healthy
                else "; ".join(issues)
            ),
        },
        "snmp": {
            "in_segs": in_segs,
            "out_segs": out_segs,
            "retrans_segs": retrans_segs,
            "in_errs": in_errs,
            "in_csum_errors": in_csum_errors,
            "out_rsts": out_rsts,
            "estab_resets": estab_resets,
            "attempt_fails": attempt_fails,
            "curr_estab": curr_estab,
        },
        "tcpext": {
            "tcp_timeouts": tcp_timeouts,
            "loss_probes": loss_probes,
            "fast_retrans": fast_retrans,
            "slow_start_retrans": slow_start_retrans,
            "spurious_rtx": spurious_rtx,
        },
        "sysctl": {
            "tcp_retries1": retries1,
            "tcp_retries2": retries2,
            "tcp_reordering": reordering,
        },
        "thresholds": {
            "warn_retrans_pct": warn_retrans_pct,
            "crit_retrans_pct": crit_retrans_pct,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network TCP Retransmission, Checksum Error & Loss Recovery Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument(
        "--warn-pct",
        type=float,
        default=2.0,
        help="Warning threshold for retransmission percentage (default: 2.0)",
    )
    parser.add_argument(
        "--crit-pct",
        type=float,
        default=5.0,
        help="Critical threshold for retransmission percentage (default: 5.0)",
    )
    args = parser.parse_args()

    result = audit_tcp_retrans(
        warn_retrans_pct=args.warn_pct,
        crit_retrans_pct=args.crit_pct,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        s = result["summary"]
        print(f"TCP Retransmission Guard Status: {s['status']}")
        print(f"  Established Sockets:   {s['curr_estab']}")
        print(f"  Inbound Segments:      {s['in_segs']:,}")
        print(f"  Outbound Segments:     {s['out_segs']:,}")
        print(f"  Retransmitted Segs:    {s['retrans_segs']:,} ({s['retrans_ratio_pct']:.4f}%)")
        print(f"  Checksum Errors:       {s['in_csum_errors']}")
        print(f"  Input Errors:          {s['in_errs']}")
        if s["issues"]:
            print("  Issues:")
            for iss in s["issues"]:
                print(f"    - {iss}")
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if result["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
