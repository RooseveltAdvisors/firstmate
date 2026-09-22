#!/usr/bin/env bash
# bin/fm-jev-mtu-probe-guard.sh - Wrapper for Host Network TCP MTU Probing Guard (Pattern 158)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-mtu-probe-guard.py" "$@"
