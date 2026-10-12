#!/usr/bin/env python3
"""
bin/fm-jev-tcp-fastopen-guard.py - Host Network TCP Fast Open (TFO / RFC 7413) Security & Telemetry Guard (Pattern 275 / Pattern 413)

Audits Linux kernel TCP Fast Open configuration and telemetry:
  - /proc/sys/net/ipv4/tcp_fastopen:
      Bitmap flags (0x1=client, 0x2=server, 0x4=client data without cookie, 0x200=server data without cookie).
  - /proc/sys/net/ipv4/tcp_fastopen_blackhole_timeout_sec:
      Blackhole detection re-enable timer.
  - /proc/net/netstat (TcpExt):
      TCPFastOpenActive, TCPFastOpenActiveFail, TCPFastOpenPassive, TCPFastOpenPassiveFail,
      TCPFastOpenListenOverflow, TCPFastOpenCookieReqd, TCPFastOpenBlackhole, TCPFastOpenPassiveAltKey.

Invariants:
  - Listen overflow == 0 (no TFO listen backlog drops).
  - Middlebox blackhole events <= 5.
  - Outbound TFO failure rate < 25% when sample size > 50.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_NET_NETSTAT = "/proc/net/netstat"
PROC_SYS_IPV4 = "/proc/sys/net/ipv4"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def parse_netstat_fastopen(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "TCPFastOpenActive": 0,
        "TCPFastOpenActiveFail": 0,
        "TCPFastOpenPassive": 0,
        "TCPFastOpenPassiveFail": 0,
        "TCPFastOpenListenOverflow": 0,
        "TCPFastOpenCookieReqd": 0,
        "TCPFastOpenBlackhole": 0,
        "TCPFastOpenPassiveAltKey": 0,
    }
    if not os.path.isfile(path):
        return metrics
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(0, len(lines) - 1, 2):
            if lines[i].startswith("TcpExt:"):
                headers = lines[i].split()[1:]
                values = lines[i + 1].split()[1:]
                for h, v in zip(headers, values):
                    if h in metrics:
                        try:
                            metrics[h] = int(v)
                        except ValueError:
                            pass
    except Exception:
        pass
    return metrics


def audit_tcp_fastopen_guard(
    conf_dir: str = PROC_SYS_IPV4,
    netstat_file: str = PROC_NET_NETSTAT,
    warn_active_fail_pct: float = 25.0,
    warn_passive_fail_pct: float = 15.0,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    fastopen_val = read_sysctl_int(os.path.join(conf_dir, "tcp_fastopen"), -1)
    blackhole_timeout = read_sysctl_int(os.path.join(conf_dir, "tcp_fastopen_blackhole_timeout_sec"), 0)
    metrics = parse_netstat_fastopen(netstat_file)

    client_enabled = bool(fastopen_val != -1 and (fastopen_val & 0x1))
    server_enabled = bool(fastopen_val != -1 and (fastopen_val & 0x2))
    client_no_cookie = bool(fastopen_val != -1 and (fastopen_val & 0x4))
    server_no_cookie = bool(fastopen_val != -1 and (fastopen_val & 0x200))

    active_tot = metrics["TCPFastOpenActive"] + metrics["TCPFastOpenActiveFail"]
    active_fail_pct = 0.0
    if active_tot > 0:
        active_fail_pct = round((metrics["TCPFastOpenActiveFail"] / active_tot) * 100.0, 2)

    passive_tot = metrics["TCPFastOpenPassive"] + metrics["TCPFastOpenPassiveFail"]
    passive_fail_pct = 0.0
    if passive_tot > 0:
        passive_fail_pct = round((metrics["TCPFastOpenPassiveFail"] / passive_tot) * 100.0, 2)

    if metrics["TCPFastOpenListenOverflow"] > 0:
        issues.append(
            f"TCP Fast Open listen backlog overflow detected: {metrics['TCPFastOpenListenOverflow']} drops"
        )
        recommendations.append("Increase listener backlog or tune somaxconn to accommodate TFO bursts")

    if metrics["TCPFastOpenBlackhole"] > 5:
        issues.append(
            f"Elevated TCP Fast Open middlebox blackhole events: {metrics['TCPFastOpenBlackhole']}"
        )
        recommendations.append("Inspect network path for legacy firewalls/NATs stripping SYN payload data")

    if active_tot > 50 and active_fail_pct >= warn_active_fail_pct:
        issues.append(
            f"Elevated outbound TFO failure rate: {active_fail_pct}% ({metrics['TCPFastOpenActiveFail']}/{active_tot})"
        )
        recommendations.append("Verify peer endpoint TFO cookie compatibility or consider disabling client TFO")

    if passive_tot > 50 and passive_fail_pct >= warn_passive_fail_pct:
        issues.append(
            f"Elevated inbound TFO failure rate: {passive_fail_pct}% ({metrics['TCPFastOpenPassiveFail']}/{passive_tot})"
        )
        recommendations.append("Check TFO server secret key consistency across multi-host cluster instances")

    if metrics["TCPFastOpenListenOverflow"] > 100:
        status = "CRITICAL"
    elif issues:
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "fastopen_bitmap": fastopen_val,
        "client_enabled": client_enabled,
        "server_enabled": server_enabled,
        "client_no_cookie": client_no_cookie,
        "server_no_cookie": server_no_cookie,
        "blackhole_timeout_sec": blackhole_timeout,
        "active_handshakes": metrics["TCPFastOpenActive"],
        "active_fails": metrics["TCPFastOpenActiveFail"],
        "active_fail_pct": active_fail_pct,
        "passive_handshakes": metrics["TCPFastOpenPassive"],
        "passive_fails": metrics["TCPFastOpenPassiveFail"],
        "passive_fail_pct": passive_fail_pct,
        "listen_overflows": metrics["TCPFastOpenListenOverflow"],
        "blackhole_events": metrics["TCPFastOpenBlackhole"],
        "rfc7413_compliant": (fastopen_val >= 0),
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network TCP Fast Open (TFO / RFC 7413) Security & Telemetry Guard (Pattern 275 / Pattern 413)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--conf-dir", default=PROC_SYS_IPV4, help="Path to ipv4 sysctl directory")
    parser.add_argument("--netstat-file", default=PROC_NET_NETSTAT, help="Path to netstat file")
    parser.add_argument("--warn-active-fail", type=float, default=25.0, help="Warning threshold for active fail pct")
    parser.add_argument("--warn-passive-fail", type=float, default=15.0, help="Warning threshold for passive fail pct")
    args = parser.parse_args()

    res = audit_tcp_fastopen_guard(
        conf_dir=args.conf_dir,
        netstat_file=args.netstat_file,
        warn_active_fail_pct=args.warn_active_fail,
        warn_passive_fail_pct=args.warn_passive_fail,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] TCP Fast Open Guard: {res['status']}")
        print(f"    Bitmap: {res['fastopen_bitmap']} (client={res['client_enabled']}, server={res['server_enabled']})")
        print(f"    Blackhole Timeout: {res['blackhole_timeout_sec']}s | Blackhole Events: {res['blackhole_events']}")
        print(f"    Active TFO: {res['active_handshakes']} ok, {res['active_fails']} fail ({res['active_fail_pct']}%)")
        print(f"    Passive TFO: {res['passive_handshakes']} ok, {res['passive_fails']} fail ({res['passive_fail_pct']}%)")
        print(f"    Listen Overflows: {res['listen_overflows']}")
        if res["issues"]:
            print("    Issues:")
            for iss in res["issues"]:
                print(f"      - {iss}")
        if res["recommendations"]:
            print("    Recommendations:")
            for rec in res["recommendations"]:
                print(f"      - {rec}")

    return 0 if res["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
