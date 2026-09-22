#!/usr/bin/env bash
# bin/fm-jev-transport-matrix-guard.sh - Wrapper for TCP Transport Capability Matrix Guard (Pattern 200 - Bicentennial Milestone)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-transport-matrix-guard.py" "$@"
