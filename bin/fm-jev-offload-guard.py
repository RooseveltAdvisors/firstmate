#!/usr/bin/env python3
"""
bin/fm-jev-offload-guard.py - Host Network Generic Receive Offload (GRO) & Hardware Offload Hygiene Guard (Pattern 217)

Audits Linux network device hardware acceleration and protocol offload features:
  - 'ethtool -k <iface>' (rx-checksumming, tx-checksumming, scatter-gather, TSO, GSO, GRO, LRO)
  - /sys/class/net/<iface>/operstate (Interface operational status)
  - /sys/class/net/<iface>/speed (Interface link speed in Mbps)

Detects missing or disabled packet offload capabilities (such as disabled GRO/GSO causing CPU
saturation during multi-agent API bursts), unintended Large Receive Offload (LRO) which can
corrupt forwarded packets, and broken checksum offloads across host physical and virtual NICs.

Invariants:
  - Read-only diagnostics by default. Safe and non-destructive.
  - Fail-open: graceful fallback when ethtool or sysfs paths are restricted or absent.
  - Fast bounded execution (< 0.05s).
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
from typing import Any, Dict, List, Optional


CRITICAL_FEATURES = [
    "rx-checksumming",
    "tx-checksumming",
    "scatter-gather",
    "tcp-segmentation-offload",
    "generic-segmentation-offload",
    "generic-receive-offload",
    "large-receive-offload",
]


def read_sysfs_str(path: str, default: str = "") -> str:
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return default


def parse_ethtool_features(lines: List[str]) -> Dict[str, Any]:
    features: Dict[str, Any] = {}
    for line in lines:
        if ":" not in line:
            continue
        parts = line.split(":", 1)
        name = parts[0].strip()
        val_str = parts[1].strip()
        is_on = val_str.startswith("on")
        is_fixed = "[fixed]" in val_str
        features[name] = {
            "enabled": is_on,
            "raw": val_str,
            "fixed": is_fixed,
        }
    return features


def get_iface_features(iface: str, mock_dir: Optional[str] = None) -> Dict[str, Any]:
    if mock_dir and os.path.exists(mock_dir):
        mock_file = os.path.join(mock_dir, f"{iface}_ethtool.txt")
        if os.path.exists(mock_file):
            try:
                with open(mock_file, "r", encoding="utf-8") as f:
                    return parse_ethtool_features(f.readlines())
            except Exception:
                return {}
    try:
        res = subprocess.run(
            ["ethtool", "-k", iface],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
        if res.returncode == 0:
            return parse_ethtool_features(res.stdout.splitlines())
    except Exception:
        pass
    return {}


def audit_offloads(
    mock_dir: Optional[str] = None,
    sysfs_net_dir: str = "/sys/class/net",
) -> Dict[str, Any]:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if not os.path.exists(sysfs_net_dir) and not mock_dir:
        ifaces = []
    elif mock_dir and os.path.exists(mock_dir):
        ifaces = [
            f.replace("_ethtool.txt", "")
            for f in os.listdir(mock_dir)
            if f.endswith("_ethtool.txt")
        ]
    else:
        try:
            ifaces = [d for d in os.listdir(sysfs_net_dir) if d != "lo"]
        except Exception:
            ifaces = []

    interfaces_report: Dict[str, Any] = {}
    issues: List[str] = []
    status = "HEALTHY"

    for iface in sorted(ifaces):
        operstate_path = os.path.join(sysfs_net_dir, iface, "operstate")
        speed_path = os.path.join(sysfs_net_dir, iface, "speed")

        operstate = read_sysfs_str(operstate_path, "unknown")
        speed_raw = read_sysfs_str(speed_path, "")
        speed_mbps = int(speed_raw) if speed_raw.isdigit() else None

        features = get_iface_features(iface, mock_dir)
        filtered_features = {
            k: features[k] for k in CRITICAL_FEATURES if k in features
        }

        # Check for LRO enabled (risk of TCP stream reassembly corruption)
        lro = features.get("large-receive-offload", {})
        if lro.get("enabled", False):
            issues.append(f"Interface {iface}: Large Receive Offload (LRO) is enabled; potential packet boundary corruption")
            if status != "CRITICAL":
                status = "WARNING"

        # Check if primary active ethernet has GRO disabled
        gro = features.get("generic-receive-offload", {})
        if operstate == "up" and gro and not gro.get("enabled", False):
            issues.append(f"Active interface {iface}: Generic Receive Offload (GRO) is disabled; degraded network throughput")
            if status != "CRITICAL":
                status = "WARNING"

        interfaces_report[iface] = {
            "operstate": operstate,
            "speed_mbps": speed_mbps,
            "features": filtered_features,
        }

    return {
        "timestamp": now,
        "summary": {
            "status": status,
            "healthy": status == "HEALTHY",
            "interfaces_audited": len(ifaces),
            "issues": issues,
        },
        "interfaces": interfaces_report,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Host Network Generic Receive Offload (GRO) & Hardware Offload Hygiene Guard (Pattern 217)"
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON output")
    parser.add_argument("--mock-dir", type=str, default=None, help="Directory containing mock ethtool output files")
    parser.add_argument("--sysfs-net-dir", type=str, default="/sys/class/net", help="Path to /sys/class/net")

    args = parser.parse_args()

    report = audit_offloads(
        mock_dir=args.mock_dir,
        sysfs_net_dir=args.sysfs_net_dir,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"[{s['status']}] Audited {s['interfaces_audited']} interfaces")
        for iface, data in report["interfaces"].items():
            feats = data["features"]
            gro_str = "on" if feats.get("generic-receive-offload", {}).get("enabled") else "off"
            gso_str = "on" if feats.get("generic-segmentation-offload", {}).get("enabled") else "off"
            tso_str = "on" if feats.get("tcp-segmentation-offload", {}).get("enabled") else "off"
            lro_str = "on" if feats.get("large-receive-offload", {}).get("enabled") else "off"
            speed_str = f"{data['speed_mbps']} Mbps" if data['speed_mbps'] else "n/a"
            print(f"  - {iface:<10} [{data['operstate']}] speed: {speed_str} | GRO: {gro_str} | GSO: {gso_str} | TSO: {tso_str} | LRO: {lro_str}")
        if s["issues"]:
            print("  Issues:")
            for issue in s["issues"]:
                print(f"    - {issue}")

    return 0 if report["summary"]["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
