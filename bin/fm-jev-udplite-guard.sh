#!/usr/bin/env bash
# bin/fm-jev-udplite-guard.sh - Wrapper for UDP-Lite Transport Guard (Pattern 244)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-udplite-guard.py" "$@"
