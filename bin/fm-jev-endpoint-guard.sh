#!/usr/bin/env bash
# fm-jev-endpoint-guard.sh - Wrapper for Jev Multi-Agent Upstream Service Endpoint & Latency Guard (Pattern 49)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-endpoint-guard.py" "$@"
