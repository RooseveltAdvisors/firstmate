#!/usr/bin/env bash
# bin/fm-jev-rps-rfs-guard.sh - Linux Network RPS, RFS & GRO Normal Batch Guard (Pattern 306 / Pattern 444)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-rps-rfs-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-rps-rfs-guard.py" "$@"
