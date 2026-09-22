#!/usr/bin/env bash
# bin/fm-jev-syn-retry-guard.sh - Wrapper for Host Network TCP Retransmission Collapse & SYN Retry Budget Guard (Pattern 189)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-syn-retry-guard.py" "$@"
