#!/usr/bin/env bash
# fm-jev-tmux-sweeper.sh - Wrapper for Jev Multi-Agent Orphaned Screen & Tmux Dead Session Sweeper (Pattern 44)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-tmux-sweeper.py" "$@"
