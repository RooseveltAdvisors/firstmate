#!/usr/bin/env bash
# fm-jev-syncookie-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP SYN Cookie Guard (Pattern 118)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-syncookie-guard.py" "$@"
