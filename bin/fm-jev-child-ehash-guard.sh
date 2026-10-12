#!/usr/bin/env bash
# bin/fm-jev-child-ehash-guard.sh - Wrapper for Host Network TCP Child Established Hash Table Guard (Pattern 185)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-child-ehash-guard.py" "$@"
