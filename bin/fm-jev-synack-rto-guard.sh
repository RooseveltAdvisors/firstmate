#!/usr/bin/env bash
# fm-jev-synack-rto-guard.sh - Wrapper for Jev Host Network TCP SYN/ACK Retransmission Guard (Pattern 143)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-synack-rto-guard.py" "$@"
