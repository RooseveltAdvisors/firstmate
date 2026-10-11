#!/usr/bin/env bash
# Live drive of fm-home-summary-refresh.sh backoff against a disposable lab FM_HOME.
set -u
W=$1 LAB=$2
R() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=$LAB "$@"; }
S=$LAB/state; BO=$S/.home-summary-backoff; LOG=$S/.home-summary-refresh.log
hold_lock() { R bash -c ". '$W/bin/fm-timeout-lib.sh'; . '$W/bin/fm-wake-lib.sh'; fm_lock_acquire_wait '$S/.home-summary-refresh.lock'; echo held; sleep $1; fm_lock_release '$S/.home-summary-refresh.lock'" & sleep 0.5; }
show() { echo "  backoff file: $(cat $BO 2>/dev/null || echo '<absent>')  now=$(date +%s)"; echo "  log lines: $(wc -l < $LOG 2>/dev/null || echo 0)"; [ -f $LOG ] && echo "  last log: $(tail -n1 $LOG)"; }
gen() { jq -r .generated_epoch $S/home-summary.json; }

echo "== S1: best-effort trigger hits the deadline (lock held by a slow refresh, FM_HOME_SUMMARY_TIMEOUT=2)"
hold_lock 30
t0=$(date +%s); R FM_HOME_SUMMARY_TIMEOUT=2 $W/bin/fm-home-summary-refresh.sh --best-effort; echo "  rc=$? elapsed=$(( $(date +%s)-t0 ))s"; show

echo "== S2: best-effort trigger inside the backoff window exits 0 without running"
n=$(wc -l < $LOG); t0=$(date +%s); R FM_HOME_SUMMARY_TIMEOUT=2 $W/bin/fm-home-summary-refresh.sh --best-effort; echo "  rc=$? elapsed=$(( $(date +%s)-t0 ))s log-lines-before=$n"; show

echo "== S3: direct caller inside the window still attempts and fails loudly"
t0=$(date +%s); R FM_HOME_SUMMARY_TIMEOUT=2 $W/bin/fm-home-summary-refresh.sh; echo "  rc=$? elapsed=$(( $(date +%s)-t0 ))s"; show

echo "== S4: window expires (rewrite until=0), second consecutive failure doubles to 120s"
read -r c _ < $BO; printf '%s 0\n' $c > $BO
R FM_HOME_SUMMARY_TIMEOUT=2 $W/bin/fm-home-summary-refresh.sh --best-effort; echo "  rc=$?"; show

echo "== S5: idle-only watcher trigger while the lock is busy leaves the record untouched"
before=$(cat $BO); printf '%s 0\n' "${before%% *}" > $BO; before=$(cat $BO)
R FM_HOME_SUMMARY_IF_IDLE=1 FM_HOME_SUMMARY_TIMEOUT=2 $W/bin/fm-home-summary-refresh.sh --best-effort; echo "  rc=$? before='$before'"; show

echo "== S6: long streak caps at 3600s"
printf '9 0\n' > $BO
R FM_HOME_SUMMARY_TIMEOUT=2 $W/bin/fm-home-summary-refresh.sh --best-effort; echo "  rc=$?"; show
kill %1 2>/dev/null; wait 2>/dev/null; rm -rf $S/.home-summary-refresh.lock 2>/dev/null

echo "== S7: lock free, window expired, real producer publishes, record cleared"
printf '10 0\n' > $BO; g0=$(gen); sleep 1.1
R $W/bin/fm-home-summary-refresh.sh --best-effort; echo "  rc=$? generated_epoch $g0 -> $(gen)"; show

echo "== S8: worker-side producer failure (stub failing producer in a copied bin) counts toward backoff, logged once"
FB=$(mktemp -d); cp -a $W/bin $FB/bin; printf '#!/usr/bin/env bash\necho "producer exploded" >&2\nexit 7\n' > $FB/bin/fm-fleet-snapshot.sh
n=$(wc -l < $LOG)
R $FB/bin/fm-home-summary-refresh.sh --best-effort; echo "  rc=$? log-lines-before=$n"; show
rm -rf $FB
