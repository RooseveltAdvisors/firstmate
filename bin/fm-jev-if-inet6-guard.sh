#!/usr/bin/env bash
# bin/fm-jev-if-inet6-guard.sh - Host Network Interface IPv6 Address Scope, DAD & Lifetime Flags Guard (Pattern 246)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-if-inet6-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-if-inet6-guard.py" "$@"
