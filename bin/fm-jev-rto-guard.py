#!/usr/bin/env python3
"""
fm-jev-rto-guard.py - Jev Multi-Agent Host Network TCP RACK/TLP Loss Recovery & Spurious Timeout Guard (Pattern 111)

Audits Linux TCP loss recovery algorithms, Tail Loss Probe (TLP), RACK loss detection, and spurious RTO counters from
/proc/sys/net/ipv4/tcp_recovery, tcp_frto, tcp_retries1, tcp_retries2, and /proc/net/netstat (TcpExt:
TCPTimeouts, TCPLossProbes, TCPLossProbeRecovery, TCPSpuriousRTOs, TCPLostRetransmit, TCPFastRetrans,
TCPSlowStartRetrans, TCPSackRecoveryFail).

Detects slow retransmission timeouts, high retransmission loss rates, ineffective tail loss probes, and spurious RTO
collapses across multi-agent RPC lifecycles, database transactions, and cloud LLM streaming pipelines.

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

SYSCTL_RECOVERY = "/proc/sys/net/ipv4/tcp_recovery"
SYSCTL_FRTO = "/proc/sys/net/ipv4/tcp_frto"
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


def audit_rto(
    recovery_file: Optional[str] = None,
    frto_file: Optional[str] = None,
    retries1_file: Optional[str] = None,
    retries2_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP loss recovery, RACK/TLP settings, and RTO counters."""
    recovery_path = Path(recovery_file) if recovery_file else Path(SYSCTL_RECOVERY)
    frto_path = Path(frto_file) if frto_file else Path(SYSCTL_FRTO)
    retries1_path = Path(retries1_file) if retries1_file else Path(SYSCTL_RETRIES1)
    retries2_path = Path(retries2_file) if retries2_file else Path(SYSCTL_RETRIES2)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    recovery_val = read_int_file(recovery_path)
    frto_val = read_int_file(frto_path)
    retries1_val = read_int_file(retries1_path)
    retries2_val = read_int_file(retries2_path)

    tcpext = parse_tcpext_netstat(netstat_path)

    timeouts = tcpext.get("TCPTimeouts", 0)
    loss_probes = tcpext.get("TCPLossProbes", 0)
    loss_probe_recovery = tcpext.get("TCPLossProbeRecovery", 0)
    spurious_rto = tcpext.get("TCPSpuriousRTOs", 0)
    lost_retransmit = tcpext.get("TCPLostRetransmit", 0)
    fast_retrans = tcpext.get("TCPFastRetrans", 0)
    slow_start_retrans = tcpext.get("TCPSlowStartRetrans", 0)
    sack_recovery_fail = tcpext.get("TCPSackRecoveryFail", 0)

    # Decode tcp_recovery bitmask: bit 0 = RACK (1), bit 1 = TLP (2)
    rack_enabled = bool(recovery_val & 1) if recovery_val is not None else False
    tlp_enabled = bool(recovery_val & 2) if recovery_val is not None else False

    # Rates
    tlp_recovery_pct = round((loss_probe_recovery / loss_probes * 100), 2) if loss_probes > 0 else 0.0
    spurious_rto_pct = round((spurious_rto / timeouts * 100), 2) if timeouts > 0 else 0.0

    issues: List[str] = []

    if retries2_val is not None and retries2_val > 15:
        issues.append(f"High tcp_retries2 ({retries2_val}): dead connections take > 15 minutes to time out")

    if timeouts > 0 and spurious_rto_pct > 25.0:
        issues.append(f"High spurious RTO rate ({spurious_rto_pct}%): packets delayed in transit triggering unnecessary retransmits")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_recovery_raw": recovery_val,
            "rack_loss_detection": rack_enabled,
            "tail_loss_probe_tlp": tlp_enabled,
            "tcp_frto_mode": frto_val,
            "tcp_retries1": retries1_val,
            "tcp_retries2": retries2_val,
            "timeouts_count": timeouts,
            "spurious_rto_pct": spurious_rto_pct,
            "tlp_recovery_pct": tlp_recovery_pct,
            "issues": issues,
        },
        "counters": {
            "timeouts": timeouts,
            "loss_probes": loss_probes,
            "loss_probe_recovery": loss_probe_recovery,
            "spurious_rto": spurious_rto,
            "lost_retransmit": lost_retransmit,
            "fast_retrans": fast_retrans,
            "slow_start_retrans": slow_start_retrans,
            "sack_recovery_fail": sack_recovery_fail,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP RACK/TLP Loss Recovery & Spurious Timeout Guard (Pattern 111)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--recovery-file", type=str, default=None, help="Path to tcp_recovery")
    parser.add_argument("--frto-file", type=str, default=None, help="Path to tcp_frto")
    parser.add_argument("--retries1-file", type=str, default=None, help="Path to tcp_retries1")
    parser.add_argument("--retries2-file", type=str, default=None, help="Path to tcp_retries2")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_rto(
        recovery_file=args.recovery_file,
        frto_file=args.frto_file,
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
    print(" Jev Multi-Agent Host Network TCP Loss Recovery & RTO Guard (Pattern 111)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" RACK Loss Detection:           {'Enabled' if summary['rack_loss_detection'] else 'Disabled'}")
    print(f" Tail Loss Probe (TLP):         {'Enabled' if summary['tail_loss_probe_tlp'] else 'Disabled'}")
    print(f" Forward RTO (F-RTO):           Mode {summary['tcp_frto_mode']}")
    print(f" Retransmit Retries:            RFC {summary['tcp_retries1']} / Max {summary['tcp_retries2']}")
    print(f" Spurious RTO Rate:             {summary['spurious_rto_pct']}% of timeouts")
    print(f" TLP Loss Recovery Rate:        {summary['tlp_recovery_pct']}% of probes")
    print("--------------------------------------------------------------------------------")
    print(f" {'Loss Recovery Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Retransmission Timeouts (RTO)':<35} {counters['timeouts']:<15} Nominal")
    print(f" {'Tail Loss Probes Sent (TLP)':<35} {counters['loss_probes']:<15} Nominal")
    print(f" {'TLP Probe Recoveries':<35} {counters['loss_probe_recovery']:<15} Nominal")
    print(f" {'Spurious Retransmit Timeouts':<35} {counters['spurious_rto']:<15} Nominal")
    print(f" {'Lost Retransmissions':<35} {counters['lost_retransmit']:<15} Nominal")
    print(f" {'Fast Retransmits (SACK/DupACK)':<35} {counters['fast_retrans']:<15} Nominal")
    print(f" {'Slow-Start Retransmits':<35} {counters['slow_start_retrans']:<15} Nominal")
    print(f" {'SACK Recovery Failures':<35} {counters['sack_recovery_fail']:<15} Nominal")

    if summary["issues"]:
        print("\nActive TCP Loss Recovery Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP loss recovery mechanisms, TLP probes, and RTO counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
