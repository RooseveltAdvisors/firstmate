#!/usr/bin/env bash
# bin/fm-jev-unix-guard.sh - Wrapper for UNIX Domain Socket Namespace & Queue Guard (Pattern 206)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-unix-guard.py" "$@"
