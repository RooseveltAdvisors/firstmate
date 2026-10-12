#!/usr/bin/env bash
# bin/fm-jev-tcp-mem-guard.sh - Host Network TCP Memory Pressure, Prune & Queue Drop Guard (Pattern 223)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(which python3 || echo "/usr/bin/python3")"

if [[ ! -x "${PYTHON_BIN}" ]]; then
    echo "[fm-jev-tcp-mem-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-tcp-mem-guard.py" "$@"
