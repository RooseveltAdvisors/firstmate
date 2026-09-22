#!/usr/bin/env bash
# fm-jev-paws-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP TIME-WAIT & PAWS Guard (Pattern 109)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-paws-guard.py" "$@"
