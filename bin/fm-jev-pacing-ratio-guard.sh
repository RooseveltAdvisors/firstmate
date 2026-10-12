#!/usr/bin/env bash
# bin/fm-jev-pacing-ratio-guard.sh - Wrapper for Host Network TCP Packet Pacing Ratios Guard (Pattern 186)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-pacing-ratio-guard.py" "$@"
