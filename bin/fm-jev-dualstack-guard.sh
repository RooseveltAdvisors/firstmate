#!/usr/bin/env bash
# fm-jev-dualstack-guard.sh - Wrapper for Jev Multi-Agent Host Network IPv4/IPv6 Dual-Stack Guard (Pattern 124)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-dualstack-guard.py" "$@"
