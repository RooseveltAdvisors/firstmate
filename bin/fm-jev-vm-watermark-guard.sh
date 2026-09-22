#!/usr/bin/env bash
# bin/fm-jev-vm-watermark-guard.sh - Wrapper for Host Kernel VM Watermarks & Direct Reclaim Stall Guard (Pattern 201)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-vm-watermark-guard.py" "$@"
