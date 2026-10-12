#!/usr/bin/env bash
# bin/fm-jev-ipv6-route-table-guard.sh - Linux IPv6 Route Table Capacity, GC Threshold & MSS Policy Guard (Pattern 287 / Pattern 425)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv6-route-table-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv6-route-table-guard.py" "$@"
