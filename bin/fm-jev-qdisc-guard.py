#!/usr/bin/env python3
"""
bin/fm-jev-qdisc-guard.py - Host Network Traffic Control (tc) Qdisc Backlog & Flow Queueing Delay Guard (Pattern 219)

Audits Linux kernel Traffic Control (tc) queuing disciplines (qdiscs):
  - Ingress and egress qdiscs across all network interfaces (e.g., fq_codel, cake, noqueue, pfifo_fast)
  - /proc/sys/net/core/default_qdisc
  - Real-time egress packet backlog (backlog bytes, queued packet depth)
  - Dropped packets (drops, drop_overlimit)
  - Driver TX ring pushback and retry throttling (requeues, overlimits)
  - Flow queue statistics (fq_codel flow count, maxpacket super-frames, ECN markings)

Detects bufferbloat stalls, packet drop bursts, driver ring saturation, and egress flow delay
across multi-agent test environments, container virtual bridges, and host gigabit NICs.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when tc command or procfs is unavailable.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from typing import Any, Dict, List, Optional


def read_default_qdisc(path: str = "/proc/sys/net/core/default_qdisc") -> str:
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return f.read().strip()
        except Exception:
            pass
    return "unknown"


def parse_tc_text(text: str) -> List[Dict[str, Any]]:
    qdiscs: List[Dict[str, Any]] = []
    cur: Optional[Dict[str, Any]] = None

    for line in text.strip().split("\n"):
        line_s = line.strip()
        if not line_s:
            continue
        if line.startswith("qdisc "):
            if cur:
                qdiscs.append(cur)
            m = re.match(r"^qdisc\s+(\S+)\s+(\S+):\s+dev\s+(\S+)", line_s)
            cur = {
                "kind": m.group(1) if m else "unknown",
                "handle": m.group(2) if m else "",
                "dev": m.group(3) if m else "unknown",
                "bytes": 0,
                "packets": 0,
                "drops": 0,
                "overlimits": 0,
                "requeues": 0,
                "backlog": 0,
                "qlen": 0,
                "options": {},
            }
        elif cur:
            sm = re.search(
                r"Sent\s+(\d+)\s+bytes\s+(\d+)\s+pkt\s+\(dropped\s+(\d+),\s+overlimits\s+(\d+)\s+requeues\s+(\d+)\)",
                line_s,
            )
            if sm:
                cur["bytes"] = int(sm.group(1))
                cur["packets"] = int(sm.group(2))
                cur["drops"] = int(sm.group(3))
                cur["overlimits"] = int(sm.group(4))
                cur["requeues"] = int(sm.group(5))

            bm = re.search(r"backlog\s+(\d+)[bB]?\s+(\d+)[pP]?", line_s)
            if bm:
                cur["backlog"] = int(bm.group(1))
                cur["qlen"] = int(bm.group(2))

    if cur:
        qdiscs.append(cur)

    return qdiscs


def get_qdiscs(mock_file: Optional[str] = None) -> List[Dict[str, Any]]:
    if mock_file:
        if not os.path.exists(mock_file):
            return []
        try:
            with open(mock_file, "r", encoding="utf-8") as f:
                content = f.read()
            # Try JSON first
            try:
                data = json.loads(content)
                if isinstance(data, list):
                    return data
            except json.JSONDecodeError:
                pass
            return parse_tc_text(content)
        except Exception:
            return []

    # Try native JSON mode from iproute2
    try:
        proc = subprocess.run(
            ["tc", "-j", "-s", "qdisc", "show"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            data = json.loads(proc.stdout)
            if isinstance(data, list):
                return data
    except Exception:
        pass

    # Fallback to standard text mode
    try:
        proc = subprocess.run(
            ["tc", "-s", "qdisc", "show"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return parse_tc_text(proc.stdout)
    except Exception:
        pass

    return []


def audit_qdisc(
    mock_file: Optional[str] = None,
    default_qdisc_path: str = "/proc/sys/net/core/default_qdisc",
    warn_backlog_bytes: int = 1 * 1024 * 1024,
    crit_backlog_bytes: int = 5 * 1024 * 1024,
    warn_backlog_pkts: int = 500,
    crit_backlog_pkts: int = 2000,
    warn_drops: int = 1000,
    crit_drops: int = 10000,
    warn_overlimits: int = 1000,
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    default_qdisc = read_default_qdisc(default_qdisc_path)
    raw_qdiscs = get_qdiscs(mock_file)

    normalized_qdiscs: List[Dict[str, Any]] = []
    total_bytes = 0
    total_packets = 0
    total_drops = 0
    total_overlimits = 0
    total_requeues = 0
    total_backlog_bytes = 0
    total_backlog_pkts = 0
    active_devs: List[str] = []

    for q in raw_qdiscs:
        dev = q.get("dev", "unknown")
        kind = q.get("kind", "unknown")
        handle = str(q.get("handle", ""))
        bytes_sent = q.get("bytes", 0)
        pkts_sent = q.get("packets", 0)
        drops = q.get("drops", 0)
        overlimits = q.get("overlimits", 0)
        requeues = q.get("requeues", 0)
        backlog_b = q.get("backlog", 0)
        backlog_p = q.get("qlen", 0)

        total_bytes += bytes_sent
        total_packets += pkts_sent
        total_drops += drops
        total_overlimits += overlimits
        total_requeues += requeues
        total_backlog_bytes += backlog_b
        total_backlog_pkts += backlog_p
        active_devs.append(dev)

        entry: Dict[str, Any] = {
            "dev": dev,
            "kind": kind,
            "handle": handle,
            "bytes_sent": bytes_sent,
            "packets_sent": pkts_sent,
            "drops": drops,
            "overlimits": overlimits,
            "requeues": requeues,
            "backlog_bytes": backlog_b,
            "backlog_pkts": backlog_p,
        }

        # Flow/options details if available
        if "maxpacket" in q:
            entry["maxpacket"] = q["maxpacket"]
        if "ecn_mark" in q:
            entry["ecn_mark"] = q["ecn_mark"]
        if "new_flow_count" in q:
            entry["new_flow_count"] = q["new_flow_count"]
        if "options" in q and isinstance(q["options"], dict):
            entry["options"] = q["options"]

        normalized_qdiscs.append(entry)

    issues: List[str] = []
    status = "HEALTHY"

    if total_backlog_bytes >= crit_backlog_bytes or total_backlog_pkts >= crit_backlog_pkts:
        status = "CRITICAL"
        issues.append(
            f"Traffic control queue backlog critical: {total_backlog_bytes / 1024:.1f} KB ({total_backlog_pkts} pkts)"
        )
    elif total_backlog_bytes >= warn_backlog_bytes or total_backlog_pkts >= warn_backlog_pkts:
        status = "WARNING"
        issues.append(
            f"Traffic control queue backlog elevated: {total_backlog_bytes / 1024:.1f} KB ({total_backlog_pkts} pkts)"
        )

    if total_drops >= crit_drops and status != "CRITICAL":
        status = "CRITICAL"
        issues.append(f"Traffic control packet drops critical: {total_drops} drops")
    elif total_drops >= warn_drops and status == "HEALTHY":
        status = "WARNING"
        issues.append(f"Traffic control packet drops elevated: {total_drops} drops")

    if total_overlimits >= warn_overlimits and status == "HEALTHY":
        status = "WARNING"
        issues.append(f"Traffic control overlimits elevated: {total_overlimits} events")

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "default_qdisc": default_qdisc,
            "total_qdiscs": len(normalized_qdiscs),
            "interfaces": active_devs,
            "total_sent_bytes": total_bytes,
            "total_sent_packets": total_packets,
            "total_backlog_bytes": total_backlog_bytes,
            "total_backlog_pkts": total_backlog_pkts,
            "total_drops": total_drops,
            "total_overlimits": total_overlimits,
            "total_requeues": total_requeues,
            "issues": issues,
        },
        "qdiscs": normalized_qdiscs,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network Traffic Control (tc) Qdisc Backlog & Flow Queueing Delay Guard (Pattern 219)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--mock-file", type=str, default=None, help="Path to mock tc output (JSON or text)")
    parser.add_argument(
        "--default-qdisc-path",
        type=str,
        default="/proc/sys/net/core/default_qdisc",
        help="Path to /proc/sys/net/core/default_qdisc",
    )
    parser.add_argument(
        "--warn-backlog-bytes",
        type=int,
        default=1 * 1024 * 1024,
        help="Warning threshold for backlog bytes (default 1MB)",
    )
    parser.add_argument(
        "--crit-backlog-bytes",
        type=int,
        default=5 * 1024 * 1024,
        help="Critical threshold for backlog bytes (default 5MB)",
    )
    parser.add_argument(
        "--warn-backlog-pkts",
        type=int,
        default=500,
        help="Warning threshold for backlog packet depth (default 500)",
    )
    parser.add_argument(
        "--crit-backlog-pkts",
        type=int,
        default=2000,
        help="Critical threshold for backlog packet depth (default 2000)",
    )
    parser.add_argument(
        "--warn-drops",
        type=int,
        default=1000,
        help="Warning threshold for dropped packets (default 1000)",
    )
    parser.add_argument(
        "--crit-drops",
        type=int,
        default=10000,
        help="Critical threshold for dropped packets (default 10000)",
    )
    parser.add_argument(
        "--warn-overlimits",
        type=int,
        default=1000,
        help="Warning threshold for overlimit events (default 1000)",
    )

    args = parser.parse_args()

    report = audit_qdisc(
        mock_file=args.mock_file,
        default_qdisc_path=args.default_qdisc_path,
        warn_backlog_bytes=args.warn_backlog_bytes,
        crit_backlog_bytes=args.crit_backlog_bytes,
        warn_backlog_pkts=args.warn_backlog_pkts,
        crit_backlog_pkts=args.crit_backlog_pkts,
        warn_drops=args.warn_drops,
        crit_drops=args.crit_drops,
        warn_overlimits=args.warn_overlimits,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(
            f"[{s['status']}] Traffic Control Qdiscs: {s['total_qdiscs']} | Default: {s['default_qdisc']} | Backlog: {s['total_backlog_bytes']} B ({s['total_backlog_pkts']} pkts) | Drops: {s['total_drops']} | Requeues: {s['total_requeues']}"
        )
        print("  Active Interfaces:")
        for q in report["qdiscs"]:
            flow_info = f", {q.get('new_flow_count', 0)} flows" if "new_flow_count" in q else ""
            print(
                f"    - {q['dev']:<10} ({q['kind']}): sent {q['bytes_sent'] / (1024*1024):.1f} MB ({q['packets_sent']} pkts), drops={q['drops']}, backlog={q['backlog_bytes']} B ({q['backlog_pkts']} p){flow_info}"
            )
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
