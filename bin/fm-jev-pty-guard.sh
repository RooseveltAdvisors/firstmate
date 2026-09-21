#!/usr/bin/env bash
# fm-jev-pty-guard.sh - Wrapper for Jev Multi-Agent PTY/TTY Allocation Guard (Pattern 47)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-pty-guard.py" "$@"
