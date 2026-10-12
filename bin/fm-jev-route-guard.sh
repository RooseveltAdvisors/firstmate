#!/usr/bin/env bash
# fm-jev-route-guard.sh - Pattern 93: Jev Multi-Agent Host Network Routing Table Bloat & Nexthop Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-route-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-route-guard.py" "$@"
