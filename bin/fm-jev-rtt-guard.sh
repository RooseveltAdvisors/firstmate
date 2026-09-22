#!/usr/bin/env bash
# fm-jev-rtt-guard.sh - Wrapper for Jev Host Network TCP RTT Smoothing Guard (Pattern 133)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-rtt-guard.py" "$@"
