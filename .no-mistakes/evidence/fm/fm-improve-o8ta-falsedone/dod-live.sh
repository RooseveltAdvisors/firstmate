#!/usr/bin/env bash
# Live drive of the generated ship definition of done (bin/fm-brief.sh) and the
# done-claim gate (bin/fm-crew-state.sh) in a disposable lab home.
set -u
SRC=${ROOT:?run-worktree}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() { tmux -L fm-lab kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
mkdir "$LAB/fmroot"; git -C "$SRC" archive HEAD | tar -x -C "$LAB/fmroot"
R="$LAB/fmroot"
"$R/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
mkdir -p "$LAB/tmux"; export TMUX_TMPDIR="$LAB/tmux"
E() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB/home" "$@"; }

for mode in no-mistakes direct-PR; do
  echo "== DoD brief: --mode $mode"
  E "$R/bin/fm-brief.sh" "dod-$mode" some-proj --mode "$mode" >/dev/null 2>&1; echo "fm-brief exit=$?"
  sed -n '/^# Definition of done/,/^$/p' "$LAB/home/data/dod-$mode/brief.md"
  grep -c "The task is complete only when committed on your branch" "$LAB/home/data/dod-$mode/brief.md" | sed 's/^/legacy "complete only when committed" lines: /'
done

echo "== crew-state on ship task (mode=no-mistakes), real tmux lab socket"
tmux -L fm-lab new-session -d -s fm -n fm-preval -x 200 -y 50 bash --norc
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0"
wt="$LAB/wt"; git init -q -b main "$wt"
git -C "$wt" -c user.email=l@x -c user.name=l commit -q --allow-empty -m init
git -C "$wt" checkout -q -b fm/preval
git -C "$wt" update-ref refs/remotes/origin/main "$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" -c user.email=l@x -c user.name=l commit -q --allow-empty -m 'fix only in the worktree'
# isolate no-mistakes state to an empty disposable NM_HOME (no runs exist)
export NM_HOME="$LAB/nm"; mkdir -p "$NM_HOME"
S="$LAB/home/state"
printf 'window=fm:fm-preval\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nharness=claude\n' "$wt" "$wt" > "$S/preval.meta"
gen=$(E "$R/bin/fm-busy-event.sh" arm "$S" preval); E "$R/bin/fm-busy-event.sh" apply "$S" preval idle --gen "$gen" --source claude-hook --event stop >/dev/null
printf 'done: implementation complete\n' > "$S/preval.status"
echo "-- status: bare 'done: implementation complete' from the implementation commit"
E timeout 60 "$R/bin/fm-crew-state.sh" preval 2>&1 | head -5
echo "-- status: CI-ready 'done: PR <url> checks green' while the head exists only in the worker copy"
printf 'done: PR https://github.com/o/r/pull/1 checks green\n' > "$S/preval.status"
E timeout 60 "$R/bin/fm-crew-state.sh" preval 2>&1 | head -3
echo "-- same claim after the head is pushed to the branch remote"
git init -q --bare "$LAB/origin.git"; git -C "$wt" remote add origin "$LAB/origin.git"
git -C "$wt" push -q origin fm/preval
E timeout 60 "$R/bin/fm-crew-state.sh" preval 2>&1 | head -3
