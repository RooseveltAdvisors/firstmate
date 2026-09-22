#!/usr/bin/env bash
# fm-jev-net-metrics-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP Route Metrics Guard (Pattern 117)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-net-metrics-guard.py" "$@"
