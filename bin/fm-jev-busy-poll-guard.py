#!/usr/bin/env python3
"""
bin/fm-jev-busy-poll-guard.py - Linux Network Socket Busy Polling & NAPI Low-Latency Polling Guard (Pattern 318 / Pattern 456)

Audits Linux kernel network socket low-latency busy polling parameters:
  - /proc/sys/net/core/busy_poll (SO_BUSY_POLL microsecond timeout)
  - /proc/sys/net/core/busy_read (socket read busy polling microsecond timeout)
  - /proc/sys/net/core/gro_normal_batch (Generic Receive Offload batch size)
  - /proc/sys/net/core/dev_weight (NAPI poll device quota weight)
alongside /proc/net/netstat TcpExt metrics (BusyPollRxPackets, TCPHPAcks)
to detect excessive CPU core pinning, thread starvation, abnormal NAPI quotas,
and misconfigured GRO batch aggregation under concurrent multi-agent workloads.

Invariants:
  - Critical when busy_poll >= 500 us or busy_read >= 500 us (severe CPU monopolization).
  - Warning when busy_poll > 100 us, busy_read > 100 us, gro_normal_batch not in 1..64,
    or dev_weight not in 16..512.
  - Fail-open: graceful fallback when sysctl/netstat paths are restricted.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

PROC_NETSTAT = "/proc/net/netstat"
SYSCTL_BUSY_POLL = "/proc/sys/net/core/busy_poll"
SYSCTL_BUSY_READ = "/proc/sys/net/core/busy_read"
SYSCTL_GRO_NORMAL_BATCH = "/proc/sys/net/core/gro_normal_batch"
SYSCTL_DEV_WEIGHT = "/proc/sys/net/core/dev_weight"

DEFAULT_WARN_MAX_BUSY_POLL_US = 100
DEFAULT_CRIT_MAX_BUSY_POLL_US = 500
DEFAULT_WARN_MAX_BUSY_READ_US = 100
DEFAULT_CRIT_MAX_BUSY_READ_US = 500


def read_sysctl_int(path: Path, default: int = -1) -> int:
    """Reads an integer from a sysctl/procfs file."""
    if not path.is_file():
        return default
    try:
        content = path.read_text(encoding="utf-8", errors="replace").strip()
        return int(content) if content.isdigit() else default
    except (ValueError, OSError):
        return default


def parse_netstat_tcpext(path: Path) -> Dict[str, int]:
    """Parses TcpExt key-value metrics from /proc/net/netstat."""
    if not path.is_file():
        return {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
                keys = lines[i].split()[1:]
                vals = lines[i + 1].split()[1:]
                res: Dict[str, int] = {}
                for k, v in zip(keys, vals):
                    try:
                        res[k] = int(v)
                    except ValueError:
                        continue
                return res
    except Exception:
        pass
    return {}


def evaluate_busy_poll(
    busy_poll_file: str = SYSCTL_BUSY_POLL,
    busy_read_file: str = SYSCTL_BUSY_READ,
    gro_batch_file: str = SYSCTL_GRO_NORMAL_BATCH,
    dev_weight_file: str = SYSCTL_DEV_WEIGHT,
    netstat_file: str = PROC_NETSTAT,
    warn_max_busy_poll_us: int = DEFAULT_WARN_MAX_BUSY_POLL_US,
    crit_max_busy_poll_us: int = DEFAULT_CRIT_MAX_BUSY_POLL_US,
    warn_max_busy_read_us: int = DEFAULT_WARN_MAX_BUSY_READ_US,
    crit_max_busy_read_us: int = DEFAULT_CRIT_MAX_BUSY_READ_US,
) -> Dict[str, Any]:
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    busy_poll = read_sysctl_int(Path(busy_poll_file), default=0)
    busy_read = read_sysctl_int(Path(busy_read_file), default=0)
    gro_normal_batch = read_sysctl_int(Path(gro_batch_file), default=8)
    dev_weight = read_sysctl_int(Path(dev_weight_file), default=64)
    netstat = parse_netstat_tcpext(Path(netstat_file))

    busy_poll_rx_packets = netstat.get("BusyPollRxPackets", 0)
    hp_acks = netstat.get("TCPHPAcks", 0)

    # Evaluate busy_poll
    if busy_poll >= crit_max_busy_poll_us:
        status = "CRITICAL"
        issues.append(
            f"Critical net.core.busy_poll timeout ({busy_poll} us >= {crit_max_busy_poll_us} us); "
            "extreme CPU core monopolization risk"
        )
        recommendations.append("Reduce sysctl net.core.busy_poll to 50 us or 0")
    elif busy_poll > warn_max_busy_poll_us:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Elevated net.core.busy_poll timeout ({busy_poll} us > {warn_max_busy_poll_us} us); "
            "CPU core pinning risk"
        )
        recommendations.append("Tune net.core.busy_poll to 50 us or 0 on multi-tenant nodes")

    # Evaluate busy_read
    if busy_read >= crit_max_busy_read_us:
        status = "CRITICAL"
        issues.append(
            f"Critical net.core.busy_read timeout ({busy_read} us >= {crit_max_busy_read_us} us); "
            "extreme CPU core monopolization risk"
        )
        recommendations.append("Reduce sysctl net.core.busy_read to 50 us or 0")
    elif busy_read > warn_max_busy_read_us:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Elevated net.core.busy_read timeout ({busy_read} us > {warn_max_busy_read_us} us); "
            "CPU core pinning risk"
        )
        recommendations.append("Tune net.core.busy_read to 50 us or 0 on multi-tenant nodes")

    # Evaluate GRO normal batch
    if gro_normal_batch <= 0 or gro_normal_batch > 64:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Abnormal net.core.gro_normal_batch ({gro_normal_batch} outside nominal 1..64)"
        )
        recommendations.append("Reset net.core.gro_normal_batch to default 8")

    # Evaluate NAPI dev_weight
    if dev_weight < 16 or dev_weight > 512:
        if status != "CRITICAL":
            status = "WARNING"
        issues.append(
            f"Abnormal net.core.dev_weight ({dev_weight} outside nominal 16..512)"
        )
        recommendations.append("Reset net.core.dev_weight to default 64")

    healthy = (status == "HEALTHY")
    is_polling_healthy = (
        busy_poll < crit_max_busy_poll_us
        and busy_read < crit_max_busy_read_us
        and 1 <= gro_normal_batch <= 64
        and 16 <= dev_weight <= 512
    )

    return {
        "pattern": 318,
        "name": "busy_poll",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_polling_healthy": is_polling_healthy,
        "busy_poll_us": busy_poll,
        "busy_read_us": busy_read,
        "gro_normal_batch": gro_normal_batch,
        "dev_weight": dev_weight,
        "busy_poll_rx_packets": busy_poll_rx_packets,
        "hp_acks": hp_acks,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux network socket busy polling and NAPI low-latency polling parameters."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--busy-poll-file", default=SYSCTL_BUSY_POLL, help=f"Path to busy_poll (default: {SYSCTL_BUSY_POLL})")
    parser.add_argument("--busy-read-file", default=SYSCTL_BUSY_READ, help=f"Path to busy_read (default: {SYSCTL_BUSY_READ})")
    parser.add_argument("--gro-batch-file", default=SYSCTL_GRO_NORMAL_BATCH, help=f"Path to gro_normal_batch (default: {SYSCTL_GRO_NORMAL_BATCH})")
    parser.add_argument("--dev-weight-file", default=SYSCTL_DEV_WEIGHT, help=f"Path to dev_weight (default: {SYSCTL_DEV_WEIGHT})")
    parser.add_argument("--netstat-file", default=PROC_NETSTAT, help=f"Path to netstat (default: {PROC_NETSTAT})")
    parser.add_argument("--warn-busy-poll", type=int, default=DEFAULT_WARN_MAX_BUSY_POLL_US, help="Busy poll warning threshold us")
    parser.add_argument("--crit-busy-poll", type=int, default=DEFAULT_CRIT_MAX_BUSY_POLL_US, help="Busy poll critical threshold us")
    parser.add_argument("--warn-busy-read", type=int, default=DEFAULT_WARN_MAX_BUSY_READ_US, help="Busy read warning threshold us")
    parser.add_argument("--crit-busy-read", type=int, default=DEFAULT_CRIT_MAX_BUSY_READ_US, help="Busy read critical threshold us")

    args = parser.parse_args()

    result = evaluate_busy_poll(
        busy_poll_file=args.busy_poll_file,
        busy_read_file=args.busy_read_file,
        gro_batch_file=args.gro_batch_file,
        dev_weight_file=args.dev_weight_file,
        netstat_file=args.netstat_file,
        warn_max_busy_poll_us=args.warn_busy_poll,
        crit_max_busy_poll_us=args.crit_busy_poll,
        warn_max_busy_read_us=args.warn_busy_read,
        crit_max_busy_read_us=args.crit_busy_read,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 318 (busy_poll): {result['status']}")
        print(
            f"  Busy Polling: busy_poll={result['busy_poll_us']} us | busy_read={result['busy_read_us']} us | "
            f"GRO batch={result['gro_normal_batch']} | dev_weight={result['dev_weight']}"
        )
        print(
            f"  TcpExt: BusyPollRxPackets={result['busy_poll_rx_packets']:,} | TCPHPAcks={result['hp_acks']:,}"
        )
        if result["issues"]:
            print("  Issues:")
            for iss in result["issues"]:
                print(f"    - {iss}")
        if result["recommendations"]:
            print("  Recommendations:")
            for rec in result["recommendations"]:
                print(f"    - {rec}")

    return 0 if result["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
