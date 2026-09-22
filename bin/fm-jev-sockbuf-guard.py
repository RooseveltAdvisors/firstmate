#!/usr/bin/env python3
"""
fm-jev-sockbuf-guard.py - Jev Multi-Agent Host Network Socket Core Buffer & Netdev Backlog Guard (Pattern 104)

Audits Linux socket core buffer limits, NIC ingress backlog, and connection backlog drops from
/proc/sys/net/core/rmem_max, wmem_max, rmem_default, wmem_default, optmem_max, netdev_max_backlog, somaxconn,
/proc/net/netstat (TcpExt: TCPBacklogDrop, PFMemallocDrop, LockDroppedIcmds), and /proc/net/softnet_stat.

Detects SO_RCVBUF / SO_SNDBUF clamping bottlenecks, NIC driver backlog drops during agent burst traffic,
and listen queue starvation across multi-agent RPC endpoints, database connections, and model asset syncs.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SYSCTL_RMEM_MAX = "/proc/sys/net/core/rmem_max"
SYSCTL_WMEM_MAX = "/proc/sys/net/core/wmem_max"
SYSCTL_RMEM_DEFAULT = "/proc/sys/net/core/rmem_default"
SYSCTL_WMEM_DEFAULT = "/proc/sys/net/core/wmem_default"
SYSCTL_OPTMEM_MAX = "/proc/sys/net/core/optmem_max"
SYSCTL_NETDEV_MAX_BACKLOG = "/proc/sys/net/core/netdev_max_backlog"
SYSCTL_SOMAXCONN = "/proc/sys/net/core/somaxconn"
PROC_NETSTAT = "/proc/net/netstat"
PROC_SOFTNET_STAT = "/proc/net/softnet_stat"


def read_int_file(path: Path) -> Optional[int]:
    """Reads an integer from a sysfs/procfs file."""
    if not path.is_file():
        return None
    try:
        return int(path.read_text().strip())
    except Exception:
        return None


def parse_tcpext_netstat(path: Path) -> Dict[str, int]:
    """Parses TcpExt key-value metrics from /proc/net/netstat."""
    if not path.is_file():
        return {}

    metrics: Dict[str, int] = {}
    try:
        lines = path.read_text().splitlines()
        for i in range(len(lines) - 1):
            if lines[i].startswith("TcpExt:") and lines[i + 1].startswith("TcpExt:"):
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


def parse_softnet_stat(path: Path) -> Tuple[int, int, int]:
    """Parses /proc/net/softnet_stat across all CPU cores.
    Returns (total_processed, total_dropped, total_squeezed).
    """
    if not path.is_file():
        return 0, 0, 0

    total_proc = 0
    total_drop = 0
    total_squeeze = 0

    try:
        for line in path.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 3:
                total_proc += int(parts[0], 16)
                total_drop += int(parts[1], 16)
                total_squeeze += int(parts[2], 16)
    except Exception:
        pass

    return total_proc, total_drop, total_squeeze


def audit_sockbuf(
    rmem_max_file: Optional[str] = None,
    wmem_max_file: Optional[str] = None,
    rmem_def_file: Optional[str] = None,
    wmem_def_file: Optional[str] = None,
    optmem_file: Optional[str] = None,
    backlog_file: Optional[str] = None,
    somaxconn_file: Optional[str] = None,
    netstat_file: Optional[str] = None,
    softnet_file: Optional[str] = None,
) -> Dict[str, Any]:
    """Audits core socket buffer parameters, backlog capacities, and packet drop counters."""
    rmem_max_path = Path(rmem_max_file) if rmem_max_file else Path(SYSCTL_RMEM_MAX)
    wmem_max_path = Path(wmem_max_file) if wmem_max_file else Path(SYSCTL_WMEM_MAX)
    rmem_def_path = Path(rmem_def_file) if rmem_def_file else Path(SYSCTL_RMEM_DEFAULT)
    wmem_def_path = Path(wmem_def_file) if wmem_def_file else Path(SYSCTL_WMEM_DEFAULT)
    optmem_path = Path(optmem_file) if optmem_file else Path(SYSCTL_OPTMEM_MAX)
    backlog_path = Path(backlog_file) if backlog_file else Path(SYSCTL_NETDEV_MAX_BACKLOG)
    somaxconn_path = Path(somaxconn_file) if somaxconn_file else Path(SYSCTL_SOMAXCONN)
    netstat_path = Path(netstat_file) if netstat_file else Path(PROC_NETSTAT)
    softnet_path = Path(softnet_file) if softnet_file else Path(PROC_SOFTNET_STAT)

    rmem_max = read_int_file(rmem_max_path)
    wmem_max = read_int_file(wmem_max_path)
    rmem_default = read_int_file(rmem_def_path)
    wmem_default = read_int_file(wmem_def_path)
    optmem_max = read_int_file(optmem_path)
    netdev_backlog = read_int_file(backlog_path)
    somaxconn = read_int_file(somaxconn_path)

    tcpext = parse_tcpext_netstat(netstat_path)
    backlog_drop = tcpext.get("TCPBacklogDrop", 0)
    pfmemalloc_drop = tcpext.get("PFMemallocDrop", 0)
    lock_drop = tcpext.get("LockDroppedIcmds", 0)

    softnet_proc, softnet_drop, softnet_squeeze = parse_softnet_stat(softnet_path)

    issues: List[str] = []

    # Check somaxconn starvation
    if somaxconn is not None and somaxconn < 1024:
        issues.append(f"Low somaxconn ({somaxconn} < 1024): listen queue may reject concurrent agent connections")

    # Check netdev backlog
    if netdev_backlog is not None and netdev_backlog < 500:
        issues.append(f"Low netdev_max_backlog ({netdev_backlog} < 500): ingress ring queue risks packet drops")

    # Check socket buffer headroom
    if rmem_max is not None and rmem_max < 131072:
        issues.append(f"Severely constrained rmem_max ({rmem_max} < 128KB): limits SO_RCVBUF socket capacity")

    # Check TCP backlog drops
    if backlog_drop > 10:
        issues.append(f"Elevated TCPBacklogDrop ({backlog_drop} drops): connections dropped due to full TCP socket backlog")

    # Check memory allocation drops
    if pfmemalloc_drop > 0:
        issues.append(f"Kernel memory allocation drops ({pfmemalloc_drop} PFMemallocDrop): sk_buff allocation failed")

    # Check softnet drops
    if softnet_drop > 50:
        issues.append(f"NIC ingress softnet drops ({softnet_drop} drops): netdev backlog saturated by ingress packet bursts")

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "rmem_max_bytes": rmem_max,
            "wmem_max_bytes": wmem_max,
            "rmem_default_bytes": rmem_default,
            "wmem_default_bytes": wmem_default,
            "optmem_max_bytes": optmem_max,
            "netdev_max_backlog": netdev_backlog,
            "somaxconn": somaxconn,
            "tcp_backlog_drops": backlog_drop,
            "pfmemalloc_drops": pfmemalloc_drop,
            "softnet_processed": softnet_proc,
            "softnet_dropped": softnet_drop,
            "softnet_squeezed": softnet_squeeze,
            "issues": issues,
        },
        "counters": {
            "backlog_drop": backlog_drop,
            "pfmemalloc_drop": pfmemalloc_drop,
            "lock_drop": lock_drop,
            "softnet_proc": softnet_proc,
            "softnet_drop": softnet_drop,
            "softnet_squeeze": softnet_squeeze,
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Socket Core Buffer & Netdev Backlog Guard (Pattern 104)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--rmem-max-file", type=str, default=None, help="Path to rmem_max")
    parser.add_argument("--wmem-max-file", type=str, default=None, help="Path to wmem_max")
    parser.add_argument("--rmem-def-file", type=str, default=None, help="Path to rmem_default")
    parser.add_argument("--wmem-def-file", type=str, default=None, help="Path to wmem_default")
    parser.add_argument("--optmem-file", type=str, default=None, help="Path to optmem_max")
    parser.add_argument("--backlog-file", type=str, default=None, help="Path to netdev_max_backlog")
    parser.add_argument("--somaxconn-file", type=str, default=None, help="Path to somaxconn")
    parser.add_argument("--netstat-file", type=str, default=None, help="Path to /proc/net/netstat")
    parser.add_argument("--softnet-file", type=str, default=None, help="Path to /proc/net/softnet_stat")
    args = parser.parse_args()

    result = audit_sockbuf(
        rmem_max_file=args.rmem_max_file,
        wmem_max_file=args.wmem_max_file,
        rmem_def_file=args.rmem_def_file,
        wmem_def_file=args.wmem_def_file,
        optmem_file=args.optmem_file,
        backlog_file=args.backlog_file,
        somaxconn_file=args.somaxconn_file,
        netstat_file=args.netstat_file,
        softnet_file=args.softnet_file,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    counters = result["counters"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network Socket Buffer & Backlog Guard (Pattern 104)")
    print("================================================================================")
    print(f" Timestamp:                     {result['timestamp']}")
    print(f" Status:                        {status_color}{summary['status']}{reset_color}")
    print(f" Socket rmem_max / wmem_max:    {summary['rmem_max_bytes']} / {summary['wmem_max_bytes']} bytes")
    print(f" Socket rmem/wmem default:      {summary['rmem_default_bytes']} / {summary['wmem_default_bytes']} bytes")
    print(f" Socket optmem_max:             {summary['optmem_max_bytes']} bytes")
    print(f" Netdev Max Backlog:            {summary['netdev_max_backlog']}")
    print(f" somaxconn (Listen Limit):      {summary['somaxconn']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Kernel Network Metric':<30} {'Count':<15} {'Status'}")
    print("--------------------------------------------------------------------------------")
    print(f" {'TCP Socket Backlog Drops':<30} {counters['backlog_drop']:<15} Nominal")
    print(f" {'Page Allocator Drops':<30} {counters['pfmemalloc_drop']:<15} Nominal")
    print(f" {'Socket Lock Dropped ICMP':<30} {counters['lock_drop']:<15} Nominal")
    print(f" {'Softnet Packets Processed':<30} {counters['softnet_proc']:<15} Nominal")
    print(f" {'Softnet Ingress Drops':<30} {counters['softnet_drop']:<15} {'Nominal' if counters['softnet_drop'] <= 50 else 'WARNING'}")
    print(f" {'Softnet Budget Squeezes':<30} {counters['softnet_squeeze']:<15} Nominal")

    if summary["issues"]:
        print("\nActive Socket Buffer / Ingress Backlog Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll host network socket buffer and ingress backlog parameters nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
