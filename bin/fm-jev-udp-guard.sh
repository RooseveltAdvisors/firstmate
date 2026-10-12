#!/usr/bin/env bash
# bin/fm-jev-udp-guard.sh - Host Network UDP Datagram Buffer & Socket Drop Guard (Pattern 215)
# Audits Linux kernel UDP datagram queues, socket drops, buffer memory, and protocol errors.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/fm-jev-udp-guard.py" "$@"
