#!/usr/bin/env python3
"""
fm-jev-pmtu-guard.py - Jev Multi-Agent Host Network TCP PMTU Black Hole & MSS Clamping Guard (Pattern 144)

Audits Linux TCP Path MTU (PMTU) discovery configuration (/proc/sys/net/ipv4/tcp_mtu_probing,
/proc/sys/net/ipv4/tcp_base_mss, /proc/sys/net/ipv4/tcp_min_snd_mss) and MTU probing telemetry
from /proc/net/netstat (TCPMTUPFail, TCPMTUPSuccess, TCPDelivered).

In multi-agent environments communicating across cloud VPC peering links, WireGuard/Tailscale
mesh tunnels, and remote API endpoints, Path MTU discovery frequently encounters "black holes"
where intermediate firewalls or routers drop ICMP "Packet Too Big" (Type 3, Code 4) messages.
When DF (Don't Fragment) frames exceed tunnel MTUs, connections hang indefinitely during large
payload transfers (e.g. streaming LLM completions, diff pushes).

Linux TCP MTU Probing (RFC 4821) dynamically searches for working MSS sizes without relying on
ICMP feedback. This guard monitors PMTU probing status and probe failure ratios, ensuring
inter-agent network packets are never silently swallowed by MTU black holes.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl or procfs entries are inaccessible.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSCTL_MTU_PROBING = "/proc/sys/net/ipv4/tcp_mtu_probing"
SYSCTL_BASE_MSS = "/proc/sys/net/ipv4/tcp_base_mss"
SYSCTL_MIN_SND_MSS = "/proc/sys/net/ipv4/tcp_min_snd_mss"
PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_proc_pairs(path: Path, section_name: str) -> Dict[str, int]:
    """Parses paired header/metric lines from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(0, len(lines) - 1):
            line = lines[i]
            if line.startswith(f"{section_name}:"):
                keys = line.split()[1:]
                next_line = lines[i + 1]
                if next_line.startswith(f"{section_name}:"):
                    vals = next_line.split()[1:]
                    for k, v in zip(keys, vals):
                        try:
                            metrics[k] = int(v)
                        except ValueError:
                            continue
                break
    except Exception:
        pass
    return metrics


