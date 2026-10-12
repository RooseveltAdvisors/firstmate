#!/usr/bin/env bash
# bin/fm-jev-wscale-guard.sh - Wrapper for Host Network TCP Window Scale Guard (Pattern 157)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-wscale-guard.py" "$@"
