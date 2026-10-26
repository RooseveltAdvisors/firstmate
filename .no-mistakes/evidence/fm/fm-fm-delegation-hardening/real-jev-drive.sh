#!/usr/bin/env bash
# Live drive against the REAL Jev service through the product's default proxy.
set -u
REPO=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M5SDV9REPXRKVD9443H5KZTR
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
trap 'rm -rf "$LAB"' EXIT
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/bin" "$LAB/projects/portal"
touch "$LAB/AGENTS.md"
cp "$REPO/bin/fm-jev-guard.sh" "$REPO/bin/fm-jev-guard.py" "$REPO/bin/fm-jev-wake-triage.sh" "$LAB/bin/"
git -C "$LAB" init -q 2>/dev/null
git -C "$LAB" -c user.email=lab@invalid -c user.name=lab commit -q --allow-empty -m init 2>/dev/null

PASS=0; FAIL=0
check() { # <label> <ok:0|1> <detail>
  if [ "$2" -eq 1 ]; then PASS=$((PASS+1)); printf 'PASS | %s | %s\n' "$1" "$3"
  else FAIL=$((FAIL+1)); printf 'FAIL | %s | %s\n' "$1" "$3"; fi
}

export FM_ROOT_OVERRIDE="$LAB" FM_HOME="$LAB"
unset FM_JEV_PROXY_BIN FM_TEST_JEV_RESPONSE FM_TEST_QUERY_LOG 2>/dev/null || true
GUARD="$LAB/bin/fm-jev-guard.sh"
echo "=== R1: ambiguous supervisor read is CLASSIFIED by the REAL Jev service (tier 3) ==="
rc=0; out=$("$GUARD" --command 'cat state/task.status' 2>&1) || rc=$?
row=$(grep 'cat state/task.status' "$LAB/state/.jev-guard-telemetry" 2>/dev/null | tail -1)
[ "$rc" -eq 0 ] && [[ "$row" == *$'\t'"allow"$'\t'"tier3"$'\t'"supervisor_approved"$'\t'* ]] && ok=1 || ok=0
check "real-Jev tier-3 classification allows a supervisor read" "$ok" "rc=$rc telemetry=$row"

echo "=== R2: project work pre-denies WITHOUT a query even with the real proxy ==="
rc=0; out=$("$GUARD" --command 'cd projects/portal && npm test' 2>&1) || rc=$?
row=$(grep 'npm test' "$LAB/state/.jev-guard-telemetry" 2>/dev/null | tail -1)
[ "$rc" -eq 2 ] && [[ "$out" == *'Project work must be delegated'* ]] && [[ "$row" == *$'\t'"deny"$'\t'"tier1"$'\t'"require_delegation"* ]] && ok=1 || ok=0
check "real-proxy project work pre-denied at tier 1 before any query" "$ok" "rc=$rc telemetry=$row out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"

echo "=== R3: retained bin/fm-jev-wake-triage.sh answers from the REAL service ==="
rc=0; out=$("$LAB/bin/fm-jev-wake-triage.sh" --class ship --age 1800 --escalation-count 1 --task labtask --last-status 'run step: waiting on CI' 2>&1) || rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
action=$(printf '%s\n' "$out" | sed -n 's/^action=//p')
choice=$(printf '%s\n' "$out" | sed -n 's/^choice=//p')
noul=$(printf '%s\n' "$out" | sed -n 's/^noul=//p')
tel=$(tail -1 "$LAB/state/.jev-triage-telemetry" 2>/dev/null)
[ "$rc" -eq 0 ] && [ -n "$action" ] && [ -n "$choice" ] && [ -n "$noul" ] && ok=1 || ok=0
check "wake triage returns a real class decision (action=$action choice=$choice noul=$noul)" "$ok" "rc=$rc telemetry=$tel"

echo "=== R4: real-Jev project_worker answer forces the deny even when action allows ==="
rc=0; out=$("$GUARD" --command 'pytest tests/ -q' 2>&1) || rc=$?
printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-200 | sed 's/^/    /'
echo
echo "REAL-JEV-R3 RESULT: pass=$PASS fail=$FAIL"
echo "calibration log (first decision recorded by the real tool):"
tail -n 2 "$LAB/state/.jev-triage-calibration.jsonl" 2>/dev/null | cut -c1-300
exit 0
