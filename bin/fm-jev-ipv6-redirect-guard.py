#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-redirect-guard.py - Host IPv6 ICMPv6 Redirect Policy & Telemetry Guard (Pattern 265 / Pattern 403)

Audits Linux kernel IPv6 ICMPv6 redirect policies (RFC 4861 §4.5, §8)
and redirect traffic telemetry:
  - conf/*/accept_redirects:
      0 = drop all incoming ICMPv6 redirect messages (hardened router / secure host)
      1 = accept ICMPv6 redirects for off-link routing updates
  - conf/*/forwarding:
      0 = host mode (may accept redirects per RFC 4861 §4.5)
      1 = router mode (RFC 4861 §8 mandates routers MUST NOT accept redirects)
  - /proc/net/snmp6:
      Icmp6InRedirects = incoming redirect count
      Icmp6OutRedirects = outgoing redirect count
      Icmp6InErrors = ICMPv6 general input errors

Invariants:
  - All interfaces with accept_redirects must have value in {0, 1}.
  - RFC 4861 §8: If forwarding == 1, accept_redirects must be 0 (routers must not accept redirects).
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths or snmp6 are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV6_BASE = "/proc/sys/net/ipv6/conf"
PROC_SNMP6 = "/proc/net/snmp6"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def parse_snmp6_redirects(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "Icmp6InRedirects": 0,
        "Icmp6OutRedirects": 0,
        "Icmp6InErrors": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2 and parts[0] in metrics:
                    try:
                        metrics[parts[0]] = int(parts[1])
                    except ValueError:
                        pass
    except OSError:
        pass
    return metrics


def audit_ipv6_redirect_guard(
    conf_dir: str = CONF_IPV6_BASE,
    snmp6_path: str = PROC_SNMP6,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, Any]] = {}
    issues: List[str] = []
    status = "HEALTHY"
    accepting_count = 0
    dropping_count = 0

    if os.path.isdir(conf_dir):
        try:
            for ifname in sorted(os.listdir(conf_dir)):
                iface_path = os.path.join(conf_dir, ifname)
                if os.path.isdir(iface_path):
                    redir_p = os.path.join(iface_path, "accept_redirects")
                    fwd_p = os.path.join(iface_path, "forwarding")

                    if os.path.isfile(redir_p):
                        redir_val = read_sysctl_int(redir_p, -1)
                        fwd_val = read_sysctl_int(fwd_p, 0)

                        if redir_val not in (0, 1):
                            issues.append(f"Interface {ifname} has invalid accept_redirects={redir_val}")
                            status = "WARNING"
                        elif redir_val == 1:
                            accepting_count += 1
                        else:
                            dropping_count += 1

                        if fwd_val == 1 and redir_val == 1:
                            issues.append(
                                f"Interface {ifname} has forwarding=1 but accept_redirects=1; "
                                "RFC 4861 §8 mandates IPv6 routers MUST NOT accept redirects"
                            )
                            status = "WARNING"

                        interfaces[ifname] = {
                            "accept_redirects": redir_val,
                            "forwarding": fwd_val,
                            "rfc4861_compliant": not (fwd_val == 1 and redir_val == 1),
                        }
        except OSError:
            pass

    snmp6_metrics = parse_snmp6_redirects(snmp6_path)
    in_redirects = snmp6_metrics.get("Icmp6InRedirects", 0)
    out_redirects = snmp6_metrics.get("Icmp6OutRedirects", 0)
    in_errors = snmp6_metrics.get("Icmp6InErrors", 0)

    default_redir = interfaces.get("default", {}).get("accept_redirects", 1)
    all_redir = interfaces.get("all", {}).get("accept_redirects", 1)

    return {
        "pattern": 265,
        "name": "ipv6_redirect",
        "description": "Host IPv6 ICMPv6 Redirect Policy & Telemetry Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "accepting_interfaces_count": accepting_count,
        "dropping_interfaces_count": dropping_count,
        "default_accept_redirects": default_redir,
        "all_accept_redirects": all_redir,
        "in_redirects": in_redirects,
        "out_redirects": out_redirects,
        "in_errors": in_errors,
        "interfaces": interfaces,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 ICMPv6 Redirect Policy & Telemetry Guard (Pattern 265 / Pattern 403)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to /proc/sys/net/ipv6/conf directory")
    parser.add_argument("--snmp6-file", default=PROC_SNMP6, help="Path to /proc/net/snmp6")

    args = parser.parse_args()

    report = audit_ipv6_redirect_guard(
        conf_dir=args.conf_dir,
        snmp6_path=args.snmp6_file,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 265: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  accepting_interfaces_count: {report['accepting_interfaces_count']}")
        print(f"  dropping_interfaces_count: {report['dropping_interfaces_count']}")
        print(f"  default_accept_redirects: {report['default_accept_redirects']}")
        print(f"  in_redirects: {report['in_redirects']}, out_redirects: {report['out_redirects']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
