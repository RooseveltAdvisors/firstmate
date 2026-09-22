#!/usr/bin/env bash
# bin/fm-jev-arp-guard.sh - Wrapper for IP Neighbor & ARP Table Saturation Guard (Pattern 204)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-arp-guard.py" "$@"
