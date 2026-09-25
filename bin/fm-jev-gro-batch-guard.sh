#!/usr/bin/env bash
# bin/fm-jev-gro-batch-guard.sh - Host Network Generic Receive Offload (GRO) Batching, NAPI Weight Biases & Timestamp Policy Guard (Pattern 283 / Pattern 421)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-gro-batch-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-gro-batch-guard.py" "$@"
