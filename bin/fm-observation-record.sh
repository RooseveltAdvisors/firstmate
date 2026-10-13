#!/usr/bin/env bash
# fm-observation-record.sh - observation metadata record builder and spooler.
#
# SI Control Phase 3: Section 2.3 Record schema (PHI-free by construction).
#
# Builds one record per model call containing only:
#   - Identity: task_id, trace_id, span_id, bead_id, runtime_identity, parent_task_id
#   - Call: provider, model, start_time, end_time, duration_ms, status, error_class
#   - Usage: input_tokens, output_tokens, reasoning_tokens, cache_tokens
#   - Policy: decision_id, decision, policy_version, jev_risk_flags
#   - Retention: retention_policy_class
#
# Strictly forbidden in this record:
#   prompt text, completion text, tool arguments, file contents, credentials,
#   patient IDs, MRNs, SSNs, and recipient emails.
#
# Usage:
#   fm-observation-record.sh write <provider> <model> <duration_ms> <input_tokens> <output_tokens> [status] [error_class]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# Refuse gate agent lifecycle against real fleet
fm_refuse_if_gate_agent

cmd=${1:-write}
provider=${2:-unknown}
model=${3:-unknown}
duration_ms=${4:-0}
input_tokens=${5:-0}
output_tokens=${6:-0}
status=${7:-ok}
error_class=${8:-}

if [ "$cmd" != "write" ]; then
  echo "usage: fm-observation-record.sh write <provider> <model> <duration_ms> <input_tokens> <output_tokens> [status] [error_class]" >&2
  exit 2
fi

for n in "$duration_ms" "$input_tokens" "$output_tokens"; do
  case "$n" in
    '' | *[!0-9]*)
      echo "fm-observation-record: duration_ms, input_tokens, and output_tokens must be non-negative integers (got '$n')" >&2
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "fm-observation-record: jq is required to build the record" >&2
  exit 1
fi

home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
spool_dir="$home/state/observation"
mkdir -p "$spool_dir" 2>/dev/null || true
spool_file="$spool_dir/spool.jsonl"

now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
task_id=${FM_TASK_ID:-task-ambient}

# Trace identity resolution from TRACEPARENT (W3C: 00-<32hex>-<16hex>-<2hex>)
trace_id=""
span_id=""
if [ -n "${TRACEPARENT:-}" ]; then
  raw_tp="$TRACEPARENT"
  trace_id=$(printf '%s' "$raw_tp" | awk -F'-' '{print $2}')
  span_id=$(printf '%s' "$raw_tp" | awk -F'-' '{print $3}')
fi
[ -n "$trace_id" ] || trace_id="00000000000000000000000000000000"
[ -n "$span_id" ] || span_id="0000000000000000"

if ! record=$(jq -nc \
    --arg task "$task_id" \
    --arg trace "$trace_id" \
    --arg span "$span_id" \
    --arg provider "$provider" \
    --arg model "$model" \
    --arg start "$now_iso" \
    --arg end "$now_iso" \
    --argjson dur "$duration_ms" \
    --argjson in_tok "$input_tokens" \
    --argjson out_tok "$output_tokens" \
    --arg status "$status" \
    --arg err "${error_class:-null}" \
    '{
      identity: {
        task_id: $task,
        trace_id: $trace,
        span_id: $span,
        bead_id: null,
        runtime_identity: {
          harness: "pi",
          adapter: "pi"
        },
        parent_task_id: null
      },
      call: {
        provider: $provider,
        model: $model,
        start_time: $start,
        end_time: $end,
        duration_ms: $dur,
        status: $status,
        error_class: (if $err == "null" then null else $err end)
      },
      usage: {
        input_tokens: $in_tok,
        output_tokens: $out_tok,
        reasoning_tokens: 0,
        cache_tokens: 0
      },
      policy: {
        decision_id: null,
        decision: null,
        policy_version: "2026-10-12",
        jev_risk_flags: []
      },
      retention: {
        retention_policy_class: "metadata_general_90d"
      }
    }'); then
  echo "fm-observation-record: failed to build record" >&2
  exit 1
fi

# Append to local append-only spool
printf '%s\n' "$record" >> "$spool_file" || {
  echo "fm-observation-record: failed to append to $spool_file" >&2
  exit 1
}
echo "ok: recorded observation metadata to $spool_file"
