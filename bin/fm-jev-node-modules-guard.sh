#!/usr/bin/env bash
# fm-jev-node-modules-guard.sh - Wrapper for Jev Multi-Agent node_modules Bloat Guard (Pattern 57)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-node-modules-guard.py" "$@"
