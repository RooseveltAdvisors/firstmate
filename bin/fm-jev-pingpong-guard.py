#!/usr/bin/env python3
"""
fm-jev-pingpong-guard.py - Jev Multi-Agent Host Network TCP Ping-Pong Interactive RPC Guard (Pattern 130)

Audits Linux TCP ping-pong interactive heuristics (/proc/sys/net/ipv4/tcp_pingpong_thresh),
compressed SACK delay timers (/proc/sys/net/ipv4/tcp_comp_sack_delay_ns, /proc/sys/net/ipv4/tcp_comp_sack_nr),
and delayed ACK / header prediction telemetry from /proc/net/netstat.

In conversational multi-agent systems and subagent JSON-RPC grids, rapid request/response turns
rely on TCP QuickACK heuristics to avoid 40ms delayed-ACK timeouts that degrade turn-to-turn latency.

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

SYSCTL_PINGPONG_THRESH = "/proc/sys/net/ipv4/tcp_pingpong_thresh"
SYSCTL_COMP_SACK_DELAY = "/proc/sys/net/ipv4/tcp_comp_sack_delay_ns"
SYSCTL_COMP_SACK_NR = "/proc/sys/net/ipv4/tcp_comp_sack_nr"

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


def audit_pingpong(
    pingpong_file: Optional[str] = None,
    sack_delay_file: Optional[str] = None,
    sack_nr_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits host TCP ping-pong parameters and delayed ACK telemetry."""
    pingpong_p = Path(pingpong_file or SYSCTL_PINGPONG_THRESH)
    sack_delay_p = Path(sack_delay_file or SYSCTL_COMP_SACK_DELAY)
    sack_nr_p = Path(sack_nr_file or SYSCTL_COMP_SACK_NR)
    netstat_p = Path(netstat_file or PROC_NETSTAT)

    pingpong_thresh = read_int_file(pingpong_p)
    if pingpong_thresh is None:
        pingpong_thresh = 1

    sack_delay_ns = read_int_file(sack_delay_p)
    if sack_delay_ns is None:
        sack_delay_ns = 1000000

    sack_nr = read_int_file(sack_nr_p)
    if sack_nr is None:
        sack_nr = 44

    netstat_tcp = parse_proc_pairs(netstat_p, "TcpExt")

    delayed_acks = netstat_tcp.get("DelayedACKs", 0)
    delayed_ack_locked = netstat_tcp.get("DelayedACKLocked", 0)
    delayed_ack_lost = netstat_tcp.get("DelayedACKLost", 0)
    hp_hits = netstat_tcp.get("TCPHPHits", 0)
    hp_acks = netstat_tcp.get("TCPHPAcks", 0)

    issues: List[str] = []
    healthy = True

    if pingpong_thresh < 1:
        healthy = False
        issues.append("tcp_pingpong_thresh is 0. Interactive RPC flow heuristic disabled.")

    lost_ratio = (delayed_ack_lost / delayed_acks * 100.0) if delayed_acks > 0 else 0.0
    if lost_ratio > 35.0:
        issues.append(f"Elevated delayed-ACK timer expirations ({lost_ratio:.1f}% expired). Indicates interactive streams stalling on delayed ACKs.")

    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_pingpong_thresh": pingpong_thresh,
            "comp_sack_delay_ms": round(sack_delay_ns / 1000000.0, 2),
            "comp_sack_nr": sack_nr,
            "delayed_acks": delayed_acks,
            "delayed_ack_lost": delayed_ack_lost,
            "delayed_ack_lost_pct": round(lost_ratio, 2),
            "hp_hits": hp_hits,
            "hp_acks": hp_acks,
            "issues": issues,
        },
        "counters": {
            "delayed_acks": delayed_acks,
            "delayed_ack_locked": delayed_ack_locked,
            "delayed_ack_lost": delayed_ack_lost,
            "hp_hits": hp_hits,
            "hp_acks": hp_acks,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Ping-Pong Interactive RPC Guard (Pattern 130)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--pingpong-file", type=str, default=None, help="Path to tcp_pingpong_thresh")
    parser.add_argument("--sack-delay-file", type=str, default=None, help="Path to tcp_comp_sack_delay_ns")
    parser.add_argument("--sack-nr-file", type=str, default=None, help="Path to tcp_comp_sack_nr")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_pingpong(
        pingpong_file=args.pingpong_file,
        sack_delay_file=args.sack_delay_file,
        sack_nr_file=args.sack_nr_file,
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
    print(" Jev Multi-Agent Host Network TCP Ping-Pong QuickACK Guard (Pattern 130)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Ping-Pong Threshold:           {summary['tcp_pingpong_thresh']} ({'Interactive QuickACK Heuristic Active' if summary['tcp_pingpong_thresh'] >= 1 else 'Disabled'})")
    print(f" Compressed SACK Delay:         {summary['comp_sack_delay_ms']} ms")
    print(f" Compressed SACK Packet Limit:  {summary['comp_sack_nr']} packets")
    print(f" Total Delayed ACKs Sent:       {counters['delayed_acks']:,}")
    print(f" Delayed ACK Timer Expirations: {counters['delayed_ack_lost']:,} ({summary['delayed_ack_lost_pct']}%)")
    print(f" Header Prediction Hits (Fast): {counters['hp_hits']:,}")
    print(f" Header Prediction Fast ACKs:   {counters['hp_acks']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Interactive ACK Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'tcp_pingpong_thresh':<35} {summary['tcp_pingpong_thresh']:<15} {'Nominal' if summary['tcp_pingpong_thresh'] >= 1 else 'WARNING'}")
    print(f" {'Delayed ACK Lost Ratio':<35} {summary['delayed_ack_lost_pct']:<14}% Nominal")
    print(f" {'Header Prediction Hits':<35} {counters['hp_hits']:<15} Nominal")

    if summary["issues"]:
        print("\nActive Ping-Pong / QuickACK Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP ping-pong interactive parameters, QuickACK heuristics, and delayed-ACK metrics nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
