#!/usr/bin/env bash
# bin/fm-jev-frto-guard.sh - Wrapper for Host Network TCP Forward RTO (F-RTO) Recovery & Spurious Timeout Guard (Pattern 196)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-frto-guard.py" "$@"
