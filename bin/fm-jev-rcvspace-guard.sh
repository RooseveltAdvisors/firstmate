#!/usr/bin/env bash
# bin/fm-jev-rcvspace-guard.sh - Wrapper for Host Network TCP RCV Space Guard (Pattern 160)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-rcvspace-guard.py" "$@"
