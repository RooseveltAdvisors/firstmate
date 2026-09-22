#!/usr/bin/env bash
# fm-jev-sack-compression-guard.sh - Wrapper for Jev Host Network TCP SACK Compression Guard (Pattern 137)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-sack-compression-guard.py" "$@"
