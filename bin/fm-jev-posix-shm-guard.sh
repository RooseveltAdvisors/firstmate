#!/usr/bin/env bash
# bin/fm-jev-posix-shm-guard.sh - POSIX Shared Memory & Named Semaphore Hygiene Guard (Pattern 312 / Pattern 450)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-posix-shm-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-posix-shm-guard.py" "$@"
