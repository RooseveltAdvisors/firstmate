#!/usr/bin/env bash
# bin/fm-jev-binfmt-misc-guard.sh - Linux Binary Format Emulation (binfmt_misc) Guard (Pattern 307 / Pattern 445)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-binfmt-misc-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-binfmt-misc-guard.py" "$@"
