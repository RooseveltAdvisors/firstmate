#!/usr/bin/env python3
"""
fm-jev-rtt-guard.py - Jev Multi-Agent Host Network TCP RTT Smoothing & Min RTT Window Guard (Pattern 133)

Audits Linux TCP Round-Trip Time (RTT) smoothing, minimum RTT filter window
(/proc/sys/net/ipv4/tcp_min_rtt_wlen), Forward RTO algorithm (/proc/sys/net/ipv4/tcp_frto),
congestion control algorithm (/proc/sys/net/ipv4/tcp_congestion_control),
and spurious retransmission timeout (RTO) counters from /proc/net/netstat.
Also samples active TCP connections for RTT variance and min RTT stability.

In distributed multi-agent workflows spanning local mesh, private clinics, and cloud LLM APIs,
inaccurate RTT estimation causes premature retransmission timeouts, spurious loss recovery,
and bufferbloat stalls.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysctl, procfs entries, or ss tools are inaccessible.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SYSCTL_MIN_RTT_WLEN = "/proc/sys/net/ipv4/tcp_min_rtt_wlen"
SYSCTL_FRTO = "/proc/sys/net/ipv4/tcp_frto"
SYSCTL_CC = "/proc/sys/net/ipv4/tcp_congestion_control"

PROC_NETSTAT = "/proc/net/netstat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def read_str_file(path: Path) -> Optional[str]:
    """Reads a string from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return path.read_text().strip()
    except Exception:
        return None


def parse_netstat_counters(netstat_path: Path) -> Dict[str, int]:
    """Parses TcpExt counters from /proc/net/netstat."""
    counters: Dict[str, int] = {
        "spurious_rtos": 0,
        "timeouts": 0,
        "loss_probes": 0,
        "loss_probe_recoveries": 0,
        "spurious_rtx_host": 0,
    }
    if not netstat_path.is_file():
        return counters

    try:
        lines = netstat_path.read_text().splitlines()
        for i in range(0, len(lines) - 1, 2):
            header_line = lines[i].strip()
            data_line = lines[i + 1].strip()
            if header_line.startswith("TcpExt:") and data_line.startswith("TcpExt:"):
                headers = header_line.split()[1:]
                values = data_line.split()[1:]
                header_map = {h: int(v) for h, v in zip(headers, values) if v.isdigit()}

                counters["spurious_rtos"] = header_map.get("TCPSpuriousRTOs", 0)
                counters["timeouts"] = header_map.get("TCPTimeouts", 0)
                counters["loss_probes"] = header_map.get("TCPLossProbes", 0)
                counters["loss_probe_recoveries"] = header_map.get("TCPLossProbeRecovery", 0)
                counters["spurious_rtx_host"] = header_map.get("TCPSpuriousRtxHostQueues", 0)
                break
    except Exception:
        pass

    return counters


def parse_ss_rtt_samples(raw_text: str) -> Dict[str, Any]:
    """Parses socket statistics text (from ss -ti) to extract RTT metrics."""
    # Matches rtt:9.453/12.39 or rtt:12.725/11.828 minrtt:1.681 rto:213
    rtt_pattern = re.compile(r"rtt:([0-9.]+)/([0-9.]+)")
    minrtt_pattern = re.compile(r"minrtt:([0-9.]+)")
    rto_pattern = re.compile(r"rto:([0-9.]+)")

    samples: List[Dict[str, float]] = []
    lines = raw_text.splitlines()

    for line in lines:
        if "rtt:" in line:
            rtt_match = rtt_pattern.search(line)
            if not rtt_match:
                continue
            rtt_val = float(rtt_match.group(1))
            rttvar_val = float(rtt_match.group(2))

            minrtt_val = rtt_val
            min_match = minrtt_pattern.search(line)
            if min_match:
                minrtt_val = float(min_match.group(1))

            rto_val = 200.0
            rto_match = rto_pattern.search(line)
            if rto_match:
                rto_val = float(rto_match.group(1))

            samples.append({
                "rtt_ms": rtt_val,
                "rttvar_ms": rttvar_val,
                "minrtt_ms": minrtt_val,
                "rto_ms": rto_val,
                "variance_ratio": round(rttvar_val / rtt_val, 2) if rtt_val > 0 else 0.0,
            })

    if not samples:
        return {
            "total_sampled": 0,
            "avg_rtt_ms": 0.0,
            "min_rtt_ms": 0.0,
            "max_rtt_ms": 0.0,
            "high_variance_sockets": 0,
            "samples": [],
        }

    rtts = [s["rtt_ms"] for s in samples]
    high_var = [s for s in samples if s["variance_ratio"] > 3.0]

    return {
        "total_sampled": len(samples),
        "avg_rtt_ms": round(sum(rtts) / len(rtts), 2),
        "min_rtt_ms": round(min(s["minrtt_ms"] for s in samples), 3),
        "max_rtt_ms": round(max(rtts), 2),
        "high_variance_sockets": len(high_var),
        "samples": samples[:10],
    }


