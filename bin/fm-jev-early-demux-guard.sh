#!/usr/bin/env bash
# fm-jev-early-demux-guard.sh - Wrapper for Jev Host Network TCP/IP Early Demux Guard (Pattern 129)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-early-demux-guard.py" "$@"
