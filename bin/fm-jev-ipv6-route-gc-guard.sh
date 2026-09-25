#!/usr/bin/env bash
# bin/fm-jev-ipv6-route-gc-guard.sh - Host Network IPv6 Route Garbage Collection & Expiration Policy Guard (Pattern 281 / Pattern 419)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv6-route-gc-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv6-route-gc-guard.py" "$@"
