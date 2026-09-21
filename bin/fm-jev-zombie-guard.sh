#!/usr/bin/env bash
# fm-jev-zombie-guard.sh - Wrapper for Jev Multi-Agent Subprocess Zombie & Defunct PPID Leak Guard (Pattern 45)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-zombie-guard.py" "$@"
