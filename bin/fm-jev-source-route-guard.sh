#!/usr/bin/env bash
# bin/fm-jev-source-route-guard.sh - Host Network IPv4/IPv6 Source Routing & RH0 Mitigation Guard (Pattern 248)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-source-route-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-source-route-guard.py" "$@"
