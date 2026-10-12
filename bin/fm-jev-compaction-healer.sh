#!/usr/bin/env bash
# fm-jev-compaction-healer.sh - Pattern 68: Jev Multi-Agent Proactive Memory Compaction & Fragmentation Healer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-compaction-healer" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-compaction-healer.py" "$@"
