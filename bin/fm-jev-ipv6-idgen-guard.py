#!/usr/bin/env python3
"""
bin/fm-jev-ipv6-idgen-guard.py - Host IPv6 RFC 7217 Interface Identifier (IID) Generation Delay & Retries Guard (Pattern 271 / Pattern 409)

Audits Linux kernel IPv6 RFC 7217 semantically opaque stable privacy address and interface identifier (IID) generation policies:
  - /proc/sys/net/ipv6/idgen_delay:
      Delay in seconds between address generation attempts upon DAD collision (default: 1).
  - /proc/sys/net/ipv6/idgen_retries:
      Maximum number of generation attempts for interface identifiers (default: 3).
  - /proc/sys/net/ipv6/conf/*/regen_max_retry:
      Maximum attempts to generate temporary addresses upon collision (default: 3).
  - /proc/net/snmp6:
      Ip6InReceives, Ip6InHdrErrors, Ip6InAddrErrors, Ip6InDiscards telemetry.

Invariants:
  - idgen_delay must be >= 1 and <= 60.
  - idgen_retries must be >= 1.
  - regen_max_retry across all interfaces must be >= 1.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing or restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_SYS_IPV6 = "/proc/sys/net/ipv6"
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


def parse_snmp6_addr_telemetry(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "Ip6InReceives": 0,
        "Ip6InHdrErrors": 0,
        "Ip6InAddrErrors": 0,
        "Ip6InDiscards": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for line in lines:
            parts = line.split()
            if len(parts) >= 2 and parts[0] in metrics:
                try:
                    metrics[parts[0]] = int(parts[1])
                except ValueError:
                    pass
    except Exception:
        pass
    return metrics


def audit_ipv6_idgen_guard(
    ipv6_dir: str = PROC_SYS_IPV6,
    snmp6_file: str = PROC_SNMP6,
) -> Dict[str, Any]:
    issues: List[str] = []
    status = "HEALTHY"

    idgen_delay = read_sysctl_int(os.path.join(ipv6_dir, "idgen_delay"), default=1)
    idgen_retries = read_sysctl_int(os.path.join(ipv6_dir, "idgen_retries"), default=3)

    if idgen_delay < 1 and idgen_delay != -1:
        issues.append(
            f"IPv6 idgen_delay={idgen_delay} is below 1 second; risks rapid collision loops"
        )
        status = "WARNING"
    elif idgen_delay > 60:
        issues.append(
            f"IPv6 idgen_delay={idgen_delay} exceeds 60 seconds; risks prolonged address configuration stalls"
        )
        status = "WARNING"

    if idgen_retries < 1 and idgen_retries != -1:
        issues.append(
            f"IPv6 idgen_retries={idgen_retries} is below 1; address generation collision retry disabled"
        )
        status = "WARNING"

    conf_dir = os.path.join(ipv6_dir, "conf")
    interface_retries: Dict[str, int] = {}
    if os.path.isdir(conf_dir):
        for iface in sorted(os.listdir(conf_dir)):
            iface_path = os.path.join(conf_dir, iface)
            if os.path.isdir(iface_path):
                retry_val = read_sysctl_int(os.path.join(iface_path, "regen_max_retry"), default=3)
                interface_retries[iface] = retry_val
                if retry_val < 1 and retry_val != -1:
                    issues.append(f"Interface '{iface}' regen_max_retry={retry_val} is below 1")
                    status = "WARNING"

    snmp_stats = parse_snmp6_addr_telemetry(snmp6_file)
    if snmp_stats["Ip6InAddrErrors"] > 0:
        issues.append(f"Detected {snmp_stats['Ip6InAddrErrors']} IPv6 inbound address errors")
        status = "WARNING"

    return {
        "pattern": 271,
        "name": "ipv6_idgen",
        "description": "Host IPv6 RFC 7217 Interface Identifier (IID) Generation Delay & Retries Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "idgen_delay_sec": idgen_delay,
        "idgen_retries": idgen_retries,
        "audited_interfaces": len(interface_retries),
        "in_addr_errors": snmp_stats["Ip6InAddrErrors"],
        "in_receives": snmp_stats["Ip6InReceives"],
        "rfc7217_compliant": (idgen_delay >= 1 and idgen_retries >= 1),
        "telemetry": snmp_stats,
        "interface_regen_max_retries": interface_retries,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host IPv6 RFC 7217 Interface Identifier (IID) Generation Delay & Retries Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results as JSON")
    parser.add_argument(
        "--ipv6-dir",
        default=PROC_SYS_IPV6,
        help="IPv6 sysctl directory (default: /proc/sys/net/ipv6)",
    )
    parser.add_argument(
        "--snmp6-file",
        default=PROC_SNMP6,
        help="SNMP6 proc file (default: /proc/net/snmp6)",
    )
    args = parser.parse_args()

    res = audit_ipv6_idgen_guard(ipv6_dir=args.ipv6_dir, snmp6_file=args.snmp6_file)

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"Pattern {res['pattern']}: {res['name']} - Status: {res['status']}")
        print(
            f"  idgen_delay={res['idgen_delay_sec']}s, idgen_retries={res['idgen_retries']} "
            f"(rfc7217_compliant={res['rfc7217_compliant']})"
        )
        print(
            f"  interfaces_audited={res['audited_interfaces']}, "
            f"in_addr_errors={res['in_addr_errors']}, in_receives={res['in_receives']}"
        )
        if res["issues"]:
            print("  Issues:")
            for issue in res["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if res["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
