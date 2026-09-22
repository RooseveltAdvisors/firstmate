#!/usr/bin/env bash
# bin/fm-jev-sack-guard.sh - Wrapper for TCP SACK & OFO Queue Guard (Pattern 210)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-sack-guard.py" "$@"
