#!/usr/bin/env bash
# bin/fm-jev-wmem-rmem-guard.sh - Wrapper for Host Network TCP Socket Memory Limits & Auto-Tuning Buffer Guard (Pattern 190)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-wmem-rmem-guard.py" "$@"
