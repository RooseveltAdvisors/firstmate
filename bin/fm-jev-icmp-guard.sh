#!/usr/bin/env bash
# bin/fm-jev-icmp-guard.sh - Wrapper for ICMP Rate Limiting & Error Message Storm Guard (Pattern 205)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-icmp-guard.py" "$@"
