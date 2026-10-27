#!/usr/bin/env bash
# Live product drive: fm-contributions.sh settlement/ledger convergence scenarios.
# Drives the REAL bin/fm-contributions.sh CLI against disposable FM_HOME
# fixtures in /tmp, with a stub `gh` standing in for the external GitHub forge
# service only. Transcripts land in the run's evidence directory.
set -u
WT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M5Y1A4N1TAT4AA89M1E05CEH
EV=/home/jon/.no-mistakes/evidence/01M5Y1A4N1TAT4AA89M1E05CEH
RUN=$(mktemp -d /tmp/fm-live.XXXXXX)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$EV"
T='' # current transcript
STATUS=0

say() { printf '%s\n' "$*" | tee -a "$T"; }
check() { # check <label> <command...>
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then say "PASS: $label"; else say "FAIL: $label"; STATUS=1; fi
}
capture() { # capture VAR cmd... : run, tee output into transcript, keep exit code
  local __var=$1; shift
  local __out __rc
  __out=$("$@" 2>&1); __rc=$?
  printf '$ %s\n%s\n[exit %s]\n' "$*" "$__out" "$__rc" >> "$T"
  printf -v "$__var" '%s' "$__out"
  return $__rc
}

# ---- disposable fixture home ----------------------------------------------

gh_stub() { # path : stub external GitHub forge (gh CLI) logging every call
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FORGE/calls"
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api repos/o/r/pulls/'*)
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:false,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end)}' ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    if [ -e "$FORGE/no-checks" ]; then
      printf '[{"check_runs":[]}]\n'
    else
      printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]\n'
    fi ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh stub call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$1"
}

new_home() { # name : echoes home path
  local home="$RUN/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" \
    "$home/fakebin" "$home/wt" "$home/forge" "$home/root/bin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf -- '- [ ] delivery - Delivery PR https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' \
    >> "$home/data/backlog.md"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  gh_stub "$home/fakebin/gh"
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  printf '[]\n' > "$home/forge/comments.json"
  printf '[]\n' > "$home/forge/reviews.json"
  printf '[]\n' > "$home/forge/inline.json"
  printf '%s\n' "$home"
}

fm() { # home cmd... : run a real product command against the disposable home
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW=$NOW "$@"
}

valid_ledger() { # record-file : product's own fm-contributions.jq valid_record
  jq -L "$WT/bin" -ne --slurpfile record "$1" 'include "fm-contributions"; $record[0] | valid_record' >/dev/null 2>&1
}

CONTRIB=("$WT/bin/fm-contributions.sh")

# ---- S1: no-CI merged settlement writes a machine-readable v1 record ------
s1() {
  local home out
  T="$EV/01-scenario1-no-ci-settlement-record.log"; : > "$T"
  home=$(new_home s1-no-ci-settle)
  : > "$home/forge/no-checks"; printf 'merged\n' > "$home/forge/state"
  say "== Scenario 1: a no-CI merged pull request settles into a v1 ledger record =="
  say "fixture: task delivery owns https://github.com/o/r/pull/8; forge reports merged with zero check runs"
  capture out fm "$home" "${CONTRIB[@]}" poll; rc=$?
  check 'settlement poll exits 0' [ "$rc" -eq 0 ]
  check 'settlement poll is silent (no unreadable record reported)' [ -z "$out" ]
  say "persisted ledger: $(cat "$home/data/delivery/contributions.json")"
  check 'stored record passes the product validator fm-contributions.jq valid_record' \
    valid_ledger "$home/data/delivery/contributions.json"
  check 'record observes merged state with an empty checks array and no error' \
    jq -e '.records[0] | .observation.state == "merged" and (.observation.checks | length) == 0 and .error == null' \
    "$home/data/delivery/contributions.json"
  capture out fm "$home" "${CONTRIB[@]}" owned
  check 'fleet owned view (read-only consumer) reads the settled record' \
    jq -e 'any(.[]; .url == "https://github.com/o/r/pull/8" and .final == true)' <<<"$out"
  local before after
  before=$(cat "$home/data/delivery/contributions.json")
  : > "$home/forge/calls"
  capture out fm "$home" "${CONTRIB[@]}" poll
  after=$(cat "$home/data/delivery/contributions.json")
  check 're-poll leaves the settled record byte-identical (settles once)' [ "$before" = "$after" ]
  check 're-poll makes no forge calls (terminal record is not re-read)' [ ! -s "$home/forge/calls" ]
}

