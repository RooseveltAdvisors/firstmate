#!/usr/bin/env bash
# fm-jev-notsent-guard.sh - Wrapper for Jev Host Network TCP Unsent Queue Guard (Pattern 128)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-notsent-guard.py" "$@"
