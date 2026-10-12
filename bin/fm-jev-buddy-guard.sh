#!/usr/bin/env bash
# fm-jev-buddy-guard.sh - Jev Multi-Agent Kernel Buddy Allocator & Fragmentation Guard (Pattern 67)
# Wrapper script for bin/fm-jev-buddy-guard.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-buddy-guard.py" "$@"
