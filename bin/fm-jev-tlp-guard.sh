#!/usr/bin/env bash
# bin/fm-jev-tlp-guard.sh - Wrapper for Host Network TCP Tail Loss Probe Guard (Pattern 154)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-tlp-guard.py" "$@"
