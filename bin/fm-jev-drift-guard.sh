#!/usr/bin/env bash
# fm-jev-drift-guard.sh - Wrapper for Jev Multi-Agent Worktree Detached HEAD & Git Ref Drift Guard (Pattern 50)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-drift-guard.py" "$@"
