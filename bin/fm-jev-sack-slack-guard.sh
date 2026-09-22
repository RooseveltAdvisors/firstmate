#!/usr/bin/env bash
# bin/fm-jev-sack-slack-guard.sh - Wrapper for Host Network TCP SACK Compression Slack Guard (Pattern 184)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-sack-slack-guard.py" "$@"
