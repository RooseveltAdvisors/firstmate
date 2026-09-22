#!/usr/bin/env bash
# fm-jev-ack-guard.sh - Wrapper for Jev Multi-Agent Host Network TCP ACK Compression & Delayed ACK Guard (Pattern 113)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-ack-guard.py" "$@"