# ---- S2: incident replay: hand-written non-v1 record cannot wedge settlement
seed_incident_record() { # file : the exact fm-contrib-shape incident record
  jq -n '{schema:"fm-contributions.v1",task:"delivery",records:[{url:"https://github.com/o/r/pull/8",
    kind:"pr",verdict:"merged",observation:{state:"merged"}}]}' > "$1"
}

s2() {
  local home out rc
  T="$EV/02-scenario2-incident-replay-after-fix.log"; : > "$T"
  home=$(new_home s2-incident)
  : > "$home/forge/no-checks"; printf 'merged\n' > "$home/forge/state"
  mkdir -p "$home/data/delivery"
  seed_incident_record "$home/data/delivery/contributions.json"
  cp "$home/data/delivery/contributions.json" "$home/seed.json"
  say "== Scenario 2 (adversarial): a lane hand-writes the no-CI settlement record =="
  say "seeded data/delivery/contributions.json with the incident shape: bare-string verdict 'merged', partial observation"
  say "bytes: $(cat "$home/data/delivery/contributions.json")"
  capture out fm "$home" "${CONTRIB[@]}" poll; rc=$?
  check 'settlement poll completes without hand repair (exit 0)' [ "$rc" -eq 0 ]
  check 'settlement reports exactly one unreadable durable record' \
    [ "$out" = 'contributions: 1 unreadable durable record(s)' ]
  say "ledger after settlement: $(cat "$home/data/delivery/contributions.json")"
  check 'ledger converges to a v1 record (product validator)' \
    valid_ledger "$home/data/delivery/contributions.json"
  check 'record is rebuilt from observed evidence: merged state, verdict null' \
    jq -e '.records[0].observation.state == "merged" and .records[0].verdict == null' \
    "$home/data/delivery/contributions.json"
  check 'hand-written bytes are kept aside as contributions.json.invalid.*' \
    bash -c 'ls "$1/data/delivery/" | grep -q "^contributions\.json\.invalid\."' _ "$home"
  check 'kept-aside bytes equal the hand-written record exactly' \
    bash -c 'cat "$1"/data/delivery/contributions.json.invalid.* | diff - "$1/seed.json"' _ "$home"
  capture out fm "$home" "${CONTRIB[@]}" owned
  check 'fleet owned view now reads the rebuilt record (machine-readable again)' \
    jq -e 'any(.[]; .url == "https://github.com/o/r/pull/8" and .final == true)' <<<"$out"
}

# ---- S2 before-fix repro: same incident wedges the base commit ------------
s2_before() {
  local home out rc
  T="$EV/03-scenario2-before-fix-wedge-base-commit.log"; : > "$T"
  say "== Scenario 2 before-fix repro against base commit a049d301907329c628b73dea4d6722a4ee203ce7 =="
  git -C "$WT" archive a049d301907329c628b73dea4d6722a4ee203ce7 | tar -x -C "$RUN/base"
  home=$(new_home s2-base)
  : > "$home/forge/no-checks"; printf 'merged\n' > "$home/forge/state"
  mkdir -p "$home/data/delivery"
  seed_incident_record "$home/data/delivery/contributions.json"
  capture out fm "$home" "$RUN/base/bin/fm-contributions.sh" poll; rc=$?
  say "observable result: settlement poll exit=$rc, ledger file after the failed run:"
  say "$(cat "$home/data/delivery/contributions.json")"
  check 'base commit wedges: settlement poll fails' [ "$rc" -ne 0 ]
  check 'base commit fails with invalid stored contribution record' \
    grep -q 'invalid stored contribution record' <<<"$out"
  check 'base commit leaves the corrupt record in place (hand repair required)' \
    jq -e '.records[0].verdict == "merged"' "$home/data/delivery/contributions.json"
  check 'base commit quarantines nothing' \
    bash -c '! ls "$1/data/delivery/" | grep -q "^contributions\.json\.invalid\."' _ "$home"
}

