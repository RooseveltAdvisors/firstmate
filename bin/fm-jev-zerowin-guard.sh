#!/usr/bin/env bash
# fm-jev-zerowin-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP Zero-Window & Flow Control Guard (Pattern 110)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-zerowin-guard.py" "$@"
