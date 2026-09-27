#!/usr/bin/env bash
# Behavior tests for bin/fm-lane-recover.sh, the bounded recovery ladder.
#
# The cases that matter here are the refusals, because the ladder's value is as
# much in what it declines to do as in what it tries:
#   - THE-FM is never a target, asserted rather than attempted.
#   - Inconclusive endpoint evidence never authorizes a relaunch.
#   - An unhealthy lane never ends at rung=none, which would report success
#     while doing nothing.
#   - Planning consumes no attempt budget and changes nothing.
#
# Every case drives the real script through its command line, and every rung
# decision is asserted from `plan`, so no test ever launches or replaces an
# agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP=$(fm_test_tmproot fm-lane-recover)
LADDER="$ROOT/bin/fm-lane-recover.sh"
NOW=$(date +%s)

# A fake tmux that drives fm_backend_agent_state to one chosen classification,
# the same shape tests/fm-secondmate-liveness.test.sh establishes.
#   alive      a named agent command holds the pane
#   dead       a bare shell holds it
#   ambiguous  an unrecognized process holds it
#   unreadable the pane read fails while the inventory still lists the window
#   missing    the inventory is readable and omits the window
fake_tmux() {  # <dir> <state> <session:window>
  local dir=$1 state=$2 win=$3 fakebin
  # tmux lists window NAMES, so the inventory answer is the part after the
  # colon; printing the whole target here would make every window read missing.
  win=${win#*:}
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    case '$state' in
      alive) printf '%s\n' pi ;;
      dead) printf '%s\n' bash ;;
      ambiguous) printf '%s\n' node ;;
      unreadable|missing) exit 1 ;;
    esac
    exit 0 ;;
  list-windows)
    case '$state' in
      missing) printf '%s\n' someothewindow ;;
      *) printf '%s\n' '$win' ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# home <name> : a central home with config, plus a lane whose own supervision
# home exists so the rail can read a beat for it.
home() {
  local root="$TMP/$1"
  mkdir -p "$root/state" "$root/config"
  printf '%s\n' '# fixture' '# thresholds left at defaults' > "$root/config/response-lanes.conf"
  printf '%s\n' "$root"
}

lane() {  # <root> <lane> [beat-age] [harness]
  local root=$1 name=$2 age=${3:-0} harness=${4:-pi}
  mkdir -p "$root/lanes/$name/state" "$root/state/$name.inbox/handled"
  fm_write_secondmate_meta "$root/state/$name.meta" "$root/lanes/$name" \
    "sess:$name" alpha "$harness"
  : > "$root/lanes/$name/state/.last-watcher-beat"
  [ "$age" = 0 ] || fm_touch_epoch "$(( NOW - age ))" "$root/lanes/$name/state/.last-watcher-beat"
  printf '%s\n' "lane $name" >> "$root/config/response-lanes.conf"
}

conf() { printf '%s\n' "$2" >> "$1/config/response-lanes.conf"; }
pane() { printf '%s\n' "$3" > "$1/state/$2.pane"; }

