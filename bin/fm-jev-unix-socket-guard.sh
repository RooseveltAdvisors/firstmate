#!/usr/bin/env bash
# fm-jev-unix-socket-guard.sh - Pattern 74: Jev Multi-Agent Unix Domain Socket & Abstract Namespace Leak Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-unix-socket-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-unix-socket-guard.py" "$@"
