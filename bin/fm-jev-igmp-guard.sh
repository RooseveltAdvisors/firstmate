#!/usr/bin/env bash
# bin/fm-jev-igmp-guard.sh - Wrapper for IP Multicast & IGMP Query Guard (Pattern 211)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-igmp-guard.py" "$@"