# ---- S3: corrupt record in one task cannot wedge another task's enrollment
s3() {
  local home out rc
  T="$EV/04-scenario3-unreadable-record-cannot-wedge-enrollment.log"; : > "$T"
  home=$(new_home s3-enroll)
  mkdir -p "$home/data/stranger"
  printf 'incomplete JSON\n' > "$home/data/stranger/contributions.json"
  say "== Scenario 3 (adversarial): a corrupt ledger entry in another task cannot wedge enrollment =="
  say "seeded data/stranger/contributions.json with garbage: 'incomplete JSON'"
  capture out fm "$home" "${CONTRIB[@]}" enroll delivery https://github.com/o/r/pull/9; rc=$?
  check 'enrollment of a new contribution completes (exit 0)' [ "$rc" -eq 0 ]
  say "delivery ledger: $(cat "$home/data/delivery/contributions.json")"
  say "stranger directory now: $(ls "$home/data/stranger/")"
  check 'enrolled record passes the product validator' \
    valid_ledger "$home/data/delivery/contributions.json"
  check 'enrollment recorded the enrolled URL' \
    jq -e '.records[0].url == "https://github.com/o/r/pull/9"' "$home/data/delivery/contributions.json"
  check 'corrupt record is out of the ledger path' [ ! -e "$home/data/stranger/contributions.json" ]
  check 'corrupt bytes are kept aside as contributions.json.invalid.*' \
    bash -c 'ls "$1/data/stranger/" | grep -q "^contributions\.json\.invalid\."' _ "$home"
  check 'kept-aside bytes are the original garbage' \
    bash -c 'grep -q "incomplete JSON" "$1"/data/stranger/contributions.json.invalid.*' _ "$home"
  capture out fm "$home" "${CONTRIB[@]}" owned
  check 'fleet owned view reads the converged ledger' \
    jq -e 'any(.[]; .url == "https://github.com/o/r/pull/9")' <<<"$out"
}

# ---- S4: read-only views stay fail-closed and never move a corrupt record --
s4() {
  local home out out1 out2 rc1 rc2
  T="$EV/05-scenario4-readonly-views-fail-closed.log"; : > "$T"
  home=$(new_home s4-readonly)
  mkdir -p "$home/data/stranger"
  printf 'incomplete JSON\n' > "$home/data/stranger/contributions.json"
  say "== Scenario 4 (adversarial boundary): read-only fleet views keep failing on a corrupt record =="
  capture out1 fm "$home" "${CONTRIB[@]}" owned; rc1=$?
  capture out2 fm "$home" "${CONTRIB[@]}" pending; rc2=$?
  check 'owned view refuses with unverified ownership (exit non-zero)' [ "$rc1" -ne 0 ]
  check 'owned view names the unreadable record' \
    grep -q 'unreadable contribution record(s); ownership is unverified' <<<"$out1"
  check 'pending view refuses with unverified signals (exit non-zero)' [ "$rc2" -ne 0 ]
  check 'pending view names the unreadable record' \
    grep -q 'unreadable contribution record(s); pending signals are unverified' <<<"$out2"
  say "stranger directory after both read-only calls: $(ls "$home/data/stranger/")"
  check 'read-only views never move the corrupt record (file still at its ledger path)' \
    [ -f "$home/data/stranger/contributions.json" ]
  check 'read-only views quarantine nothing' \
    bash -c '! ls "$1/data/stranger/" | grep -q "^contributions\.json\.invalid\."' _ "$home"
}

