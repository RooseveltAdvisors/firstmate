#!/usr/bin/env bash
# bin/fm-jev-fwmark-guard.sh - Wrapper for Host Network TCP Firewall Mark Guard (Pattern 179)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-fwmark-guard.py" "$@"
