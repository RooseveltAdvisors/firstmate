#!/usr/bin/env bash
# bin/fm-jev-ptype-guard.sh - Pattern 220: Host Network Kernel Packet Type Handler (ptype) Guard wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${FM_PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-ptype-guard.py" "$@"
