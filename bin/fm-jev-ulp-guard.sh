#!/usr/bin/env bash
# bin/fm-jev-ulp-guard.sh - Wrapper for Host Network TCP ULP Guard (Pattern 182)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-ulp-guard.py" "$@"
