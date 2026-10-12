#!/usr/bin/env bash
# bin/fm-jev-dsack-guard.sh - Wrapper for Host Network TCP D-SACK Guard (Pattern 156)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-dsack-guard.py" "$@"
