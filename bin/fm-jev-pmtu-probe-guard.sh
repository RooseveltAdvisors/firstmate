#!/usr/bin/env bash
# bin/fm-jev-pmtu-probe-guard.sh - Wrapper for Host Network TCP Path MTU Discovery Probe Guard (Pattern 175)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-pmtu-probe-guard.py" "$@"
