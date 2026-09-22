#!/usr/bin/env bash
# bin/fm-jev-ktls-guard.sh - Host Network Kernel TLS (kTLS) Guard Wrapper (Pattern 225)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${SCRIPT_DIR}/../.venv/bin/python3"

if [[ ! -x "${PYTHON_BIN}" ]]; then
    PYTHON_BIN="python3"
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ktls-guard.py" "$@"
