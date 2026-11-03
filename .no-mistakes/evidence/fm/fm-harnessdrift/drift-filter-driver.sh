#!/usr/bin/env bash
# Throwaway manual driver (test-phase evidence, NOT repo source).
#
# Drives the foreign-harness helper filter introduced in
# tests/fm-harness-liveness-drift-live-e2e.test.sh (intent item 2, bead
# fm-zpdvi) against REAL processes and the REAL bin/fm-harness.sh evidence
# interfaces (ancestry / ancestry-descent). The selection loop below is copied
# verbatim from that guard. The helpers are spawned as direct children of the
# pane command before it execs pi, which is exactly the fm-zpdvi shape: pi
# 1.4.0 keeps a cursor-agent `models` helper as a child in the pane's
# foreground process group.
#
# Case 1 (drop branch): pane = real pi 1.4.0 at comm strength, foreground
#   children = real cursor-agent and real kimi helpers. Unfiltered, the
#   vantage path reproduces the false DETECTION DRIFT (a foreign comm verdict
#   beside `comm pi`); filtered, the eligible leaves drop the foreign helpers
#   and the verdicts stay `comm pi`.
# Case 2 (keep branch, adversarial): pane = anonymous `sleep` (a "renamed
#   agent": the walk finds no expected harness) with a real kimi helper
#   child. The filter must keep the foreign leaf so the reject-other
#   cross-check still reports DETECTION DRIFT.
set -u
ROOT={run-worktree}
REAL_TMUX=$(command -v tmux)
SOCKET="fm-drift-filter-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-drift-filter.XXXXXX")
KIMI_BIN=$(command -v kimi || printf '%s' "$HOME/.kimi-code/bin/kimi")
CURSOR_BIN=$(command -v cursor-agent)
PI_BIN=$(command -v pi)
FAILURES=0

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  sleep 0.3
  # Kill only the exact helper pids this driver recorded; never by name.
  for f in "$LAB"/*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null || true)
    if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
      # Unfreeze a SIGSTOPped helper first, then this pid's current children,
      # then the pid itself. All by exact pid/parent, never by name.
      kill -CONT "$pid" 2>/dev/null || true
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      kill -CONT "$pid" 2>/dev/null || true
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$LAB"
}
trap cleanup EXIT

check() {  # <ok|fail> <label>
  if [ "$1" = ok ]; then printf 'ok - %s\n' "$2"; else printf 'NOT OK - %s\n' "$2"; FAILURES=$((FAILURES + 1)); fi
}

"$REAL_TMUX" -L "$SOCKET" new-session -d -s drift -n control -c "$LAB" \
  || { echo "could not start private tmux server"; exit 1; }

echo "=== Case 1: pi pane with real foreign-harness helper children -> filter drops them (fm-zpdvi shape) ==="
# The cursor helper mirrors pi 1.4.0's own `cursor-agent models` helper (bead
# fm-zpdvi): a cursor process parented under the pane process. The models
# one-shot only lives ~0.9s, so the pane runs it behind a fifo gate and this
# driver SIGSTOPs the first spawned one to freeze a stable live vantage (frozen
# after exec: comm/argv are real process state). The bare cursor-agent TUI is
# deliberately NOT used here: its launcher daemonizes out of the pane's process
# tree (verified: the surviving agent re-parents to a subreaper), so it is not a
# descendant vantage in either the real guard or this driver.
cat > "$LAB/pane-a.sh" <<EOF
#!/bin/bash
mkfifo "$LAB/models.fifo"
# Hold a read-write fd open on the fifo so the reader blocks on an empty pipe
# instead of seeing EOF when transient writers disconnect.
exec 3<>"$LAB/models.fifo"
(
  while read -r _; do
    env HOME="$LAB/home-cursor" DISABLE_AUTOUPDATER=1 "$CURSOR_BIN" models >"$LAB/cursor.log" 2>&1 &
    echo \$! > "$LAB/models.pid"
  done < "$LAB/models.fifo"
) &
echo \$! > "$LAB/cursor-loop.pid"
env HOME="$LAB/home-kimi" KIMI_CODE_HOME="$LAB/home-kimi/.kimi-code" KIMI_CODE_NO_AUTO_UPDATE=1 DISABLE_AUTOUPDATER=1 "$KIMI_BIN" --auto >"$LAB/kimi.log" 2>&1 &
echo \$! > "$LAB/kimi.pid"
exec env DISABLE_AUTOUPDATER=1 "$PI_BIN"
EOF
chmod +x "$LAB/pane-a.sh"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t drift: -n pi-pane -c "$LAB" -- /bin/bash "$LAB/pane-a.sh" \
  || { echo "could not launch pi pane"; exit 1; }
sleep 5

# Spawn one cursor-agent models helper through the pane's gate and freeze it.
for _ in $(seq 1 40); do [ -p "$LAB/models.fifo" ] && break; sleep 0.1; done
models_pid=
for attempt in 1 2 3; do
  printf 'go\n' > "$LAB/models.fifo"
  for _ in $(seq 1 80); do
    mp=$(cat "$LAB/models.pid" 2>/dev/null || true)
    if [ -n "$mp" ] && [ -d "/proc/$mp" ]; then
      # Wait until the wrapper has exec'd into the node image and the real
      # product resolves its identity, then freeze it mid-life.
      if [ "$("$ROOT/bin/fm-harness.sh" ancestry "$mp" 2>/dev/null || true)" = "comm cursor" ]; then
        kill -STOP "$mp" 2>/dev/null || true
        if [ "$("$ROOT/bin/fm-harness.sh" ancestry "$mp" 2>/dev/null || true)" = "comm cursor" ]; then
          models_pid=$mp
          break
        fi
        kill -CONT "$mp" 2>/dev/null || true
        kill "$mp" 2>/dev/null || true
      fi
    fi
    sleep 0.02
  done
  [ -n "$models_pid" ] && break
done

target=drift:pi-pane
pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_pid}' 2>/dev/null | tr -d ' ')
pane_tty=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_tty}' 2>/dev/null | tr -d ' ')
kimi_pid=$(cat "$LAB/kimi.pid" 2>/dev/null || true)
expect_harness=pi
echo "pane_pid=$pane_pid pane_tty=$pane_tty kimi_pid=$kimi_pid models_pid=$models_pid (SIGSTOPped)"
echo "--- process sample on $pane_tty (pid comm ppid pgid tpgid) ---"
LC_ALL=C ps -t "${pane_tty#/dev/}" -o pid=,comm=,ppid=,pgid=,tpgid= 2>/dev/null

pane_self_verdict=$("$ROOT/bin/fm-harness.sh" ancestry "$pane_pid" 2>/dev/null || true)
echo "pane_self_verdict=[$pane_self_verdict]"
[ "$pane_self_verdict" = "comm pi" ] && check ok "C1: pane process is the expected harness at comm strength" \
  || check fail "C1: pane process is the expected harness at comm strength (got '$pane_self_verdict')"

# ---- UNFILTERED vantage selection (the pre-fix behavior) ----
fg_pids_all=$(LC_ALL=C ps -t "${pane_tty#/dev/}" -o pid=,pgid=,tpgid= 2>/dev/null \
  | while read -r fg_pid fg_pgid fg_tpgid; do
      [ -n "$fg_pid" ] || continue
      [ "$fg_pgid" = "$fg_tpgid" ] || continue
      printf '%s ' "$fg_pid"
    done)
echo "unfiltered fg pids: [$fg_pids_all]"
# shellcheck disable=SC2086
verdicts_all=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$pane_pid" $fg_pids_all 2>/dev/null || true)
echo "unfiltered ancestry verdicts: [$(printf '%s' "$verdicts_all" | tr '\n' ';')]"
case "$verdicts_all" in
  *cursor*|*kimi*)
    check ok "C1: unfiltered vantage set reproduces the fm-zpdvi symptom (a foreign verdict beside comm pi)" ;;
  *)
    check fail "C1: unfiltered vantage set reproduces the fm-zpdvi symptom (got [$(printf '%s' "$verdicts_all" | tr '\n' ';')])" ;;
esac

# ---- per-branch pin: each foreign helper is a comm-strength vantage beside pi ----
# kimi helper: stable pid, pin directly.
if [ -n "$kimi_pid" ]; then
  pv=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$pane_pid" "$kimi_pid" 2>/dev/null || true)
  echo "probe leaves=[$kimi_pid] (kimi): [$(printf '%s' "$pv" | tr '\n' ';')]"
  case "$pv" in
    *"comm kimi"*)
      case "$pv" in
        *"comm pi"*) check ok "C1: the kimi helper child is a comm-strength foreign vantage beside comm pi (the fm-zpdvi drift shape)" ;;
        *) check fail "C1: the kimi helper child chain reaches comm pi (got [$(printf '%s' "$pv" | tr '\n' ';')])" ;;
      esac ;;
    *) check fail "C1: the kimi helper child resolves comm kimi (got [$(printf '%s' "$pv" | tr '\n' ';')])" ;;
  esac
fi
# cursor helper: the frozen cursor-agent models process (the exact fm-zpdvi
# helper family), pinned directly.
cursor_leaf=$models_pid
if [ -n "$cursor_leaf" ] && [ -d "/proc/$cursor_leaf" ]; then
  pv=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$pane_pid" "$cursor_leaf" 2>/dev/null || true)
  echo "probe leaves=[$cursor_leaf] (cursor): [$(printf '%s' "$pv" | tr '\n' ';')]"
  case "$pv" in
    *"comm cursor"*)
      case "$pv" in
        *"comm pi"*) check ok "C1: the cursor-agent models helper is a comm-strength foreign vantage beside comm pi (the exact fm-zpdvi drift shape)" ;;
        *) check fail "C1: the cursor helper chain reaches comm pi (got [$(printf '%s' "$pv" | tr '\n' ';')])" ;;
      esac ;;
    *) check fail "C1: the cursor helper resolves comm cursor (got [$(printf '%s' "$pv" | tr '\n' ';')])" ;;
  esac
else
  check fail "C1: no live cursor-agent models helper was found in the pane foreground group to pin"
fi

# ---- FILTERED vantage selection (the changed guard's code, copied verbatim) ----
fg_pids=$(LC_ALL=C ps -t "${pane_tty#/dev/}" -o pid=,pgid=,tpgid= 2>/dev/null \
  | while read -r fg_pid fg_pgid fg_tpgid; do
      [ -n "$fg_pid" ] || continue
      [ "$fg_pgid" = "$fg_tpgid" ] || continue
      if [ "$fg_pid" != "$pane_pid" ] \
        && [ "$pane_self_verdict" = "comm $expect_harness" ]; then
        leaf_verdict=$("$ROOT/bin/fm-harness.sh" ancestry "$fg_pid" 2>/dev/null || true)
        leaf_strength=${leaf_verdict%% *}
        leaf_named=${leaf_verdict#* }
        # Foreign harness helper nested under the expected agent.
        if [ "$leaf_strength" = comm ] && [ "$leaf_named" != "$expect_harness" ]; then
          continue
        fi
      fi
      printf '%s ' "$fg_pid"
    done)
echo "filtered fg pids:   [$fg_pids]"
# shellcheck disable=SC2086
verdicts=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$pane_pid" $fg_pids 2>/dev/null || true)
echo "filtered ancestry verdicts:   [$(printf '%s' "$verdicts" | tr '\n' ';')]"
case "$verdicts" in
  *"comm pi"*) check ok "C1: filtered vantage set still resolves comm pi (liveness identity kept)" ;;
  *) check fail "C1: filtered vantage set still resolves comm pi (got [$(printf '%s' "$verdicts" | tr '\n' ';')])" ;;
esac
case "$verdicts" in
  *cursor*|*kimi*)
    check fail "C1: filtered vantage set drops the foreign helpers (got [$(printf '%s' "$verdicts" | tr '\n' ';')])" ;;
  *)
    check ok "C1: filtered vantage set drops the foreign helpers (no foreign verdict remains)" ;;
esac
# The guard's reject-other loop over the filtered verdicts:
drift1=0
while read -r strength named; do
  [ -n "$strength" ] || continue
  [ "$strength" = comm ] || continue
  [ "$named" = "$expect_harness" ] || drift1=1
done <<EOF
$verdicts
EOF
[ "$drift1" = 0 ] && check ok "C1: reject-other cross-check passes on the filtered verdicts (no false DETECTION DRIFT)" \
  || check fail "C1: reject-other cross-check passes on the filtered verdicts"

echo
echo "=== Case 2 (adversarial): renamed/anonymous pane + real kimi helper child -> leaf kept, drift still reported ==="
cat > "$LAB/pane-b.sh" <<EOF
#!/bin/bash
env HOME="$LAB/home-kimi2" KIMI_CODE_HOME="$LAB/home-kimi2/.kimi-code" KIMI_CODE_NO_AUTO_UPDATE=1 DISABLE_AUTOUPDATER=1 "$KIMI_BIN" --auto >"$LAB/kimi2.log" 2>&1 &
echo \$! > "$LAB/kimi2.pid"
exec /bin/sleep 300
EOF
chmod +x "$LAB/pane-b.sh"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t drift: -n anon-pane -c "$LAB" -- /bin/bash "$LAB/pane-b.sh" \
  || { echo "could not launch anon pane"; exit 1; }
sleep 4

target=drift:anon-pane
pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_pid}' 2>/dev/null | tr -d ' ')
pane_tty=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$target" '#{pane_tty}' 2>/dev/null | tr -d ' ')
echo "pane_pid=$pane_pid pane_tty=$pane_tty"
echo "--- process sample on $pane_tty (pid comm ppid pgid tpgid) ---"
LC_ALL=C ps -t "${pane_tty#/dev/}" -o pid=,comm=,ppid=,pgid=,tpgid= 2>/dev/null

pane_self_verdict=$("$ROOT/bin/fm-harness.sh" ancestry "$pane_pid" 2>/dev/null || true)
echo "pane_self_verdict=[$pane_self_verdict]"
[ "$pane_self_verdict" != "comm pi" ] && check ok "C2: pane is NOT the expected harness at comm strength (renamed-agent shape)" \
  || check fail "C2: pane is NOT the expected harness at comm strength (got '$pane_self_verdict')"

fg_pids=$(LC_ALL=C ps -t "${pane_tty#/dev/}" -o pid=,pgid=,tpgid= 2>/dev/null \
  | while read -r fg_pid fg_pgid fg_tpgid; do
      [ -n "$fg_pid" ] || continue
      [ "$fg_pgid" = "$fg_tpgid" ] || continue
      if [ "$fg_pid" != "$pane_pid" ] \
        && [ "$pane_self_verdict" = "comm $expect_harness" ]; then
        leaf_verdict=$("$ROOT/bin/fm-harness.sh" ancestry "$fg_pid" 2>/dev/null || true)
        leaf_strength=${leaf_verdict%% *}
        leaf_named=${leaf_verdict#* }
        if [ "$leaf_strength" = comm ] && [ "$leaf_named" != "$expect_harness" ]; then
          continue
        fi
      fi
      printf '%s ' "$fg_pid"
    done)
echo "filtered fg pids:   [$fg_pids]"
# shellcheck disable=SC2086
verdicts=$("$ROOT/bin/fm-harness.sh" ancestry-descent "$pane_pid" $fg_pids 2>/dev/null || true)
echo "filtered ancestry verdicts:   [$(printf '%s' "$verdicts" | tr '\n' ';')]"
case "$verdicts" in
  *kimi*|*cursor*)
    check ok "C2: the foreign helper leaf is KEPT when the pane is not the expected harness" ;;
  *)
    check fail "C2: the foreign helper leaf is KEPT when the pane is not the expected harness (got [$(printf '%s' "$verdicts" | tr '\n' ';')])" ;;
esac
drift2=0
while read -r strength named; do
  [ -n "$strength" ] || continue
  [ "$strength" = comm ] || continue
  [ "$named" = "$expect_harness" ] || drift2=1
done <<EOF
$verdicts
EOF
[ "$drift2" = 1 ] && check ok "C2: reject-other cross-check still reports DETECTION DRIFT (reject-other not weakened)" \
  || check fail "C2: reject-other cross-check still reports DETECTION DRIFT"

echo
echo "RESULT: $FAILURES failure(s)"
exit "$FAILURES"
