#!/usr/bin/env bash
# bin/fm-jev-nf-conntrack-tcp-timeouts-guard.sh - Host Network Netfilter TCP Connection Tracking State Machine Timeouts Guard (Pattern 274 / Pattern 412)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-nf-conntrack-tcp-timeouts-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-nf-conntrack-tcp-timeouts-guard.py" "$@"
