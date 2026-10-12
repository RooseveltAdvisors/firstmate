#!/usr/bin/env bash
# fm-jev-coredump-guard.sh - Wrapper for Jev Multi-Agent Core Dump & Crash Artifact Guard (Pattern 54)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-coredump-guard.py" "$@"
