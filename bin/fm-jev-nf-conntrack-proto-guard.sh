#!/usr/bin/env bash
# bin/fm-jev-nf-conntrack-proto-guard.sh - Linux Netfilter Conntrack UDP, ICMP & Generic Protocol Timeouts Guard (Pattern 302 / Pattern 440)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-nf-conntrack-proto-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-nf-conntrack-proto-guard.py" "$@"
