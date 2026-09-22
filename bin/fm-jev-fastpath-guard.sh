#!/usr/bin/env bash
# bin/fm-jev-fastpath-guard.sh - Wrapper for Host Network TCP Fast-Path Header Prediction & Pure ACK Guard (Pattern 197)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-fastpath-guard.py" "$@"
