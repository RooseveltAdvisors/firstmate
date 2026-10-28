#!/usr/bin/env bash
# Live CLI drive of the fm-v0kjm lease turn-token contract against a disposable
# lab home: the real bin/fm-lease.sh and the real guarded repair script
# bin/fm-control.sh. A long-lived sleeper stands in for the session-lock
# holder (the harness pid) so the record test (pid alive + lock line 1) holds.
# Usage: cli-adversarial.sh <code-root>
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
S=$LAB/state
sleep 900 & HOLDER=$!
sleep 900 & OTHER=$!
cleanup() { kill "$HOLDER" "$OTHER" 2>/dev/null; TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
printf '%s\n' "$HOLDER" > "$S/.lock"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s fmlab -n fm-fm-g2jj0 -x 160 -y 40 cat
SOCK=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display -p -t fmlab '#{socket_path},#{pid},#{session_id}')
LAB_TMUX="${SOCK%\$*}${SOCK##*\$}"
mkdir -p "$LAB/projects/g2jj0"
mkdir -p "$LAB/projects/g2jj0-wt"
printf 'project=%s\nworktree=%s\nwindow=fmlab:fm-fm-g2jj0\nbackend=tmux\nharness=claude\nendpoint_task_id=fm-g2jj0\n' "$LAB/projects/g2jj0" "$LAB/projects/g2jj0-wt" > "$S/fm-g2jj0.meta"

PASSES=0 FAILS=0
ok() { PASSES=$((PASSES + 1)); printf 'PASS %s\n' "$1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; }
lenv() { env -i HOME="$HOME" PATH="$PATH" LANG=C.UTF-8 FM_HOME="$LAB" TMUX="$LAB_TMUX" TMUX_TMPDIR="$LAB/tmux" PI_CODING_AGENT=true "$@"; }
lease() { lenv "$@"; }
as_branch() { local turn=$1; shift; lenv FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$HOLDER" FM_BRANCH_REPORT_TURN="$turn" "$@"; }
as_main() { lenv FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID="$HOLDER" "$@"; }
check() { lease "$ROOT/bin/fm-lease.sh" check "$1" 2>&1; }
fields() { awk -F '\t' '{ print NF }' "$S/.lease-$1"; }
REFUSAL="error: claim refused - task 'fm-g2jj0' is leased to the branch supervision actor (state/.lease-fm-g2jj0)"
GUARD="error: lifecycle control (fm-control) refused - task 'fm-g2jj0' is leased to the branch supervision actor (state/.lease-fm-g2jj0)"

echo "== C1/C2 supervision-host turn record: live turn refuses main, ended turn frees it"
printf 'turn=host-4242-1793200000.3\nrows=7\ntasks=fm-g2jj0\nunscoped=0\nwake=signal: fm-g2jj0 blocked\nposture=attended\n' > "$S/.supervision-host-turn"
as_branch host-4242-1793200000.3 "$ROOT/bin/fm-lease.sh" claim fm-g2jj0 --actor branch
line=$(cat "$S/.lease-fm-g2jj0")
[ "$line" = "$(printf 'branch\t%s\t%s\tturn:host-4242-1793200000.3' "$HOLDER" "$(cut -f3 "$S/.lease-fm-g2jj0")")" ] \
  && ok "host-path branch claim records turn:host-4242-1793200000.3 as field 4" "$(printf '%s' "$line" | tr '\t' '|')" \
  || bad "host-path claim line" "$line"
case "$(check fm-g2jj0)" in *" live") ok "lease is live while .supervision-host-turn names it" "$(check fm-g2jj0)" ;; *) bad "live-turn check" "$(check fm-g2jj0)" ;; esac
out=$(as_main "$ROOT/bin/fm-lease.sh" claim fm-g2jj0 2>&1); rc=$?
[ "$rc" = 6 ] && [ "$out" = "$REFUSAL" ] && ok "main claim refused (rc 6) with the incident's exact refusal" "$out" || bad "main claim during live turn rc=$rc" "$out"
out=$(as_main "$ROOT/bin/fm-control.sh" fm-g2jj0 interrupt 2>&1); rc=$?
case "$out" in *"$GUARD"*) [ "$rc" = 6 ] && ok "main repair (fm-control interrupt) refused by the lease guard (rc 6)" "$(printf '%s' "$out" | grep -m1 'refused')" || bad "fm-control rc=$rc" "$out" ;; *) bad "fm-control was not lease-refused rc=$rc" "$out" ;; esac
rm -f "$S/.supervision-host-turn"
case "$(check fm-g2jj0)" in *" stale") ok "turn record gone: same lease reads stale while holder pid $HOLDER lives and holds the lock" "$(check fm-g2jj0)" ;; *) bad "ended-turn check" "$(check fm-g2jj0)" ;; esac
out=$(as_main "$ROOT/bin/fm-control.sh" fm-g2jj0 interrupt 2>&1); rc=$?
case "$out" in *"leased to the branch"*) bad "fm-control still lease-refused after the turn ended rc=$rc" "$out" ;; *) ok "main repair (fm-control interrupt) passes the lease guard after the turn ended (rc $rc)" "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')" ;; esac
out=$(as_main "$ROOT/bin/fm-lease.sh" claim fm-g2jj0 2>&1); rc=$?
[ "$rc" = 0 ] && case "$(check fm-g2jj0)" in "main $HOLDER "*" live") true ;; *) false ;; esac \
  && ok "main claims the task" "$(check fm-g2jj0)" || bad "main claim after ended turn rc=$rc" "$out $(check fm-g2jj0)"
