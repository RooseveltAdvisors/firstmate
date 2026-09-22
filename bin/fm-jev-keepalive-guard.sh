#!/usr/bin/env bash
# bin/fm-jev-keepalive-guard.sh - Wrapper for Pattern 148
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(which python3 || echo "python3")"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-keepalive-guard.py" "$@"
