#!/usr/bin/env bash
# fm-observation-spool-shipper.sh - forward local observation records to OTLP gateway.
#
# SI Control Phase 3: Section 2.4 Data flow.
#
# Reads the local append-only spool ($FM_HOME/state/observation/spool.jsonl),
# rotates bounded files, and ships to the OTLP gateway.
#
# Failure rule (Section 2.6):
# Failed observation shipping never blocks model calls and never degrades into
# writing content to general logs.
#
# Adopts bin/fm-gate-refuse-lib.sh: refuses fleet mutation from inside a
# no-mistakes gate context unless running in a marked disposable lab home.
#
# Usage:
#   fm-observation-spool-shipper.sh [ship|rotate|status]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# Refuse gate agent lifecycle against real fleet
fm_refuse_if_gate_agent

cmd=${1:-ship}
home=${FM_HOME:-.}
spool_dir="$home/state/observation"
spool_file="$spool_dir/spool.jsonl"
shipped_dir="$spool_dir/shipped"
otlp_endpoint="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://127.0.0.1:4318/v1/logs}"
max_spool_bytes=$((10 * 1024 * 1024)) # 10 MB rotation threshold

case "$cmd" in
  status)
    if [ ! -f "$spool_file" ]; then
      echo "spool: empty (no spool file)"
      exit 0
    fi
    count=$(wc -l < "$spool_file" 2>/dev/null || echo 0)
    bytes=$(wc -c < "$spool_file" 2>/dev/null || echo 0)
    echo "spool: $count records, $bytes bytes ($spool_file)"
    exit 0
    ;;
  rotate)
    if [ ! -f "$spool_file" ]; then
      exit 0
    fi
    bytes=$(wc -c < "$spool_file" 2>/dev/null || echo 0)
    if [ "$bytes" -ge "$max_spool_bytes" ]; then
      mkdir -p "$shipped_dir" 2>/dev/null || true
      rot_file="$shipped_dir/spool.$(date +%s).jsonl"
      mv -f "$spool_file" "$rot_file"
      touch "$spool_file"
      echo "ok: rotated spool to $rot_file"
    fi
    exit 0
    ;;
  ship)
    if [ ! -f "$spool_file" ] || [ ! -s "$spool_file" ]; then
      exit 0
    fi
    mkdir -p "$shipped_dir" 2>/dev/null || true
    # Atomically move active spool to a shipping batch
    batch_file="$shipped_dir/batch.$$.jsonl"
    mv -f "$spool_file" "$batch_file" 2>/dev/null || exit 0
    touch "$spool_file"

    count=$(wc -l < "$batch_file" 2>/dev/null || echo 0)
    # Ship to OTLP gateway if curl is available and endpoint responds
    if command -v curl >/dev/null 2>&1; then
      # Post batch as newline-delimited logs or structured payload
      if curl -s -f -X POST -H "Content-Type: application/json" --data-binary @"$batch_file" --connect-timeout 2 --max-time 5 "$otlp_endpoint" >/dev/null 2>&1; then
        echo "ok: shipped $count observation records to OTLP gateway ($otlp_endpoint)"
        rm -f "$batch_file"
        exit 0
      fi
    fi
    # If OTLP gateway is unreachable or offline, keep in shipped_dir for retry
    echo "notice: OTLP gateway unreachable; retained $count records in $batch_file for retry"
    exit 0
    ;;
  *)
    echo "usage: fm-observation-spool-shipper.sh [ship|rotate|status]" >&2
    exit 2
    ;;
esac
