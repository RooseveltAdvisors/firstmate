#!/usr/bin/env bash
# bin/fm-jev-autocork-guard.sh - Wrapper for Host Network TCP Autocorking & Coalescence Guard (Pattern 194)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-autocork-guard.py" "$@"
