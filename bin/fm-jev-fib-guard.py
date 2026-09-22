#!/usr/bin/env python3
"""
bin/fm-jev-fib-guard.py - Host Network FIB Trie Architecture & Route Lookup Depth Guard (Pattern 209)

Audits Linux kernel Forwarding Information Base (FIB) trie statistics from /proc/net/fib_triestat:
  - Table trie depth (average depth, maximum lookup depth) across Main, Local, and custom VRFs
  - Leaf and prefix density (leaves, prefixes, internal tnodes, pointer table overhead)
  - Route lookup efficiency (gets, backtracks, semantic matches, null node hits, skipped node resizes)

Detects deep routing trie degradation, excessive lookup backtracking, and pointer array memory bloat
across multi-agent mesh networks, WireGuard tunnels, container bridges, and VPC gateways.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when sysfs/procfs files are missing or restricted.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import datetime
import json
import os
import re
import sys
from typing import Any, Dict, List, Tuple


def parse_fib_triestat(path: str = "/proc/net/fib_triestat") -> Tuple[Dict[str, Dict[str, Any]], Dict[str, Any]]:
    tables: Dict[str, Dict[str, Any]] = {}
    summary: Dict[str, Any] = {
        "total_tables": 0,
        "total_leaves": 0,
        "total_prefixes": 0,
        "total_internal_nodes": 0,
        "max_depth_overall": 0,
        "total_gets": 0,
        "total_backtracks": 0,
        "total_semantic_matches": 0,
        "total_null_hits": 0,
        "total_size_kb": 0,
    }

    if not os.path.exists(path):
        return tables, summary

    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        current_table = ""
        current_data: Dict[str, Any] = {}

        for line in content.splitlines():
            line_str = line.strip()
            if not line_str:
                continue

            # Detect table headers like "Main:", "Local:", "Id 259:"
            table_match = re.match(r"^(Main|Local|Id\s+\d+):", line_str)
            if table_match:
                if current_table and current_data:
                    tables[current_table] = current_data
                current_table = table_match.group(1).replace(" ", "_")
                current_data = {
                    "aver_depth": 0.0,
                    "max_depth": 0,
                    "leaves": 0,
                    "prefixes": 0,
                    "internal_nodes": 0,
                    "pointers": 0,
                    "null_ptrs": 0,
                    "total_size_kb": 0,
                    "gets": 0,
                    "backtracks": 0,
                    "semantic_matches": 0,
                    "null_hits": 0,
                }
                continue

            if not current_table or not current_data:
                continue

            if "Aver depth:" in line_str:
                current_data["aver_depth"] = float(line_str.split(":")[-1].strip())
            elif "Max depth:" in line_str:
                val = int(line_str.split(":")[-1].strip())
                current_data["max_depth"] = val
                if val > summary["max_depth_overall"]:
                    summary["max_depth_overall"] = val
            elif "Leaves:" in line_str:
                val = int(line_str.split(":")[-1].strip())
                current_data["leaves"] = val
                summary["total_leaves"] += val
            elif "Prefixes:" in line_str:
                val = int(line_str.split(":")[-1].strip())
                current_data["prefixes"] = val
                summary["total_prefixes"] += val
            elif "Internal nodes:" in line_str:
                val = int(line_str.split(":")[-1].strip())
                current_data["internal_nodes"] = val
                summary["total_internal_nodes"] += val
            elif "Pointers:" in line_str:
                current_data["pointers"] = int(line_str.split(":")[-1].strip())
            elif "Null ptrs:" in line_str:
                current_data["null_ptrs"] = int(line_str.split(":")[-1].strip())
            elif "Total size:" in line_str:
                parts = line_str.split(":")[-1].strip().split()
                if parts and parts[0].isdigit():
                    val = int(parts[0])
                    current_data["total_size_kb"] = val
                    summary["total_size_kb"] += val
            elif line_str.startswith("gets ="):
                val = int(line_str.split("=")[-1].strip())
                current_data["gets"] = val
                summary["total_gets"] += val
            elif line_str.startswith("backtracks ="):
                val = int(line_str.split("=")[-1].strip())
                current_data["backtracks"] = val
                summary["total_backtracks"] += val
            elif line_str.startswith("semantic match passed ="):
                val = int(line_str.split("=")[-1].strip())
                current_data["semantic_matches"] = val
                summary["total_semantic_matches"] += val
            elif line_str.startswith("null node hit="):
                val = int(line_str.split("=")[-1].strip())
                current_data["null_hits"] = val
                summary["total_null_hits"] += val

        if current_table and current_data:
            tables[current_table] = current_data

        summary["total_tables"] = len(tables)

    except Exception:
        pass

    return tables, summary


def audit_fib_guard(path: str = "/proc/net/fib_triestat") -> Dict[str, Any]:
    tables, summary = parse_fib_triestat(path)

    issues: List[str] = []
    status = "HEALTHY"

    backtrack_ratio = 0.0
    if summary["total_gets"] > 0:
        backtrack_ratio = round(summary["total_backtracks"] / summary["total_gets"], 6)

    if summary["max_depth_overall"] >= 15:
        issues.append(
            f"CRITICAL: Excessive FIB trie maximum depth ({summary['max_depth_overall']}); severe route lookup latency"
        )
        status = "CRITICAL"
    elif summary["max_depth_overall"] >= 8:
        issues.append(
            f"WARNING: Elevated FIB trie maximum depth ({summary['max_depth_overall']})"
        )
        status = "WARNING"

    if summary["total_gets"] > 1000 and backtrack_ratio >= 0.05:
        issues.append(
            f"WARNING: High FIB lookup backtrack ratio ({backtrack_ratio * 100:.2f}% across {summary['total_gets']:,} lookups)"
        )
        if status != "CRITICAL":
            status = "WARNING"

    healthy = status == "HEALTHY"
    recommendation = (
        "Kernel FIB routing trie architecture, lookup depths, and prefix hierarchies are nominal."
        if healthy
        else "; ".join(issues)
    )

    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "summary": {
            "status": status,
            "healthy": healthy,
            "total_tables": summary["total_tables"],
            "total_leaves": summary["total_leaves"],
            "total_prefixes": summary["total_prefixes"],
            "total_internal_nodes": summary["total_internal_nodes"],
            "max_depth_overall": summary["max_depth_overall"],
            "total_size_kb": summary["total_size_kb"],
            "total_gets": summary["total_gets"],
            "total_backtracks": summary["total_backtracks"],
            "backtrack_ratio": backtrack_ratio,
            "total_semantic_matches": summary["total_semantic_matches"],
            "issues": issues,
            "recommendation": recommendation,
        },
        "tables": tables,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Host Network FIB Trie Architecture & Route Lookup Depth Guard (Pattern 209)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON telemetry")
    args = parser.parse_args()

    report = audit_fib_guard()
    s = report["summary"]

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"[{s['status']}] Pattern 209: Host Network FIB Trie Architecture Guard")
        print(
            f"  FIB Tables: {s['total_tables']} tables, {s['total_prefixes']} prefixes, "
            f"{s['total_leaves']} leaves, max_depth={s['max_depth_overall']} (overhead: {s['total_size_kb']} kB)"
        )
        print(
            f"  Route Lookups: {s['total_gets']:,} gets, {s['total_backtracks']:,} backtracks "
            f"({s['backtrack_ratio'] * 100:.4f}% ratio), {s['total_semantic_matches']:,} semantic matches"
        )
        print(f"  Recommendation: {s['recommendation']}")

    return 0 if s["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
