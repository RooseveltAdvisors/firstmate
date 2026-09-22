#!/usr/bin/env bash
# fm-jev-udp-guard.sh - Pattern 98: Jev Multi-Agent Host Network UDP Socket Buffer Overflow & Datagram Drop Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-udp-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-udp-guard.py" "$@"
