#!/usr/bin/env bash
# bin/fm-jev-ofo-guard.sh - Wrapper for Host Network TCP OFO Queue Guard (Pattern 161)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-ofo-guard.py" "$@"
