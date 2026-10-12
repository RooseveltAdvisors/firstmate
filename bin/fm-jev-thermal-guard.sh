#!/usr/bin/env bash
# fm-jev-thermal-guard.sh - Jev Multi-Agent Host Hardware Thermal & CPU Throttling Guard (Pattern 66)
# Wrapper script for bin/fm-jev-thermal-guard.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-thermal-guard.py" "$@"
