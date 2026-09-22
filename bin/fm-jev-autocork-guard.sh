#!/usr/bin/env bash
# fm-jev-autocork-guard.sh - Wrapper for Jev Host Network TCP Auto Corking Guard (Pattern 135)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-autocork-guard.py" "$@"