def audit_pmtu_guard(
    mtu_probing_file: Optional[str] = None,
    base_mss_file: Optional[str] = None,
    min_snd_mss_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits TCP MTU probing, base MSS bounds, and PMTU failure counters."""
    probing_path = Path(mtu_probing_file or SYSCTL_MTU_PROBING)
    base_mss_path = Path(base_mss_file or SYSCTL_BASE_MSS)
    min_mss_path = Path(min_snd_mss_file or SYSCTL_MIN_SND_MSS)
    netstat_path = Path(netstat_file or PROC_NETSTAT)

    tcp_mtu_probing = read_int_file(probing_path)
    if tcp_mtu_probing is None:
        tcp_mtu_probing = 0

    tcp_base_mss = read_int_file(base_mss_path)
    if tcp_base_mss is None:
        tcp_base_mss = 1024

    tcp_min_snd_mss = read_int_file(min_mss_path)
    if tcp_min_snd_mss is None:
        tcp_min_snd_mss = 48

    netstat_metrics = parse_proc_pairs(netstat_path, "TcpExt")

    mtu_fail = netstat_metrics.get("TCPMTUPFail", 0)
    mtu_success = netstat_metrics.get("TCPMTUPSuccess", 0)
    delivered = netstat_metrics.get("TCPDelivered", 0)

    total_probes = mtu_fail + mtu_success
    fail_ratio_pct = round((mtu_fail / max(total_probes, 1)) * 100, 2) if total_probes > 0 else 0.0

    status = "HEALTHY"
    issues: List[str] = []
    recommendations: List[str] = []

    # Evaluation Rules
    if total_probes > 500 and fail_ratio_pct > 60.0:
        status = "CRITICAL"
        issues.append(f"Severe PMTU probing failure ratio ({mtu_fail:,} failed / {total_probes:,} probes, {fail_ratio_pct}%)")
        recommendations.append("Investigate middlebox ICMP packet drops or lower interface MTU to 1420/1280")
    elif mtu_fail > 1000:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Elevated PMTU probe failures ({mtu_fail:,} failures)")
        recommendations.append("Verify tunnel MSS clamping or enable tcp_mtu_probing=1")

    if tcp_base_mss < 512 or tcp_base_mss > 1460:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"Abnormal tcp_base_mss ({tcp_base_mss}); recommended range is 512–1460 bytes")
        recommendations.append("Restore net.ipv4.tcp_base_mss to 1024")

    if tcp_min_snd_mss < 48:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(f"tcp_min_snd_mss ({tcp_min_snd_mss}) is below safe RFC floor (48 bytes)")
        recommendations.append("Restore net.ipv4.tcp_min_snd_mss to 48")

    if not recommendations:
        if tcp_mtu_probing == 0:
            recommendations.append("Consider setting net.ipv4.tcp_mtu_probing=1 for automatic RFC 4821 black-hole recovery")
        else:
            recommendations.append("TCP PMTU discovery, black hole probing, and MSS clamping operating nominally")

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "tcp_mtu_probing": tcp_mtu_probing,
            "tcp_base_mss": tcp_base_mss,
            "tcp_min_snd_mss": tcp_min_snd_mss,
            "mtu_probes_failed": mtu_fail,
            "mtu_probes_succeeded": mtu_success,
            "total_probes": total_probes,
            "fail_ratio_pct": fail_ratio_pct,
            "issues": issues,
            "recommendations": recommendations,
        },
        "counters": {
            "tcp_mtup_fail": mtu_fail,
            "tcp_mtup_success": mtu_success,
            "tcp_delivered": delivered,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP PMTU Guard (Pattern 144)"
    )
    parser.add_argument("--json", action="store_true", help="Output audit results in JSON format")
    parser.add_argument("--mtu-probing-file", type=str, help="Override path to tcp_mtu_probing sysctl")
    parser.add_argument("--base-mss-file", type=str, help="Override path to tcp_base_mss sysctl")
    parser.add_argument("--min-snd-mss-file", type=str, help="Override path to tcp_min_snd_mss sysctl")
    parser.add_argument("--netstat-file", type=str, help="Override path to /proc/net/netstat")

    args = parser.parse_args()

    result = audit_pmtu_guard(
        mtu_probing_file=args.mtu_probing_file,
        base_mss_file=args.base_mss_file,
        min_snd_mss_file=args.min_snd_mss_file,
        netstat_file=args.netstat_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    s = result["summary"]
    c = result["counters"]

    print("=== Jev Host Network TCP PMTU Black Hole Guard (Pattern 144) ===")
    print(f"Status:                    {s['status']}")
    print(f"TCP MTU Probing:           {'Disabled (0)' if s['tcp_mtu_probing'] == 0 else ('Blackhole-Only (1)' if s['tcp_mtu_probing'] == 1 else 'Always (2)')}")
    print(f"Base MSS:                  {s['tcp_base_mss']} bytes")
    print(f"Min Send MSS:              {s['tcp_min_snd_mss']} bytes")
    print(f"MTU Probes Succeeded:      {c['tcp_mtup_success']:,}")
    print(f"MTU Probes Failed:         {c['tcp_mtup_fail']:,} ({s['fail_ratio_pct']}%)")
    print(f"Total Segments Delivered:  {c['tcp_delivered']:,}")

    if s["issues"]:
        print("\nIssues Identified:")
        for issue in s["issues"]:
            print(f"  - [!] {issue}")

    print("\nRecommendations:")
    for rec in s["recommendations"]:
        print(f"  - {rec}")


if __name__ == "__main__":
    main()
