#!/usr/bin/env bash
# bin/fm-jev-mptcp-timeout-guard.sh - Linux kernel Multipath TCP (MPTCP RFC 8684) Path Management & Timeout Policy Guard (Pattern 285 / Pattern 423)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-mptcp-timeout-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-mptcp-timeout-guard.py" "$@"
