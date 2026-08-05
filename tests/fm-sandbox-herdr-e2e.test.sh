#!/usr/bin/env bash
# Opt-in destructive proof for the Docker Sandboxes layer in a named Herdr lab.
# It never runs in the portable suite. Set FM_RUN_SANDBOX_HERDR_E2E=1 and pass
# an ephemeral FM_SANDBOX_OPENAI_API_KEY only during a controlled rollout.
set -eu

[ "${FM_RUN_SANDBOX_HERDR_E2E:-}" = 1 ] || {
  echo "skip: set FM_RUN_SANDBOX_HERDR_E2E=1 for the controlled Docker Sandboxes + Herdr lab proof"
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v sbx >/dev/null 2>&1 || { echo "skip: sbx not installed"; exit 0; }
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not installed"; exit 0; }
[ -n "${FM_SANDBOX_OPENAI_API_KEY:-}" ] || { echo "error: proof requires an ephemeral task-scoped OpenAI API key" >&2; exit 1; }

HERDR_LAB_HELPER='/opt/ra/firstmate/bin/fm-herdr-lab.sh'
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fleet-sandboxed-worker-fabric)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

ID="sbx-herdr-proof-$$"
TASK_TMP="/tmp/fm-$ID"
PROOF_ROOT=$(mktemp -d "/tmp/fm-sandbox-herdr-proof.XXXXXX")
FM_HOME="$PROOF_ROOT/home"
STATE="$FM_HOME/state"
CONFIG="$FM_HOME/config"
SOURCE="$PROOF_ROOT/fixture"
BRIEF="$PROOF_ROOT/brief.md"
SENTINEL="$PROOF_ROOT/host-sentinel"
RESULT="$STATE/$ID.sandbox-proof.json"
mkdir -p "$STATE" "$CONFIG" "$SOURCE"
printf '%s\n' v1 > "$CONFIG/sandbox-workers-enabled"
printf '%s\n' 'host-only sentinel' > "$SENTINEL"
printf '%s\n' '# harmless sandbox proof fixture' > "$BRIEF"

HOSTNAME_NOW=$(hostname -f 2>/dev/null || hostname)
jq -n --arg hostname "$HOSTNAME_NOW" '{
  version:1,
  hosts:[{
    id:"herdr-lab",role:"dev",transport:"local",hostname:$hostname,
    enabled:true,priority:0,cpus:2,memory:"4GiB",maxConcurrent:1,
    profiles:["codex-github-bun-v1"],authMode:"ephemeral-api-key",
    privateNetworkGrant:false
  }]
}' > "$CONFIG/sandbox-hosts.json"

git -C "$SOURCE" init -q
printf '%s\n' v1 > "$SOURCE/.firstmate-sandbox-proof-fixture"
printf '%s\n' 'fixture' > "$SOURCE/fixture.txt"
cat > "$SOURCE/Dockerfile" <<'DOCKERFILE'
FROM busybox:1.37
COPY fixture.txt /fixture.txt
CMD ["test", "-f", "/fixture.txt"]
DOCKERFILE
git -C "$SOURCE" add .
git -C "$SOURCE" -c user.name='Firstmate Sandbox Proof' -c user.email='sandbox-proof@example.invalid' commit -qm initial
git -C "$SOURCE" branch -M "fm/$ID"

CREATE_JSON=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
  workspace create --cwd "$SOURCE" --label "fm-sandbox-proof-$ID" --no-focus)
WORKSPACE_ID=$(printf '%s' "$CREATE_JSON" | jq -r '.result.workspace.workspace_id // empty')
TAB_ID=$(printf '%s' "$CREATE_JSON" | jq -r '.result.tab.tab_id // empty')
PANE_ID=$(printf '%s' "$CREATE_JSON" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WORKSPACE_ID" ] && [ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || {
  echo "error: isolated Herdr workspace create returned incomplete IDs" >&2
  exit 1
}

read -r SANDBOX_NAME SANDBOX_NONCE <<EOF
$(FM_HOME="$FM_HOME" "$ROOT/bin/fm-sandbox.sh" identity "$ID" herdr-lab)
EOF
cat > "$STATE/$ID.meta" <<EOF
window=$HERDR_LAB_SESSION:$PANE_ID
worktree=$SOURCE
project=$SOURCE
harness=codex
kind=ship
mode=local-only
yolo=off
tasktmp=$TASK_TMP
model=default
effort=high
execution=sandbox
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$WORKSPACE_ID
herdr_tab_id=$TAB_ID
herdr_pane_id=$PANE_ID
sandbox_host=herdr-lab
sandbox_profile=codex-github-bun-v1
sandbox_name=$SANDBOX_NAME
sandbox_nonce=$SANDBOX_NONCE
sandbox_owner=$STATE/$ID.sandbox.json
sandbox_brief=$BRIEF
EOF

FM_HOME="$FM_HOME" FM_SANDBOX_OPENAI_API_KEY="$FM_SANDBOX_OPENAI_API_KEY" \
  "$ROOT/bin/fm-sandbox.sh" prepare "$ID"

printf -v PROOF_COMMAND '%q ' env FM_HOME="$FM_HOME" FM_SANDBOX_HERDR_LAB_PROOF=1 \
  "$ROOT/bin/fm-sandbox.sh" lab-proof "$ID" "$SENTINEL" "$RESULT"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE_ID" "$PROOF_COMMAND" >/dev/null

for _ in $(seq 1 180); do
  [ -f "$RESULT" ] && break
  sleep 1
done
[ -f "$RESULT" ] || { echo "error: sandbox proof did not finish within 180 seconds" >&2; exit 1; }
jq -e '
  .schema == "fm-sandbox-herdr-proof.v1"
  and (.herdr_session | startswith("fm-lab-"))
  and .checks.hostSentinelBlocked
  and .checks.privateNetworkBlocked
  and (.checks.hostDockerSocketMounted | not)
  and .checks.privateDockerUsable
  and .checks.cloneEditBuildTest
' "$RESULT" >/dev/null
grep -F 'edited inside disposable microVM clone' "$SOURCE/proof-output.txt" >/dev/null \
  || { echo "error: committed fixture edit did not synchronize back" >&2; exit 1; }

printf -v CLEANUP_COMMAND '%q ' env FM_HOME="$FM_HOME" \
  "$ROOT/bin/fm-sandbox.sh" cleanup "$ID"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE_ID" "$CLEANUP_COMMAND" >/dev/null
for _ in $(seq 1 60); do
  [ "$(jq -r '.lifecycle // empty' "$STATE/$ID.sandbox.json" 2>/dev/null || true)" = removed ] && break
  sleep 1
done
[ "$(jq -r .lifecycle "$STATE/$ID.sandbox.json")" = removed ] \
  || { echo "error: exact sandbox cleanup did not complete" >&2; exit 1; }

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null
rm -rf "$TASK_TMP" "$PROOF_ROOT"
echo "ok - named Herdr lab proved microVM filesystem/network/Docker/workcopy isolation and exact cleanup"
