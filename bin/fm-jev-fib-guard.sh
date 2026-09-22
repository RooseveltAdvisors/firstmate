#!/usr/bin/env bash
# bin/fm-jev-fib-guard.sh - Wrapper for FIB Trie Architecture & Lookup Depth Guard (Pattern 209)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-fib-guard.py" "$@"
