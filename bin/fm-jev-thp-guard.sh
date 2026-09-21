#!/usr/bin/env bash
# fm-jev-thp-guard.sh - Jev Multi-Agent Transparent Huge Pages (THP) & Compaction Stall Guard (Pattern 64)
# Wrapper script for bin/fm-jev-thp-guard.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-thp-guard.py" "$@"
