#!/usr/bin/env bash
# fm-jev-challenge-ack-guard.sh - Wrapper for Jev Host Network TCP Challenge ACK Guard (Pattern 134)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-challenge-ack-guard.py" "$@"
