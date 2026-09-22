#!/usr/bin/env bash
# bin/fm-jev-ecn-guard.sh - Wrapper for Host Network TCP ECN Guard (Pattern 159)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-ecn-guard.py" "$@"
