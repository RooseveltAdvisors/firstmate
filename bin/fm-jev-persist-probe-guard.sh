#!/usr/bin/env bash
# bin/fm-jev-persist-probe-guard.sh - Wrapper for Host Network TCP Zero-Window Probing & Persist Timer Stasis Guard (Pattern 169)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-persist-probe-guard.py" "$@"
