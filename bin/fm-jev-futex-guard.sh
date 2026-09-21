#!/usr/bin/env bash
# fm-jev-futex-guard.sh - Jev Multi-Agent Futex Contention & Thread Stargate Guard (Pattern 63)
# Wrapper script for bin/fm-jev-futex-guard.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-futex-guard.py" "$@"
