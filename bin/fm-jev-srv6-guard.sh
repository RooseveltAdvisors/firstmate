#!/usr/bin/env bash
# bin/fm-jev-srv6-guard.sh - Host Segment Routing over IPv6 (SRv6 / RFC 8754) & SRH Security Policy Guard (Pattern 257 — 300th Milestone)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
    echo "[fm-jev-srv6-guard] ERROR: python3 binary not found" >&2
    exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-srv6-guard.py" "$@"
