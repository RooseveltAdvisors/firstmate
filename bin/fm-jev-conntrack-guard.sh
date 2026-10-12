#!/usr/bin/env bash
# bin/fm-jev-conntrack-guard.sh - Wrapper for Netfilter Conntrack & Routing Cache Guard (Pattern 207)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-conntrack-guard.py" "$@"
