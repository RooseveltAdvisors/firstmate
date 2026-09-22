#!/usr/bin/env bash
# bin/fm-jev-zerowin-guard.sh - Wrapper for Pattern 147
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(which python3 || echo "python3")"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-zerowin-guard.py" "$@"
