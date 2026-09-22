#!/usr/bin/env python3
"""
bin/fm-jev-frto-guard.py - Host Network TCP Forward RTO (F-RTO) Recovery & Spurious Timeout Guard (Pattern 196)

Audits kernel TCP Forward RTO recovery algorithm (tcp_frto) and loss recovery counters from
/proc/net/netstat (TCPSpuriousRTOs, TCPLossProbes, TCPLossProbeRecovery, TCPTimeouts, TCPSackRecovery).
Ensures RFC 5682 F-RTO SACK detection is active to prevent spurious retransmission timeouts,
protects against false congestion window collapses during transient cross-region WAN jitter,
and verifies Tail Loss Probe (TLP) recovery across multi-agent microservice networks.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List


def read_sysctl_int(path: str) -> int:
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return -1


def parse_netstat_ext(path: str = "/proc/net/netstat") -> Dict[str, int]:
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
            if len(headers) == len(values) and headers[0] == "TcpExt:" and values[0] == "TcpExt:":
                for h, v in zip(headers[1:], values[1:]):
                    try:
                        counters[h] = int(v)
                    except ValueError:
                        continue
    except Exception as e:
        print(f"Warning: unable to parse netstat {path}: {e}", file=sys.stderr)
    return counters


def audit_frto(
    tcp_frto_file: str = "/proc/sys/net/ipv4/tcp_frto",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    frto = read_sysctl_int(tcp_frto_file)

    netstat = parse_netstat_ext(netstat_file)

    spurious_rtos = netstat.get("TCPSpuriousRTOs", 0)
    loss_probes = netstat.get("TCPLossProbes", 0)
    loss_probe_recovery = netstat.get("TCPLossProbeRecovery", 0)
    timeouts = netstat.get("TCPTimeouts", 0)
    sack_recovery = netstat.get("TCPSackRecovery", 0)

    spurious_rto_pct = round((spurious_rtos / timeouts * 100.0), 4) if timeouts > 0 else 0.0
    tlp_recovery_pct = round((loss_probe_recovery / loss_probes * 100.0), 4) if loss_probes > 0 else 0.0

    issues: List[str] = []
    status = "HEALTHY"

    # Critical conditions
    if frto == 0:
        issues.append("tcp_frto is 0 (disabled): spurious timeouts will falsely collapse congestion window to 1 MSS")
        status = "CRITICAL"
    if spurious_rto_pct >= 25.0:
        issues.append(f"Spurious RTO ratio ({spurious_rto_pct}%) exceeds 25.0% critical threshold: severe RTT estimation instability")
        status = "CRITICAL"

    # Warning conditions
    if status != "CRITICAL":
        if frto == 1:
            issues.append("tcp_frto is 1 (basic F-RTO): SACK-enhanced F-RTO (2) recommended for optimal fast recovery")
            status = "WARNING"
        if spurious_rto_pct >= 5.0:
            issues.append(f"Spurious RTO ratio ({spurious_rto_pct}%) exceeds 5.0% warning threshold: transient delay jitter detected")
            status = "WARNING"

    frto_mode_desc = {
        0: "disabled",
        1: "basic F-RTO enabled",
        2: "SACK-enhanced F-RTO enabled (RFC 5682)",
    }.get(frto, f"unknown ({frto})")

    summary = {
        "status": status,
        "healthy": (status == "HEALTHY"),
        "tcp_frto": frto,
        "tcp_frto_mode": frto_mode_desc,
        "spurious_rtos": spurious_rtos,
        "spurious_rto_pct": spurious_rto_pct,
        "loss_probes_sent": loss_probes,
        "loss_probe_recoveries": loss_probe_recovery,
        "tlp_recovery_pct": tlp_recovery_pct,
        "tcp_timeouts": timeouts,
        "sack_recoveries": sack_recovery,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "tcp_frto": frto,
        },
        "netstat_counters": {
            "TCPSpuriousRTOs": spurious_rtos,
            "TCPLossProbes": loss_probes,
            "TCPLossProbeRecovery": loss_probe_recovery,
            "TCPTimeouts": timeouts,
            "TCPSackRecovery": sack_recovery,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Forward RTO (F-RTO) Recovery & Spurious Timeout Guard (Pattern 196)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_frto()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Forward RTO (F-RTO) Guard (Pattern 196) - Status: {s['status']}")
    print(f"  tcp_frto:              {s['tcp_frto']} ({s['tcp_frto_mode']})")
    print(f"  Spurious RTOs:         {s['spurious_rtos']:,} ({s['spurious_rto_pct']}% of timeouts)")
    print(f"  Tail Loss Probes:      {s['loss_probes_sent']:,}")
    print(f"  TLP Recoveries:        {s['loss_probe_recoveries']:,} ({s['tlp_recovery_pct']}%)")
    print(f"  Total RTO Timeouts:    {s['tcp_timeouts']:,}")
    print(f"  SACK Fast Recoveries:  {s['sack_recoveries']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
