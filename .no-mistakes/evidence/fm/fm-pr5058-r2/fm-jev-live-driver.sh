#!/usr/bin/env bash
set -u
W=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"; cp -R "$W/bin" "$LAB/bin"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX; echo "tmux socket dir: $TMUX_TMPDIR"
SRV=$(mktemp -d)
cleanup(){ tmux kill-server 2>/dev/null; kill $STUB 2>/dev/null; rm -rf "$LAB" "$SRV"; }
trap cleanup EXIT
# disposable Jev System One endpoint: classifies by key prefix
cat > "$SRV/jev.py" <<'PY'
import http.server, json, sys
M={"old":("stale_historical",0.1),"pending-reply":("stale_historical",0.1),"spend":("policy_spend",0.3),"net":("external_block",0.5),"fix":("actionable_now",0.95)}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(s):
        raw=s.rfile.read(int(s.headers["Content-Length"])); open(sys.argv[2],"ab").write(raw+b"\n")
        if s.headers.get("Authorization")!="Bearer lab-key": s.send_response(401); s.end_headers(); return
        k=json.loads(raw)["state"]["key"]; a={}
        for p,(c,n) in M.items():
            if k.startswith(p): a={"category":{"choice":c,"confidence":0.8},"actionable_now":{"noul":n}}; break
        if k.startswith("garbage"): a={"category":{"choice":"nope"}}
        o=json.dumps({"answers":a}).encode(); s.send_response(200); s.end_headers(); s.wfile.write(o)
    def log_message(s,*a): pass
srv=http.server.HTTPServer(("127.0.0.1",0),H); open(sys.argv[1],"w").write(str(srv.server_port)); srv.serve_forever()
PY
python3 "$SRV/jev.py" "$SRV/port" "$SRV/req.log" & STUB=$!
for _ in $(seq 50); do [ -s "$SRV/port" ] && break; sleep 0.1; done
export FM_JEV_TS_BASE="http://127.0.0.1:$(cat "$SRV/port")"
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE
export FM_HOME="$LAB"
# real tmux window acting as the task pane
tmux new-session -d -s sess -n fm-t1 "bash --norc -i"
printf 'window=sess:fm-t1\nkind=ship\n' > "$LAB/state/t1.meta"
cat > "$LAB/state/t1.status" <<S
blocked [key=old-dep]: waiting on superseded dependency from phase 1
needs-decision [key=spend-tier]: approve paid API tier for Acme Clinic rollout
blocked [key=net-down]: upstream host unreachable
needs-decision [key=fix-now]: choose the fix now
blocked [key=pending-reply-abc]: pending-reply-missed: task=t1 request=STATUS_PING
needs-decision [key=garbage-x]: jev returns junk
S
# legacy fm- prefixed ledger whose fm-send target would be t2.status
printf 'window=sess:fm-t1\nkind=ship\n' > "$LAB/state/t2.meta"
printf 'blocked [key=old-legacy]: superseded legacy item\n' > "$LAB/state/fm-t2.status"
printf 'Acme Clinic\n' > "$LAB/config/dispatch-never-send"
J=bin/fm-jev-decisions.sh
echo '### S1 table, key from env'; TYPESAFE_API_KEY=lab-key $J --task t1
echo; echo '### S2 json + filters (--category actionable_now)'; TYPESAFE_API_KEY=lab-key $J --task t1 --category actionable_now --json
echo; echo '### S2 --min-noul 0.4 keys'; TYPESAFE_API_KEY=lab-key $J --task t1 --min-noul 0.4 --json | python3 -c 'import json,sys;print([i["key"] for i in json.load(sys.stdin)])'
echo; echo '### S2 --limit 2'; TYPESAFE_API_KEY=lab-key $J --task t1 --limit 2 --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))'
echo; echo '### S3 never-send: request log lines containing "acme" (case-insens):'; grep -ci acme "$SRV/req.log"; grep -o '"note": "[^"]*withheld[^"]*"' "$SRV/req.log" | head -1
echo; echo '### S4 key from home .env only'; printf 'TYPESAFE_API_KEY=lab-key\n' > "$LAB/.env"; env -u TYPESAFE_API_KEY $J --task t1 --category external_block; rm "$LAB/.env"
echo; echo '### S5 no key anywhere -> unavailable, exit code'; env -u TYPESAFE_API_KEY PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin" $J --task t1 </dev/null; echo "exit=$?"
echo; echo '### S6 --resolve-cmds (only old-dep expected)'; CMDS=$(TYPESAFE_API_KEY=lab-key $J --task t1 --resolve-cmds); echo "$CMDS"
echo; echo '### S6 execute generated command via real fm-send against lab task pane'; (cd /tmp && env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS bash -c "$CMDS"); echo "exit=$?"
echo '--- status tail:'; tail -2 "$LAB/state/t1.status"
echo '--- pane doorbell:'; tmux capture-pane -p -t sess:fm-t1 | grep -v '^$' | tail -3; echo '--- inbox record:'; cat "$LAB/state/t1.inbox/"*.msg 2>/dev/null | head -3
echo '--- re-triage after close (old-dep should be gone):'; TYPESAFE_API_KEY=lab-key $J --task t1 --json | python3 -c 'import json,sys;print(sorted(i["key"] for i in json.load(sys.stdin)))'
echo; echo '### S7 ledger mismatch: fm-t2.status (fm-send would close t2.status)'; TYPESAFE_API_KEY=lab-key $J --status-file "$LAB/state/fm-t2.status"; TYPESAFE_API_KEY=lab-key $J --status-file "$LAB/state/fm-t2.status" --resolve-cmds
echo; echo '### S8 --all across state'; TYPESAFE_API_KEY=lab-key $J --all | tail -3
echo; echo '### S9 wrong key -> 401 -> unavailable, not crash'; TYPESAFE_API_KEY=bad $J --task t1 --limit 1; echo "exit=$?"
