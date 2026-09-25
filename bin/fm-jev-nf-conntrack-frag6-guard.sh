#!/usr/bin/env bash
# bin/fm-jev-nf-conntrack-frag6-guard.sh - Host Network Netfilter IPv6 Fragment Reassembly Queue & Memory Policy Guard (Pattern 273 / Pattern 411)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-nf-conntrack-frag6-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-nf-conntrack-frag6-guard.py" "$@"
