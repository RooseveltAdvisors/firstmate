#!/usr/bin/env bash
# bin/fm-jev-retrans-fail-guard.sh - Wrapper for Host Network TCP Retransmission Failure Guard (Pattern 165)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-retrans-fail-guard.py" "$@"
