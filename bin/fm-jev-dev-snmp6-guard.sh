#!/usr/bin/env bash
# bin/fm-jev-dev-snmp6-guard.sh - Wrapper for Per-Interface IPv6 SNMP Guard (Pattern 243)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-dev-snmp6-guard.py" "$@"