# ---- S5: healthy ledger mutations keep every row and never quarantine -----
s5() {
  local home out rc
  T="$EV/06-scenario5-healthy-ledger-never-quarantined.log"; : > "$T"
  home=$(new_home s5-healthy)
  mkdir -p "$home/data/delivery"
  jq -n --arg head "$HEAD_A" '{schema:"fm-contributions.v1",task:"delivery",records:[
    {url:"https://github.com/o/r/pull/8",kind:"pr",checked_at:"2026-09-15T08:00:00Z",error:null,pending:[],seen:[],
     verdict:{head:$head,source:"https://github.com/o/r/pull/8#issuecomment-1",actor:"captain",summary:"choose contract"},
     observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",can_merge:false,review_decision:"APPROVED",
       checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:"2026-09-15T08:00:00Z"}],reviews:[],events:[]}},
    {url:"https://github.com/o/r/pull/10",kind:"pr",checked_at:"2026-09-15T08:00:00Z",error:null,pending:[],seen:[],verdict:null,
     observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",can_merge:false,review_decision:"",
       checks:[],reviews:[],events:[]}}]}' > "$home/data/delivery/contributions.json"
  say "== Scenario 5 (adversarial boundary): a healthy ledger is never quarantined or truncated =="
  say "seeded a valid ledger: pull/8 with a recorded captain verdict + pull/10"
  capture out fm "$home" "${CONTRIB[@]}" enroll delivery https://github.com/o/r/pull/9
  check 'enrollment merges a third row instead of rebuilding' \
    jq -e '.records | length == 3' "$home/data/delivery/contributions.json"
  capture out fm "$home" "${CONTRIB[@]}" poll; rc=$?
  check 'settlement poll over the healthy ledger exits 0' [ "$rc" -eq 0 ]
  say "ledger after enrollment and re-observation: $(cat "$home/data/delivery/contributions.json")"
  check 'all three URLs survive the mutations' \
    jq -e '([.records[].url] | sort) == ["https://github.com/o/r/pull/10","https://github.com/o/r/pull/8","https://github.com/o/r/pull/9"]' \
      "$home/data/delivery/contributions.json"
  check 'the recorded captain verdict survives re-observation' \
    jq -e '.records[] | select(.url == "https://github.com/o/r/pull/8") | .verdict.summary == "choose contract"' \
      "$home/data/delivery/contributions.json"
  check 're-observation refreshed pull/8 from the forge (open state recorded)' \
    jq -e '.records[] | select(.url == "https://github.com/o/r/pull/8") | .observation.state == "open"' \
      "$home/data/delivery/contributions.json"
  check 'no record was quarantined anywhere in the healthy home' \
    bash -c '! ls "$1"/data/*/ | grep -q "^contributions\.json\.invalid\."' _ "$home"
  check 'ledger still passes the product validator' \
    valid_ledger "$home/data/delivery/contributions.json"
}

# ---- S7: arm --if-owned converges and keeps its ownership gate honest ------
s7() {
  local home out rc
  T="$EV/08-scenario7-arm-if-owned-converges.log"; : > "$T"
  home=$(new_home s7-arm)
  sed -i '/Delivery PR/d' "$home/data/backlog.md"
  rm -f "$home/state/delivery.meta"
  mkdir -p "$home/data/ghost"
  printf 'incomplete JSON\n' > "$home/data/ghost/contributions.json"
  say "== Scenario 7 (adversarial): arm --if-owned converges on a corrupt record and keeps its ownership gate =="
  say "fixture: only durable state is a corrupt data/ghost/contributions.json (ownership unprovable from it)"
  capture out fm "$home" "${CONTRIB[@]}" arm --if-owned; rc=$?
  check 'arm --if-owned completes instead of wedging (exit 0)' [ "$rc" -eq 0 ]
  say "ghost directory after arm: $(ls "$home/data/ghost/")"
  check 'corrupt record is quarantined out of the ledger during arm' \
    [ ! -e "$home/data/ghost/contributions.json" ]
  check 'quarantine kept the bytes aside' \
    bash -c 'ls "$1/data/ghost/" | grep -q "^contributions\.json\.invalid\."' _ "$home"
  check 'the ownership gate cannot prove the empty ledger unowned after quarantine, so the check is registered' \
    [ -f "$home/state/contributions.check.sh" ]
  # Counter-case of the same gate: a genuinely clean, record-free home stays
  # unowned and must NOT register a check.
  home=$(new_home s7-arm-clean)
  sed -i '/Delivery PR/d' "$home/data/backlog.md"
  rm -f "$home/state/delivery.meta"
  capture out fm "$home" "${CONTRIB[@]}" arm --if-owned; rc=$?
  check 'arm --if-owned on a record-free home exits 0' [ "$rc" -eq 0 ]
  check 'a record-free home stays unowned: no check is registered' \
    [ ! -e "$home/state/contributions.check.sh" ]
}

mkdir -p "$RUN/base"
s1
s2
s2_before
s3
s4
s5
s7
say ''
if [ "$STATUS" -eq 0 ]; then say 'ALL SCENARIO CHECKS PASSED'; else say 'SOME SCENARIO CHECKS FAILED'; fi
echo "RUN=$RUN STATUS=$STATUS"
exit "$STATUS"
