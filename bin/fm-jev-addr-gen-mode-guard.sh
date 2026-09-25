#!/usr/bin/env bash
# bin/fm-jev-addr-gen-mode-guard.sh - Host IPv6 Interface Identifier Address Generation Mode & Privacy Guard (Pattern 264 / Pattern 402)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-addr-gen-mode-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-addr-gen-mode-guard.py" "$@"
