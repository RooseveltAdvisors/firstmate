#!/usr/bin/env bash
# fm-jev-container-guard.sh - Wrapper for Jev Multi-Agent Container & Volume Guard (Pattern 58)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-container-guard.py" "$@"
