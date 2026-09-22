#!/usr/bin/env bash
# fm-jev-entropy-guard.sh - Pattern 81: Jev Multi-Agent Kernel Entropy Pool & Hardware RNG Depletion Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-entropy-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-entropy-guard.py" "$@"
