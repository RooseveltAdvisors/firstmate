#!/usr/bin/env bash
# bin/fm-jev-skbuff-guard.sh - Wrapper for Socket Buffer Auto-Tuning & Protocol Memory Guard (Pattern 208)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-skbuff-guard.py" "$@"
