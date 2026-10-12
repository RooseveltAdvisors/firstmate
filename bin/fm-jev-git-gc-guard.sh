#!/usr/bin/env bash
# fm-jev-git-gc-guard.sh - Wrapper for Jev Multi-Agent Git Object Hygiene Guard (Pattern 53)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-git-gc-guard.py" "$@"
