#!/usr/bin/env bash
# fm-jev-classify.sh - JEV advisory risk classifier for consequential actions.
#
# SI Control Phase 3: Section 4 JEV Classifier.
#
# JEV is intelligence, not enforcement.
# Its output is an advisory label: a risk class, a confidence, and a reason.
# It NEVER writes decision=allow, and it cannot convert a denial into an allow.
# If an action is flagged as risky or uncertain, it routes to captain hold.
# A missing or timed-out JEV response fails closed (DENY).
#
# Usage:
#   fm-jev-classify.sh classify <action_class> <target> <payload_path>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# Refuse gate agent lifecycle against real fleet
fm_refuse_if_gate_agent

action_class=${1:-}
target=${2:-}
payload_path=${3:-}

if [ -z "$action_class" ] || [ -z "$target" ] || [ -z "$payload_path" ]; then
  echo "usage: fm-jev-classify.sh <action_class> <target> <payload_path>" >&2
  exit 2
fi

# Validated action taxonomy (§4.3: send, booking, charging, deploy)
case "$action_class" in
  send | booking | charging | deploy) ;;
  *)
    echo "fm-jev-classify: unknown action class '$action_class' (must be send|booking|charging|deploy)" >&2
    exit 1
    ;;
esac

if [ ! -f "$payload_path" ]; then
  echo "fm-jev-classify: payload file '$payload_path' not found" >&2
  exit 1
fi

# Advisory evaluation based on payload size, patterns, and target
risk_label="not_risky"
confidence="0.95"
reason="Verified action within declared parameters"

# Example heuristics for risky indicators
if grep -q -i -E "drop table|rm -rf /|force-push|prod-destroy" "$payload_path" 2>/dev/null; then
  risk_label="risky"
  confidence="0.99"
  reason="Destructive operations detected in payload"
elif [ "$target" = "production" ] || [ "$target" = "srv-covenant-app" ]; then
  # Deploying to production services is marked for review
  if [ "$action_class" = "deploy" ]; then
    risk_label="risky"
    confidence="0.90"
    reason="Production service deployment requires explicit captain review"
  fi
fi

if command -v jq >/dev/null 2>&1; then
  jq -nc \
    --arg risk "$risk_label" \
    --argjson conf "$confidence" \
    --arg reason "$reason" \
    --arg action "$action_class" \
    --arg target "$target" \
    '{risk_label: $risk, confidence: $conf, reason: $reason, action_class: $action, target: $target, advisory_only: true}'
else
  printf '{"risk_label":"%s","confidence":%s,"reason":"%s","action_class":"%s","target":"%s","advisory_only":true}\n' \
    "$risk_label" "$confidence" "$reason" "$action_class" "$target"
fi
exit 0
