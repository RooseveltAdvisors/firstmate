#!/usr/bin/env bash
# bin/fm-jev-nf-flowtable-guard.sh - Host Network Netfilter Flowtable Offload & Generic/GRE Timeouts Guard (Pattern 277 / Pattern 415)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-nf-flowtable-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-nf-flowtable-guard.py" "$@"
