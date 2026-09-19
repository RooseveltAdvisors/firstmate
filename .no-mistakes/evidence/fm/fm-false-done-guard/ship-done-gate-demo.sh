#!/usr/bin/env bash
# End-to-end demonstration of the ship-done acceptance gate against the REAL
# GitHub forge. One ship task walks the lifecycle a crewmate actually walks:
# local commit -> push -> open PR. The operator surface is bin/fm-done-guard.sh.
#
# Honest about the fixture: the branch is pushed to a LOCAL bare remote (no
# writes to the real repository), then origin's URL is pointed at the task's
# real repository so the repo-identity check and the live PR read are genuine.
# PR numbers below are real, read live from github.com/kunchenguid/firstmate.
set -u
REPO_ROOT=$1
WORK=$2
OPEN_PR=$3
CLOSED_PR=$4
FOREIGN_PR=$5

GUARD="$REPO_ROOT/bin/fm-done-guard.sh"
REAL_ORIGIN=https://github.com/kunchenguid/firstmate.git

hr() { printf '\n─────────────────────────────────────────────────────────────\n%s\n─────────────────────────────────────────────────────────────\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

HOME_DIR="$WORK/fm-home"
STATE="$HOME_DIR/state"
ID=ship-demo
WT="$WORK/worktree"
BRANCH="fm/$ID"
mkdir -p "$STATE" "$WORK/upstream.git"

# A real repository with a real remote to push to.
git init -q --bare "$WORK/upstream.git"
git init -q "$WORK/repo"
git -C "$WORK/repo" -c user.name=demo -c user.email=demo@example.invalid commit -q --allow-empty -m base
git -C "$WORK/repo" remote add origin "$WORK/upstream.git"
git -C "$WORK/repo" push -q origin HEAD:refs/heads/main
git -C "$WORK/repo" worktree add -q -b "$BRANCH" "$WT"

cat > "$STATE/$ID.meta" <<META
window=firstmate:fm-$ID
kind=ship
mode=no-mistakes
worktree=$WT
META

# Record what the worker is told when its done is refused.
cat > "$WORK/fake-send" <<'SH'
#!/usr/bin/env bash
printf 'to task: %s\nmessage: %s\n' "$1" "$2"
exit 0
SH
chmod +x "$WORK/fake-send"

check() {
  local rc=0
  printf '$ fm-done-guard.sh check %s\n' "$ID"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$GUARD" check "$ID" || rc=$?
  printf '[exit %s]\n' "$rc"
}
apply() {
  local rc=0
  printf '$ fm-done-guard.sh apply %s\n' "$ID"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DONE_GUARD_SEND="$WORK/fake-send" \
    "$GUARD" apply "$ID" || rc=$?
  printf '[exit %s]\n' "$rc"
}

hr "1. Worker commits locally and reports done (the reported failure mode)"
printf 'feature\n' > "$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" -c user.name=crew -c user.email=crew@example.invalid commit -q -m "implement the feature"
printf 'done: implementation complete, all tests pass\n' > "$STATE/$ID.status"
printf 'worker wrote to state/%s.status: %s\n' "$ID" "$(cat "$STATE/$ID.status")"
run bash -c 'cd "$1" && git -C "$1" log --oneline -1' _ "$WT"
check

hr "2. The same refused done, applied: the worker is steered to push"
apply

hr "3. Worker pushes the branch but opens no PR"
git -C "$WT" push -q -u origin "$BRANCH"
printf 'remote-tracking ref now present: %s\n' "$(git -C "$WT" for-each-ref --format='%(refname)' "refs/remotes/origin/$BRANCH")"
printf 'done: pushed the branch, work is finished\n' > "$STATE/$ID.status"
printf 'worker wrote to state/%s.status: %s\n' "$ID" "$(cat "$STATE/$ID.status")"
check

hr "4. Worker names a PR that the forge reports CLOSED (live read)"
git -C "$WT" remote set-url origin "$REAL_ORIGIN"
printf 'done: PR %s checks green\n' "$CLOSED_PR" > "$STATE/$ID.status"
printf 'worker wrote to state/%s.status: %s\n' "$ID" "$(cat "$STATE/$ID.status")"
check

hr "5. Worker names an open PR that belongs to a DIFFERENT repository"
printf 'done: PR %s checks green\n' "$FOREIGN_PR" > "$STATE/$ID.status"
printf 'worker wrote to state/%s.status: %s\n' "$ID" "$(cat "$STATE/$ID.status")"
check

hr "6. Worker pushes AND opens a PR the forge reports OPEN (live read)"
printf 'done: PR %s checks green\n' "$OPEN_PR" > "$STATE/$ID.status"
printf 'worker wrote to state/%s.status: %s\n' "$ID" "$(cat "$STATE/$ID.status")"
check

hr "7. Non-PR work is untouched: a scout done still lands"
SCOUT=scout-demo
cat > "$STATE/$SCOUT.meta" <<META
window=firstmate:fm-$SCOUT
kind=scout
mode=scout
worktree=$WT
META
printf 'done: survey written to notes.md\n' > "$STATE/$SCOUT.status"
printf '$ fm-done-guard.sh check %s\n' "$SCOUT"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$GUARD" check "$SCOUT"
printf '[exit %s]\n' "$?"
