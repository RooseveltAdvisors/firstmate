#!/usr/bin/env bash
# bin/fm-jev-aio-guard.sh - Linux Native Asynchronous I/O (AIO) Capacity Guard (Pattern 316 / Pattern 454)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-aio-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-aio-guard.py" "$@"
