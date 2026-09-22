#!/usr/bin/env bash
# bin/fm-jev-dev-mcast-guard.sh - Wrapper for Device Multicast Filter & Promiscuous Guard (Pattern 213)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-dev-mcast-guard.py" "$@"
