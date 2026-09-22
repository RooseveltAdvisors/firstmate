#!/usr/bin/env bash
# bin/fm-jev-ehash-guard.sh - Wrapper for Host Network TCP Established Hash Table Guard (Pattern 166)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-ehash-guard.py" "$@"
