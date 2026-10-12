#!/usr/bin/env bash
# fm-jev-swap-thrash-guard.sh - Pattern 79: Jev Multi-Agent Swap I/O Thrashing & Major Page Fault Stall Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-swap-thrash-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-swap-thrash-guard.py" "$@"