as_main "$ROOT/bin/fm-lease.sh" release fm-g2jj0

echo "== C3 a symlinked turn record never vouches for a token"
printf 'turn=9.1\n' > "$LAB/elsewhere-turn"
ln -s "$LAB/elsewhere-turn" "$S/.branch-turn"
printf 'branch\t%s\t100\tturn:9.1\n' "$HOLDER" > "$S/.lease-fm-g2jj0"
case "$(check fm-g2jj0)" in *" stale") ok "symlinked .branch-turn naming turn=9.1 leaves lease turn:9.1 stale" ;; *) bad "symlink check" "$(check fm-g2jj0)" ;; esac
rm -f "$S/.branch-turn"; cp "$LAB/elsewhere-turn" "$S/.branch-turn"
case "$(check fm-g2jj0)" in *" live") ok "the same content as a regular file makes it live (only the symlink differed)" ;; *) bad "regular record check" "$(check fm-g2jj0)" ;; esac

echo "== C4/C5 exact-match only: no prefix, superset, or non-turn-line match"
printf 'turn=9.2\n' > "$S/.branch-turn"
for tok in 9.21 9 9.2.1 9.20; do
  printf 'branch\t%s\t100\tturn:%s\n' "$HOLDER" "$tok" > "$S/.lease-fm-g2jj0"
  case "$(check fm-g2jj0)" in *" stale") ok "record turn=9.2 does not vouch for lease turn:$tok" ;; *) bad "token $tok" "$(check fm-g2jj0)" ;; esac
done
printf 'branch\t%s\t100\tturn:9.2\n' "$HOLDER" > "$S/.lease-fm-g2jj0"
case "$(check fm-g2jj0)" in *" live") ok "record turn=9.2 vouches for exactly turn:9.2" ;; *) bad "exact token" "$(check fm-g2jj0)" ;; esac
rm -f "$S/.branch-turn"
printf 'turn=host-1-2.1\nrows=9.5\ntasks=9.5\nwake=turn=9.5\n' > "$S/.supervision-host-turn"
printf 'branch\t%s\t100\tturn:9.5\n' "$HOLDER" > "$S/.lease-fm-g2jj0"
case "$(check fm-g2jj0)" in *" stale") ok "a token named only on rows=/tasks=/wake= lines is not a live turn" ;; *) bad "non-turn line" "$(check fm-g2jj0)" ;; esac
rm -f "$S/.supervision-host-turn"

echo "== C6 malformed recorded field 4 falls back to the pre-token pid-only verdict"
for f4 in 'turn:bad token!' 'xturn:9.2' 'turn:' 'turn:9.2;id' 'garbage'; do
  printf 'branch\t%s\t100\t%s\n' "$HOLDER" "$f4" > "$S/.lease-fm-g2jj0"
  case "$(check fm-g2jj0)" in *" live") ok "field 4 '$f4' reads as no token: live holder keeps the legacy verdict" ;; *) bad "malformed '$f4'" "$(check fm-g2jj0)" ;; esac
