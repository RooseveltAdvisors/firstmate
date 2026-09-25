#!/usr/bin/env bash
# bin/fm-jev-ndisc-timer-guard.sh - Host IPv6 Neighbor Discovery (NDISC) Reachability Timers & Resolution Guard (Pattern 268 / Pattern 406)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-ndisc-timer-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ndisc-timer-guard.py" "$@"
