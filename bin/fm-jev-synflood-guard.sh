#!/usr/bin/env bash
# fm-jev-synflood-guard.sh - Wrapper for Jev Host Network TCP SYN-Flood Guard (Pattern 140)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-synflood-guard.py" "$@"
