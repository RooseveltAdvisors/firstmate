#!/usr/bin/env bash
# bin/fm-jev-packet-ring-guard.sh - Host Network Raw Packet Socket Ring Buffer & Ethertype Filter Guard (Pattern 218)
# Audits Linux kernel raw packet sockets (AF_PACKET), mmap rings, and queued buffer memory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/fm-jev-packet-ring-guard.py" "$@"
