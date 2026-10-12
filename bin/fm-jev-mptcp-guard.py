#!/usr/bin/env python3
"""
bin/fm-jev-mptcp-guard.py - Host Network Multipath TCP (MPTCP) Subflow Health & Path Manager Guard (Pattern 172)

Audits kernel Multipath TCP (MPTCP RFC 8684) sysctl parameters (enabled, path_manager,
scheduler, syn_retrans_before_tcp_fallback) alongside MPTcpExt netstat counters
(MPCapableSYNRX, MPJoinSynRx, MPFailTx, DSSCorruptionFallback, SubflowStale, SubflowRecover)
to verify multipath subflow resilience and fallback stability across multi-agent connections.
"""

import argparse
import datetime
import json
import os
import subprocess
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


def read_sysctl_str(path: str) -> str:
    if not os.path.exists(path):
        return "unknown"
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception as e:
        print(f"Warning: unable to read {path}: {e}", file=sys.stderr)
        return "unknown"


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


def get_mptcp_limits() -> Dict[str, Any]:
    limits = {"subflows": 2, "add_addr_accepted": 0, "available": False}
    try:
        res = subprocess.run(
            ["ip", "mptcp", "limits", "show"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if res.returncode == 0:
            limits["available"] = True
            parts = res.stdout.strip().split()
            for i in range(len(parts) - 1):
                if parts[i] == "subflows":
                    limits["subflows"] = int(parts[i + 1])
                elif parts[i] == "add_addr_accepted":
                    limits["add_addr_accepted"] = int(parts[i + 1])
    except Exception:
        pass
    return limits


def audit_mptcp(
    enabled_file: str = "/proc/sys/net/mptcp/enabled",
    path_manager_file: str = "/proc/sys/net/mptcp/path_manager",
    scheduler_file: str = "/proc/sys/net/mptcp/scheduler",
    syn_fallback_file: str = "/proc/sys/net/mptcp/syn_retrans_before_tcp_fallback",
    stale_loss_file: str = "/proc/sys/net/mptcp/stale_loss_cnt",
    netstat_file: str = "/proc/net/netstat",
    check_ip: bool = True,
) -> Dict[str, Any]:
    enabled = read_sysctl_int(enabled_file)
    path_manager = read_sysctl_str(path_manager_file)
    scheduler = read_sysctl_str(scheduler_file)
    syn_fallback = read_sysctl_int(syn_fallback_file)
    stale_loss = read_sysctl_int(stale_loss_file)
    netstat = parse_netstat(netstat_file)
    limits = get_mptcp_limits() if check_ip else {"subflows": 2, "add_addr_accepted": 0, "available": False}

    mp_capable_syn_rx = netstat.get("MPCapableSYNRX", 0)
    mp_capable_syn_tx = netstat.get("MPCapableSYNTX", 0)
    mp_join_syn_rx = netstat.get("MPJoinSynRx", 0)
    mp_join_syn_tx = netstat.get("MPJoinSynTx", 0)
    mp_fail_tx = netstat.get("MPFailTx", 0)
    mp_fail_rx = netstat.get("MPFailRx", 0)
    dss_corruption_fallback = netstat.get("DSSCorruptionFallback", 0)
    dss_corruption_reset = netstat.get("DSSCorruptionReset", 0)
    subflow_stale = netstat.get("SubflowStale", 0)
    subflow_recover = netstat.get("SubflowRecover", 0)
    mp_curr_estab = netstat.get("MPCurrEstab", 0)
    blackhole = netstat.get("Blackhole", 0)

    issues = []
    status = "HEALTHY"
    healthy = True

    if dss_corruption_fallback > 0 or dss_corruption_reset > 0:
        status = "WARNING"
        healthy = False
        issues.append(f"MPTCP DSS corruption detected (fallback={dss_corruption_fallback}, reset={dss_corruption_reset})")

    if mp_fail_tx > 10 or mp_fail_rx > 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Elevated MPTCP fallback failures (tx={mp_fail_tx}, rx={mp_fail_rx})")

    if subflow_stale > subflow_recover + 10:
        status = "WARNING"
        healthy = False
        issues.append(f"Subflows stale without recovery (stale={subflow_stale}, recovered={subflow_recover})")

    if blackhole > 5:
        status = "WARNING"
        healthy = False
        issues.append(f"MPTCP path blackholing detected (count={blackhole})")

    summary = {
        "status": status,
        "healthy": healthy,
        "mptcp_enabled": enabled,
        "path_manager": path_manager,
        "scheduler": scheduler,
        "syn_retrans_before_tcp_fallback": syn_fallback,
        "stale_loss_cnt": stale_loss,
        "curr_estab": mp_curr_estab,
        "mp_capable_syn_rx": mp_capable_syn_rx,
        "mp_capable_syn_tx": mp_capable_syn_tx,
        "mp_join_syn_rx": mp_join_syn_rx,
        "mp_join_syn_tx": mp_join_syn_tx,
        "mp_fail_tx": mp_fail_tx,
        "mp_fail_rx": mp_fail_rx,
        "dss_corruption_fallback": dss_corruption_fallback,
        "subflow_stale": subflow_stale,
        "subflow_recover": subflow_recover,
        "blackhole": blackhole,
        "limits": limits,
        "issues": issues,
    }

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": summary,
        "sysctls": {
            "enabled": enabled,
            "path_manager": path_manager,
            "scheduler": scheduler,
            "syn_retrans_before_tcp_fallback": syn_fallback,
            "stale_loss_cnt": stale_loss,
        },
        "counters": {
            "MPCapableSYNRX": mp_capable_syn_rx,
            "MPCapableSYNTX": mp_capable_syn_tx,
            "MPJoinSynRx": mp_join_syn_rx,
            "MPJoinSynTx": mp_join_syn_tx,
            "MPFailTx": mp_fail_tx,
            "MPFailRx": mp_fail_rx,
            "DSSCorruptionFallback": dss_corruption_fallback,
            "DSSCorruptionReset": dss_corruption_reset,
            "SubflowStale": subflow_stale,
            "SubflowRecover": subflow_recover,
            "MPCurrEstab": mp_curr_estab,
            "Blackhole": blackhole,
        },
        "limits": limits,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Host Network Multipath TCP (MPTCP) Subflow Health & Path Manager Guard (Pattern 172)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit report as JSON")
    args = parser.parse_args()

    report = audit_mptcp()

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    s = report["summary"]
    print(f"MPTCP Subflow Health Guard (Pattern 172) - Status: {s['status']}")
    print(f"  net.mptcp.enabled:                  {s['mptcp_enabled']} (1 = enabled)")
    print(f"  path_manager:                       {s['path_manager']}")
    print(f"  scheduler:                          {s['scheduler']}")
    print(f"  syn_retrans_before_tcp_fallback:   {s['syn_retrans_before_tcp_fallback']}")
    print(f"  stale_loss_cnt:                     {s['stale_loss_cnt']}")
    print(f"  Current Established Sockets:        {s['curr_estab']}")
    print(f"  MPCapable SYN RX / TX:              {s['mp_capable_syn_rx']} / {s['mp_capable_syn_tx']}")
    print(f"  MPJoin SYN RX / TX:                 {s['mp_join_syn_rx']} / {s['mp_join_syn_tx']}")
    print(f"  MPFail TX / RX:                     {s['mp_fail_tx']} / {s['mp_fail_rx']}")
    print(f"  DSS Corruption Fallback / Reset:    {s['dss_corruption_fallback']}")
    print(f"  Subflows Stale / Recovered:         {s['subflow_stale']} / {s['subflow_recover']}")
    print(f"  Blackhole events:                   {s['blackhole']}")
    if s["limits"]["available"]:
        print(f"  ip mptcp limits:                    subflows={s['limits']['subflows']}, add_addr_accepted={s['limits']['add_addr_accepted']}")

    if s["issues"]:
        print("\nIssues:")
        for iss in s["issues"]:
            print(f"  - {iss}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
