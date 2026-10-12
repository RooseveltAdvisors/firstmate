#!/usr/bin/env python3
"""
fm-jev-tlp-guard.py - Jev Multi-Agent Host Network TCP Tail Loss Probe (TLP) & Loss Recovery Guard (Pattern 154)

Audits Linux TCP Tail Loss Probe (TLP) sysctl settings and recovery metrics from /proc/net/netstat:
  - net.ipv4.tcp_early_retrans (0=disabled, 1=early retrans, 2=delayed ER, 3=delayed ER + TLP, 4=TLP only)
  - TCPLossProbes (Number of Tail Loss Probes sent to elicit ACK and prevent RTO)
  - TCPLossProbeRecovery (Loss recovery events triggered directly by a Tail Loss Probe)
  - TCPLossFailures (Loss recovery events that failed and fell back to full RTO)
  - TCPTimeouts (Total retransmission timeouts)
  - TCPFastRetrans (Fast retransmissions)
  - TCPDelivered (Total TCP segments delivered to local application sockets)

In multi-agent token streaming and high-frequency inter-agent RPC pipelines, drops at the tail
of a burst/response would ordinarily force a full retransmission timeout (RTO, 200ms+ delay).
TLP (RFC 8985) sends an early probe segment to elicit an immediate duplicate or selective ACK,
converting expensive RTO stalls into sub-millisecond fast recoveries.

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

PROC_NETSTAT = "/proc/net/netstat"
SYSCTL_EARLY_RETRANS = "/proc/sys/net/ipv4/tcp_early_retrans"


def parse_sysctl_early_retrans(sysctl_path: Path) -> int:
    """Reads net.ipv4.tcp_early_retrans mode."""
    if not sysctl_path.is_file():
        return 3
    try:
        content = sysctl_path.read_text().strip()
        return int(content) if content.isdigit() else 3
    except Exception:
        return 3


def parse_tlp_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses TCP TLP and loss recovery metrics from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "loss_probes": 0,
        "loss_probe_recovery": 0,
        "loss_failures": 0,
        "timeouts": 0,
        "fast_retrans": 0,
        "delivered": 0,
    }

    if not netstat_path.is_file():
        return counters

    try:
        lines = netstat_path.read_text().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header_line = lines[i].strip()
            data_line = lines[i + 1].strip()
            if header_line.startswith("TcpExt:") and data_line.startswith("TcpExt:"):
                headers = header_line.split()[1:]
                values = data_line.split()[1:]
                header_map = {h: int(v) for h, v in zip(headers, values) if v.isdigit()}

                counters["loss_probes"] = header_map.get("TCPLossProbes", 0)
                counters["loss_probe_recovery"] = header_map.get("TCPLossProbeRecovery", 0)
                counters["loss_failures"] = header_map.get("TCPLossFailures", 0)
                counters["timeouts"] = header_map.get("TCPTimeouts", 0)
                counters["fast_retrans"] = header_map.get("TCPFastRetrans", 0)
                counters["delivered"] = header_map.get("TCPDelivered", 0)
                break
    except Exception:
        pass

    return counters


def audit_tlp(
    netstat_file: Optional[str] = None,
    early_retrans_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP Tail Loss Probe and loss recovery efficiency."""
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    early_retrans_path = Path(early_retrans_file) if early_retrans_file else Path(SYSCTL_EARLY_RETRANS)

    early_retrans = parse_sysctl_early_retrans(early_retrans_path)
    counters = parse_tlp_counters(netstat_path)

    loss_probes = counters["loss_probes"]
    loss_probe_recovery = counters["loss_probe_recovery"]
    loss_failures = counters["loss_failures"]
    timeouts = counters["timeouts"]
    fast_retrans = counters["fast_retrans"]
    delivered = counters["delivered"]

    recovery_ratio_pct = (
        round((loss_probe_recovery / loss_probes * 100), 2)
        if loss_probes > 0
        else 0.0
    )

    total_tail_loss_events = loss_probe_recovery + loss_failures
    failure_ratio_pct = (
        round((loss_failures / total_tail_loss_events * 100), 2)
        if total_tail_loss_events > 0
        else 0.0
    )

    issues: List[str] = []

    # 1. Early retransmit / TLP disabled
    if early_retrans == 0:
        issues.append(
            "Tail Loss Probe is disabled (net.ipv4.tcp_early_retrans = 0); tail packet drops will stall on full RTO"
        )

    # 2. Excessive failure ratio (> 50% failures on significant sample size)
    if total_tail_loss_events > 500 and failure_ratio_pct > 50.0:
        issues.append(
            f"High TLP failure ratio detected ({failure_ratio_pct}% of tail losses failed to recover before RTO)"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    mode_labels = {
        0: "Disabled",
        1: "Early Retransmit Only",
        2: "Early Retransmit (Delayed)",
        3: "Early Retransmit + Tail Loss Probe (RFC 8985)",
        4: "Tail Loss Probe Only",
    }
    mode_desc = mode_labels.get(early_retrans, f"Custom ({early_retrans})")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "early_retrans_sysctl": early_retrans,
            "early_retrans_mode": mode_desc,
            "loss_probes": loss_probes,
            "loss_probe_recovery": loss_probe_recovery,
            "loss_failures": loss_failures,
            "recovery_ratio_pct": recovery_ratio_pct,
            "failure_ratio_pct": failure_ratio_pct,
            "timeouts": timeouts,
            "fast_retrans": fast_retrans,
            "delivered": delivered,
            "issues": issues,
        },
        "counters": counters,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Tail Loss Probe (TLP) & Loss Recovery Guard (Pattern 154)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--early-retrans-file", type=str, default=None, help="Path to /proc/sys/net/ipv4/tcp_early_retrans")
    args = parser.parse_args()

    result = audit_tlp(
        netstat_file=args.netstat_file,
        early_retrans_file=args.early_retrans_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP Tail Loss Probe (TLP) Guard (Pattern 154)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Sysctl tcp_early_retrans:      {summary['early_retrans_sysctl']} ({summary['early_retrans_mode']})")
    print(f" Tail Loss Probes Sent:         {summary['loss_probes']:,}")
    print(f" TLP Loss Recoveries:           {summary['loss_probe_recovery']:,} ({summary['recovery_ratio_pct']}% of probes)")
    print(f" TLP Loss Failures:             {summary['loss_failures']:,} ({summary['failure_ratio_pct']}% failure ratio)")
    print(f" Total Segments Delivered:      {summary['delivered']:,}")
    print(f" Total Fast Retransmissions:    {summary['fast_retrans']:,}")
    print(f" Total Retransmission Timeouts: {summary['timeouts']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'TLP / Loss Metric':<35} {'Value':<18} {'Status'}")
    print("--------------------------------------------------------------------------------")
    early_mode_status = "Nominal" if summary['early_retrans_sysctl'] in [3, 4] else "Suboptimal"
    rec_val = f"{summary['loss_probe_recovery']:,}"
    fail_ratio_val = f"{summary['failure_ratio_pct']} %"
    fail_status = "Nominal" if summary['failure_ratio_pct'] <= 50.0 else "High"
    print(f" {'Early Retransmit / TLP Mode':<35} {str(summary['early_retrans_sysctl']):<18} {early_mode_status}")
    print(f" {'Loss Probe Direct Recovery':<35} {rec_val:<18} {'Active'}")
    print(f" {'Tail Loss Failure Ratio':<35} {fail_ratio_val:<18} {fail_status}")

    if summary["issues"]:
        print("\nActive TCP Tail Loss Probe Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP Tail Loss Probe (TLP) acceleration and loss recovery metrics nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
