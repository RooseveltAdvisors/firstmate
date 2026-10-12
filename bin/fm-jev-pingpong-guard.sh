#!/usr/bin/env bash
# fm-jev-pingpong-guard.sh - Wrapper for Jev Host Network TCP Ping-Pong Guard (Pattern 130)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-pingpong-guard.py" "$@"
