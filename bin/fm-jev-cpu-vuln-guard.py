#!/usr/bin/env python3
"""
bin/fm-jev-cpu-vuln-guard.py - Linux CPU Speculative Execution Vulnerability & Microcode Guard (Pattern 323 / Pattern 461)

Audits Linux kernel CPU hardware vulnerability mitigations (/sys/devices/system/cpu/vulnerabilities/*)
including Spectre v1/v2, Meltdown, Speculative Store Bypass, Retbleed, L1TF, MDS, MMIO Stale Data,
and Gather Data Sampling to detect unmitigated speculative execution vectors, missing CPU microcode,
and cross-tenant memory isolation leaks that jeopardize multi-agent secrets and process sandboxes.

Invariants:
  - Critical/Warning if any monitored hardware vulnerability is reported as "Vulnerable".
  - Fail-open: graceful fallback when sysfs paths are restricted or in containers.
  - Bounded fast execution (< 0.02s).
"""

import argparse
import datetime
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

SYSFS_CPU_VULN_DIR = "/sys/devices/system/cpu/vulnerabilities"


def read_sysfs_text(path: Path) -> str:
    """Reads stripped text from a sysfs attribute."""
    if not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        return ""


def evaluate_cpu_vuln(
    vuln_dir: str = SYSFS_CPU_VULN_DIR,
    warn_on_unmitigated: bool = True,
) -> Dict[str, Any]:
    v_path = Path(vuln_dir)
    issues: List[str] = []
    recommendations: List[str] = []
    status = "HEALTHY"

    if not v_path.is_dir():
        return {
            "pattern": 323,
            "name": "cpu_vuln",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "HEALTHY",
            "healthy": True,
            "is_mitigations_healthy": True,
            "total_vulnerabilities_monitored": 0,
            "not_affected_count": 0,
            "mitigated_count": 0,
            "vulnerable_count": 0,
            "unknown_count": 0,
            "vulnerabilities": {},
            "issues": [],
            "recommendations": [
                "CPU vulnerabilities sysfs directory not found; running in virtualized or containerized environment."
            ],
        }

    vulnerabilities: Dict[str, Dict[str, str]] = {}
    is_warning = False
    is_critical = False

    not_affected_count = 0
    mitigated_count = 0
    vulnerable_count = 0
    unknown_count = 0

    for f_path in sorted(v_path.iterdir()):
        if not f_path.is_file():
            continue

        v_name = f_path.name
        raw_val = read_sysfs_text(f_path)
        val_lower = raw_val.lower()

        classification = "unknown"
        if val_lower.startswith("not affected"):
            classification = "not_affected"
            not_affected_count += 1
        elif val_lower.startswith("mitigation"):
            classification = "mitigated"
            mitigated_count += 1
        elif val_lower.startswith("vulnerable"):
            classification = "vulnerable"
            vulnerable_count += 1
            if warn_on_unmitigated:
                if any(k in v_name for k in ("spectre", "meltdown", "retbleed", "mds")):
                    is_critical = True
                else:
                    is_warning = True
                issues.append(f"CPU vulnerability '{v_name}' is UNMITIGATED: {raw_val}")
        else:
            unknown_count += 1

        vulnerabilities[v_name] = {
            "classification": classification,
            "description": raw_val,
        }

    total_monitored = len(vulnerabilities)

    if total_monitored == 0:
        return {
            "pattern": 323,
            "name": "cpu_vuln",
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "status": "HEALTHY",
            "healthy": True,
            "is_mitigations_healthy": True,
            "total_vulnerabilities_monitored": 0,
            "not_affected_count": 0,
            "mitigated_count": 0,
            "vulnerable_count": 0,
            "unknown_count": 0,
            "vulnerabilities": {},
            "issues": [],
            "recommendations": [
                "No CPU vulnerability mitigation attributes found in sysfs."
            ],
        }

    if vulnerable_count > 0:
        recommendations.append(
            f"{vulnerable_count} CPU vulnerability/vulnerabilities unmitigated; "
            "update processor microcode (intel-microcode / amd64-microcode) and enable kernel speculative execution mitigations"
        )
    else:
        recommendations.append(
            f"All {total_monitored} monitored CPU hardware vulnerabilities are either mitigated ({mitigated_count}) "
            f"or not affected ({not_affected_count})"
        )

    status = "CRITICAL" if is_critical else ("WARNING" if is_warning else "HEALTHY")
    healthy = (status == "HEALTHY")
    is_mitigations_healthy = healthy

    return {
        "pattern": 323,
        "name": "cpu_vuln",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": status,
        "healthy": healthy,
        "is_mitigations_healthy": is_mitigations_healthy,
        "total_vulnerabilities_monitored": total_monitored,
        "not_affected_count": not_affected_count,
        "mitigated_count": mitigated_count,
        "vulnerable_count": vulnerable_count,
        "unknown_count": unknown_count,
        "vulnerabilities": vulnerabilities,
        "issues": issues,
        "recommendations": recommendations,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Linux kernel CPU hardware speculative execution vulnerability mitigations."
    )
    parser.add_argument("--json", action="store_true", help="Output telemetry in JSON format")
    parser.add_argument("--vuln-dir", default=SYSFS_CPU_VULN_DIR, help=f"Path to CPU vulnerabilities sysfs (default: {SYSFS_CPU_VULN_DIR})")
    parser.add_argument("--ignore-unmitigated", action="store_true", help="Do not warn on unmitigated CPU vulnerabilities")

    args = parser.parse_args()

    result = evaluate_cpu_vuln(
        vuln_dir=args.vuln_dir,
        warn_on_unmitigated=not args.ignore_unmitigated,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_symbol = "✓" if result["healthy"] else "✗"
        print(f"[{status_symbol}] Pattern 323 (cpu_vuln): {result['status']}")
        print(
            f"  Monitored: {result['total_vulnerabilities_monitored']} | "
            f"Mitigated: {result['mitigated_count']} | Not Affected: {result['not_affected_count']} | "
            f"Vulnerable: {result['vulnerable_count']}"
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
