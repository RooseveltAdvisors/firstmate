#!/usr/bin/env bash
# bin/fm-jev-rpl-seg-guard.sh - Host IPv6 RPL Routing Header Type 3 (RFC 6554) & Source Routing Guard (Pattern 258)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-rpl-seg-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-rpl-seg-guard.py" "$@"
