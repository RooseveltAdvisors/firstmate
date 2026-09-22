#!/usr/bin/env bash
# fm-jev-tso-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP Segmentation Offload Guard (Pattern 122)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-tso-guard.py" "$@"
