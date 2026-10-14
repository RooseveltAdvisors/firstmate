LAB=$(mktemp -d); rmdir "$LAB"; bin/fm-lab-home.sh create "$LAB" >/dev/null
X(){ env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" "$@"; }
echo "## ledger records after send DENY + draft ALLOW"
X bin/fm-action-gate.sh check mail_send a@b t1; X bin/fm-action-gate.sh check mail_draft d t1
cat "$LAB/state/evidence/actions/action-ledger.jsonl"
echo "## ledger unwritable -> draft not allowed"
chmod 555 "$LAB/state/evidence/actions"; chmod 444 "$LAB/state/evidence/actions/action-ledger.jsonl"
X bin/fm-action-gate.sh execute mail_draft d t1 "" echo SHOULD-NOT-RUN; echo "[exit=$?]"
chmod -R u+w "$LAB"; echo "LAB=$LAB"
