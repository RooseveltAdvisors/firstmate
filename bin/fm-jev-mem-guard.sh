#!/usr/bin/env bash
# fm-jev-mem-guard.sh - Wrapper for Jev Multi-Agent Memory RSS & Swap Thrashing Guard (Pattern 46)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-mem-guard.py" "$@"
