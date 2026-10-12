#!/usr/bin/env bash
# bin/fm-jev-ipv4-route-gc-guard.sh - Host Network IPv4 Routing Cache Garbage Collection & PMTU Exception Policy Guard (Pattern 284 / Pattern 422)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv4-route-gc-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv4-route-gc-guard.py" "$@"
