#!/usr/bin/env bash
# Live CLI drive of bin/fm-action-gate.sh against a disposable lab FM_HOME.
set -u
G="$PWD/bin/fm-action-gate.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"; unset FM_TASK_ID FM_RUNNER_UNTRUSTED FM_CAPTAIN_AUTH FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
S="$LAB/state/grants"; MARK="$LAB/ran"
run(){ echo "\$ fm-action-gate.sh $*"; out=$("$G" "$@" 2>&1); rc=$?; echo "$out" | sed 's/^/  /'; echo "  [exit $rc]"; }
echo "== S1 mail_send hard deny"; run check mail_send someone@x.com t1; run execute send someone@x.com t1 "" touch $MARK.send
echo "== S2 draft allowed through check and execute (no grant, no stray cmd)"; run check mail_draft box t1; run execute mail_draft box t1
run execute mail_draft box t1 "" touch $MARK.draft; ls $MARK.draft >/dev/null 2>&1 && echo "  draft cmd ran: yes"
echo "== S3 consequential action without grant -> HUMAN_REVIEW, cmd not run"; run execute booking cal-x t1 "" touch $MARK.nogrant; ls $MARK.nogrant 2>/dev/null || echo "  cmd ran: no"
echo "== S4 runner cannot mint"; FM_TASK_ID=t1 run mint-grant $S/r.json booking cal-x t1 2030-01-01T00:00:00Z ref-1
FM_RUNNER_UNTRUSTED=1 run mint-grant $S/r.json booking cal-x t1 2030-01-01T00:00:00Z ref-1
echo "== S5 captain mints into store; mint outside store refused; empty task refused"
run mint-grant /tmp/outside-$$.json booking cal-x t1 2030-01-01T00:00:00Z ref-1
run mint-grant $S/g.json booking cal-x "" 2030-01-01T00:00:00Z ref-1
run mint-grant $S/g.json booking cal-x t1 2030-01-01T00:00:00Z captain-ref-1; cat $S/g.json; ls -ld $S
echo "== S6 mismatch denials"; run check booking cal-OTHER t1 $S/g.json; run check charging cal-x t1 $S/g.json; run check booking cal-x t2 $S/g.json; run check booking cal-x "" $S/g.json
echo "== S7 forged grant outside store denied"; cp $S/g.json /tmp/forged-$$.json; run execute booking cal-x t1 /tmp/forged-$$.json touch $MARK.forged; ls $MARK.forged 2>/dev/null || echo "  cmd ran: no"; rm -f /tmp/forged-$$.json
echo "== S8 valid grant executes once"; run execute booking cal-x t1 $S/g.json touch $MARK.ok; ls $MARK.ok && echo "  cmd ran: yes"; cat $S/g.json
echo "== S9 replay: same file, and copy with used_at reset, both denied"; run execute booking cal-x t1 $S/g.json touch $MARK.replay
jq '.used_at=null' $S/g.json > $S/copy.json; run execute booking cal-x t1 $S/copy.json touch $MARK.replay2; ls $MARK.replay* 2>/dev/null || echo "  replay cmd ran: no"
echo "== S10 expired grant denied"; run mint-grant $S/e.json prod_deploy srv-x t1 2020-01-01T00:00:00Z captain-ref-2; run execute deploy srv-x t1 $S/e.json touch $MARK.exp
echo "== S11 JEV-only grant cannot authorize"; jq -n '{action_class:"charging",target:"acct",task_id:"t1",expires_at:"2030-01-01T00:00:00Z",jev_classification:{decision:"allow"}}' > $S/jev.json; run check charging acct t1 $S/jev.json
echo "== S12 ledger unwritable -> ALLOW path denies"; L2=$(mktemp -d); bin/fm-lab-home.sh create "$L2" >/dev/null; mkdir -p $L2/state/evidence; chmod 500 $L2/state/evidence; FM_HOME=$L2 run check mail_draft box t1; chmod 700 $L2/state/evidence; rm -rf $L2
echo "== Ledger (persisted state)"; cat $LAB/state/evidence/actions/action-ledger.jsonl
rm -rf "$LAB"
