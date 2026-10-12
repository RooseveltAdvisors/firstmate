#!/usr/bin/env bash
# fm-jev-secret-guard.sh - Wrapper for Jev Multi-Agent Secret Exposure Guard (Pattern 56)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-secret-guard.py" "$@"
