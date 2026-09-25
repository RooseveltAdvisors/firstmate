#!/usr/bin/env bash
# bin/fm-jev-proxy-ndp-guard.sh - Host IPv6 Proxy Neighbor Discovery (Proxy NDP / RFC 4389) Guard (Pattern 259)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-proxy-ndp-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-proxy-ndp-guard.py" "$@"
