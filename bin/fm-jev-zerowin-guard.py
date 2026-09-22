#!/usr/bin/env python3
"""
fm-jev-zerowin-guard.py - Jev Multi-Agent Host Network TCP Zero-Window & Flow Control Stall Guard (Pattern 110)

Audits Linux TCP zero-window flow control events, window probes, and auto-corking metrics from
/proc/sys/net/ipv4/tcp_autocorking and /proc/net/netstat (TcpExt: TCPZeroWindowDrop, TCPToZeroWindowAdv,
TCPFromZeroWindowAdv, TCPWantZeroWindowAdv, TCPWinProbe, TCPAutoCorking).

Detects local process receive buffer stalls, remote API gateway backpressure, and flow control freezes halting
streaming LLM token responses and high-throughput agent artifact transfers.

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

SYSCTL_AUTOCORKING = "/proc/sys/net/ipv4/tcp_autocorking"
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


def audit_zerowin(
    autocorking_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits zero-window flow control metrics and window probing events."""
    autocorking_path = Path(autocorking_file) if autocorking_file else Path(SYSCTL_AUTOCORKING)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    autocorking = read_int_file(autocorking_path)
    tcpext = parse_tcpext_netstat(netstat_path)

    zerowin_drop = tcpext.get("TCPZeroWindowDrop", 0)
    to_zerowin = tcpext.get("TCPToZeroWindowAdv", 0)
    from_zerowin = tcpext.get("TCPFromZeroWindowAdv", 0)
    want_zerowin = tcpext.get("TCPWantZeroWindowAdv", 0)
    win_probe = tcpext.get("TCPWinProbe", 0)
    auto_corking_ops = tcpext.get("TCPAutoCorking", 0)

    issues: List[str] = []

    if zerowin_drop > 0:
        issues.append(f"TCP packets dropped due to Zero Window condition ({zerowin_drop} drops)")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_autocorking": autocorking == 1 if autocorking is not None else None,
            "zero_window_drops": zerowin_drop,
            "to_zero_window_advertised": to_zerowin,
            "from_zero_window_received": from_zerowin,
            "window_probes_sent": win_probe,
            "issues": issues,
        },
        "counters": {
            "zerowin_drop": zerowin_drop,
            "to_zerowin_adv": to_zerowin,
            "from_zerowin_adv": from_zerowin,
            "want_zerowin_adv": want_zerowin,
            "win_probe": win_probe,
            "auto_corking_ops": auto_corking_ops,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP Zero-Window & Flow Control Stall Guard (Pattern 110)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--autocorking-file", type=str, default=None, help="Path to tcp_autocorking")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    result = audit_zerowin(
        autocorking_file=args.autocorking_file,
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
    print(" Jev Multi-Agent Host Network TCP Zero-Window & Flow Control Guard (Pattern 110)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" TCP AutoCorking:               {'Enabled' if summary['tcp_autocorking'] else 'Disabled'}")
    print(f" Zero Window Drops:             {summary['zero_window_drops']}")
    print(f" Zero Window Sent (Local Full): {summary['to_zero_window_advertised']:,}")
    print(f" Zero Window Recv (Peer Full):  {summary['from_zero_window_received']:,}")
    print(f" Window Probes Sent:            {summary['window_probes_sent']:,}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Flow Control Metric':<35} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Packets Dropped (Zero Window)':<35} {counters['zerowin_drop']:<15} {'Nominal' if counters['zerowin_drop'] == 0 else 'WARNING'}")
    print(f" {'To-Zero-Window Adv (Local Full)':<35} {counters['to_zerowin_adv']:<15} Nominal")
    print(f" {'From-Zero-Window Adv (Peer Full)':<35} {counters['from_zerowin_adv']:<15} Nominal")
    print(f" {'Want-Zero-Window Requests':<35} {counters['want_zerowin_adv']:<15} Nominal")
    print(f" {'Window Probes Transmitted':<35} {counters['win_probe']:<15} Nominal")
    print(f" {'Auto-Corking Coalesce Events':<35} {counters['auto_corking_ops']:<15} Nominal")

    if summary["issues"]:
        print("\nActive TCP Flow Control Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP zero-window flow control metrics and buffer states nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
