#!/usr/bin/env bash
# bin/fm-jev-invalid-ratelimit-guard.sh - Wrapper for Host Network TCP Invalid Segment Rate Limiting Guard (Pattern 173)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-invalid-ratelimit-guard.py" "$@"
