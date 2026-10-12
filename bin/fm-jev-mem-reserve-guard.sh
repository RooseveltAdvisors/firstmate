#!/usr/bin/env bash
# bin/fm-jev-mem-reserve-guard.sh - Linux Kernel Admin & User Memory Reserve Guard (Pattern 311 / Pattern 449)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-mem-reserve-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-mem-reserve-guard.py" "$@"
