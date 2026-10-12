#!/usr/bin/env python3
"""
bin/fm-jev-zero-window-adv-guard.py - Host Network TCP Zero-Window Flow Control & Buffer Saturation Guard (Pattern 162)

Audits TCP zero-window flow control counters (TCPToZeroWindowAdv, TCPFromZeroWindowAdv,
TCPWantZeroWindowAdv, TCPZeroWindowDrop) from /proc/net/netstat along with window scaling sysctls
(tcp_app_win, tcp_adv_win_scale) to verify application read responsiveness and prevent zero-window
flow control stalls across high-throughput agent token streams.
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict


def read_sysctl_int(path: str) -> int:
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


def audit_zero_window(
    netstat_file: str = "/proc/net/netstat",
    app_win_file: str = "/proc/sys/net/ipv4/tcp_app_win",
    adv_win_scale_file: str = "/proc/sys/net/ipv4/tcp_adv_win_scale",
) -> Dict[str, Any]:
    netstat = parse_netstat(netstat_file)
    app_win = read_sysctl_int(app_win_file)
    adv_win_scale = read_sysctl_int(adv_win_scale_file)

    to_zero = netstat.get("TCPToZeroWindowAdv", 0)
    from_zero = netstat.get("TCPFromZeroWindowAdv", 0)
    want_zero = netstat.get("TCPWantZeroWindowAdv", 0)
    zero_drop = netstat.get("TCPZeroWindowDrop", 0)
    rcv_q_drop = netstat.get("TCPRcvQDrop", 0)

    net_zero_active = max(0, to_zero - from_zero)

    issues = []
    status = "HEALTHY"
    healthy = True

    if zero_drop > 50:
        status = "WARNING"
        healthy = False
        issues.append(f"Detected TCP zero-window packet drops: {zero_drop}")

    if net_zero_active > 100:
        status = "WARNING"
        healthy = False
        issues.append(f"High number of active zero-window advertised sockets: {net_zero_active}")

    summary = {
        "status": status,
        "healthy": healthy,
        "tcp_app_win": app_win,
        "tcp_adv_win_scale": adv_win_scale,
        "to_zero_window": to_zero,
        "from_zero_window": from_zero,
        "want_zero_window": want_zero,
        "zero_window_drop": zero_drop,
        "rcv_q_drop": rcv_q_drop,
        "net_zero_active": net_zero_active,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "counters": {
            "TCPToZeroWindowAdv": to_zero,
            "TCPFromZeroWindowAdv": from_zero,
            "TCPWantZeroWindowAdv": want_zero,
            "TCPZeroWindowDrop": zero_drop,
            "TCPRcvQDrop": rcv_q_drop,
        },
        "sysctls": {
            "tcp_app_win": app_win,
            "tcp_adv_win_scale": adv_win_scale,
        },
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network TCP Zero-Window Flow Control & Buffer Saturation Guard (Pattern 162)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_zero_window()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"TCP Zero-Window Guard (Pattern 162) - Status: {s['status']}")
    print(f"  Transitions TO Zero Window:    {s['to_zero_window']:,}")
    print(f"  Transitions FROM Zero Window:  {s['from_zero_window']:,}")
    print(f"  Desired Zero Window Events:    {s['want_zero_window']:,}")
    print(f"  Zero Window Packet Drops:      {s['zero_window_drop']:,}")
    print(f"  Receive Queue Drops:           {s['rcv_q_drop']:,}")
    print(f"  Net Zero Active Sockets:       {s['net_zero_active']:,}")
    print(f"  tcp_app_win:                   {s['tcp_app_win']}")
    print(f"  tcp_adv_win_scale:             {s['tcp_adv_win_scale']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
