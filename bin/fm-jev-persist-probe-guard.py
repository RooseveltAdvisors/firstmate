#!/usr/bin/env python3
"""
bin/fm-jev-persist-probe-guard.py - Host Network TCP Zero-Window Probing & Persist Timer Stasis Guard (Pattern 169)

Audits TCP zero-window probe counters (TCPWinProbe, TCPWantZeroWindowAdv, TCPToZeroWindowAdv,
TCPFromZeroWindowAdv, TCPZeroWindowDrop) from /proc/net/netstat alongside active socket persist timer
distributions from /proc/net/tcp and /proc/net/tcp6 to detect zero-window stasis and prevent socket
buffer exhaustion across high-throughput streaming endpoints.
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
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


def parse_tcp_persist_sockets(path: str) -> List[Dict[str, int]]:
    if not os.path.exists(path):
        return []
    persist_sockets: List[Dict[str, int]] = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
        for line in lines[1:]:
            parts = line.strip().split()
            if len(parts) < 7:
                continue
            timer_parts = parts[5].split(":")
            try:
                tr = int(timer_parts[0], 16)
            except ValueError:
                continue
            if tr == 4:  # Zero-window probe / persist timer (timer_active=4)
                try:
                    retrans = int(parts[6], 16)
                    tx_queue = int(parts[4].split(":")[0], 16)
                    rx_queue = int(parts[4].split(":")[1], 16)
                    state = int(parts[3], 16)
                except (ValueError, IndexError):
                    retrans = 0
                    tx_queue = 0
                    rx_queue = 0
                    state = 1
                persist_sockets.append(
                    {
                        "state": state,
                        "retrans": retrans,
                        "tx_queue": tx_queue,
                        "rx_queue": rx_queue,
                    }
                )
    except Exception as e:
        print(f"Warning: unable to parse {path}: {e}", file=sys.stderr)
    return persist_sockets


def audit_persist_probe(
    netstat_file: str = "/proc/net/netstat",
    tcp_file: str = "/proc/net/tcp",
    tcp6_file: str = "/proc/net/tcp6",
    retries2_file: str = "/proc/sys/net/ipv4/tcp_retries2",
    warn_persist_thresh: int = 50,
    crit_persist_thresh: int = 200,
    warn_high_retry_thresh: int = 5,
    warn_zero_drop_thresh: int = 1,
    warn_probe_ratio_thresh: float = 1.0,
) -> Dict[str, Any]:
    netstat = parse_netstat(netstat_file)
    retries2 = read_sysctl_int(retries2_file)

    win_probe = netstat.get("TCPWinProbe", 0)
    want_zero_win_adv = netstat.get("TCPWantZeroWindowAdv", 0)
    to_zero_win_adv = netstat.get("TCPToZeroWindowAdv", 0)
    from_zero_win_adv = netstat.get("TCPFromZeroWindowAdv", 0)
    zero_win_drop = netstat.get("TCPZeroWindowDrop", 0)
    delivered = netstat.get("TCPDelivered", 0)

    win_probe_ratio_pct = (
        round((win_probe / delivered * 100), 4) if delivered > 0 else 0.0
    )

    persist_v4 = parse_tcp_persist_sockets(tcp_file)
    persist_v6 = parse_tcp_persist_sockets(tcp6_file)
    all_persist = persist_v4 + persist_v6

    persist_count = len(all_persist)
    high_retry_persist = [
        s for s in all_persist if s["retrans"] >= warn_high_retry_thresh
    ]
    high_retry_count = len(high_retry_persist)
    max_probe_retries = (
        max(s["retrans"] for s in all_persist) if all_persist else 0
    )
    persist_tx_bytes = sum(s["tx_queue"] for s in all_persist)

    issues: List[str] = []
    recommendations: List[str] = []
    is_critical = False

    if zero_win_drop >= warn_zero_drop_thresh:
        issues.append(
            f"TCP zero-window drops detected: {zero_win_drop:,} drops due to closed receive window buffer limits"
        )
        recommendations.append(
            "Tune receive socket buffers (net.ipv4.tcp_rmem) or throttle incoming streaming rates to prevent zero-window drops"
        )

    if persist_count >= crit_persist_thresh:
        is_critical = True
        issues.append(
            f"Critical persist timer stasis: {persist_count:,} sockets currently stalled probing zero-window peers (>= {crit_persist_thresh})"
        )
        recommendations.append(
            "Immediate remediation required: identify stalled peer connections and verify application consumer health"
        )
    elif persist_count >= warn_persist_thresh:
        issues.append(
            f"Elevated persist timer stasis: {persist_count:,} sockets currently probing zero-window peers (>= {warn_persist_thresh})"
        )
        recommendations.append(
            "Monitor persist timer socket duration and investigate downstream receiver flow control bottlenecks"
        )

    if high_retry_count > 0:
        issues.append(
            f"Stalled zero-window sockets: {high_retry_count} connection(s) with >= {warn_high_retry_thresh} unanswered persist probes (max={max_probe_retries})"
        )
        recommendations.append(
            f"Verify remote consumer responsiveness; connections may hang until tcp_retries2 ({retries2}) expires"
        )

    if delivered >= 10000 and win_probe_ratio_pct >= warn_probe_ratio_thresh:
        issues.append(
            f"Elevated zero-window probe ratio: {win_probe:,}/{delivered:,} delivered ({win_probe_ratio_pct}% >= {warn_probe_ratio_thresh}%)"
        )
        recommendations.append(
            "Audit flow control dynamics across high-throughput socket connections to reduce receiver stalls"
        )

    healthy = len(issues) == 0
    if is_critical:
        status = "CRITICAL"
    elif not healthy:
        status = "WARNING"
    else:
        status = "HEALTHY"

    return {
        "status": status,
        "healthy": healthy,
        "win_probe": win_probe,
        "win_probe_ratio_pct": win_probe_ratio_pct,
        "want_zero_win_adv": want_zero_win_adv,
        "to_zero_win_adv": to_zero_win_adv,
        "from_zero_win_adv": from_zero_win_adv,
        "zero_win_drop": zero_win_drop,
        "persist_sockets_count": persist_count,
        "high_retry_persist_count": high_retry_count,
        "max_probe_retries": max_probe_retries,
        "persist_tx_queue_bytes": persist_tx_bytes,
        "tcp_retries2": retries2,
        "delivered": delivered,
        "issues": issues,
        "recommendations": recommendations,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network TCP Zero-Window Probing & Persist Timer Stasis Guard (Pattern 169)"
    )
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")
    parser.add_argument("--netstat-file", default="/proc/net/netstat", help="Path to /proc/net/netstat")
    parser.add_argument("--tcp-file", default="/proc/net/tcp", help="Path to /proc/net/tcp")
    parser.add_argument("--tcp6-file", default="/proc/net/tcp6", help="Path to /proc/net/tcp6")
    parser.add_argument("--retries2-file", default="/proc/sys/net/ipv4/tcp_retries2", help="Path to tcp_retries2")
    parser.add_argument("--warn-persist", type=int, default=50, help="Warning threshold for persist sockets")
    parser.add_argument("--crit-persist", type=int, default=200, help="Critical threshold for persist sockets")
    parser.add_argument("--warn-retry", type=int, default=5, help="Warning threshold for unanswered persist probes")
    parser.add_argument("--warn-zero-drop", type=int, default=1, help="Warning threshold for zero window drops")
    parser.add_argument("--warn-probe-ratio", type=float, default=1.0, help="Warning threshold for win_probe ratio %%")
    args = parser.parse_args()

    result = audit_persist_probe(
        netstat_file=args.netstat_file,
        tcp_file=args.tcp_file,
        tcp6_file=args.tcp6_file,
        retries2_file=args.retries2_file,
        warn_persist_thresh=args.warn_persist,
        crit_persist_thresh=args.crit_persist,
        warn_high_retry_thresh=args.warn_retry,
        warn_zero_drop_thresh=args.warn_zero_drop,
        warn_probe_ratio_thresh=args.warn_probe_ratio,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_sym = "[OK]" if result["healthy"] else f"[{result['status']}]"
        print(f"{status_sym} TCP Zero-Window Probing & Persist Timer Guard: status={result['status']}")
        print(f"     Zero-Window Probes: {result['win_probe']:,} (ratio: {result['win_probe_ratio_pct']}%)")
        print(f"     Persist Sockets:    {result['persist_sockets_count']} (high-retry: {result['high_retry_persist_count']}, max={result['max_probe_retries']})")
        print(f"     Zero-Window Drops:  {result['zero_win_drop']:,}")
        print(f"     Zero Adv (Want/To/From): {result['want_zero_win_adv']:,} / {result['to_zero_win_adv']:,} / {result['from_zero_win_adv']:,}")
        print(f"     tcp_retries2:       {result['tcp_retries2']}")
        for iss in result["issues"]:
            print(f"     Issue: {iss}")
        for rec in result["recommendations"]:
            print(f"     Rec:   {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
