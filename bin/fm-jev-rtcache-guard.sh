#!/usr/bin/env bash
# bin/fm-jev-rtcache-guard.sh - Wrapper for Routing Cache Exception & Martian Packet Drop Guard (Pattern 202)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-rtcache-guard.py" "$@"
