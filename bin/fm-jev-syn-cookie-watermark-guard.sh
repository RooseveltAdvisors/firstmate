#!/usr/bin/env bash
# bin/fm-jev-syn-cookie-watermark-guard.sh - Wrapper for Pattern 145
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(which python3 || echo "python3")"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-syn-cookie-watermark-guard.py" "$@"
