#!/usr/bin/env bash
# bin/fm-jev-task-count-guard.sh - Linux Kernel Task, Thread & PID Table Saturation Guard (Pattern 310 / Pattern 448)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-task-count-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-task-count-guard.py" "$@"
