#!/usr/bin/env bash
# bin/fm-jev-fin-timeout-guard.sh - Wrapper for Host Network TCP FIN Timeout & Orphan Connection Reclamation Guard (Pattern 193)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-fin-timeout-guard.py" "$@"
