#!/usr/bin/env bash
# fm-jev-numa-guard.sh - Pattern 83: Jev Multi-Agent Core CPU Affinity & NUMA Node Memory Allocation Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-numa-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-numa-guard.py" "$@"
