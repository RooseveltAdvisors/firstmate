#!/usr/bin/env bash
# bin/fm-jev-backlog-ack-guard.sh - Wrapper for Host Network TCP Backlog ACK Deferral Guard (Pattern 177)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-backlog-ack-guard.py" "$@"
