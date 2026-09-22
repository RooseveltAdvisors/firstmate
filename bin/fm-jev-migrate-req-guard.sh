#!/usr/bin/env bash
# bin/fm-jev-migrate-req-guard.sh - Wrapper for Host Network TCP Listener Connection Migration Guard (Pattern 178)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-migrate-req-guard.py" "$@"