done
rm -f "$S/.lease-fm-g2jj0"

echo "== C7 forged FM_BRANCH_REPORT_TURN values are never recorded"
for forged in '9.2;rm -rf ~' '../../etc' 'a b' '$(id)' 'turn:9.2' $'9.2\tx'; do
  rm -f "$S/.lease-fm-g2jj0"
  as_branch "$forged" "$ROOT/bin/fm-lease.sh" claim fm-g2jj0 --actor branch
  [ "$(fields fm-g2jj0)" = 3 ] && ok "env token $(printf '%q' "$forged") -> 3-field lease, no token recorded" || bad "forged $(printf '%q' "$forged")" "$(cat "$S/.lease-fm-g2jj0")"
done
rm -f "$S/.lease-fm-g2jj0"

echo "== C8 main never carries a turn token"
lenv FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID="$HOLDER" FM_BRANCH_REPORT_TURN=9.2 "$ROOT/bin/fm-lease.sh" claim fm-g2jj0
[ "$(fields fm-g2jj0)" = 3 ] && ok "main claim with FM_BRANCH_REPORT_TURN=9.2 in its env records 3 fields" "$(tr '\t' '|' < "$S/.lease-fm-g2jj0")" || bad "main token" "$(cat "$S/.lease-fm-g2jj0")"
as_main "$ROOT/bin/fm-lease.sh" release fm-g2jj0

echo "== C9 a live turn record never revives a dead or non-holder pid"
printf 'turn=9.3\n' > "$S/.branch-turn"
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
printf 'branch\t%s\t100\tturn:9.3\n' "$DEAD" > "$S/.lease-fm-g2jj0"
case "$(check fm-g2jj0)" in *" stale") ok "dead pid $DEAD with a live turn record is stale" ;; *) bad "dead pid" "$(check fm-g2jj0)" ;; esac
printf 'branch\t%s\t100\tturn:9.3\n' "$OTHER" > "$S/.lease-fm-g2jj0"
case "$(check fm-g2jj0)" in *" stale") ok "live pid $OTHER that is not the lock holder is stale despite the live turn record" ;; *) bad "non-holder pid" "$(check fm-g2jj0)" ;; esac
rm -f "$S/.branch-turn" "$S/.lease-fm-g2jj0"

echo "== C10 a legacy 3-field branch lease keeps the pid-only verdict byte for byte"
printf 'branch\t%s\t123\n' "$HOLDER" > "$S/.lease-fm-g2jj0"
before=$(cat "$S/.lease-fm-g2jj0")
case "$(check fm-g2jj0)" in *" live") ok "legacy lease with live lock holder reads live" ;; *) bad "legacy check" "$(check fm-g2jj0)" ;; esac
out=$(as_main "$ROOT/bin/fm-lease.sh" claim fm-g2jj0 2>&1); rc=$?
[ "$rc" = 6 ] && [ "$out" = "$REFUSAL" ] && [ "$(cat "$S/.lease-fm-g2jj0")" = "$before" ] && ok "main stays refused by the legacy lease, which is left untouched" || bad "legacy refusal rc=$rc" "$out"
rm -f "$S/.lease-fm-g2jj0"

echo "== C11 sweep removes exactly the provably stale leases"
printf 'turn=9.4\n' > "$S/.branch-turn"
printf 'branch\t%s\t100\tturn:9.4\n' "$HOLDER" > "$S/.lease-live-turn"
printf 'branch\t%s\t100\tturn:9.3\n' "$HOLDER" > "$S/.lease-ended-turn"
printf 'branch\t%s\t100\n' "$HOLDER" > "$S/.lease-legacy"
printf 'main\t%s\t100\n' "$HOLDER" > "$S/.lease-mainheld"
lease "$ROOT/bin/fm-lease.sh" sweep
left=$(cd "$S" && ls -1 .lease-* 2>/dev/null | grep -v '\.lock$' | tr '\n' ' ')
[ "$left" = ".lease-legacy .lease-live-turn .lease-mainheld " ] && ok "sweep kept live-turn, legacy, and main leases; removed only the ended turn's" "$left" || bad "sweep left: $left"

printf '\nCLI_SUMMARY passes=%s fails=%s\n' "$PASSES" "$FAILS"
[ "$FAILS" = 0 ]
