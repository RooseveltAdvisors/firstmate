#!/usr/bin/env bash
# bin/fm-jev-router-solicit-guard.sh - Host IPv6 Router Solicitation (RS / RFC 4861 / RFC 7559) & ICMPv6 Discovery Guard (Pattern 260)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-router-solicit-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-router-solicit-guard.py" "$@"
