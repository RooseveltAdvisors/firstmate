#!/usr/bin/env python3
"""
bin/fm-jev-netlink-guard.py - Host Network Netlink Socket Buffer & Routing Netlink Drop Guard (Pattern 214)

Audits Linux kernel Netlink IPC sockets and buffer drops across all netlink protocols:
  - /proc/net/netlink (sk, Eth protocol family, Pid/port_id, Groups, Rmem, Wmem, Dump, Locks, Drops, Inode)
  - /proc/sys/net/core/rmem_default, wmem_default, rmem_max, wmem_max (Core socket memory limits)
  - Resolves process command names for netlink socket endpoints where available

Detects netlink buffer overruns (ENOBUFS drops), routing event loss (NETLINK_ROUTE drops),
uevent queue starvation (NETLINK_KOBJECT_UEVENT), and runaway netlink socket proliferation
across multi-agent tool workers, container network interfaces, and host daemon subsystems.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when procfs or sysctl paths are restricted or missing.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional


NETLINK_PROTOCOLS: Dict[int, str] = {
    0: "NETLINK_ROUTE",
    1: "NETLINK_UNUSED",
    2: "NETLINK_USERSOCK",
    3: "NETLINK_FIREWALL",
    4: "NETLINK_SOCK_DIAG",
    5: "NETLINK_NFLOG",
    6: "NETLINK_XFRM",
    7: "NETLINK_SELINUX",
    8: "NETLINK_ISCSI",
    9: "NETLINK_AUDIT",
    10: "NETLINK_FIB_LOOKUP",
    11: "NETLINK_CONNECTOR",
    12: "NETLINK_NETFILTER",
    13: "NETLINK_IP6_FW",
    14: "NETLINK_DNART",
    15: "NETLINK_KOBJECT_UEVENT",
    16: "NETLINK_GENERIC",
    17: "NETLINK_DM",
    18: "NETLINK_SCSITRANSPORT",
    19: "NETLINK_ECRYPTFS",
    20: "NETLINK_RDMA",
    21: "NETLINK_CRYPTO",
    22: "NETLINK_SMC",
}


def read_sysctl_int(path: str, default: int = 0) -> int:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read().strip()
            return int(content) if content.isdigit() else default
    except Exception:
        return default


def get_proc_comm(pid: int) -> Optional[str]:
    """Resolves comm name for a PID if present in /proc."""
    if pid <= 0 or pid > 4194304:  # Netlink port IDs above max PID are thread or hash IDs
        return None
    comm_path = f"/proc/{pid}/comm"
    if os.path.exists(comm_path):
        try:
            with open(comm_path, "r", encoding="utf-8") as f:
                return f.read().strip()
        except Exception:
            return None
    return None


def parse_proc_netlink(path: str = "/proc/net/netlink") -> List[Dict[str, Any]]:
    sockets: List[Dict[str, Any]] = []
    if not os.path.exists(path):
        return sockets

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return sockets

    for line in lines:
        parts = line.strip().split()
        if not parts or parts[0] == "sk":
            continue
        if len(parts) >= 10:
            try:
                sk = parts[0]
                eth = int(parts[1])
                port_id = int(parts[2])
                groups = parts[3]
                rmem = int(parts[4])
                wmem = int(parts[5])
                dump = int(parts[6])
                locks = int(parts[7])
                drops = int(parts[8])
                inode = int(parts[9])

                proto_name = NETLINK_PROTOCOLS.get(eth, f"NETLINK_{eth}")
                comm = get_proc_comm(port_id)

                sockets.append({
                    "sk": sk,
                    "protocol_num": eth,
                    "protocol_name": proto_name,
                    "port_id": port_id,
                    "comm": comm,
                    "groups": groups,
                    "rmem": rmem,
                    "wmem": wmem,
                    "dump": dump,
                    "locks": locks,
                    "drops": drops,
                    "inode": inode,
                })
            except (ValueError, IndexError):
                continue

    return sockets


def audit_netlink(
    proc_netlink_path: str = "/proc/net/netlink",
    sysctl_dir: str = "/proc/sys/net/core",
    warn_drops: int = 1,
    crit_drops: int = 100,
    warn_sockets: int = 1000,
    crit_sockets: int = 5000,
    warn_rmem_bytes: int = 10 * 1024 * 1024,
    crit_rmem_bytes: int = 50 * 1024 * 1024,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sockets = parse_proc_netlink(proc_netlink_path)

    rmem_default = read_sysctl_int(os.path.join(sysctl_dir, "rmem_default"), 212992)
    wmem_default = read_sysctl_int(os.path.join(sysctl_dir, "wmem_default"), 212992)
    rmem_max = read_sysctl_int(os.path.join(sysctl_dir, "rmem_max"), 212992)
    wmem_max = read_sysctl_int(os.path.join(sysctl_dir, "wmem_max"), 212992)

    total_sockets = len(sockets)
    total_drops = sum(s["drops"] for s in sockets)
    sockets_with_drops = sum(1 for s in sockets if s["drops"] > 0)
    max_socket_drops = max((s["drops"] for s in sockets), default=0)
    total_rmem = sum(s["rmem"] for s in sockets)
    total_wmem = sum(s["wmem"] for s in sockets)

    proto_dist: Dict[str, int] = {}
    proto_drops: Dict[str, int] = {}
    proto_rmem: Dict[str, int] = {}

    for s in sockets:
        p = s["protocol_name"]
        proto_dist[p] = proto_dist.get(p, 0) + 1
        proto_drops[p] = proto_drops.get(p, 0) + s["drops"]
        proto_rmem[p] = proto_rmem.get(p, 0) + s["rmem"]

    issues: List[str] = []
    status = "HEALTHY"

    if total_drops >= crit_drops:
        status = "CRITICAL"
        issues.append(f"Netlink socket buffer drops critical: {total_drops} total dropped messages (>= {crit_drops})")
    elif total_drops >= warn_drops:
        status = "WARNING"
        issues.append(f"Netlink socket buffer drops detected: {total_drops} total dropped messages across {sockets_with_drops} sockets")

    if total_rmem >= crit_rmem_bytes:
        status = "CRITICAL"
        issues.append(f"Netlink receive buffer memory critical: {total_rmem / (1024*1024):.2f} MB (>= {crit_rmem_bytes / (1024*1024):.1f} MB)")
    elif total_rmem >= warn_rmem_bytes and status != "CRITICAL":
        status = "WARNING"
        issues.append(f"Netlink receive buffer memory elevated: {total_rmem / (1024*1024):.2f} MB")

    if total_sockets >= crit_sockets:
        status = "CRITICAL"
        issues.append(f"Netlink socket table exhaustion: {total_sockets} sockets (>= {crit_sockets})")
    elif total_sockets >= warn_sockets and status != "CRITICAL":
        status = "WARNING"
        issues.append(f"Netlink socket count elevated: {total_sockets} sockets (>= {warn_sockets})")

    top_drop_sockets = sorted(
        [s for s in sockets if s["drops"] > 0],
        key=lambda x: x["drops"],
        reverse=True,
    )[:10]

    top_rmem_sockets = sorted(
        sockets,
        key=lambda x: x["rmem"],
        reverse=True,
    )[:5]

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "total_sockets": total_sockets,
            "total_drops": total_drops,
            "sockets_with_drops": sockets_with_drops,
            "max_socket_drops": max_socket_drops,
            "total_rmem_bytes": total_rmem,
            "total_wmem_bytes": total_wmem,
            "issues": issues,
        },
        "protocols": {
            p: {
                "socket_count": proto_dist[p],
                "drops": proto_drops.get(p, 0),
                "rmem_bytes": proto_rmem.get(p, 0),
            }
            for p in sorted(proto_dist.keys())
        },
        "sysctl": {
            "rmem_default": rmem_default,
            "wmem_default": wmem_default,
            "rmem_max": rmem_max,
            "wmem_max": wmem_max,
        },
        "top_drop_sockets": top_drop_sockets,
        "top_rmem_sockets": top_rmem_sockets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network Netlink Socket Buffer & Routing Netlink Drop Guard (Pattern 214)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--warn-drops", type=int, default=1, help="Warning threshold for buffer drops (default: 1)")
    parser.add_argument("--crit-drops", type=int, default=100, help="Critical threshold for buffer drops (default: 100)")
    parser.add_argument("--warn-sockets", type=int, default=1000, help="Warning threshold for total sockets (default: 1000)")
    parser.add_argument("--crit-sockets", type=int, default=5000, help="Critical threshold for total sockets (default: 5000)")
    parser.add_argument("--proc-netlink", type=str, default="/proc/net/netlink", help="Path to /proc/net/netlink")
    parser.add_argument("--sysctl-dir", type=str, default="/proc/sys/net/core", help="Path to /proc/sys/net/core")

    args = parser.parse_args()

    report = audit_netlink(
        proc_netlink_path=args.proc_netlink,
        sysctl_dir=args.sysctl_dir,
        warn_drops=args.warn_drops,
        crit_drops=args.crit_drops,
        warn_sockets=args.warn_sockets,
        crit_sockets=args.crit_sockets,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"[{s['status']}] Netlink Sockets: {s['total_sockets']} | Drops: {s['total_drops']} | Rmem: {s['total_rmem_bytes']} B | Wmem: {s['total_wmem_bytes']} B")
        print("  Protocols:")
        for proto, data in report["protocols"].items():
            print(f"    - {proto:<24}: {data['socket_count']:>3} sockets, {data['drops']:>3} drops, {data['rmem_bytes']:>6} B rmem")
        if report["top_drop_sockets"]:
            print("  Top Drop Sockets:")
            for item in report["top_drop_sockets"]:
                comm_str = f" ({item['comm']})" if item['comm'] else ""
                print(f"    - {item['protocol_name']} port={item['port_id']}{comm_str}: {item['drops']} drops")
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
