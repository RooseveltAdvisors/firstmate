#!/usr/bin/env python3
"""
bin/fm-jev-addr-gen-mode-guard.py - Host IPv6 Interface Identifier Address Generation Mode & Privacy Guard (Pattern 264 / Pattern 402)

Audits Linux kernel IPv6 Interface Identifier (IID) generation mode (RFC 7217 vs RFC 4291)
and address retention policies:
  - conf/*/addr_gen_mode:
      0 = IN6_ADDR_GEN_MODE_EUI64 (traditional modified EUI-64 MAC-based address, RFC 4291)
      1 = IN6_ADDR_GEN_MODE_NONE (no address generated automatically; managed by user space)
      2 = IN6_ADDR_GEN_MODE_STABLE_PRIVACY (RFC 7217 semantically opaque stable privacy address)
      3 = IN6_ADDR_GEN_MODE_RANDOM (random link-local address)
  - conf/*/keep_addr_on_down:
      0 = flush IPv6 addresses on interface down
      1 = retain IPv6 addresses on interface down
  - conf/*/use_oif_addrs_only:
      0 = RFC 6724 default source address selection
      1 = strictly select source address configured on output interface
  - conf/*/regen_max_retry:
      Max attempts to generate unique RFC 4941 temporary address on DAD collision (default: 3)

Invariants:
  - All interfaces with addr_gen_mode configured must be within valid range [0, 3].
  - regen_max_retry must be >= 1 to ensure DAD collision retry resilience.
  - Passive read-only audit: non-destructive.
  - Fail-open: graceful fallback when sysctl paths are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

CONF_IPV6_BASE = "/proc/sys/net/ipv6/conf"

ADDR_GEN_MODES = {
    0: "EUI64",
    1: "NONE",
    2: "STABLE_PRIVACY",
    3: "RANDOM",
}


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def audit_addr_gen_mode_guard(
    conf_dir: str = CONF_IPV6_BASE,
    min_regen_retry: int = 1,
) -> Dict[str, Any]:
    interfaces: Dict[str, Dict[str, Any]] = {}
    issues: List[str] = []
    mode_counts: Dict[str, int] = {name: 0 for name in ADDR_GEN_MODES.values()}
    mode_counts["UNKNOWN"] = 0
    status = "HEALTHY"

    if os.path.isdir(conf_dir):
        try:
            for ifname in sorted(os.listdir(conf_dir)):
                iface_path = os.path.join(conf_dir, ifname)
                if os.path.isdir(iface_path):
                    agm_p = os.path.join(iface_path, "addr_gen_mode")
                    keep_p = os.path.join(iface_path, "keep_addr_on_down")
                    oif_p = os.path.join(iface_path, "use_oif_addrs_only")
                    regen_p = os.path.join(iface_path, "regen_max_retry")

                    if os.path.isfile(agm_p):
                        mode_val = read_sysctl_int(agm_p, -1)
                        keep_val = read_sysctl_int(keep_p, 0)
                        oif_val = read_sysctl_int(oif_p, 0)
                        regen_val = read_sysctl_int(regen_p, 3)

                        mode_name = ADDR_GEN_MODES.get(mode_val, "UNKNOWN")
                        if mode_name in mode_counts:
                            mode_counts[mode_name] += 1
                        else:
                            mode_counts["UNKNOWN"] += 1

                        if mode_val not in ADDR_GEN_MODES:
                            issues.append(f"Interface {ifname} has invalid addr_gen_mode={mode_val}")
                            status = "WARNING"

                        if regen_val < min_regen_retry:
                            issues.append(
                                f"Interface {ifname} regen_max_retry={regen_val} below minimum {min_regen_retry}"
                            )
                            status = "WARNING"

                        interfaces[ifname] = {
                            "addr_gen_mode": mode_val,
                            "mode_name": mode_name,
                            "keep_addr_on_down": keep_val,
                            "use_oif_addrs_only": oif_val,
                            "regen_max_retry": regen_val,
                        }
        except OSError:
            pass

    default_mode = interfaces.get("default", {}).get("addr_gen_mode", 0)
    all_mode = interfaces.get("all", {}).get("addr_gen_mode", 0)

    return {
        "pattern": 264,
        "name": "addr_gen_mode",
        "description": "Host IPv6 Interface Identifier Address Generation Mode & Privacy Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "interfaces_audited": len(interfaces),
        "mode_counts": mode_counts,
        "default_mode": default_mode,
        "default_mode_name": ADDR_GEN_MODES.get(default_mode, "UNKNOWN"),
        "all_mode": all_mode,
        "all_mode_name": ADDR_GEN_MODES.get(all_mode, "UNKNOWN"),
        "eui64_interfaces": mode_counts.get("EUI64", 0),
        "none_interfaces": mode_counts.get("NONE", 0),
        "stable_privacy_interfaces": mode_counts.get("STABLE_PRIVACY", 0),
        "random_interfaces": mode_counts.get("RANDOM", 0),
        "interfaces": interfaces,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Host IPv6 Interface Identifier Address Generation Mode & Privacy Guard (Pattern 264 / Pattern 402)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    parser.add_argument("--conf-dir", default=CONF_IPV6_BASE, help="Path to /proc/sys/net/ipv6/conf directory")
    parser.add_argument(
        "--min-regen-retry", type=int, default=1, help="Minimum temporary address regen retry ceiling"
    )

    args = parser.parse_args()

    report = audit_addr_gen_mode_guard(
        conf_dir=args.conf_dir,
        min_regen_retry=args.min_regen_retry,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Pattern 264: {report['name']} - Status: {report['status']}")
        print(f"  interfaces_audited: {report['interfaces_audited']}")
        print(f"  default_mode: {report['default_mode']} ({report['default_mode_name']})")
        print(f"  all_mode: {report['all_mode']} ({report['all_mode_name']})")
        print(f"  mode breakdown: EUI64={report['eui64_interfaces']}, NONE={report['none_interfaces']}, STABLE_PRIVACY={report['stable_privacy_interfaces']}, RANDOM={report['random_interfaces']}")
        if report["issues"]:
            print("  Issues:")
            for issue in report["issues"]:
                print(f"    - {issue}")
        else:
            print("  Issues: none (nominal)")

    return 0 if report["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
