#!/usr/bin/env bash
# bin/fm-jev-optmem-guard.sh - Host Network Core Socket Ancillary Buffer & SKB Page Fragment Guard (Pattern 276 / Pattern 414)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-optmem-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-optmem-guard.py" "$@"
