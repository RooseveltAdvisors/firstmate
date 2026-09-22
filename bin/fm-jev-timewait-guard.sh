#!/usr/bin/env bash
# bin/fm-jev-timewait-guard.sh - Wrapper for Host Network TCP TIME-WAIT Guard (Pattern 164)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-timewait-guard.py" "$@"
