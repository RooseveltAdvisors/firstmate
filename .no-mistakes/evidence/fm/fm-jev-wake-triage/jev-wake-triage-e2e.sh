#!/usr/bin/env bash
# End-to-end evidence driver for the Jev stale-escalation triage gate.
#
# Drives the REAL bin/fm-watch.sh and the REAL bin/fm-jev-wake-triage.sh.
# Only the typesafe.ai HTTP transport is faked (a fake `curl` on PATH that
# records argv / request body / bearer header and replays a canned System One
# answer). Nothing touches the network.
#
# Scenario 0 is the pre-change baseline: bin/fm-watch.sh pinned at the base
# commit (1bb72cc5), which has no Jev gate at all.
set -u

REPO="/home/jon/.no-mistakes/worktrees/16b9fb59e3d9/01M2VVY4YF7E7FK91NRKXS7KM3"
BASE_COMMIT=1bb72cc5f88014c86e3d03244efa0bb26c22d001

# shellcheck source=/dev/null
. "$REPO/tests/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-evidence)
WATCH="$REPO/bin/fm-watch.sh"
KEY='vault-injected-jev-key'

# --- pre-change watcher (no Jev gate) ---------------------------------------
BASE_BIN="$TMP_ROOT/base-bin"
cp -R "$REPO/bin" "$BASE_BIN"
git -C "$REPO" show "$BASE_COMMIT:bin/fm-watch.sh" > "$BASE_BIN/fm-watch.sh"
chmod +x "$BASE_BIN/fm-watch.sh"
rm -f "$BASE_BIN/fm-jev-wake-triage.sh"
BASE_WATCH="$BASE_BIN/fm-watch.sh"

file_mtime() { stat -c %Y "$1" 2>/dev/null; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

wait_poll_cycle() {  # <state> <pid> - true when a full poll passed with no wake
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat"); [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# A ship parked mid-pipeline: last status line is a pre-validation leftover,
# pane hash unchanged for 500s, FM_STALE_ESCALATE_SECS=240 -> at threshold.
prime_ship() {  # <name> <status-line> -> prints dir
  local name=$1 status_line=$2 dir state fakebin window key pane_hash
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  window="test:$name"
  mkdir -p "$dir/config" "$dir/curl-log"
  printf 'idle building output' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf '%s\n' "$status_line" > "$state/wedged.status"
  prime_status_seen "$state" "$state/wedged.status" >/dev/null || return 1
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "$FAKE_CURL_LOG/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
cp "$FAKE_CURL_RESPONSE" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$dir"
}

jev_answer() {  # <dir> <choice> <noul>
  local dir=$1 choice=$2 noul=$3 pw=0.01 tw=0.01 hi=0.01
  case "$choice" in pipeline_wait) pw=0.98 ;; true_wedge) tw=0.98 ;; healthy_idle) hi=0.98 ;; esac
  cat > "$dir/response.json" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "class": { "type": "choice", "choice": "$choice", "confidence": 0.94,
      "probabilities": { "pipeline_wait": $pw, "true_wedge": $tw, "healthy_idle": $hi } },
    "wedge_probability": { "type": "noul", "noul": $noul }
  },
  "usage": { "input_tokens": 214, "output_tokens": 12 } }
JSON
}

# Launch the watcher for one case. Prints nothing; sets WATCH_PID.
launch() {  # <dir> <watch-binary> [extra env assignments...]
  local dir=$1 bin=$2; shift 2
  env PATH="$dir/fakebin:$PATH" \
    FM_FAKE_TMUX_WINDOW="test:$(basename "$dir")" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FAKE_CURL_LOG="$dir/curl-log" FAKE_CURL_RESPONSE="$dir/response.json" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$bin" > "$dir/watch.out" 2> "$dir/watch.err" &
  WATCH_PID=$!
}

rule() { printf '\n══════════════════════════════════════════════════════════════════════\n%s\n══════════════════════════════════════════════════════════════════════\n' "$1"; }

printf 'Jev stale-escalation triage — end-to-end operator transcript\n'
printf 'repo:   %s\n' "$REPO"
printf 'commit: %s (base %s)\n' "$(git -C "$REPO" rev-parse --short HEAD)" "${BASE_COMMIT:0:8}"
printf 'fixture: one ship, pane unchanged 500s, FM_STALE_ESCALATE_SECS=240, crew state "working (run-step validating)"\n'
printf 'network: none — fake curl replays a canned typesafe.ai System One answer\n'

