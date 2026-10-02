#!/usr/bin/env bash
# Live driver: part 1 of the change - skip identical config-reread payloads and
# label an actual pointer send. Drives the REAL product entry point
# bin/fm-config-push.sh end-to-end against a marked disposable lab home and a
# REAL tmux server on a private socket (no fake tmux), plus the same sequence
# against the base commit's scripts as the fail-before contrast.
#
# Usage: live-config-push.sh <bin-dir-under-test> <label>
set -u

ROOT=/home/jon/.no-mistakes/worktrees/2f32188048b1/01M3XNRZQKW563WQCGY4XH4RVF
EVD=/home/jon/.no-mistakes/evidence/01M3XNRZQKW563WQCGY4XH4RVF
BIN=${1:?bin dir under test}
LABEL=${2:?label}
REAL_TMUX=$(command -v tmux) || { echo "tmux missing"; exit 2; }

FAILURES=0
fail() { printf '[%s] FAIL: %s\n' "$LABEL" "$*"; FAILURES=$((FAILURES + 1)); }
expect_eq() { [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"; }
expect_in() { case "$2" in *"$1"*) ;; *) fail "$3 (missing: $1)";; esac; }
expect_not_in() { case "$2" in *"$1"*) fail "$3 (unexpected: $1)";; *) ;; esac; }

TMPW=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-cfgpush.XXXXXX") || exit 2
LAB="$TMPW/lab"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home create failed"; exit 2; }
SM=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-sm.XXXXXX") || exit 2
LABTMUX=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 2
LOG="$EVD/live-config-push.$LABEL.log"
: > "$LOG"

cleanup() {
  TMUX_TMPDIR="$LABTMUX" "$REAL_TMUX" -L fm-lab kill-server 2>/dev/null || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$TMPW" "$SM"
}
trap cleanup EXIT

export TMUX_TMPDIR="$LABTMUX"
mkdir -p "$TMPW/bin" "$SM/bin" "$SM/config" "$SM/state"
printf 'lab secondmate\n' > "$SM/AGENTS.md"
printf 'sm\n' > "$SM/.fm-secondmate-home"

# A live watcher fixture (this driver process) so the advisory guard stays quiet.
identity=$(FM_STATE_OVERRIDE="$LAB/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$")
mkdir -p "$LAB/state/.watch.lock"
printf '%s\n' "$$" > "$LAB/state/.watch.lock/pid"
printf '%s\n' "$LAB" > "$LAB/state/.watch.lock/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$LAB/state/.watch.lock/watcher-path"
printf '%s\n' "$identity" > "$LAB/state/.watch.lock/pid-identity"
touch "$LAB/state/.last-watcher-beat"

# PATH wrapper: every product tmux call lands on the private fm-lab socket.
cat > "$TMPW/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L fm-lab "\$@"
EOF
chmod +x "$TMPW/bin/tmux"
# A pane whose foreground command reads as a live agent (codex), so fm-send's
# doorbell ring addresses a live endpoint exactly as in production.
mkdir -p "$TMPW/agent"
ln -s "$(command -v bash)" "$TMPW/agent/codex"

# Primary home (marked lab home): the source of inherited config.
printf 'codex\n' > "$LAB/config/crew-harness"
printf 'old-harness\n' > "$SM/config/crew-harness"
cat > "$LAB/state/sm.meta" <<EOF
window=firstmate:fm-sm
kind=secondmate
home=$SM
EOF

mkpane() { "$TMPW/bin/tmux" new-window -d -t 'firstmate:' -n "$1" "$TMPW/agent/codex --norc"; }
"$TMPW/bin/tmux" new-session -d -s firstmate -n fm-sm "$TMPW/agent/codex --norc"
"$TMPW/bin/tmux" new-window -d -t firstmate -n keep 'bash --norc'
sleep 0.3

run_push() { # [ENV=val ...]
  # An ordinary caller runs this from their own checkout: drive it with cwd
  # outside the gate worktree so the product's own gate-context check (whose
  # lab-home allowance config-push's FM_*_OVERRIDE propagation defeats) sees a
  # normal session. NO_MISTAKES_GATE stays unset.
  cd "$LAB" || return 1
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      PATH="$TMPW/bin:$PATH" TMUX_TMPDIR="$LABTMUX" FM_HOME="$LAB" \
      FM_BACKEND=tmux FM_SEND_SETTLE=0 FM_CREW_STATE_NO_FORGE=1 \
      "$@" "$BIN/fm-config-push.sh" 2>&1
}

