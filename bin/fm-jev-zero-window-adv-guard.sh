#!/usr/bin/env bash
# bin/fm-jev-zero-window-adv-guard.sh - Wrapper for Host Network TCP Zero-Window Guard (Pattern 162)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-zero-window-adv-guard.py" "$@"
