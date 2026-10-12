#!/usr/bin/env bash
# bin/fm-jev-aslr-guard.sh - Linux Kernel ASLR & Virtual Memory Security Hardening Guard (Pattern 315 / Pattern 453)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-aslr-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-aslr-guard.py" "$@"
