#!/usr/bin/env bash
# bin/fm-jev-tw-reuse-delay-guard.sh - Wrapper for Host Network TCP TIME_WAIT Reuse Delay Guard (Pattern 183)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-tw-reuse-delay-guard.py" "$@"
