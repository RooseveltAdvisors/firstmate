#!/usr/bin/env bash
# bin/fm-jev-low-latency-guard.sh - Wrapper for Host Network TCP Low Latency Guard (Pattern 171)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-low-latency-guard.py" "$@"
