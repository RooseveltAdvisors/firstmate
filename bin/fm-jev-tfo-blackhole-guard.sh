#!/usr/bin/env bash
# bin/fm-jev-tfo-blackhole-guard.sh - Wrapper for Host Network TCP Fast Open Blackhole Guard (Pattern 174)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-tfo-blackhole-guard.py" "$@"
