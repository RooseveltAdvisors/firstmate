#!/usr/bin/env bash
# bin/fm-jev-raw-socket-guard.sh - Pattern 222: Host Network Raw Socket (SOCK_RAW) Guard wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${FM_PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-raw-socket-guard.py" "$@"
