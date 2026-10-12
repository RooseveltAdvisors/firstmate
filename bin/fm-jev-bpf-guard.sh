#!/usr/bin/env bash
# fm-jev-bpf-guard.sh - Pattern 75: Jev Multi-Agent eBPF Map & BPF Program Limit Exhaustion Guard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

if ! command -v "$PYTHON_EXEC" >/dev/null 2>&1; then
    echo "ERROR: python3 required for fm-jev-bpf-guard" >&2
    exit 1
fi

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-bpf-guard.py" "$@"
