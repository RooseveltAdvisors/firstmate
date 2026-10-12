#!/usr/bin/env bash
# bin/fm-jev-tcp-fastopen-guard.sh - Host Network TCP Fast Open (TFO / RFC 7413) Security & Telemetry Guard (Pattern 275 / Pattern 413)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-tcp-fastopen-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-tcp-fastopen-guard.py" "$@"
