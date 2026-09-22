#!/usr/bin/env bash
# bin/fm-jev-plpmtud-guard.sh - Wrapper for Host Network TCP MTU Probing (PLPMTUD) & Blackhole Guard (Pattern 198)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-plpmtud-guard.py" "$@"