# ladder <root> <probe-state> <window> <mode...>
ladder() {
  local root=$1 state=$2 win=$3 fb slug
  shift 3
  # PATH is colon separated, so a fake-bin directory named after a session:window
  # target would split into two bogus entries and the fake would never be found.
  slug=${win//:/-}
  fb=$(fake_tmux "$root/fake-$state-$slug" "$state" "$win")
  PATH="$fb:$BASE_PATH" FM_TEST_SEAM=1 FM_HOME="$root" \
    FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" \
    "$LADDER" "$@" 2>&1
}

row() {  # <output> <lane>
  printf '%s\n' "$1" | grep "^lane=$2 " | head -1
}

field() {  # <row> <name>
  printf '%s\n' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p"
}

# --- THE-FM is never a target ------------------------------------------------
# The refusal is asserted, not attempted: a fake tmux that records every call
# proves nothing was even probed on the way to refusing.
R=$(home thefm)
mkdir -p "$R/state/itself.inbox/handled"
fm_write_secondmate_meta "$R/state/itself.meta" "$R" "sess:itself" alpha pi
conf "$R" 'lane itself'
OUT=$(ladder "$R" dead sess:itself plan)
ROW=$(row "$OUT" itself)
assert_equals refused "$(field "$ROW" rung)" 'a lane whose home resolves to THE-FM is refused'
assert_contains "$ROW" 'never restarts or recreates' 'the refusal says what it is protecting'
assert_not_contains "$OUT" 'rung=restart_lane_agent' 'THE-FM is never offered a restart'

# A record that is not a response lane at all is refused the same way.
R=$(home notalane)
mkdir -p "$R/lanes/ship/state" "$R/state/ship.inbox/handled"
fm_write_meta "$R/state/ship.meta" 'window=sess:ship' 'kind=ship' "home=$R/lanes/ship"
conf "$R" 'lane ship'
OUT=$(ladder "$R" dead sess:ship plan)
assert_equals refused "$(field "$(row "$OUT" ship)" rung)" 'a record that is not a response lane is refused'

# --- an unread lane is never acted on ---------------------------------------
R=$(home unread)
lane "$R" gone
rm -rf "$R/state/gone.inbox"
OUT=$(ladder "$R" dead sess:gone plan)
ROW=$(row "$OUT" gone)
assert_equals none "$(field "$ROW" rung)" 'a lane the rail could not read is left alone'
assert_contains "$ROW" 'unread is not dead' 'the reason says why an unread lane is not a dead one'

# --- inconclusive endpoint evidence never relaunches -------------------------
# Each inconclusive state gets its own home so the verdict cannot leak between
# them, and each must both decline rung 1 AND still escalate, because the lane
# is unhealthy either way.
for state in ambiguous unreadable; do
  R=$(home "inconclusive-$state")
  lane "$R" stalled 4000
  pane "$R" stalled 'nothing interesting'
  OUT=$(ladder "$R" "$state" sess:stalled plan)
  ROW=$(row "$OUT" stalled)
  assert_not_equals restart_lane_agent "$(field "$ROW" rung)" \
    "an $state endpoint must never be relaunched"
  assert_equals escalate_captain "$(field "$ROW" rung)" \
    "an $state endpoint on a dead lane escalates rather than reporting nothing to do"
done

# --- a proven dead endpoint reaches rung 1 ----------------------------------
R=$(home rung1)
lane "$R" downed 4000
pane "$R" downed 'nothing interesting'
OUT=$(ladder "$R" dead sess:downed plan)
ROW=$(row "$OUT" downed)
assert_equals restart_lane_agent "$(field "$ROW" rung)" 'a proven dead endpoint reaches the restart rung'
assert_contains "$ROW" 'attempt 1 of 2' 'the rung records which attempt this would be'
assert_contains "$ROW" 'action=would-run' 'planning only says what it would run'

# --- probe-alive must not short-circuit the error class ----------------------
# The regression this ordering exists for: process alive, provider dead. Before
# the fix this exited at rung=none reporting that the endpoint probes alive.
R=$(home providerdead)
lane "$R" stalled 4000
pane "$R" stalled 'stream disconnected before completion'
conf "$R" 'SWITCH_MODEL=some-other-model'
OUT=$(ladder "$R" alive sess:stalled plan)
ROW=$(row "$OUT" stalled)
assert_equals switch_model_or_harness "$(field "$ROW" rung)" \
  'a live endpoint with a matched provider error reaches the switch rung'
assert_contains "$ROW" 'stream_disconnected' 'the rung names the class that justified it'
assert_contains "$ROW" 'fm-control.sh' 'the switch uses the existing owner of replacing a running agent'
assert_contains "$ROW" 'some-other-model' 'the configured switch target is the one that would be used'
assert_contains "$ROW" 'persist is attempted' 'a live endpoint is asked to persist first, bounded'
assert_not_contains "$ROW" 'endpoint probes alive' \
  'probe liveness must not be the terminal answer for a provider-dead lane'

# Same lane, same live endpoint, but no provider error: there is nothing to
# switch onto, so this must escalate rather than swap a healthy provider. This
# is what keeps the case above from passing vacuously.
R=$(home providerclean)
lane "$R" stalled 4000
pane "$R" stalled 'nothing interesting'
conf "$R" 'SWITCH_MODEL=some-other-model'
OUT=$(ladder "$R" alive sess:stalled plan)
assert_equals escalate_captain "$(field "$(row "$OUT" stalled)" rung)" \
  'a live endpoint with no provider error does not get a profile switch'

# --- a provider fault on a missing endpoint is not the provider's fault ------
R=$(home missingendpoint)
lane "$R" vanished 4000
pane "$R" vanished 'Account budget exceeded'
conf "$R" 'SWITCH_MODEL=some-other-model'
conf "$R" 'ATTEMPT_CEILING=0'
OUT=$(ladder "$R" missing sess:vanished plan)
ROW=$(row "$OUT" vanished)
assert_equals escalate_captain "$(field "$ROW" rung)" \
  'a missing endpoint never gets a profile switch, because the provider is not the cause'
assert_contains "$ROW" 'provider is not the cause' 'the escalation says why rung 2 does not apply'

# --- a class the rail does not publish is never dropped ---------------------
R=$(home unhandled)
lane "$R" odd 4000
pane "$R" odd 'nothing interesting'
conf "$R" 'SWITCH_MODEL=some-other-model'
# A rail that reports a class its own published vocabulary does not contain.
# That is the drift the ladder must refuse to guess about, and a stub rail is
# the only way to produce it, since the real rail keeps the two in step.
cat > "$R/stub-rail" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  classes) printf 'class none matched=no\nclass budget_exceeded matched=yes\n' ;;
  read) printf 'lane=odd source=local verdict=dead pending_count=0 handled_count=0 inbox_drain_age_s=- pending_reply_missed=0 pending_reply_resolved=0 error_signature_class=brand_new_class watcher_beat_age_s=4000 agent_status=alive route_evidence_count=0 drained_while_error_active=no mover=- reason=fixture\n' ;;
