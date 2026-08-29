#!/usr/bin/env bash
# fm-evolve-loop.sh - run the graph-of-loops pass and project unhealthy loops into Beads.
#
# The evolve pass is the graph evaluator and owns its report schema.
# This wrapper consumes a JSON report whose top-level `loops` array contains
# loop records with `id` or `name`, `status`, and an optional finding or summary.
# Statuses `stalled` and `drifting` create or update one `watch-loop` bead.
# Status `converging` is healthy and creates no bead.
# Each unhealthy bead depends on one open `watch-loop` review sentinel so the
# standard `bd blocked --json` view surfaces the finding to firstmate status.
#
# Usage:
#   fm-evolve-loop.sh                 run bin/fm-evolve-pass.sh once
#   fm-evolve-loop.sh --pass PATH     use a pass executable at PATH
#   fm-evolve-loop.sh --report PATH   retain the pass report at PATH
#   fm-evolve-loop.sh --help          print this usage
#
# The wrapper is intentionally one-shot.
# Schedule it from cron or another process-event source, for example:
#   0 */4 * * * /path/to/firstmate/bin/fm-evolve-loop.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PASS="$FM_ROOT/bin/fm-evolve-pass.sh"
REPORT_DEST="$STATE/.fm-evolve-loop-report.json"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pass)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PASS=$2
      shift 2
      ;;
    --pass=*) PASS=${1#*=}; shift ;;
    --report)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REPORT_DEST=$2
      shift 2
      ;;
    --report=*) REPORT_DEST=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "fm-evolve-loop: jq not found" >&2; exit 1; }
command -v bd >/dev/null 2>&1 || { echo "fm-evolve-loop: bd not found" >&2; exit 1; }
[ -x "$PASS" ] || { echo "fm-evolve-loop: evolve pass is not executable: $PASS" >&2; exit 1; }
mkdir -p "$STATE" || { echo "fm-evolve-loop: could not create state directory: $STATE" >&2; exit 1; }

