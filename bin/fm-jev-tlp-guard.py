#!/usr/bin/env python3
"""
bin/fm-jev-tlp-guard.py - Host Network TCP Tail Loss Probe (TLP) & Loss Recovery Guard (Pattern 154)

Audits tcp_early_retrans sysctl and /proc/net/netstat loss probe counters
(TCPLossProbes, TCPLossProbeRecovery, TCPLossFailures, TCPLossUndo) to verify
RFC 8985 Tail Loss Probe and RFC 5827 early retransmission defense, ensuring
fast tail loss recovery without heavy retransmission timeout (RTO) stalls
across multi-agent streaming connections.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl(path: str = "/proc/sys/net/ipv4/tcp_early_retrans") -> int:
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


def audit_tlp(
    sysctl_file: str = "/proc/sys/net/ipv4/tcp_early_retrans",
    netstat_file: str = "/proc/net/netstat",
) -> Dict[str, Any]:
    early_retrans = read_sysctl(sysctl_file)
    netstat = parse_netstat(netstat_file)

    loss_probes = netstat.get("TCPLossProbes", 0)
    loss_probe_recovery = netstat.get("TCPLossProbeRecovery", 0)
    loss_failures = netstat.get("TCPLossFailures", 0)
    loss_undo = netstat.get("TCPLossUndo", 0)
    fast_retrans = netstat.get("TCPFastRetrans", 0)
    timeouts = netstat.get("TCPTimeouts", 0)

    recovery_ratio_pct = 0.0
    if loss_probes > 0:
        recovery_ratio_pct = round((loss_probe_recovery / loss_probes) * 100.0, 3)

    failure_ratio_pct = 0.0
    if loss_probes > 0:
        failure_ratio_pct = round((loss_failures / loss_probes) * 100.0, 3)

    issues = []
    status = "HEALTHY"
    healthy = True

    # Validate sysctl: 0 = disabled, 1 = ER only, 2 = delayed ER, 3 = TLP + ER
    if early_retrans == 0:
        status = "WARNING"
        healthy = False
        issues.append("tcp_early_retrans is disabled (0), tail loss probe inactive")
    elif early_retrans < 0:
        issues.append(f"Unable to read tcp_early_retrans from {sysctl_file}")

    # Check for excessive failure ratio (> 50%)
    if loss_probes > 1000 and failure_ratio_pct > 50.0:
        status = "WARNING"
        healthy = False
        issues.append(f"High loss probe failure ratio: {failure_ratio_pct}% (> 50%)")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_early_retrans": early_retrans,
        "loss_probes": loss_probes,
        "loss_probe_recovery": loss_probe_recovery,
        "recovery_ratio_pct": recovery_ratio_pct,
        "loss_failures": loss_failures,
        "failure_ratio_pct": failure_ratio_pct,
        "loss_undo": loss_undo,
        "fast_retrans": fast_retrans,
        "timeouts": timeouts,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "tcp_early_retrans": early_retrans,
            "loss_probes": loss_probes,
            "loss_probe_recovery": loss_probe_recovery,
            "loss_failures": loss_failures,
            "loss_undo": loss_undo,
            "fast_retrans": fast_retrans,
            "timeouts": timeouts,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Tail Loss Probe (TLP) & Loss Recovery Guard (Pattern 154)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_tlp()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Tail Loss Probe Guard (Pattern 154) - Status: {s['status']}")
    print(f"  tcp_early_retrans Sysctl:    {s['tcp_early_retrans']} (3 = TLP + ER active)")
    print(f"  Tail Loss Probes Sent:       {s['loss_probes']:,}")
    print(f"  Loss Probes Recovered:       {s['loss_probe_recovery']:,} ({s['recovery_ratio_pct']}%)")
    print(f"  Loss Probe Failures:         {s['loss_failures']:,} ({s['failure_ratio_pct']}%)")
    print(f"  Loss Undos:                  {s['loss_undo']:,}")
    print(f"  Fast Retransmissions:        {s['fast_retrans']:,}")
    print(f"  Retransmission Timeouts:     {s['timeouts']:,}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