esac
STUB
chmod +x "$R/stub-rail"
OUT=$(PATH="$(fake_tmux "$R/fake-odd" alive sess:odd):$BASE_PATH" FM_TEST_SEAM=1 \
  FM_HOME="$R" FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" \
  FM_LANE_RAIL="$R/stub-rail" "$LADDER" plan 2>&1)
ROW=$(row "$OUT" odd)
assert_equals escalate_captain "$(field "$ROW" rung)" \
  'a class the rail does not publish routes to the escalation rung'
assert_contains "$ROW" 'unhandled_errclass' 'the unhandled class is named rather than silently dropped'

# --- rung 3: a recovered lane's unclaimed work is re-sent once --------------
R=$(home rung3)
lane "$R" reloaded 4000
pane "$R" reloaded 'nothing interesting'
printf 'schema=1\nat=now\n--\ncorr=0123456789abcdef original work order\n' > "$R/state/reloaded.inbox/001.msg"
OUT=$(ladder "$R" alive sess:reloaded plan)
assert_contains "$OUT" 'mode=dry-run' 'a plan is labeled as a dry run'
ROW=$(row "$OUT" reloaded)
assert_equals redispatch "$(field "$ROW" rung)" \
  'an alive endpoint on a lane that still holds unclaimed work reaches rung 3 before the page'
assert_contains "$ROW" 'action=would-run' 'planning says what rung 3 would run'
assert_contains "$ROW" 'fresh correlation ids' 'the plan names the re-send contract'
assert_absent "$R/state/.lane-recovery-reloaded" 'planning the re-send writes no ladder log'
OUT=$(ladder "$R" alive sess:reloaded run)
assert_contains "$OUT" 'refusing to act' 'the off-switch also holds rung 3'
assert_absent "$R/state/.lane-recovery-reloaded" 'a refused re-send writes no ladder log'
conf "$R" 'RECOVERY=acting'
OUT=$(ladder "$R" alive sess:reloaded run)
assert_contains "$OUT" 'mode=acting' 'the banner labels an acting sweep'
assert_not_contains "$OUT" 'mode=acting1' 'the banner label is not a parameter echo'
ROW=$(row "$OUT" reloaded)
assert_contains "$ROW" 'rung=redispatch action=done' 'the acting run executes the re-send'
assert_contains "$ROW" 'sent=1' 'the acting run reports what it re-sent'
assert_grep "$(printf 'redispatch\tattempt')" "$R/state/.lane-recovery-reloaded" \
  'the re-send writes the attempt row the once-only cap counts'
assert_present "$R/state/reloaded.inbox/002.msg" 'the re-send left a new inbox record'
OLD_CORR=$(LC_ALL=C grep -o 'corr=[A-Fa-f0-9]*' "$R/state/reloaded.inbox/001.msg" | head -1)
NEW_CORR=$(LC_ALL=C grep -o 'corr=[A-Fa-f0-9]*' "$R/state/reloaded.inbox/002.msg" | head -1)
assert_not_equals '' "$NEW_CORR" 'the re-send carries a correlation id'
assert_not_equals "$OLD_CORR" "$NEW_CORR" \
  'the re-send mints a fresh correlation id, so the duplicate is detectable'
assert_present "$R/state/reloaded.inbox/001.msg" 'the original unclaimed record is never discarded'
OUT=$(ladder "$R" alive sess:reloaded run)
ROW=$(row "$OUT" reloaded)
assert_equals escalate_captain "$(field "$ROW" rung)" \
  'once the once-only cap is spent the same lane escalates instead of re-sending again'
assert_contains "$ROW" 'action=parked' 'the escalation parks the lane for a person'
assert_grep "$(printf 'escalate_captain\tparked')" "$R/state/.lane-recovery-reloaded" \
  'the ladder log carries the escalation that followed the re-send'

# --- no unhealthy lane ever ends at rung=none -------------------------------
# The invariant, asserted directly across every endpoint state: a dead verdict
# must never produce rung=none, whatever the probe said.
for state in alive dead ambiguous unreadable missing; do
  R=$(home "invariant-$state")
  lane "$R" sick 4000
  pane "$R" sick 'nothing interesting'
  OUT=$(ladder "$R" "$state" sess:sick plan)
  ROW=$(row "$OUT" sick)
  assert_equals dead "$(field "$ROW" verdict)" "the $state fixture must really be a dead lane"
  assert_not_equals none "$(field "$ROW" rung)" \
    "a dead lane with an $state endpoint must not report nothing to do"
done

# --- planning changes nothing -----------------------------------------------
R=$(home nomutate)
lane "$R" downed 4000
pane "$R" downed 'nothing interesting'
ladder "$R" dead sess:downed plan > /dev/null
assert_absent "$R/state/.lane-recovery-downed" 'planning writes no ladder log'
assert_absent "$R/state/.secondmate-relaunch-downed" 'planning consumes no relaunch budget'

# --- the off-switch ---------------------------------------------------------
R=$(home offswitch)
lane "$R" downed 4000
pane "$R" downed 'nothing interesting'
OUT=$(ladder "$R" dead sess:downed run)
assert_contains "$OUT" 'refusing to act' 'run refuses while the off-switch is off'
assert_contains "$OUT" 'action=would-run' 'a refused run degrades to printing the plan'
assert_absent "$R/state/.lane-recovery-downed" 'a refused run writes no ladder log'
conf "$R" 'RECOVERY=dry-run'
OUT=$(ladder "$R" dead sess:downed run)
assert_contains "$OUT" 'refusing to act' 'dry-run is still not acting'
assert_absent "$R/state/.lane-recovery-downed" 'RECOVERY=dry-run writes no ladder log either'

# --- parking keeps recovery out of a human decision -------------------------
R=$(home parked)
lane "$R" held 4000
pane "$R" held 'nothing interesting'
printf '%s\t%s\t%s\t%s\n' "$NOW" escalate_captain parked 'fixture' > "$R/state/.lane-recovery-held"
OUT=$(ladder "$R" dead sess:held plan)
ROW=$(row "$OUT" held)
assert_equals none "$(field "$ROW" rung)" 'a parked lane stays out of automatic recovery'
assert_contains "$ROW" 'until it is cleared' 'the reason says what would re-arm it'
OUT=$(ladder "$R" dead sess:held clear held)
assert_contains "$OUT" 're-armed' 'clear reports that the lane is re-armed'
OUT=$(ladder "$R" dead sess:held plan)
assert_not_equals none "$(field "$(row "$OUT" held)" rung)" \
  'a cleared lane is considered by the ladder again'

# --- an unconfigured home is inert -----------------------------------------
R="$TMP/off"
mkdir -p "$R/state" "$R/config"
OUT=$(FM_HOME="$R" FM_STATE_OVERRIDE="$R/state" FM_CONFIG_OVERRIDE="$R/config" "$LADDER" plan 2>&1)
assert_contains "$OUT" 'not configured' 'an unconfigured home says so and does nothing'

pass 'fm-lane-recover.sh: refusals, rung ordering that does not short-circuit on probe liveness, no silent no-op on a dead lane, and a planning mode that changes nothing'