TMP_REPORT=$(mktemp "$STATE/.fm-evolve-loop-report.XXXXXX") || {
  echo "fm-evolve-loop: could not create a report file in $STATE" >&2
  exit 1
}
cleanup() {
  rm -f -- "$TMP_REPORT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! "$PASS" > "$TMP_REPORT"; then
  echo "fm-evolve-loop: evolve pass failed; report was not projected into Beads" >&2
  exit 1
fi
if ! jq -e '(. | type) == "object" and (.loops | type) == "array"' "$TMP_REPORT" >/dev/null 2>&1; then
  echo "fm-evolve-loop: evolve pass report must be a JSON object with a loops array" >&2
  exit 1
fi
if ! cp "$TMP_REPORT" "$REPORT_DEST"; then
  echo "fm-evolve-loop: could not retain the evolve report at $REPORT_DEST" >&2
  exit 1
fi

bd_run() {
  (
    cd "$FM_ROOT" || exit 1
    bd "$@"
  )
}

unhealthy_count=$(jq '[.loops[] | select((.status // "" | ascii_downcase) == "stalled" or (.status // "" | ascii_downcase) == "drifting")] | length' "$TMP_REPORT")
if [ "$unhealthy_count" -eq 0 ]; then
  printf 'fm-evolve-loop: no stalled or drifting loops; healthy loops required no action\n'
  exit 0
fi

watch_loops=$(bd_run list --label watch-loop --all --limit 0 --json 2>/dev/null) || {
  echo "fm-evolve-loop: could not list existing watch-loop beads" >&2
  exit 1
}

sentinel=$(printf '%s\n' "$watch_loops" | jq -r '
  .[] | select((.metadata.watch_loop_role // "") == "review-sentinel") | .id
' | head -n 1)
if [ -z "$sentinel" ]; then
  sentinel=$(bd_run create --silent \
    --title "Loop health findings require review" \
    --description "Open review sentinel for stalled or drifting graph-of-loops findings." \
    --labels watch-loop \
    --metadata '{"watch_loop_role":"review-sentinel"}') || {
    echo "fm-evolve-loop: could not create the watch-loop review sentinel" >&2
    exit 1
  }
  watch_loops=$(bd_run list --label watch-loop --all --limit 0 --json 2>/dev/null) || {
    echo "fm-evolve-loop: could not refresh existing watch-loop beads" >&2
    exit 1
  }
fi

projected=0
while IFS= read -r loop; do
  [ -n "$loop" ] || continue
  status=$(printf '%s\n' "$loop" | jq -r '.status // ""' | tr '[:upper:]' '[:lower:]')
  case "$status" in
    stalled|drifting) ;;
    converging) continue ;;
    *) continue ;;
  esac

  loop_id=$(printf '%s\n' "$loop" | jq -r '.id // ""')
  loop_name=$(printf '%s\n' "$loop" | jq -r '.name // ""')
  loop_key=$(printf '%s\n' "$loop" | jq -r '.key // ""')
  canonical_id="${loop_id:-${loop_name:-${loop_key}}}"
  [ -n "$canonical_id" ] || {
    echo "fm-evolve-loop: unhealthy loop has no id, loop_id, key, or name" >&2
    exit 1
  }
  name=$(printf '%s\n' "$loop" | jq -r '.name // .title // .id // .loop_id // .key')
  finding=$(printf '%s\n' "$loop" | jq -c 'if .finding != null then .finding elif .summary != null then .summary elif .reason != null then .reason elif .details != null then .details else . end')
  title="Loop health: $name ($status)"
  description=$(printf 'Graph-of-loops pass found a %s loop.\n\nLoop: %s\nFinding: %s\n' "$status" "$canonical_id" "$finding")
  metadata=$(jq -cn --arg loop_id "$loop_id" --arg loop_name "$loop_name" --arg loop_key "$loop_key" --arg loop_status "$status" \
    --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{loop_id:$loop_id,loop_name:$loop_name,loop_key:$loop_key,loop_status:$loop_status,watch_loop_role:"finding",observed_at:$observed_at}')
  bead_id=$(printf '%s\n' "$watch_loops" | jq -r --arg id "$loop_id" --arg name "$loop_name" --arg key "$loop_key" '
    .[] | select(
      ((.metadata.loop_id // "") != "" and (.metadata.loop_id // "") == $id) or
      ((.metadata.loop_name // "") != "" and (.metadata.loop_name // "") == $name) or
      ((.metadata.loop_key // "") != "" and (.metadata.loop_key // "") == $key)
    ) | .id
  ' | head -n 1)

  if [ -z "$bead_id" ]; then
    bead_id=$(bd_run create --silent --title "$title" --description "$description" \
      --labels watch-loop --metadata "$metadata") || {
      echo "fm-evolve-loop: could not create a bead for loop $loop_id" >&2
      exit 1
    }
  else
    existing_status=$(printf '%s\n' "$watch_loops" | jq -r --arg bead_id "$bead_id" \
      '.[] | select(.id == $bead_id) | .status // ""')
    if [ "$existing_status" = closed ]; then
      bd_run reopen "$bead_id" >/dev/null || {
        echo "fm-evolve-loop: could not reopen bead $bead_id for loop $loop_id" >&2
        exit 1
      }
    fi
    bd_run update "$bead_id" --title "$title" --description "$description" \
      --add-label watch-loop --set-metadata "loop_id=$loop_id" \
      --set-metadata "loop_name=$loop_name" \
      --set-metadata "loop_key=$loop_key" \
      --set-metadata "loop_status=$status" \
      --set-metadata "watch_loop_role=finding" \
      --set-metadata "observed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null || {
      echo "fm-evolve-loop: could not update bead $bead_id for loop $canonical_id" >&2
      exit 1
    }
  fi

  dependencies=$(bd_run dep list "$bead_id" --json 2>/dev/null) || {
    echo "fm-evolve-loop: could not inspect dependencies for bead $bead_id" >&2
    exit 1
  }
  if ! printf '%s\n' "$dependencies" | jq -e --arg sentinel "$sentinel" \
    '[.[] | select(.id == $sentinel and .dependency_type == "blocks")] | length > 0' >/dev/null; then
    bd_run dep "$sentinel" --blocks "$bead_id" >/dev/null || {
      echo "fm-evolve-loop: could not block bead $bead_id behind the review sentinel" >&2
      exit 1
    }
  fi
  projected=$((projected + 1))
  watch_loops=$(bd_run list --label watch-loop --all --limit 0 --json 2>/dev/null) || {
    echo "fm-evolve-loop: could not refresh watch-loop beads after loop $loop_id" >&2
    exit 1
  }
  printf 'watch-loop: %s -> %s (%s)\n' "$loop_id" "$bead_id" "$status"
done < <(jq -c '.loops[]' "$TMP_REPORT")

printf 'fm-evolve-loop: projected %s unhealthy loop(s); healthy loops required no action\n' "$projected"
