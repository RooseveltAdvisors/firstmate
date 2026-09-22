#!/usr/bin/env bash
# bin/fm-jev-neigh-stat-guard.sh - Wrapper for Neighbor Table Cache Stats Guard (Pattern 212)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-neigh-stat-guard.py" "$@"
