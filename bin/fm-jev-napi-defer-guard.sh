#!/usr/bin/env bash
# bin/fm-jev-napi-defer-guard.sh - Wrapper for NAPI Hard IRQ Deferral Guard (Pattern 240)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-napi-defer-guard.py" "$@"
