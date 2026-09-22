#!/usr/bin/env bash
# fm-jev-epoll-guard.sh - Wrapper for Jev Host Network TCP Epoll Wait Guard (Pattern 139)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-epoll-guard.py" "$@"
