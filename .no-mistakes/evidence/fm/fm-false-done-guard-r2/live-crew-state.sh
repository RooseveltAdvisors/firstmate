#!/usr/bin/env bash
# Live drive of fm-crew-state.sh against real idle tmux panes on a private lab socket.
set -u
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/nm"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX
trap 'tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
cat > "$LAB/fakebin/gh" <<'G'
#!/usr/bin/env bash
case "${1:-}" in api) printf 'state=%s\nmerged=false\n' "${GH_STATE:-OPEN}";; *) exit 1;; esac
G
# No no-mistakes run exists for these tasks (keeps the real daemon untouched).
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/fakebin/no-mistakes"
cp "$LAB/fakebin/gh" "$LAB/fakebin/gh-axi"; chmod +x "$LAB/fakebin/"*
export FM_HOME="$LAB" NM_HOME="$LAB/nm" PATH="$LAB/fakebin:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE
tmux new-session -d -s lab -n base sleep 900
PR=https://github.com/example/repo/pull/7
mkship() {
  local id=$1
  git init -q --bare "$LAB/remotes/$id.git"; git init -q -b main "$LAB/projects/$id"
  git -C "$LAB/projects/$id" commit -q --allow-empty -m base
  git -C "$LAB/projects/$id" remote add origin "$LAB/remotes/$id.git"; git -C "$LAB/projects/$id" push -q origin main
  git -C "$LAB/projects/$id" checkout -q -b "fm/$id"
  echo x > "$LAB/projects/$id/f"; git -C "$LAB/projects/$id" add f; git -C "$LAB/projects/$id" commit -qm work
  printf 'window=lab:fm-%s\nworktree=%s\nkind=ship\nmode=no-mistakes\nharness=claude\n' "$id" "$LAB/projects/$id" > "$LAB/state/$id.meta"
  tmux new-window -d -t lab -n "fm-$id" sleep 900
  gen=$("$R/bin/fm-busy-event.sh" arm "$LAB/state" "$id"); "$R/bin/fm-busy-event.sh" apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event stop
}
publish() { git -C "$LAB/projects/$1" push -q -u origin "fm/$1"; git -C "$LAB/projects/$1" remote set-url origin https://github.com/example/repo.git; }
say() { printf '\n### %s\n' "$*"; }
cs() { FM_CREW_STATE_NO_FORGE=1 "$R/bin/fm-crew-state.sh" "$1" 2>&1; }

say "C1 unpushed ship 'done: implementation complete' -> crew-state must NOT read done"
mkship c1; echo 'done: implementation complete' > "$LAB/state/c1.status"; cs c1

say "C2 pushed + forge-confirmed open PR -> crew-state reads done"
mkship c2; publish c2; echo "done: PR $PR checks green" > "$LAB/state/c2.status"; cs c2

say "C3 PR merged after done; receipt recorded, branch never on remote (squash-pruned), offline -> done"
mkship c3; echo "pr=$PR" >> "$LAB/state/c3.meta"; echo "done: PR $PR checks green" > "$LAB/state/c3.status"
( . "$R/bin/fm-pr-lib.sh"; fm_pr_poll_merge_mark_notified "$LAB/state" c3 github github.com example/repo 7 )
FM_DONE_GUARD_NO_FORGE=1 cs c3

say "C4 same merged ship read via fleet-snapshot captured copy (FM_CREW_STATE_STATUS_OVERRIDE) -> done"
SNAP=$(mktemp -d); cp "$LAB/state/c3.status" "$LAB/state/c3.meta" "$SNAP/"
FM_DONE_GUARD_NO_FORGE=1 FM_CREW_STATE_STATUS_OVERRIDE="$SNAP/c3.status" cs c3; rm -rf "$SNAP"

say "C5 adversarial: PR CLOSED, no receipt -> not done"
mkship c5; publish c5; echo "done: PR $PR checks green" > "$LAB/state/c5.status"; GH_STATE=CLOSED cs c5

say "C6 fleet snapshot over the lab home (consumer of crew-state)"
FM_DONE_GUARD_NO_FORGE=1 FM_CREW_STATE_NO_FORGE=1 "$R/bin/fm-fleet-snapshot.sh" 2>/dev/null | jq -c ".. | objects | select(.id? and (.id|test(\"^c[1-5]$\"))) | {id, crew_state: (.crew_state // .state // .current_state)}" 2>&1 | head; echo "--- raw state lines:"; FM_DONE_GUARD_NO_FORGE=1 FM_CREW_STATE_NO_FORGE=1 "$R/bin/fm-fleet-snapshot.sh" 2>/dev/null | grep -nE "state: (done|unknown)" | head
