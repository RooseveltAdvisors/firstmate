#!/usr/bin/env bash
# bin/fm-jev-nf-conntrack-events-guard.sh - Host Network Netfilter Connection Tracking Event Delivery, Flow Accounting & Helper Expectation Security Policy Guard (Pattern 272 / Pattern 410)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-nf-conntrack-events-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-nf-conntrack-events-guard.py" "$@"
