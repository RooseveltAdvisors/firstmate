#!/usr/bin/env bash
# bin/fm-jev-slow-start-guard.sh - Wrapper for Host Network TCP Slow Start After Idle & Congestion Control Guard (Pattern 199)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-slow-start-guard.py" "$@"
