#!/usr/bin/env bash
# bin/fm-jev-fwmark-reflect-guard.sh - Host Dual-Stack Firewall Mark (fwmark) Reflection & Policy Routing Guard (Pattern 269 / Pattern 407)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-fwmark-reflect-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-fwmark-reflect-guard.py" "$@"
