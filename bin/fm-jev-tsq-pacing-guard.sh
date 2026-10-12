#!/usr/bin/env bash
# bin/fm-jev-tsq-pacing-guard.sh - Wrapper for Host Network TCP TSQ Pacing Guard (Pattern 167)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-tsq-pacing-guard.py" "$@"
