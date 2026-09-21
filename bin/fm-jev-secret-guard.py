#!/usr/bin/env python3
"""
fm-jev-secret-guard.py - Jev Multi-Agent Secret & API Token Exposure Guard (Pattern 56)

Audits multi-agent scratch directories, /tmp, and repo untracked files for unredacted API tokens
and private credentials (GitHub tokens, OpenAI/Anthropic keys, AWS credentials, SSH private keys).
Prevents credential leakage across shared multi-agent seats and prevents secret commits.

Invariants:
  - Read-only diagnostics by default. Non-destructive.
  - Redacts detected secret strings in all outputs and JSON logs.
  - Fail-open: graceful handling of binary or permission-restricted files.
  - Bounded fast execution (< 2.0s), skipping files > 5MB.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Pattern, Tuple


DEFAULT_AUDIT_PATHS = [
    "/opt/ra/firstmate/scratch",
    "/home/jon/git/jev/scratch",
    "/tmp",
]

SECRET_RULES: List[Tuple[str, Pattern[str]]] = [
    ("GitHub Personal Access Token", re.compile(r"ghp_[A-Za-z0-9_]{36,}")),
    ("GitHub OAuth Access Token", re.compile(r"gho_[A-Za-z0-9_]{36,}")),
    ("OpenAI API Key", re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
    ("Anthropic API Key", re.compile(r"sk-ant-[A-Za-z0-9_-]{32,}")),
    ("AWS Access Key ID", re.compile(r"\b(AKIA[0-9A-Z]{16})\b")),
    ("SSH/PGP Private Key", re.compile(r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")),
    ("Slack API Token", re.compile(r"xox[baprs]-[A-Za-z0-9-]{20,}")),
    ("Stripe API Key", re.compile(r"sk_(?:live|test)_[0-9a-zA-Z]{24,}")),
]

SKIP_EXTENSIONS = {
    ".pyc", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf",
    ".zip", ".tar", ".gz", ".xz", ".zst", ".7z", ".bin",
    ".exe", ".so", ".dylib", ".wasm", ".o", ".a",
}

IGNORE_DIR_NAMES = {
    ".git", "node_modules", ".cache", ".cargo", "venv", ".venv",
}


def mask_secret(secret_str: str) -> str:
    """Masks secret showing only prefix and suffix."""
    if len(secret_str) <= 8:
        return "****"
    return secret_str[:4] + "..." + secret_str[-4:]


def scan_file_for_secrets(file_path: str, max_size_bytes: int = 5 * 1024 * 1024) -> List[Dict[str, Any]]:
    """Scans a single file for known secret patterns."""
    findings: List[Dict[str, Any]] = []

    ext = os.path.splitext(file_path)[1].lower()
    if ext in SKIP_EXTENSIONS:
        return findings

    try:
        st = os.stat(file_path, follow_symlinks=False)
        if st.st_size > max_size_bytes or st.st_size == 0:
            return findings

        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            for line_no, line in enumerate(f, start=1):
                # Quick skip line if no indicators
                if not any(marker in line for marker in ("ghp_", "gho_", "sk-", "AKIA", "BEGIN", "xox", "sk_")):
                    continue

                for rule_name, pattern in SECRET_RULES:
                    for match in pattern.finditer(line):
                        raw_val = match.group(0)
                        # Filter out common false positives or test fixtures
                        if "dummy" in raw_val.lower() or "example" in raw_val.lower() or "test" in raw_val.lower():
                            continue
                        findings.append({
                            "file": file_path,
                            "line": line_no,
                            "type": rule_name,
                            "masked": mask_secret(raw_val),
                        })
    except (PermissionError, FileNotFoundError, IsADirectoryError):
        pass
    except Exception:
        pass

    return findings


def audit_path_secrets(root_path: str, max_depth: int = 3) -> List[Dict[str, Any]]:
    """Recursively scans a path up to max_depth for unredacted secrets."""
    findings: List[Dict[str, Any]] = []
    if not os.path.exists(root_path):
        return findings

    root_depth = root_path.rstrip(os.path.sep).count(os.path.sep)

    try:
        for dirpath, dirnames, filenames in os.walk(root_path, followlinks=False):
            current_depth = dirpath.count(os.path.sep) - root_depth
            if current_depth >= max_depth:
                dirnames.clear()

            # Skip common ignorable dirs
            if os.path.basename(dirpath) in IGNORE_DIR_NAMES:
                dirnames.clear()
                continue

            for fname in filenames:
                fpath = os.path.join(dirpath, fname)
                file_findings = scan_file_for_secrets(fpath)
                findings.extend(file_findings)
    except (PermissionError, FileNotFoundError):
        pass

    return findings


def audit_fleet_secrets(
    search_paths: Optional[List[str]] = None,
    max_depth: int = 3,
) -> Dict[str, Any]:
    """Audits fleet paths for credential exposures."""
    if search_paths is None:
        search_paths = DEFAULT_AUDIT_PATHS

    all_findings: List[Dict[str, Any]] = []
    scanned_roots: List[str] = []

    for p in search_paths:
        expanded = os.path.expanduser(p)
        if os.path.exists(expanded):
            scanned_roots.append(expanded)
            items = audit_path_secrets(expanded, max_depth=max_depth)
            all_findings.extend(items)

    status = "HEALTHY"
    recommendation = "optimal"

    if all_findings:
        status = "CRITICAL"
        recommendation = f"{len(all_findings)} unredacted credentials exposed; immediate revocation and redaction required"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "scanned_paths": scanned_roots,
            "total_findings_count": len(all_findings),
            "status": status,
            "recommendation": recommendation,
            "healthy": (status == "HEALTHY"),
        },
        "findings": all_findings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Secret & API Token Exposure Guard (Pattern 56)"
    )
    parser.add_argument(
        "--paths",
        nargs="+",
        default=None,
        help="Paths to audit for exposed credentials (default: /opt/ra/firstmate/scratch, /home/jon/git/jev/scratch, /tmp)",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=2,
        help="Max directory search depth (default: 2)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON results",
    )

    args = parser.parse_args()

    results = audit_fleet_secrets(
        search_paths=args.paths,
        max_depth=args.depth,
    )

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if results["summary"]["healthy"] else 1

    summary = results["summary"]
    print(f"Jev Secret Exposure Guard (Pattern 56) - {results['timestamp']}")
    print(f"Audited {len(summary['scanned_paths'])} paths: {summary['scanned_paths']}")
    print(f"Exposed Secrets: {summary['total_findings_count']}")
    print(f"Health Status:   {summary['status']}")
    print(f"Recommendation:  {summary['recommendation']}")

    if results["findings"]:
        print("\nFindings Breakdown:")
        for f in results["findings"][:15]:
            print(f"  - {f['file']}:{f['line']} [{f['type']}] -> {f['masked']}")

    return 0 if summary["healthy"] else 1


if __name__ == "__main__":
    sys.exit(main())
