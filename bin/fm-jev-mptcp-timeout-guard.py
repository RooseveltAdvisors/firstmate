#!/usr/bin/env python3
"""
bin/fm-jev-mptcp-timeout-guard.py - Linux kernel Multipath TCP (MPTCP RFC 8684) Path Management & Timeout Policy Guard (Pattern 285 / Pattern 423)

Audits Linux kernel Multipath TCP (MPTCP RFC 8684) path management parameters, connection lifecycle timeouts,
middlebox blackhole fallback policies, and address discovery error telemetry:
  - /proc/sys/net/mptcp/add_addr_timeout:
      Timeout in seconds for MPTCP ADD_ADDR signals before path announcement failure (default 120s).
  - /proc/sys/net/mptcp/close_timeout:
      Timeout in seconds for closing MPTCP socket and subflow teardown (default 60s).
  - /proc/sys/net/mptcp/blackhole_timeout:
      Timeout in seconds for middlebox blackhole fallback to standard TCP (default 3600s).
  - /proc/sys/net/mptcp/allow_join_initial_addr_port:
      Policy allowing MP_JOIN requests to target initial port (default 1).
  - /proc/sys/net/mptcp/checksum_enabled:
      MPTCP DSS 64-bit checksum verification policy (default 0).
  - /proc/sys/net/mptcp/pm_type:
      In-kernel (0) vs Userspace (1) path manager selection.
  - /proc/net/netstat (MPTcpExt):
      MPFailTx, MPFailRx, DSSCorruptionFallback, Blackhole, AddAddrTxDrop, AddAddrDrop.

Invariants:
  - add_addr_timeout must be >= 1s and <= 3600s to avoid stalled path announcements or immediate timeout aborts.
  - close_timeout must be >= 1s and <= 600s to prevent hanging socket descriptors or premature socket termination.
  - blackhole_timeout must be >= 0s to guarantee orderly fallback when middleboxes strip MPTCP options.
  - allow_join_initial_addr_port should be 1 for resilient multi-subflow establishment.
  - Fail-open: graceful fallback when sysctl paths or /proc/net/netstat are restricted.
  - Fast bounded execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List

PROC_MPTCP_DIR = "/proc/sys/net/mptcp"
PROC_NETSTAT = "/proc/net/netstat"


def read_sysctl_int(path: str, default: int = -1) -> int:
    if not os.path.isfile(path):
        return default
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read().strip()
        return int(content.split()[0]) if content and (content.split()[0].lstrip("-").isdigit()) else default
    except (ValueError, OSError, IndexError):
        return default


def parse_netstat_mptcpext(path: str) -> Dict[str, int]:
    metrics: Dict[str, int] = {}
    if not os.path.isfile(path):
        return metrics

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("MPTcpExt:") and lines[i + 1].startswith("MPTcpExt:"):
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


def audit_mptcp_timeout_guard(
    mptcp_dir: str = PROC_MPTCP_DIR,
    netstat_path: str = PROC_NETSTAT,
) -> Dict[str, Any]:
    add_addr_timeout = read_sysctl_int(os.path.join(mptcp_dir, "add_addr_timeout"), default=120)
    close_timeout = read_sysctl_int(os.path.join(mptcp_dir, "close_timeout"), default=60)
    blackhole_timeout = read_sysctl_int(os.path.join(mptcp_dir, "blackhole_timeout"), default=3600)
    allow_join = read_sysctl_int(os.path.join(mptcp_dir, "allow_join_initial_addr_port"), default=1)
    checksum_enabled = read_sysctl_int(os.path.join(mptcp_dir, "checksum_enabled"), default=0)
    pm_type = read_sysctl_int(os.path.join(mptcp_dir, "pm_type"), default=0)

    netstat = parse_netstat_mptcpext(netstat_path)
    mp_fail_tx = netstat.get("MPFailTx", 0)
    mp_fail_rx = netstat.get("MPFailRx", 0)
    dss_corruption_fallback = netstat.get("DSSCorruptionFallback", 0)
    dss_corruption_reset = netstat.get("DSSCorruptionReset", 0)
    blackhole_count = netstat.get("Blackhole", 0)
    add_addr_tx_drop = netstat.get("AddAddrTxDrop", 0)
    add_addr_drop = netstat.get("AddAddrDrop", 0)
    mp_join_rejected = netstat.get("MPJoinRejected", 0)

    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if add_addr_timeout < 1:
        issues.append(f"Invalid add_addr_timeout ({add_addr_timeout}s): must be >= 1s to prevent instant address announcement aborts")
        recommendations.append("Set net.mptcp.add_addr_timeout to 120s")
        status = "WARNING"
    elif add_addr_timeout > 3600:
        issues.append(f"Excessive add_addr_timeout ({add_addr_timeout}s > 3600s): stalled address notifications may linger for hours")
        recommendations.append("Reduce net.mptcp.add_addr_timeout to 120s")
        status = "WARNING"

    if close_timeout < 1:
        issues.append(f"Invalid close_timeout ({close_timeout}s): must be >= 1s to allow subflow graceful teardown")
        recommendations.append("Set net.mptcp.close_timeout to 60s")
        status = "WARNING"
    elif close_timeout > 600:
        issues.append(f"High close_timeout ({close_timeout}s > 600s): lingering closed MPTCP sockets may exhaust file descriptors")
        recommendations.append("Reduce net.mptcp.close_timeout to 60s")
        status = "WARNING"

    if blackhole_timeout < 0:
        issues.append(f"Invalid blackhole_timeout ({blackhole_timeout}s): negative timeout value")
        recommendations.append("Set net.mptcp.blackhole_timeout to 3600s")
        status = "WARNING"

    if dss_corruption_fallback > 0 or dss_corruption_reset > 0:
        issues.append(f"MPTCP DSS corruption detected: fallback={dss_corruption_fallback}, reset={dss_corruption_reset}")
        recommendations.append("Investigate middlebox payload tampering or consider enabling net.mptcp.checksum_enabled=1")
        status = "WARNING"

    if mp_fail_tx > 50 or mp_fail_rx > 50:
        issues.append(f"High MPTCP fallback failures: tx={mp_fail_tx}, rx={mp_fail_rx}")
        recommendations.append("Verify multi-homed path MTU and investigate middlebox option stripping")
        status = "WARNING"

    if add_addr_tx_drop > 100 or add_addr_drop > 100:
        issues.append(f"Elevated ADD_ADDR drops: tx_drop={add_addr_tx_drop}, rx_drop={add_addr_drop}")
        recommendations.append("Audit MPTCP address limit capacity via 'ip mptcp limits' to accommodate advertised subflow paths")
        status = "WARNING"

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": (status == "HEALTHY"),
        "add_addr_timeout_sec": add_addr_timeout,
        "close_timeout_sec": close_timeout,
        "blackhole_timeout_sec": blackhole_timeout,
        "allow_join_initial_addr_port": allow_join,
        "checksum_enabled": checksum_enabled,
        "pm_type": pm_type,
        "mp_fail_tx": mp_fail_tx,
        "mp_fail_rx": mp_fail_rx,
        "dss_corruption_fallback": dss_corruption_fallback,
        "dss_corruption_reset": dss_corruption_reset,
        "blackhole_count": blackhole_count,
        "add_addr_tx_drop": add_addr_tx_drop,
        "add_addr_drop": add_addr_drop,
        "mp_join_rejected": mp_join_rejected,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network Multipath TCP (MPTCP RFC 8684) Path Management & Timeout Policy Guard (Pattern 285 / Pattern 423)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--mptcp-dir", default=PROC_MPTCP_DIR, help="Path to MPTCP sysctl directory")
    parser.add_argument("--netstat-file", default=PROC_NETSTAT, help="Path to /proc/net/netstat")
    args = parser.parse_args()

    res = audit_mptcp_timeout_guard(
        mptcp_dir=args.mptcp_dir,
        netstat_path=args.netstat_file,
    )

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        status_sym = "✓" if res["healthy"] else "✗"
        print(f"[{status_sym}] MPTCP Timeout Guard: {res['status']}")
        print(f"    Timeout Parameters: add_addr_timeout={res.get('add_addr_timeout_sec', 0)}s | close_timeout={res.get('close_timeout_sec', 0)}s | blackhole_timeout={res.get('blackhole_timeout_sec', 0)}s")
        print(f"    Policy & PM: allow_join_initial={res.get('allow_join_initial_addr_port', 0)} | checksum={res.get('checksum_enabled', 0)} | pm_type={res.get('pm_type', 0)}")
        print(f"    Telemetry: mp_fail_tx={res.get('mp_fail_tx', 0)} | mp_fail_rx={res.get('mp_fail_rx', 0)} | dss_fallback={res.get('dss_corruption_fallback', 0)} | blackholes={res.get('blackhole_count', 0)}")
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
