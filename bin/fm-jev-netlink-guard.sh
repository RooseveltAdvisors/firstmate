#!/usr/bin/env bash
# bin/fm-jev-netlink-guard.sh - Host Network Netlink Socket Buffer & Routing Netlink Drop Guard (Pattern 214)
# Audits Linux kernel netlink socket queues, protocol allocation, and dropped messages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/fm-jev-netlink-guard.py" "$@"
