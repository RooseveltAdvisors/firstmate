#!/usr/bin/env bash
# bin/fm-jev-netns-policy-guard.sh - Host Network Namespace Configuration Inheritance & Tunnel Policy Guard (Pattern 251)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-netns-policy-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-netns-policy-guard.py" "$@"
