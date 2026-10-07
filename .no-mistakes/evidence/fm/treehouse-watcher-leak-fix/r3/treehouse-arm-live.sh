#!/usr/bin/env bash
# Live: arm a real watcher from treehouse pool-slot copies of bin/ (base vs head).
# usage: treehouse-arm-live.sh <label> <bin-src-dir> <scratch>
label=$1 src=$2 R=$3
arm() {  # <name> <arm-script> <FM_HOME> [status-to-write]
  local name=$1 script=$2 home=$3 out="$R/$1.out" i
  echo "== $label-$name"; echo "   arm: $script  FM_HOME=$home"
  env -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$home" FM_GATE_REFUSE_BYPASS='' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ARM_CONFIRM_TIMEOUT=20 "$script" > "$out" 2>&1 &
  local ap=$!
  for i in $(seq 100); do grep -qE '^watcher: (started|FAILED)' "$out" && break; kill -0 $ap 2>/dev/null || break; sleep 0.1; done
  grep -m1 -E '^watcher:' "$out" | sed 's/^/   /'
  if grep -q '^watcher: started' "$out"; then
    printf 'done: probe\n' > "$home/state/probe.status"
  fi
  for i in $(seq 150); do kill -0 $ap 2>/dev/null || break; sleep 0.1; done
  kill -0 $ap 2>/dev/null && { echo "   arm still running after 15s; killing"; kill $ap; }
  wait $ap; echo "   arm rc=$? ; last: $(grep -E '^(signal|watcher: FAILED)' "$out" | tail -1)"
  pkill -f "$R/.*fm-watch" 2>/dev/null; true
}
mkdir -p "$R/fleethome/data" "$R/fleethome/state" "$R/fleethome/config" "$R/fleethome/projects"
s1="$R/.treehouse/pool-1/slot-1/firstmate"; mkdir -p "$s1"; cp -R "$src" "$s1/bin"
s2="$R/.treehouse/pool-2/slot-2/firstmate"; mkdir -p "$s2"/{data,state,config,projects}; cp -R "$src" "$s2/bin"
s3="$R/.treehouse/pool-3/slot-3/firstmate"; mkdir -p "$s3"/{data,state,config,projects}; cp -R "$src" "$s3/bin"
ln -s "$R/.treehouse" "$R/th-link"
arm A-stale-task-worktree-arms-for-fleet-home "$s1/bin/fm-watch-arm.sh" "$R/fleethome"
arm B-home-living-in-pool-slot "$s2/bin/fm-watch-arm.sh" "$s2"
arm C-slot-with-layout-arming-foreign-home "$s2/bin/fm-watch-arm.sh" "$R/fleethome"
arm D-home-in-slot-via-symlinked-ancestor "$R/th-link/pool-3/slot-3/firstmate/bin/fm-watch-arm.sh" "$R/th-link/pool-3/slot-3/firstmate"
