#!/usr/bin/env bash
# fm-jev-cpu-burst-guard.sh - Wrapper for Jev Multi-Agent Load Derivative & CPU Saturation Burst Dampener (Pattern 51)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-cpu-burst-guard.py" "$@"
