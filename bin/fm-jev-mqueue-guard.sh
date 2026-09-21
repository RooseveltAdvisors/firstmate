#!/usr/bin/env bash
# fm-jev-mqueue-guard.sh - Jev Multi-Agent POSIX & System V IPC Message Queue Guard (Pattern 65)
# Wrapper script for bin/fm-jev-mqueue-guard.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-mqueue-guard.py" "$@"
