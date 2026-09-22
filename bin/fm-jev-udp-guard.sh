#!/usr/bin/env bash
# bin/fm-jev-udp-guard.sh - Wrapper for UDP Datagram Buffer & Raw Socket Snooping Guard (Pattern 203)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-udp-guard.py" "$@"
