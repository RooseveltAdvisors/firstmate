#!/usr/bin/env bash
# Live driver: real firstmate CLIs against a disposable lab home + real git remote; only the forge (gh) is a disposable stub.
set -u
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-labwt.XXXXXX"); SNAP=$(mktemp -d)
trap 'rm -rf "$LAB" "$W" "$SNAP"' EXIT
mkdir -p "$LAB/bin"
cat > "$LAB/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_GH_MODE:-up}" = up ] || exit 1
case "${1:-}" in api) printf 'state=%s\nmerged=false\n' "${FAKE_GH_STATE:-OPEN}";; pr) printf '%s\n' "${FAKE_GH_PR_URL:-}";; *) exit 1;; esac
SH
cp "$LAB/bin/gh" "$LAB/bin/gh-axi"
mkdir -p "$LAB/tmux" "$LAB/nm"
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nTMUX_TMPDIR="%s" exec "%s" -L fm-lab "$@"\n' "$LAB/tmux" "$REAL_TMUX" > "$LAB/bin/tmux"
chmod +x "$LAB"/bin/*
"$LAB/bin/tmux" new-session -d -s lab -n idle sleep 600
trap '"$LAB/bin/tmux" kill-server 2>/dev/null; rm -rf "$LAB" "$W" "$SNAP"' EXIT
G() { git -c user.name=t -c user.email=t@e.invalid "$@"; }
git init -q --bare "$W/remote.git"; G init -q -b main "$W/repo"; echo a>"$W/repo/a"; G -C "$W/repo" add a; G -C "$W/repo" commit -qm init; G -C "$W/repo" remote add origin "$W/remote.git"; G -C "$W/repo" push -q origin main
mk(){ local id=$1 mode=$2 kind=${3:-ship}; G -C "$W/repo" worktree add -q -b "fm/$id" "$W/$id"; printf 'window=lab:fm-%s\nworktree=%s\nproject=%s\nkind=%s\nmode=%s\nharness=claude\n' "$id" "$W/$id" "$W/$id" "$kind" "$mode" > "$LAB/state/$id.meta"; "$LAB/bin/tmux" new-window -d -t lab -n "fm-$id" sleep 600; g=$("$R/bin/fm-busy-event.sh" arm "$LAB/state" "$id"); "$R/bin/fm-busy-event.sh" apply "$LAB/state" "$id" idle --gen "$g" --source claude-hook --event stop >/dev/null; }
ci(){ echo x>>"$W/$1/f"; G -C "$W/$1" add f; G -C "$W/$1" commit -qm c; }
pub(){ G -C "$W/$1" remote set-url origin "$W/remote.git"; G -C "$W/$1" push -q -u origin "fm/$1"; G -C "$W/$1" remote set-url origin https://github.com/example/repo.git; }
chk(){ local id=$1 label=$2; shift 2; echo "\$ fm-done-guard.sh check $id   [$label]"; env PATH="$LAB/bin:$PATH" FM_HOME="$LAB" "$@" "$R/bin/fm-done-guard.sh" check "$id"; echo "exit=$?"; }
cs(){ local id=$1; shift; echo "\$ fm-crew-state.sh $id"; env PATH="$LAB/bin:$PATH" FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 NM_HOME="$LAB/nm" "$@" timeout 60 "$R/bin/fm-crew-state.sh" "$id" 2>&1 | tail -1; }
receipt(){ ( . "$R/bin/fm-pr-lib.sh"; fm_pr_poll_merge_mark_notified "$LAB/state" "$1" github github.com example/repo "$2" ); }

echo "### S1 unpushed local commit, worker says done"
mk s1 no-mistakes; ci s1; echo 'done: implementation complete' > "$LAB/state/s1.status"
chk s1 unpushed; cs s1 FM_DONE_GUARD_NO_FORGE=1
echo; echo "### S2 pushed branch, forge has no PR"
mk s2 no-mistakes; ci s2; pub s2; echo 'done: implementation complete' > "$LAB/state/s2.status"
chk s2 "pushed, no PR"
echo; echo "### S3 pushed + open PR named in done line"
mk s3 direct-PR; ci s3; pub s3; echo 'done: PR https://github.com/example/repo/pull/7 checks green' > "$LAB/state/s3.status"
chk s3 "open PR" FAKE_GH_PR_URL=https://github.com/example/repo/pull/7
echo; echo "### S4 adversarial: PR URL claimed but forge reports CLOSED"
mk s4 no-mistakes; ci s4; pub s4; echo 'done: PR https://github.com/example/repo/pull/7 checks green' > "$LAB/state/s4.status"
chk s4 "closed PR" FAKE_GH_STATE=CLOSED
echo; echo "### S5 adversarial: forge unreachable (s3 otherwise accepted)"
chk s3 "forge down" FAKE_GH_MODE=down
echo; echo "### S6 adversarial: done names a PR in another repository"
mk s6 no-mistakes; ci s6; pub s6; echo 'done: PR https://github.com/evil/other/pull/7 green' > "$LAB/state/s6.status"
chk s6 "foreign-repo PR"
echo; echo "### S7 scout and local-only tasks are skipped"
mk s7 no-mistakes scout; ci s7; echo 'done: report written' > "$LAB/state/s7.status"; chk s7 scout
mk s8 local-only; ci s8; echo 'done: local work' > "$LAB/state/s8.status"; chk s8 local-only
echo; echo "### S9 PR merged after done, branch pruned (unpushed), merge receipt recorded, offline"
mk s9 no-mistakes; ci s9; echo 'pr=https://github.com/example/repo/pull/7' >> "$LAB/state/s9.meta"; echo 'done: shipped' > "$LAB/state/s9.status"
receipt s9 7; ls "$LAB/state" | grep '^s9'
chk s9 "receipt, NO_FORGE, forge down" FAKE_GH_MODE=down FM_DONE_GUARD_NO_FORGE=1
cs s9 FM_DONE_GUARD_NO_FORGE=1
cp "$LAB/state/s9.status" "$LAB/state/s9.meta" "$SNAP/"
echo "  (fleet-snapshot path: status+meta captured into a temp dir with no receipt)"
cs s9 FM_DONE_GUARD_NO_FORGE=1 FM_CREW_STATE_STATUS_OVERRIDE="$SNAP/s9.status" FM_CREW_STATE_META_OVERRIDE="$SNAP/s9.meta"
echo; echo "### S10 adversarial: merge receipt names a different PR (#8)"
mk s10 no-mistakes; ci s10; echo 'done: PR https://github.com/example/repo/pull/7 checks green' > "$LAB/state/s10.status"
receipt s10 8
chk s10 "foreign receipt" FM_DONE_GUARD_NO_FORGE=1
echo; echo "### S11 apply on a refused done steers the worker to push"
cat > "$LAB/fake-send" <<'SH'
#!/usr/bin/env bash
printf 'SEND %s\n' "$*" >> "$STEER_LOG"
SH
chmod +x "$LAB/fake-send"
env PATH="$LAB/bin:$PATH" FM_HOME="$LAB" FM_DONE_GUARD_NO_FORGE=1 FM_DONE_GUARD_SEND="$LAB/fake-send" STEER_LOG="$LAB/steer.log" "$R/bin/fm-done-guard.sh" apply s1; echo "exit=$?"
cat "$LAB/steer.log"
echo; echo "### S12 main wake-drain outcome backstop (offline gate)"
env PATH="$LAB/bin:$PATH" FM_HOME="$LAB" FM_DONE_GUARD_NO_FORGE=1 timeout 60 "$R/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2>&1
sed -n '/STATUS OUTCOME BACKSTOP/,/^$/p' "$LAB/drain.out" | grep -v '^●'
