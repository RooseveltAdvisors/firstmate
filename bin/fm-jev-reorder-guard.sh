#!/usr/bin/env bash
# fm-jev-reorder-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP DSACK & Reordering Guard (Pattern 112)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-reorder-guard.py" "$@"