def audit_rtt(
    min_rtt_wlen_file: Optional[str] = None,
    frto_file: Optional[str] = None,
    cc_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
    ss_sample_text: Optional[str] = None,
) -> Dict[str, Any]:
    """Performs an audit of TCP RTT smoothing and spurious RTO metrics."""
    min_rtt_path = Path(min_rtt_wlen_file) if min_rtt_wlen_file else Path(SYSCTL_MIN_RTT_WLEN)
    frto_path = Path(frto_file) if frto_file else Path(SYSCTL_FRTO)
    cc_path = Path(cc_file) if cc_file else Path(SYSCTL_CC)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)

    min_rtt_wlen = read_int_file(min_rtt_path)
    if min_rtt_wlen is None:
        min_rtt_wlen = 300  # Kernel default

    frto = read_int_file(frto_path)
    if frto is None:
        frto = 2  # Nominal default

    cc_algo = read_str_file(cc_path)
    if cc_algo is None:
        cc_algo = "cubic"

    counters = parse_netstat_counters(netstat_path)

    # Collect socket samples
    if ss_sample_text is not None:
        socket_stats = parse_ss_rtt_samples(ss_sample_text)
    else:
        try:
            res = subprocess.run(
                ["ss", "-ti", "state", "established"],
                capture_output=True,
                text=True,
                timeout=0.5,
            )
            socket_stats = parse_ss_rtt_samples(res.stdout)
        except Exception:
            socket_stats = parse_ss_rtt_samples("")

    timeouts = counters["timeouts"]
    spurious = counters["spurious_rtos"]
    spurious_ratio_pct = round((spurious / timeouts * 100), 2) if timeouts > 0 else 0.0

    issues: List[str] = []

    if frto == 0:
        issues.append("Forward RTO recovery (tcp_frto) is disabled; spurious timeouts will trigger slow-start")

    if min_rtt_wlen < 10:
        issues.append(f"tcp_min_rtt_wlen ({min_rtt_wlen}s) is unusually short; min RTT tracking may destabilize")

    if timeouts >= 50 and spurious_ratio_pct > 25.0:
        issues.append(
            f"High spurious RTO ratio detected: {spurious_ratio_pct}% ({spurious}/{timeouts}) spurious timeouts"
        )

    if socket_stats["high_variance_sockets"] > 20:
        issues.append(
            f"{socket_stats['high_variance_sockets']} sockets have extreme RTT jitter (variance/RTT > 3.0)"
        )

    healthy = len(issues) == 0
    status = "HEALTHY" if healthy else "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "tcp_min_rtt_wlen": min_rtt_wlen,
            "tcp_frto": frto,
            "tcp_congestion_control": cc_algo,
            "spurious_rto_pct": spurious_ratio_pct,
            "issues": issues,
        },
        "counters": counters,
        "socket_stats": socket_stats,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network TCP RTT Smoothing & Min RTT Window Guard (Pattern 133)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--min-rtt-file", type=str, default=None, help="Path to tcp_min_rtt_wlen")
    parser.add_argument("--frto-file", type=str, default=None, help="Path to tcp_frto")
    parser.add_argument("--cc-file", type=str, default=None, help="Path to tcp_congestion_control")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--ss-file", type=str, default=None, help="Path to ss text dump")
    args = parser.parse_args()

    ss_text = None
    if args.ss_file and Path(args.ss_file).is_file():
        ss_text = Path(args.ss_file).read_text()

    result = audit_rtt(
        min_rtt_wlen_file=args.min_rtt_file,
        frto_file=args.frto_file,
        cc_file=args.cc_file,
        netstat_file=args.netstat_file,
        ss_sample_text=ss_text,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    sockets = result["socket_stats"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network TCP RTT Smoothing & Min RTT Guard (Pattern 133)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Congestion Algorithm:          {summary['tcp_congestion_control']}")
    print(f" Min RTT Window Filter Length:  {summary['tcp_min_rtt_wlen']}s (tcp_min_rtt_wlen)")
    print(f" Forward RTO Recovery (F-RTO):  {summary['tcp_frto']} ({'Active' if summary['tcp_frto'] > 0 else 'Disabled'})")
    print(f" Total TCP Timeouts:            {counters['timeouts']:,}")
    print(f" Spurious RTOs:                 {counters['spurious_rtos']:,} ({summary['spurious_rto_pct']}%)")
    print(f" Tail Loss Probes (TLP):        {counters['loss_probes']:,} ({counters['loss_probe_recoveries']:,} recovered)")
    print(f" Sampled Established Sockets:   {sockets['total_sampled']}")
    if sockets['total_sampled'] > 0:
        print(f" Avg / Min / Max RTT:           {sockets['avg_rtt_ms']}ms / {sockets['min_rtt_ms']}ms / {sockets['max_rtt_ms']}ms")
        print(f" High-Variance Sockets:         {sockets['high_variance_sockets']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'RTT Smoothing / Recovery Metric':<35} {'Count / Value':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'tcp_frto':<35} {summary['tcp_frto']:<15} {'Nominal' if summary['tcp_frto'] > 0 else 'WARNING'}")
    print(f" {'Spurious RTO Ratio':<35} {summary['spurious_rto_pct']:<14}% {'Nominal' if summary['spurious_rto_pct'] <= 25.0 else 'WARNING'}")
    print(f" {'Min RTT Window Length':<35} {str(summary['tcp_min_rtt_wlen']) + 's':<15} {'Nominal' if summary['tcp_min_rtt_wlen'] >= 10 else 'WARNING'}")

    if summary["issues"]:
        print("\nActive TCP RTT / Timeout Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host TCP RTT smoothing metrics, min RTT window, and timeout counters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
