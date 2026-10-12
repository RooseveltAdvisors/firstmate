#!/usr/bin/env bash
# bin/fm-jev-ipv4-linkdown-guard.sh - Linux IPv4 Linkdown Route Avoidance, Forwarding & Localnet Security Policy Guard (Pattern 298 / Pattern 436)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv4-linkdown-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv4-linkdown-guard.py" "$@"
