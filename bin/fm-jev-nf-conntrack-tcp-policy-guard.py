#!/usr/bin/env python3
"""
bin/fm-jev-nf-conntrack-tcp-policy-guard.py - Host Network Netfilter TCP Connection Tracking State & Security Policy Guard (Pattern 270 / Pattern 408)

Audits Linux kernel Netfilter TCP connection tracking security and state-machine policies:
  - /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal:
      Strict RFC 793 window tracking vs liberal acceptance (default 0).
  - /proc/sys/net/netfilter/nf_conntrack_tcp_ignore_invalid_rst:
      Invalid TCP RST packet drop vs acceptance policy (default 0).
  - /proc/sys/net/netfilter/nf_conntrack_tcp_loose:
      Connection pickup policy for mid-stream flows (default 1).
  - /proc/sys/net/netfilter/nf_conntrack_tcp_max_retrans:
      Maximum unacknowledged TCP retransmissions before eviction (default 3).
  - /proc/sys/net/netfilter/nf_conntrack_checksum:
      Layer 4 TCP/UDP checksum validation before flow tracking (default 1).
  - /proc/sys/net/netfilter/nf_conntrack_log_invalid:
      Rate limiting / dmesg logging for invalid packets (default 0).

Invariants:
  - be_liberal should be 0 (enforcing strict RFC 793 window tracking).
  - checksum should be 1 (verifying L4 packet integrity).
  - max_retrans should be >= 1 (allowing clean connection teardown).
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

PROC_NETFILTER_DIR = "/proc/sys/net/netfilter"
PROC_SNMP = "/proc/net/snmp"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content else default
    except (ValueError, OSError, IndexError):
        return default


def parse_tcp_snmp(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {
        "EstabResets": 0,
        "InErrs": 0,
        "InCsumErrors": 0,
    }
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(0, len(lines) - 1, 2):
            if lines[i].startswith("Tcp:"):
                headers = lines[i].split()[1:]
                values = lines[i + 1].split()[1:]
                for h, v in zip(headers, values):
                    if h in metrics:
                        try:
                            metrics[h] = int(v)
                        except ValueError:
                            pass
                break
    except Exception:
        pass
    return metrics


def audit_nf_conntrack_tcp_policy_guard(
    conf_dir: str = PROC_NETFILTER_DIR,
    snmp_file: str = PROC_SNMP,
) -> Dict[str, Any]:
    issues: List[str] = []
    status = "HEALTHY"

    be_liberal = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_be_liberal"), 0)
    ignore_invalid_rst = read_sysctl_int(
        os.path.join(conf_dir, "nf_conntrack_tcp_ignore_invalid_rst"), 0
    )
    loose = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_loose"), 1)
    max_retrans = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_tcp_max_retrans"), 3)
    checksum = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_checksum"), 1)
    log_invalid = read_sysctl_int(os.path.join(conf_dir, "nf_conntrack_log_invalid"), 0)

    snmp_stats = parse_tcp_snmp(snmp_file)

    if be_liberal != 0 and be_liberal != -1:
        issues.append(
            f"Liberal TCP window tracking enabled (nf_conntrack_tcp_be_liberal={be_liberal}); out-of-window packets accepted"
        )
        status = "WARNING"

    if checksum == 0:
        issues.append(
            "Netfilter Layer 4 checksum verification is disabled (nf_conntrack_checksum=0)"
        )
        status = "WARNING"

    if max_retrans <= 0 and max_retrans != -1:
        issues.append(
            f"Netfilter TCP max retransmissions set to invalid value (nf_conntrack_tcp_max_retrans={max_retrans})"
        )
        status = "WARNING"

    return {
        "pattern": 270,
        "name": "nf_conntrack_tcp_policy",
        "description": "Host Network Netfilter TCP Connection Tracking State & Security Policy Guard",
        "status": status,
        "healthy": (status == "HEALTHY"),
        "timestamp": datetime.timezone.utc and datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "tcp_be_liberal": be_liberal,
        "tcp_ignore_invalid_rst": ignore_invalid_rst,
        "tcp_loose": loose,
        "tcp_max_retrans": max_retrans,
        "checksum_enabled": (checksum == 1),
        "log_invalid": log_invalid,
        "strict_window_tracking": (be_liberal == 0),
        "telemetry": snmp_stats,
        "issues": issues,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Netfilter TCP Connection Tracking State & Security Policy Guard"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results as JSON")
    parser.add_argument(
        "--conf-dir",
        default=PROC_NETFILTER_DIR,
        help="Netfilter sysctl directory (default: /proc/sys/net/netfilter)",
    )
    parser.add_argument(
        "--snmp-file",
        default=PROC_SNMP,
        help="SNMP proc file (default: /proc/net/snmp)",
    )
    args = parser.parse_args()

    res = audit_nf_conntrack_tcp_policy_guard(conf_dir=args.conf_dir, snmp_file=args.snmp_file)

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(f"Pattern {res['pattern']}: {res['name']} - Status: {res['status']}")
        print(
            f"  be_liberal={res['tcp_be_liberal']} (strict_window={res['strict_window_tracking']}), "
            f"checksum_enabled={res['checksum_enabled']}"
        )
        print(
            f"  loose={res['tcp_loose']}, max_retrans={res['tcp_max_retrans']}, "
            f"ignore_invalid_rst={res['tcp_ignore_invalid_rst']}"
        )
        print(
            f"  snmp: EstabResets={res['telemetry']['EstabResets']}, "
            f"InErrs={res['telemetry']['InErrs']}, InCsumErrors={res['telemetry']['InCsumErrors']}"
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
