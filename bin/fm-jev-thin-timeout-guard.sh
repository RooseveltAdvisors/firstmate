#!/usr/bin/env bash
# bin/fm-jev-thin-timeout-guard.sh - Wrapper for Host Network TCP Thin-Stream Linear Timeout Guard (Pattern 235)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-thin-timeout-guard.py" "$@"
