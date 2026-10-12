#!/usr/bin/env bash
# bin/fm-jev-keepalive-guard.sh - Wrapper for Host Network TCP Keepalive Probing & Dead Peer Reclamation Guard (Pattern 195)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-keepalive-guard.py" "$@"