inbox_count() {
  local n=0 rec
  for rec in "$LAB/state/sm.inbox"/*.msg; do [ -e "$rec" ] || continue; n=$((n + 1)); done
  printf '%s\n' "$n"
}
inbox_dump() {
  local rec
  for rec in "$LAB/state/sm.inbox"/*.msg; do
    [ -e "$rec" ] || continue
    printf -- '--- %s\n' "${rec##*/}"
    env FM_HOME="$LAB" bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$rec" 2>/dev/null
    printf '\n'
  done
}
delivered_count() {
  local n=0 p
  for p in "$SM/state"/.fm-inherited-config-reread.*; do
    case "$p" in *.pending) continue ;; esac
    [ -f "$p" ] && [ ! -L "$p" ] || continue
    [ ! -e "$p.pending" ] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}
pending_markers() {
  local n=0 p
  for p in "$SM/state"/.fm-inherited-config-reread.*.pending; do [ -f "$p" ] || continue; n=$((n + 1)); done
  printf '%s\n' "$n"
}
retry_stages() {
  local n=0 p
  for p in "$LAB/state/.fm-inherited-config-reread-retry/sm"/.fm-inherited-config-reread.*; do
    [ -f "$p" ] || continue; case "$p" in *.report) continue ;; esac; n=$((n + 1))
  done
  printf '%s\n' "$n"
}
latest_delivered() {
  local p out=
  for p in "$SM/state"/.fm-inherited-config-reread.*; do
    case "$p" in *.pending) continue ;; esac
    [ -f "$p" ] && [ ! -L "$p" ] || continue
    [ ! -e "$p.pending" ] || continue
    out=$p
  done
  printf '%s\n' "$out"
}
run_nudge() { # <report-file> - drive the reread sender (the product's own library entry)
  cd "$LAB" || return 1
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      PATH="$TMPW/bin:$PATH" TMUX_TMPDIR="$LABTMUX" FM_HOME="$LAB" \
      FM_BACKEND=tmux FM_SEND_SETTLE=0 \
      bash -c '. "$1"; fm_config_send_reread_nudge sm "$2" "$3"' \
      _ "$BIN/fm-config-inherit-lib.sh" "$SM" "$1" 2>&1
}

printf '== %s == lab %s sm %s\n' "$LABEL" "$LAB" "$SM" >> "$LOG"

# ---------- A: first real change delivers exactly one pointer ----------
out=$(run_push); rc=$?
printf -- '--- A first changed push (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 0 "A: push should succeed"
expect_in "crew-harness: pushed" "$out" "A: report should show the pushed item"
expect_in "config-reread: sent" "$out" "A: first change must report its send"
expect_eq "$(inbox_count)" 1 "A: exactly one durable reread pointer"
expect_eq "$(delivered_count)" 1 "A: exactly one delivered generation"
expect_eq "$(pending_markers)" 0 "A: no pending marker after a successful send"
instr=$(latest_delivered)
expect_in "BEGIN config/crew-harness" "$(cat "$instr" 2>/dev/null)" "A: delivered generation carries the literal payload"
printf -- '--- A pane after first send:\n%s\n' "$("$TMPW/bin/tmux" capture-pane -p -t firstmate:fm-sm 2>/dev/null)" >> "$LOG"
pane=$("$TMPW/bin/tmux" capture-pane -p -t firstmate:fm-sm 2>/dev/null)
expect_in "Firstmate instruction waiting" "$pane" "A: the live agent's terminal receives the wake"

# ---------- B: no change -> no send, no label ----------
out=$(run_push); rc=$?
printf -- '--- B unchanged push (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 0 "B: unchanged push should succeed"
expect_not_in "config-reread: sent" "$out" "B: unchanged config must not report a send"
expect_eq "$(inbox_count)" 1 "B: unchanged config must not add a pointer"

# ---------- C (adversarial): report claims pushed while payload is byte-identical ----------
rm -f "$SM/config/crew-harness"
out=$(run_push); rc=$?
printf -- '--- C dest-restored byte-identical push (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 0 "C: restoring a lost destination copy should succeed"
expect_in "crew-harness: pushed" "$out" "C: propagation reports the item pushed"
expect_not_in "config-reread: sent" "$out" "C: byte-identical payload must not report a send"
expect_eq "$(inbox_count)" 1 "C: byte-identical payload must not re-send a pointer (the loop the fix closes)"
expect_eq "$(delivered_count)" 1 "C: byte-identical payload must not publish a new generation"

printf 'drifted-elsewhere\n' > "$SM/config/crew-harness"
out=$(run_push); rc=$?
printf -- '--- C2 dest-drift byte-identical push (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 0 "C2: drift restore should succeed"
expect_in "crew-harness: pushed" "$out" "C2: propagation reports the item pushed"
expect_not_in "config-reread: sent" "$out" "C2: drift-restore payload identical to delivery must not report a send"
expect_eq "$(inbox_count)" 1 "C2: drift-restore must not re-send a pointer"

