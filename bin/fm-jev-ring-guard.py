#!/usr/bin/env python3
"""
fm-jev-ring-guard.py - Jev Multi-Agent Host Network Interface Ring Buffer Guard (Pattern 95)

Audits Linux network interface DMA ring buffer parameters (ethtool -g / sysfs) across active physical interfaces.
Compares current hardware ring buffer descriptor sizes (RX, TX) against driver pre-set maximums, and correlates
against interface drop and FIFO overrun counters.

Prevents packet drops during multi-agent RPC burst surges when ring buffers are undersized relative to hardware capacity.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when ethtool is unavailable or interfaces are virtual/loopback.
  - Fast bounded execution (< 0.03s).
"""

import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

SYS_CLASS_NET = "/sys/class/net"


def parse_ethtool_g(output: str) -> Dict[str, Dict[str, Optional[int]]]:
    """Parses output from `ethtool -g <iface>`."""
    max_rx = None
    max_tx = None
    cur_rx = None
    cur_tx = None

    in_preset = False
    in_current = False

    for line in output.splitlines():
        line_strip = line.strip()
        if "Pre-set maximums:" in line:
            in_preset = True
            in_current = False
            continue
        elif "Current hardware settings:" in line:
            in_preset = False
            in_current = True
            continue

        rx_match = re.match(r"^RX:\s+(\d+)", line_strip)
        tx_match = re.match(r"^TX:\s+(\d+)", line_strip)

        if in_preset:
            if rx_match:
                max_rx = int(rx_match.group(1))
            elif tx_match:
                max_tx = int(tx_match.group(1))
        elif in_current:
            if rx_match:
                cur_rx = int(rx_match.group(1))
            elif tx_match:
                cur_tx = int(tx_match.group(1))

    return {
        "max": {"rx": max_rx, "tx": max_tx},
        "current": {"rx": cur_rx, "tx": cur_tx},
    }


def read_int_file(path: Path) -> int:
    """Reads an integer from a sysfs file."""
    if not path.is_file():
        return 0
    try:
        return int(path.read_text().strip())
    except Exception:
        return 0


