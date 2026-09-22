#!/usr/bin/env bash
# fm-jev-sack-guard.sh - Pattern 102: Jev Multi-Agent Host Network TCP Window Scale & SACK Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-sack-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-sack-guard.py" "$@"
