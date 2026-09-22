#!/usr/bin/env bash
# bin/fm-jev-rto-bounds-guard.sh - Wrapper for Host Network TCP RTO Bounds Guard (Pattern 170 Milestone)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-rto-bounds-guard.py" "$@"
