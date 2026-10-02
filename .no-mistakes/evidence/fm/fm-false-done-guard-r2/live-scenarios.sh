#!/usr/bin/env bash
# Live drive of the ship-done gate against a disposable lab FM_HOME with real git repos.
set -u
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/fakebin"
# Disposable forge endpoint: answers one PR's state (the real forge cannot hold a disposable PR).
cat > "$LAB/fakebin/gh" <<'G'
#!/usr/bin/env bash
case "${1:-}" in api) printf 'state=%s\nmerged=false\n' "${GH_STATE:-OPEN}";; pr) echo "";; *) exit 1;; esac
G
cp "$LAB/fakebin/gh" "$LAB/fakebin/gh-axi"; chmod +x "$LAB/fakebin/"*
export FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
unset FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE
PR=https://github.com/example/repo/pull/7
mkship() { # id
  local id=$1
  git init -q --bare "$LAB/remotes/$id.git"
  git init -q -b main "$LAB/projects/$id"
  git -C "$LAB/projects/$id" commit -q --allow-empty -m base
  git -C "$LAB/projects/$id" remote add origin "$LAB/remotes/$id.git"
  git -C "$LAB/projects/$id" push -q origin main
  git -C "$LAB/projects/$id" checkout -q -b "fm/$id"
  echo x > "$LAB/projects/$id/f"; git -C "$LAB/projects/$id" add f; git -C "$LAB/projects/$id" commit -qm work
  printf 'window=nolab:fm-%s\nworktree=%s\nkind=ship\nmode=no-mistakes\n' "$id" "$LAB/projects/$id" > "$LAB/state/$id.meta"
}
publish() { git -C "$LAB/projects/$1" push -q -u origin "fm/$1"; git -C "$LAB/projects/$1" remote set-url origin https://github.com/example/repo.git; }
say() { printf '\n### %s\n' "$*"; }
cs() { FM_CREW_STATE_NO_FORGE=1 "$R/bin/fm-crew-state.sh" "$1" 2>&1; }
gd() { "$R/bin/fm-done-guard.sh" check "$1" 2>&1; echo "exit=$?"; }

say "S1 unpushed ship reports done: implementation complete"
mkship s1; echo 'done: implementation complete' > "$LAB/state/s1.status"
gd s1; cs s1

say "S2 pushed branch, no PR named (offline gate)"
mkship s2; publish s2; echo 'done: implementation complete' > "$LAB/state/s2.status"
FM_DONE_GUARD_NO_FORGE=1 gd s2

say "S3 pushed branch + forge-confirmed open PR"
mkship s3; publish s3; echo "done: PR $PR checks green" > "$LAB/state/s3.status"
gd s3; cs s3

say "S4 adversarial: names a PR but never pushed own branch"
mkship s4; git -C "$LAB/projects/s4" remote set-url origin https://github.com/example/repo.git; echo "done: PR $PR checks green" > "$LAB/state/s4.status"
gd s4

say "S5 adversarial: PR closed without merge receipt"
mkship s5; publish s5; echo "done: PR $PR checks green" > "$LAB/state/s5.status"
GH_STATE=CLOSED gd s5

say "S6 PR merged, receipt recorded, branch pruned (offline)"
mkship s6; echo "pr=$PR" >> "$LAB/state/s6.meta"; echo 'done: shipped' > "$LAB/state/s6.status"
( . "$R/bin/fm-pr-lib.sh"; fm_pr_poll_merge_mark_notified "$LAB/state" s6 github github.com example/repo 7 )
ls "$LAB/state" | grep s6
FM_DONE_GUARD_NO_FORGE=1 gd s6; FM_DONE_GUARD_NO_FORGE=1 cs s6

say "S7 fleet-snapshot path: crew-state over a captured status copy (FM_CREW_STATE_STATUS_OVERRIDE)"
SNAP=$(mktemp -d "$LAB/snap.XXXX"); cp "$LAB/state/s6.status" "$LAB/state/s6.meta" "$SNAP/"
FM_DONE_GUARD_NO_FORGE=1 FM_CREW_STATE_STATUS_OVERRIDE="$SNAP/s6.status" cs s6

say "S8 adversarial: merge receipt for a different PR (#8)"
mkship s8; echo "done: PR $PR checks green" > "$LAB/state/s8.status"
( . "$R/bin/fm-pr-lib.sh"; fm_pr_poll_merge_mark_notified "$LAB/state" s8 github github.com example/repo 8 )
FM_DONE_GUARD_NO_FORGE=1 gd s8

say "S9 scout + local-only skip the gate"
mkship s9; sed -i 's/mode=no-mistakes/mode=local-only/' "$LAB/state/s9.meta"; echo 'done: ready in branch fm/s9' > "$LAB/state/s9.status"; gd s9

say "S10 main-actor wake drain: does the outcome backstop surface the refused s1 done?"
"$R/bin/fm-wake-drain.sh" 2>&1 | grep -nE 'BACKSTOP|s1|s6|s3' || echo "(no backstop/s1 lines in drain output)"
