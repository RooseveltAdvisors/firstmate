#!/usr/bin/env bash
# fm-jev-rto-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP RACK/TLP Loss Recovery Guard (Pattern 111)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-rto-guard.py" "$@"
