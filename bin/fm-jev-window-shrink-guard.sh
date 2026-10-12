#!/usr/bin/env bash
# bin/fm-jev-window-shrink-guard.sh - Wrapper for Host Network TCP Window Shrink Guard (Pattern 169)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-window-shrink-guard.py" "$@"
