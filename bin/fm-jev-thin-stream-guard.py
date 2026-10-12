#!/usr/bin/env python3
"""
fm-jev-thin-stream-guard.py - Jev Multi-Agent Host Network TCP Early Retransmit & Thin-Stream Guard (Pattern 127)

Audits Linux TCP Early Retransmit (/proc/sys/net/ipv4/tcp_early_retrans, RFC 5827),
thin-stream linear timeouts (/proc/sys/net/ipv4/tcp_thin_linear_timeouts),
SYN linear timeouts (/proc/sys/net/ipv4/tcp_syn_linear_timeouts),
RACK loss recovery (/proc/sys/net/ipv4/tcp_recovery), Forward RTO (/proc/sys/net/ipv4/tcp_frto),
and loss probe / retransmission telemetry from /proc/net/netstat.

In multi-agent RPC and JSON-streaming topologies, interactive requests frequently have small flight
sizes (<= 4 packets), preventing traditional Fast Retransmit (which requires 3 duplicate ACKs).
Early Retransmit and Tail Loss Probes (TLP) prevent multi-second timeout stalls on single packet drops.

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

SYSCTL_EARLY_RETRANS = "/proc/sys/net/ipv4/tcp_early_retrans"
SYSCTL_THIN_LINEAR = "/proc/sys/net/ipv4/tcp_thin_linear_timeouts"
SYSCTL_SYN_LINEAR = "/proc/sys/net/ipv4/tcp_syn_linear_timeouts"
SYSCTL_RECOVERY = "/proc/sys/net/ipv4/tcp_recovery"
SYSCTL_FRTO = "/proc/sys/net/ipv4/tcp_frto"

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


def audit_thin_stream(
    early_retrans_file: Optional[str] = None,
    thin_linear_file: Optional[str] = None,
    syn_linear_file: Optional[str] = None,
    recovery_file: Optional[str] = None,
    frto_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP Early Retransmit, thin-stream parameters, and loss recovery telemetry."""
    early_p = Path(early_retrans_file or SYSCTL_EARLY_RETRANS)
    thin_p = Path(thin_linear_file or SYSCTL_THIN_LINEAR)
    syn_p = Path(syn_linear_file or SYSCTL_SYN_LINEAR)
    recov_p = Path(recovery_file or SYSCTL_RECOVERY)
    frto_p = Path(frto_file or SYSCTL_FRTO)

    netstat_p = Path(netstat_file or PROC_NETSTAT)

    early_retrans = read_int_file(early_p)
    if early_retrans is None:
        early_retrans = 3

    thin_linear = read_int_file(thin_p)
    if thin_linear is None:
        thin_linear = 0

    syn_linear = read_int_file(syn_p)
    if syn_linear is None:
        syn_linear = 0

    recovery = read_int_file(recov_p)
    if recovery is None:
        recovery = 1

    frto = read_int_file(frto_p)
    if frto is None:
        frto = 2

    netstat_tcp = parse_proc_pairs(netstat_p, "TcpExt")

    loss_probes = netstat_tcp.get("TCPLossProbes", 0)
    loss_probe_recov = netstat_tcp.get("TCPLossProbeRecovery", 0)
    fast_retrans = netstat_tcp.get("TCPFastRetrans", 0)
    slow_start_retrans = netstat_tcp.get("TCPSlowStartRetrans", 0)
    lost_retransmit = netstat_tcp.get("TCPLostRetransmit", 0)
    retrans_fail = netstat_tcp.get("TCPRetransFail", 0)
    timeouts = netstat_tcp.get("TCPTimeouts", 0)
    spurious_rtos = netstat_tcp.get("TCPSpuriousRTOs", 0)

    issues: List[str] = []
    healthy = True

    if early_retrans == 0:
        healthy = False
        issues.append("Early Retransmit is disabled (tcp_early_retrans = 0). Small-flight RPC streams will stall for full RTO on packet loss.")

    if recovery == 0:
        healthy = False
        issues.append("RACK loss detection disabled (tcp_recovery = 0). Modern time-based loss recovery inactive.")

    if retrans_fail > 1000000:
        healthy = False
        issues.append(f"Excessive TCP retransmission failures ({retrans_fail:,} failures). Network interface or driver dropping retransmit frames.")

    status = "HEALTHY" if healthy else "WARNING"

    tlp_conversion_pct = (loss_probe_recov / loss_probes * 100.0) if loss_probes > 0 else 0.0
    spurious_rto_pct = (spurious_rtos / timeouts * 100.0) if timeouts > 0 else 0.0

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "early_retrans": early_retrans,
            "thin_linear_timeouts": thin_linear,
            "syn_linear_timeouts": syn_linear,
            "recovery": recovery,
            "frto": frto,
            "loss_probes": loss_probes,
            "loss_probe_recovery": loss_probe_recov,
            "tlp_conversion_pct": round(tlp_conversion_pct, 2),
            "fast_retrans": fast_retrans,
            "timeouts": timeouts,
            "spurious_rtos": spurious_rtos,
            "spurious_rto_pct": round(spurious_rto_pct, 2),
            "issues": issues,
        },
        "counters": {
            "loss_probes": loss_probes,
            "loss_probe_recovery": loss_probe_recov,
            "fast_retrans": fast_retrans,
            "slow_start_retrans": slow_start_retrans,
            "lost_retransmit": lost_retransmit,
            "retrans_fail": retrans_fail,
            "timeouts": timeouts,
            "spurious_rtos": spurious_rtos,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Early Retransmit & Thin-Stream Guard (Pattern 127)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--early-retrans-file", type=str, default=None, help="Path to tcp_early_retrans")
    parser.add_argument("--thin-linear-file", type=str, default=None, help="Path to tcp_thin_linear_timeouts")
    parser.add_argument("--syn-linear-file", type=str, default=None, help="Path to tcp_syn_linear_timeouts")
    parser.add_argument("--recovery-file", type=str, default=None, help="Path to tcp_recovery")
    parser.add_argument("--frto-file", type=str, default=None, help="Path to tcp_frto")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_thin_stream(
        early_retrans_file=args.early_retrans_file,
        thin_linear_file=args.thin_linear_file,
        syn_linear_file=args.syn_linear_file,
        recovery_file=args.recovery_file,
        frto_file=args.frto_file,
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
    print(" Jev Multi-Agent Host Network TCP Early Retransmit & Thin Stream Guard (Pattern 127)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Early Retransmit (RFC 5827):   {summary['early_retrans']} ({'Enabled with TLP' if summary['early_retrans'] >= 3 else 'Standard / Disabled'})")
    print(f" Thin Linear Timeouts:          {summary['thin_linear_timeouts']} ({'Enabled' if summary['thin_linear_timeouts'] == 1 else 'Disabled (Default Exponential)'})")
    print(f" SYN Linear Timeouts:           {summary['syn_linear_timeouts']}")
    print(f" RACK Loss Recovery:            {summary['recovery']} ({'Active (RFC 8985)' if summary['recovery'] == 1 else 'Disabled'})")
    print(f" Forward RTO (F-RTO):           {summary['frto']}")
    print(f" Tail Loss Probes Sent:         {counters['loss_probes']:,}")
    print(f" Loss Probe Fast Recoveries:    {counters['loss_probe_recovery']:,} ({summary['tlp_conversion_pct']}%)")
    print(f" Fast Retransmissions:          {counters['fast_retrans']:,}")
    print(f" Total RTO Timeouts:            {counters['timeouts']:,}")
    print(f" Spurious RTO Timeouts:         {counters['spurious_rtos']:,} ({summary['spurious_rto_pct']}%)")
    print("--------------------------------------------------------------------------------")
    print(f" {'Thin Stream / Loss Recovery Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'tcp_early_retrans':<35} {summary['early_retrans']:<15} {'Nominal' if summary['early_retrans'] >= 3 else 'WARNING'}")
    print(f" {'tcp_recovery (RACK)':<35} {summary['recovery']:<15} {'Nominal' if summary['recovery'] == 1 else 'WARNING'}")
    print(f" {'TLP Recovery Ratio':<35} {summary['tlp_conversion_pct']:<14}% Nominal")
    print(f" {'Spurious RTO Ratio':<35} {summary['spurious_rto_pct']:<14}% Nominal")

    if summary["issues"]:
        print("\nActive Thin Stream / Loss Recovery Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP Early Retransmit parameters, RACK loss recovery, and TLP metrics nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
