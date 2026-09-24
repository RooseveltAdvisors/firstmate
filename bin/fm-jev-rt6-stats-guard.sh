#!/usr/bin/env bash
# bin/fm-jev-rt6-stats-guard.sh - Wrapper for IPv6 Route Table & FIB6 Guard (Pattern 239)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-rt6-stats-guard.py" "$@"