# --- 0. BEFORE: watcher pinned at the base commit ---------------------------
rule '0. BEFORE this change (bin/fm-watch.sh @ 1bb72cc5) — the ship gets paged'
dir=$(prime_ship jev-before 'working: still monitoring ci')
launch "$dir" "$BASE_WATCH"
wait_for_exit "$WATCH_PID" 150 >/dev/null 2>&1
printf '$ fm-watch.sh   # what the captain receives on stdout\n'
sed 's/^/  /' "$dir/watch.out"
printf '\nstate/.watch-deliveries.log (durable wake delivered to the captain):\n'
sed 's/^/  /' "$dir/state/.watch-deliveries.log" 2>/dev/null
printf '\nescalation counter: %s\n' "$(cat "$dir"/state/.wedge-escalations-* 2>/dev/null || echo '(none)')"

# --- 1. AFTER: Jev says pipeline_wait ---------------------------------------
rule '1. AFTER — Jev classifies pipeline_wait: no page at all'
dir=$(prime_ship jev-pipeline-wait 'working: still monitoring ci')
jev_answer "$dir" pipeline_wait 0.07
before_since=$(cat "$dir"/state/.stale-since-* )
launch "$dir" "$WATCH" TYPESAFE_API_KEY="$KEY"
if wait_poll_cycle "$dir/state" "$WATCH_PID"; then
  printf '$ fm-watch.sh   # a full poll cycle completed with no wake printed\n'
  printf '  (no output — the captain is not paged)\n'
else
  printf '  UNEXPECTED: watcher woke: %s\n' "$(cat "$dir/watch.out")"
fi
reap "$WATCH_PID"
printf '\nwatcher stdout bytes: %s   |   deliveries log: %s\n' \
  "$(wc -c < "$dir/watch.out" | tr -d ' ')" \
  "$( [ -s "$dir/state/.watch-deliveries.log" ] && echo 'rows present' || echo 'empty — nothing delivered' )"
printf 'escalation counter: %s\n' "$(cat "$dir"/state/.wedge-escalations-* 2>/dev/null || echo '(never created — counter untouched)')"
printf 'idle timer restarted: %s -> %s (+%ss)\n' "$before_since" "$(cat "$dir"/state/.stale-since-*)" \
  "$(( $(cat "$dir"/state/.stale-since-*) - before_since ))"
printf '\nstate/.watch-triage.log (what the operator reads instead of a page):\n'
sed 's/^/  /' "$dir/state/.watch-triage.log" 2>/dev/null
printf '\nstate/.jev-triage-telemetry:\n'
sed 's/^/  /' "$dir/state/.jev-triage-telemetry" 2>/dev/null
printf '\nstate/.jev-triage-calibration.jsonl (captain audits precision here):\n'
jq . "$dir/state/.jev-triage-calibration.jsonl" 2>/dev/null | sed 's/^/  /'
printf '\nThe real request the helper POSTed to typesafe.ai:\n'
printf '  endpoint: %s\n' "$(grep -F 'api.typesafe.ai' "$dir/curl-log/argv")"
printf '  auth header: %s\n' "$(sed 's/Bearer .*/Bearer ****REDACTED****/' "$dir/curl-log/header")"
printf '  key on argv: %s\n' "$(grep -cF "$KEY" "$dir/curl-log/argv" | sed 's/^0$/no (0 occurrences)/')"
jq '{model, state, questions: (.questions | map_values({type, instructions: (.instructions[0:90] + "…"), criteria: (.criteria // null)}))}' \
  "$dir/curl-log/body" 2>/dev/null | sed 's/^/  /'

# --- 2. AFTER: Jev says true_wedge ------------------------------------------
rule '2. AFTER — Jev classifies true_wedge: the page still fires'
dir=$(prime_ship jev-true-wedge 'working: still monitoring ci')
jev_answer "$dir" true_wedge 0.93
launch "$dir" "$WATCH" TYPESAFE_API_KEY="$KEY"
wait_for_exit "$WATCH_PID" 150 >/dev/null 2>&1
printf '$ fm-watch.sh\n'
sed 's/^/  /' "$dir/watch.out"
printf '\nescalation counter: %s\n' "$(cat "$dir"/state/.wedge-escalations-* 2>/dev/null || echo '(none)')"
printf 'telemetry: %s\n' "$(tr '\t' ' ' < "$dir/state/.jev-triage-telemetry" 2>/dev/null)"