def audit_ring(
    net_dir: Optional[str] = None,
    mock_ethtool_outputs: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """Audits NIC hardware ring buffer allocations."""
    net_path = Path(net_dir) if net_dir else Path(SYS_CLASS_NET)
    interfaces: List[Dict[str, Any]] = []
    issues: List[str] = []

    if net_path.exists() and net_path.is_dir():
        for iface_entry in sorted(net_path.iterdir()):
            if not iface_entry.is_dir():
                continue
            name = iface_entry.name

            # Skip loopback
            if name == "lo":
                continue

            # Check if physical interface (has device link) or has mock output
            is_physical = (iface_entry / "device").exists() or (
                mock_ethtool_outputs and name in mock_ethtool_outputs
            )

            operstate_file = iface_entry / "operstate"
            operstate = (
                operstate_file.read_text().strip()
                if operstate_file.is_file()
                else "unknown"
            )

            stats_dir = iface_entry / "statistics"
            rx_dropped = read_int_file(stats_dir / "rx_dropped")
            rx_fifo = read_int_file(stats_dir / "rx_fifo_errors")
            tx_dropped = read_int_file(stats_dir / "tx_dropped")
            tx_fifo = read_int_file(stats_dir / "tx_fifo_errors")

            ring_info: Dict[str, Any] = {"supported": False}

            ethtool_stdout = ""
            if mock_ethtool_outputs and name in mock_ethtool_outputs:
                ethtool_stdout = mock_ethtool_outputs[name]
            elif is_physical:
                try:
                    res = subprocess.run(
                        ["ethtool", "-g", name],
                        capture_output=True,
                        text=True,
                        timeout=1.0,
                    )
                    if res.returncode == 0:
                        ethtool_stdout = res.stdout
                except Exception:
                    pass

            if ethtool_stdout:
                parsed = parse_ethtool_g(ethtool_stdout)
                cur_rx = parsed["current"]["rx"]
                cur_tx = parsed["current"]["tx"]
                max_rx = parsed["max"]["rx"]
                max_tx = parsed["max"]["tx"]

                if cur_rx is not None and max_rx is not None:
                    ring_info = {
                        "supported": True,
                        "cur_rx": cur_rx,
                        "max_rx": max_rx,
                        "cur_tx": cur_tx,
                        "max_tx": max_tx,
                        "rx_at_max": cur_rx >= max_rx,
                        "tx_at_max": (cur_tx >= max_tx) if (cur_tx and max_tx) else True,
                    }

                    # Flag issues if ring is smaller than max AND drops/overruns are occurring
                    if cur_rx < max_rx and (rx_dropped > 0 or rx_fifo > 0):
                        issues.append(
                            f"Interface {name} has undersized RX ring ({cur_rx} < max {max_rx}) with {rx_dropped:,} drops and {rx_fifo:,} FIFO overruns. Consider expanding ring via `ethtool -G {name} rx {max_rx}`."
                        )

            interfaces.append(
                {
                    "name": name,
                    "operstate": operstate,
                    "is_physical": is_physical,
                    "ring": ring_info,
                    "rx_dropped": rx_dropped,
                    "rx_fifo_errors": rx_fifo,
                    "tx_dropped": tx_dropped,
                    "tx_fifo_errors": tx_fifo,
                }
            )

    status = "HEALTHY"
    if issues:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "interface_count": len(interfaces),
            "physical_interfaces": len([i for i in interfaces if i["is_physical"]]),
            "issues": issues,
        },
        "interfaces": interfaces,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Network Interface Ring Buffer Guard (Pattern 95)"
    )
    parser.add_argument("--json", action="store_true", help="Output JSON format")
    parser.add_argument("--net-dir", type=str, default=None, help="Path to /sys/class/net")
    args = parser.parse_args()

    result = audit_ring(net_dir=args.net_dir)

    if args.json:
        print(json.dumps(result, indent=2))
        return

    summary = result["summary"]
    status_color = "\033[32m" if summary["healthy"] else "\033[33m"
    reset_color = "\033[0m"

    print("================================================================================")
    print(" Jev Multi-Agent Host Network Interface Ring Buffer Guard (Pattern 95)")
    print("================================================================================")
    print(f" Timestamp:              {result['timestamp']}")
    print(f" Status:                 {status_color}{summary['status']}{reset_color}")
    print(f" Total Interfaces:       {summary['interface_count']}")
    print(f" Physical Interfaces:    {summary['physical_interfaces']}")
    print("--------------------------------------------------------------------------------")
    print(f" {'Interface':<12} {'State':<8} {'Cur RX':<8} {'Max RX':<8} {'Cur TX':<8} {'Max TX':<8} {'RX Drop':<8} {'FIFO'}")
    print("--------------------------------------------------------------------------------")
    for iface in result["interfaces"]:
        ring = iface["ring"]
        cur_rx_str = str(ring.get("cur_rx", "-")) if ring.get("supported") else "n/a"
        max_rx_str = str(ring.get("max_rx", "-")) if ring.get("supported") else "n/a"
        cur_tx_str = str(ring.get("cur_tx", "-")) if ring.get("supported") else "n/a"
        max_tx_str = str(ring.get("max_tx", "-")) if ring.get("supported") else "n/a"
        print(
            f" {iface['name']:<12} {iface['operstate']:<8} {cur_rx_str:<8} {max_rx_str:<8} "
            f"{cur_tx_str:<8} {max_tx_str:<8} {iface['rx_dropped']:<8} {iface['rx_fifo_errors']}"
        )

    if summary["issues"]:
        print("\nActive Ring Buffer Warnings:")
        for issue in summary["issues"]:
            print(f"  [!] {issue}")
    else:
        print("\nAll network interface ring buffer configurations nominal.")
    print("================================================================================")


if __name__ == "__main__":
    main()
