#!/usr/bin/env bash
# bin/fm-jev-mptcp-guard.sh - Wrapper for Host Network MPTCP Subflow Health Guard (Pattern 172)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-mptcp-guard.py" "$@"
