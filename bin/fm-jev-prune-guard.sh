#!/usr/bin/env bash
# fm-jev-prune-guard.sh - Wrapper for Jev Host Network TCP Receive Queue Pruning Guard (Pattern 138)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-prune-guard.py" "$@"