# --- 3. AFTER: typesafe.ai is down ------------------------------------------
rule '3. AFTER — typesafe.ai returns HTTP 500: fail-open, the page still fires'
dir=$(prime_ship jev-api-down 'working: still monitoring ci')
jev_answer "$dir" pipeline_wait 0.05     # a suppress answer the helper must NOT trust
launch "$dir" "$WATCH" TYPESAFE_API_KEY="$KEY" FAKE_CURL_HTTP=500
wait_for_exit "$WATCH_PID" 150 >/dev/null 2>&1
printf '$ fm-watch.sh\n'
sed 's/^/  /' "$dir/watch.out"
printf '\nescalation counter: %s\n' "$(cat "$dir"/state/.wedge-escalations-* 2>/dev/null || echo '(none)')"
printf 'telemetry: %s\n' "$(tr '\t' ' ' < "$dir/state/.jev-triage-telemetry" 2>/dev/null)"

# --- 4. AFTER: no key in the environment ------------------------------------
rule '4. AFTER — no TYPESAFE_API_KEY in the watcher environment: fail-open'
dir=$(prime_ship jev-no-key 'working: still monitoring ci')
jev_answer "$dir" pipeline_wait 0.05
launch "$dir" "$WATCH"
wait_for_exit "$WATCH_PID" 150 >/dev/null 2>&1
printf '$ fm-watch.sh\n'
sed 's/^/  /' "$dir/watch.out"
printf '\ncurl invoked: %s\n' "$( [ -e "$dir/curl-log/argv" ] && echo yes || echo 'no — not one network call attempted' )"
printf 'telemetry: %s\n' "$(tr '\t' ' ' < "$dir/state/.jev-triage-telemetry" 2>/dev/null)"

# --- 5. The reported incident: 9 ships parked on CI -------------------------
rule "5. The reported incident — 9 ships parked waiting on CI, one night"
STATUSES=(
  'working: still monitoring ci'
  'working: waiting on no-mistakes validation round'
  'working: ci run queued, watching checks'
  'working: pushed, waiting for required checks'
  'working: validation phase running'
  'working: waiting on the gate to finish tests'
  'working: still monitoring ci'
  'working: lint + test phases in flight'
  'working: waiting for the PR checks to go green'
)
before_pages=0; after_pages=0; suppressed=0
printf 'BEFORE (watcher @ %s):\n' "${BASE_COMMIT:0:8}"
for i in "${!STATUSES[@]}"; do
  dir=$(prime_ship "night-before-$i" "${STATUSES[$i]}")
  launch "$dir" "$BASE_WATCH"
  wait_for_exit "$WATCH_PID" 150 >/dev/null 2>&1
  if [ -s "$dir/watch.out" ]; then
    before_pages=$((before_pages + 1))
    printf '  PAGE  ship-%s  %s\n' "$i" "$(head -n 1 "$dir/watch.out")"
  else
    printf '  quiet ship-%s\n' "$i"
  fi
done
printf '\nAFTER (this change, Jev answering pipeline_wait):\n'
for i in "${!STATUSES[@]}"; do
  dir=$(prime_ship "night-after-$i" "${STATUSES[$i]}")
  jev_answer "$dir" pipeline_wait 0.08
  launch "$dir" "$WATCH" TYPESAFE_API_KEY="$KEY"
  if wait_poll_cycle "$dir/state" "$WATCH_PID"; then
    printf '  quiet ship-%s  %s\n' "$i" "$(sed -n '1s/^\[[^]]*\] //p' "$dir/state/.watch-triage.log")"
    grep -q 'jev_triage.suppressed' "$dir/state/.jev-triage-telemetry" 2>/dev/null && suppressed=$((suppressed + 1))
  else
    after_pages=$((after_pages + 1))
    printf '  PAGE  ship-%s  %s\n' "$i" "$(head -n 1 "$dir/watch.out")"
  fi
  reap "$WATCH_PID"
done
printf '\n  pages before: %s of %s      pages after: %s of %s      jev_triage.suppressed: %s\n' \
  "$before_pages" "${#STATUSES[@]}" "$after_pages" "${#STATUSES[@]}" "$suppressed"

rule 'done'
