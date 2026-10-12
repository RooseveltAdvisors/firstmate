#!/usr/bin/env bash
# bin/fm-jev-ipv4-l2-policy-guard.sh - Linux IPv4 L2 Multicast Unicast Drop, Secondary Promotion & Carrier Eviction Guard (Pattern 293 / Pattern 431)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ipv4-l2-policy-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ipv4-l2-policy-guard.py" "$@"
