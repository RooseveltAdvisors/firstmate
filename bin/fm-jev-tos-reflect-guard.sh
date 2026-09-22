#!/usr/bin/env bash
# bin/fm-jev-tos-reflect-guard.sh - Wrapper for Host Network TCP ToS Reflection Guard (Pattern 176)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-tos-reflect-guard.py" "$@"
