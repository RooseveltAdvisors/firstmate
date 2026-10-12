#!/usr/bin/env bash
# fm-jev-syn-scramble-guard.sh - Wrapper for Jev Host Network TCP SYN/FIN Scrambling Guard (Pattern 125)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-syn-scramble-guard.py" "$@"
