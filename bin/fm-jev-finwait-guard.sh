#!/usr/bin/env bash
# fm-jev-finwait-guard.sh - Pattern 108: Jev Multi-Agent Host Network TCP FIN-WAIT-2 & Orphan Socket Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-finwait-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-finwait-guard.py" "$@"
