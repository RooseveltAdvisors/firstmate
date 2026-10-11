#!/usr/bin/env bash
# Drives the real bin/fm-crew-state.sh with a disposable state dir + git worktree.
# Only `no-mistakes` (daemon run record) is stubbed; gh/gh-axi are the REAL CLIs hitting github.com.
set -u
ROOT=$1; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-crewstate-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
TERMSTEPS='steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,300
  rebase,completed,1,437
  review,completed,0,1080445
  test,completed,2,188608
  document,completed,0,23936
  lint,completed,0,33790
  push,completed,0,2192
  pr,completed,0,17545
  ci,failed,1,18495681'
FB=$LAB/fakebin; mkdir -p "$FB"
awk 'NR>=85 && /^  cat > "\$fb\/no-mistakes"/{f=1;next} f&&/^SH$/{exit} f' "$ROOT/tests/fm-crew-state.test.sh" > "$FB/no-mistakes"; chmod +x "$FB/no-mistakes"
scenario() { # name pr status outcome? cilog
  local name=$1 pr=$2 st=$3 oc=$4 log=$5 d="$LAB/$1" head
  mkdir -p "$d/state" "$d/wt"; git -C "$d/wt" init -q; git -C "$d/wt" -c user.name=t -c user.email=t@x commit -q --allow-empty -m i
  git -C "$d/wt" checkout -q -b fm/lab-$name; head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" update-ref refs/remotes/origin/main "$head"
  printf 'window=fm:fm-%s\nworktree=%s\nkind=ship\n' "$name" "$d/wt" > "$d/state/$name.meta"
  export FM_FAKE_AXI_STATUS="run:
  id: \"01LAB$name\"
  branch: fm/lab-$name
  status: $st
  head: \"$head\"
  pr: \"${PRURL:-https://github.com/kunchenguid/firstmate/pull/$pr}\"
  findings: none
${STEPS:-$TERMSTEPS}
${oc:+outcome: $oc
}${oc:+error: \"cancelled: aborted by user\"}"
  export FM_FAKE_CI_LOGS="$log"
  echo "=== $name (PR #$pr live rollup: $(gh api graphql -f query="query{repository(owner:\"kunchenguid\",name:\"firstmate\"){pullRequest(number:$pr){commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}" --jq '.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.state'); status=$st outcome=${oc:-<none>} ${EXTRA:-})"
  env ${EXTRA:-} PATH="$FB:$PATH" FM_STATE_OVERRIDE="$d/state" FM_HOME="$d" "$ROOT/bin/fm-crew-state.sh" "$name" 2>&1 | sed 's/^/  /'
}
REARM='CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
base branch advanced (e31bc6e620ca..1f3e769616fd), re-arming CI monitor timeout
error: context canceled'
PLAIN='all CI checks passed - still monitoring until merged or closed
error: context canceled'
RELAPSE='all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: 1 CI check failing'
scenario cancelled-rearm-green 6460 cancelled cancelled "$REARM"
scenario cancelled-statusonly-rearm-green 6460 cancelled "" "$REARM"
scenario cancelled-plain-green 6460 cancelled cancelled "$PLAIN"
scenario cancelled-rearm-red 7057 cancelled cancelled "$REARM"
EXTRA=FM_CREW_STATE_NO_FORGE=1 scenario cancelled-rearm-noforge 6460 cancelled cancelled "$REARM"
scenario cancelled-rearm-relapse 6460 cancelled cancelled "$RELAPSE"
# live (running) re-arm must keep log verdict even when forge is red/off
LIVESTEPS='  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0'
LIVEREARM='all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout'
STEPS=$LIVESTEPS scenario live-rearm-forge-red 7057 running "" "$LIVEREARM"
STEPS=$LIVESTEPS EXTRA=FM_CREW_STATE_NO_FORGE=1 scenario live-rearm-noforge 6460 running "" "$LIVEREARM"
STEPS=$LIVESTEPS PRURL=https://gitlab.com/o/r/-/merge_requests/2 scenario live-rearm-gitlab 0 running "" "$LIVEREARM"
