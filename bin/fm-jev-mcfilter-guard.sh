#!/usr/bin/env bash
# bin/fm-jev-mcfilter-guard.sh - Wrapper for Multicast Source Filter Guard (Pattern 242)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-mcfilter-guard.py" "$@"
