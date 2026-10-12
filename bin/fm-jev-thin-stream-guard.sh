#!/usr/bin/env bash
# fm-jev-thin-stream-guard.sh - Wrapper for Jev Host Network TCP Early Retransmit Guard (Pattern 127)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-thin-stream-guard.py" "$@"
