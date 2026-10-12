#!/usr/bin/env bash
# fm-jev-symlink-guard.sh - Wrapper for Jev Multi-Agent Broken Symlink Guard (Pattern 52)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-symlink-guard.py" "$@"
