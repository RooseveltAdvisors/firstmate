#!/usr/bin/env bash
# fm-jev-ipfrag-guard.sh - Wrapper for Jev Host Network IP Fragment Reassembly Guard (Pattern 126)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-ipfrag-guard.py" "$@"
