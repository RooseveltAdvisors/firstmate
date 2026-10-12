#!/usr/bin/env bash
# bin/fm-jev-tcp-ssthresh-metrics-guard.sh - Linux TCP Slow-Start Threshold Metrics Save & HyStart Policy Guard (Pattern 299 / Pattern 437)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-tcp-ssthresh-metrics-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-tcp-ssthresh-metrics-guard.py" "$@"
