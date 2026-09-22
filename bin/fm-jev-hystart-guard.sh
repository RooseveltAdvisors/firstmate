#!/usr/bin/env bash
# fm-jev-hystart-guard.sh - Wrapper for Jev Host Network TCP HyStart++ Guard (Pattern 136)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-hystart-guard.py" "$@"
