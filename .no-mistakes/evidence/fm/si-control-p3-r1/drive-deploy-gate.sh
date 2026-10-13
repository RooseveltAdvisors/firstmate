#!/usr/bin/env bash
# Live drive of bin/fm-deploy-gate.sh against a disposable marked lab home.
set -u
WT=/home/jon/.no-mistakes/worktrees/46339c0817e0/01M4TBB4RJ47VKE9Q4RGWVYT7Q
cd "$WT"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
export FM_HOME="$LAB" FM_TASK_ID=fm-task-live-001
W="$LAB/work"; mkdir -p "$W"
LEDGER="$LAB/state/evidence/decisions/decision-ledger.jsonl"
echo "release v1.2.3" > "$W/payload.txt"
H=$(sha256sum "$W/payload.txt" | awk '{print $1}')
EXP=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
mkrec() { jq --arg h "$H" --arg e "$EXP" --arg t "$FM_TASK_ID" \
  '.payload_hash=$h | .expires_at=$e | .task_id=$t | .used_at=null' \
  tests/fixtures/si-control-p3/policy-decision-record.json > "$1"; }
D="$W/deploys.log"; : > "$D"
deploy() { bin/fm-deploy-gate.sh execute srv-covenant-app "$W/payload.txt" "$1" sh -c "echo deployed-\$\$ >> '$D'"; }

echo "=== S1 happy path: valid record executes deploy once"
mkrec "$W/ok.json"; deploy "$W/ok.json"; echo "exit=$?"
echo "deploys=$(wc -l < "$D")  used_at=$(jq -r .used_at "$W/ok.json")  consumed_marker=$([ -d "$W/ok.json.consumed" ] && echo yes)"

echo "=== S2 replay: same record again is denied"
deploy "$W/ok.json"; echo "exit=$?  deploys=$(wc -l < "$D")"

echo "=== S3 missing decision record"
deploy "$W/nope.json"; echo "exit=$?  deploys=$(wc -l < "$D")"

echo "=== S4 payload changed after approval"
mkrec "$W/p.json"; echo tamper >> "$W/payload.txt"
deploy "$W/p.json"; echo "exit=$?  deploys=$(wc -l < "$D")"
echo "release v1.2.3" > "$W/payload.txt"

echo "=== S5 8-way race on one record (t1 fix)"
: > "$D"; mkrec "$W/race.json"; : > "$W/race.codes"
for i in 1 2 3 4 5 6 7 8; do ( deploy "$W/race.json" >/dev/null 2>&1; echo $? >> "$W/race.codes" ) & done; wait
echo "deploys=$(wc -l < "$D")  exit0=$(grep -c '^0$' "$W/race.codes")  exit1=$(grep -c '^1$' "$W/race.codes")"
echo "ledger for race.json by outcome/reason:"
jq -r --arg r "$W/race.json" 'select(.record==$r) | "\(.outcome) \(.reason)"' "$LEDGER" | sort | uniq -c
A=$(jq -r --arg r "$W/race.json" 'select(.record==$r and .outcome=="ALLOW")' "$LEDGER" | jq -s length)
CF=$(jq -r --arg r "$W/race.json" 'select(.record==$r and .reason=="consume-failed")' "$LEDGER" | jq -s length)
echo "net-authorized = ALLOW($A) - consume-failed($CF) = $((A-CF))"

echo "=== S6 no lab marker under gate context: refused"
NOLAB=$(mktemp -d); FM_HOME="$NOLAB" bin/fm-deploy-gate.sh check srv-covenant-app "$W/payload.txt" "$W/ok.json"; echo "exit=$?"; rm -rf "$NOLAB"

echo "=== full ledger"; cat "$LEDGER"
rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] || echo yes)"