# ---------- D: real send failure keeps the generation pending ----------
# The inbox record is the delivery, so a missing pane alone cannot fail it;
# make the task's steering inbox unwritable - the documented "unwritable record"
# failure - to produce a genuine send failure.
"$TMPW/bin/tmux" kill-window -t firstmate:fm-sm
chmod 0555 "$LAB/state/sm.inbox"
sleep 0.2
printf 'pi\n' > "$LAB/config/crew-harness"
out=$(run_push); rc=$?
printf -- '--- D failed send keeps generation pending (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 1 "D: a real send failure must exit non-zero"
expect_in "send failed" "$out" "D: failure must be diagnostic"
expect_eq "$(pending_markers)" 1 "D: failed generation keeps its pending marker"
expect_eq "$(delivered_count)" 1 "D: failed generation is not delivered"
expect_eq "$(retry_stages)" 1 "D: failed generation's stage is retained for retry"
expect_eq "$(inbox_count)" 1 "D: the failed send recorded no new pointer"

# ---------- E: bootstrap-respawn shape (SKIP_PENDING) delivers only the newer generation ----------
chmod 0755 "$LAB/state/sm.inbox"
mkpane fm-sm
sleep 0.2
printf 'grok\n' > "$LAB/config/crew-harness"
out=$(run_push FM_CONFIG_REREAD_SKIP_PENDING=1); rc=$?
printf -- '--- E skip-pending newer delivery (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 0 "E: newer delivery should succeed"
expect_in "config-reread: sent" "$out" "E: newer delivery must report its send"
expect_eq "$(inbox_count)" 2 "E: exactly one new pointer for the newer generation"
expect_eq "$(delivered_count)" 2 "E: newer generation delivered"
expect_eq "$(pending_markers)" 1 "E: older generation still pending"

# ---------- F (label regression): draining the OLDER pending generation must report the send ----------
out=$(run_push); rc=$?
printf -- '--- F older pending drain (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 0 "F: drain should succeed"
expect_in "config-reread: sent" "$out" "F: an actual pointer send (older pending drain) must print config-reread: sent"
expect_eq "$(inbox_count)" 3 "F: drain delivered one pointer"
expect_eq "$(delivered_count)" 3 "F: drained generation joined the delivered set"
expect_eq "$(pending_markers)" 0 "F: no pending markers remain"

# ---------- G: one delivery carrying two byte-identical generations sends only one ----------
# Two retained retry stages with byte-identical payloads enter the same delivery
# queue; the single skip gate keeps the first and discards the second.
inbox_before=$(inbox_count)
delivered_before=$(delivered_count)
retry_dir="$LAB/state/.fm-inherited-config-reread-retry/sm"
mkdir -p "$retry_dir"
printf '%s\n' 'config/crew-harness' '-----BEGIN config/crew-harness-----' \
  'sibling-payload' '-----END config/crew-harness-----' \
  > "$retry_dir/.fm-inherited-config-reread.20260721T000000.00000001"
printf '%s\n' 'config/crew-harness' '-----BEGIN config/crew-harness-----' \
  'sibling-payload' '-----END config/crew-harness-----' \
  > "$retry_dir/.fm-inherited-config-reread.20260721T000000.00000002"
: > "$TMPW/empty.report"
out=$(run_nudge "$TMPW/empty.report"); rc=$?
printf -- '--- G identical sibling stages in one delivery (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 0 "G: sibling dedup delivery should succeed"
expect_eq "$(( $(inbox_count) - inbox_before ))" 1 "G: byte-identical siblings must yield exactly one pointer"
expect_eq "$(( $(delivered_count) - delivered_before ))" 1 "G: byte-identical siblings must yield exactly one generation"

# Control: two siblings with DIFFERENT payloads are both sent
inbox_before=$(inbox_count)
delivered_before=$(delivered_count)
printf '%s\n' 'sibling-payload-A' > "$retry_dir/.fm-inherited-config-reread.20260721T000000.00000003"
printf '%s\n' 'sibling-payload-B' > "$retry_dir/.fm-inherited-config-reread.20260721T000000.00000004"
out=$(run_nudge "$TMPW/empty.report"); rc=$?
printf -- '--- G2 differing sibling stages in one delivery (rc=%s)\n%s\n' "$rc" "$out" >> "$LOG"
expect_eq "$rc" 0 "G2: differing sibling delivery should succeed"
expect_eq "$(( $(inbox_count) - inbox_before ))" 2 "G2: differing siblings must both be sent"
expect_eq "$(( $(delivered_count) - delivered_before ))" 2 "G2: differing siblings must both publish"

{
  printf -- '--- final inbox records:\n'
  inbox_dump
  printf -- '--- final pane:\n%s\n' "$("$TMPW/bin/tmux" capture-pane -p -t firstmate:fm-sm 2>/dev/null)"
} >> "$LOG"

if [ "$FAILURES" -eq 0 ]; then
  printf '[%s] ALL PASS\n' "$LABEL"
else
  printf '[%s] %s FAILURES\n' "$LABEL" "$FAILURES"
  exit 1
fi
