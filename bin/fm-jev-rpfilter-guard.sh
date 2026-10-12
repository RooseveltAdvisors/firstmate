#!/usr/bin/env bash
# fm-jev-rpfilter-guard.sh - Wrapper for Jev Multi-Agent Host Network IP Reverse Path Filtering Guard (Pattern 121)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-rpfilter-guard.py" "$@"
