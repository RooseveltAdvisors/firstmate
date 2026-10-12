#!/usr/bin/env bash
# bin/fm-jev-psched-guard.sh - Wrapper for Packet Scheduler Clock Guard (Pattern 241)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-psched-guard.py" "$@"
