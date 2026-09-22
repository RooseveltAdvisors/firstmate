#!/usr/bin/env bash
# fm-jev-ofo-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP Out-of-Order Queue & Memory Collapse Guard (Pattern 119)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-ofo-guard.py" "$@"
