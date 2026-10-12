#!/usr/bin/env bash
# bin/fm-jev-abort-overflow-guard.sh - Wrapper for Host Network TCP Listener Abort-On-Overflow Guard (Pattern 187)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-abort-overflow-guard.py" "$@"
