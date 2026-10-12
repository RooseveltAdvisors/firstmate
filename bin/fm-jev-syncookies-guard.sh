#!/usr/bin/env bash
# bin/fm-jev-syncookies-guard.sh - Wrapper for Host Network TCP SYN Cookie Storm & Syncookies Recv Guard (Pattern 192)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-syncookies-guard.py" "$@"
