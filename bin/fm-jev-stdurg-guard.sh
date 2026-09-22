#!/usr/bin/env bash
# bin/fm-jev-stdurg-guard.sh - Wrapper for Host Network TCP Urgent Pointer Guard (Pattern 180)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-stdurg-guard.py" "$@"
