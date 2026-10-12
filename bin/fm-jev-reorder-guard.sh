#!/usr/bin/env bash
# bin/fm-jev-reorder-guard.sh - Wrapper for Host Network TCP Packet Reordering Guard (Pattern 188)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-reorder-guard.py" "$@"
