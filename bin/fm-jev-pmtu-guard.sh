#!/usr/bin/env bash
# fm-jev-pmtu-guard.sh - Wrapper for Jev Host Network TCP PMTU Black Hole Guard (Pattern 144)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-pmtu-guard.py" "$@"
