#!/usr/bin/env bash
# Behavior tests for Pi Beads enforcement and graph-of-loops projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-beads-enforcement)
EXTENSION="$ROOT/.pi/extensions/beads-enforcement.ts"
LOOP="$ROOT/bin/fm-evolve-loop.sh"

write_fake_bd() {
  local fakebin=$1 fixture=$2
  cat > "$fakebin/bd" <<'SH'
#!/usr/bin/env bash
set -u
fixture=${BD_FIXTURE:?}
case "${1:-}" in
  ready|blocked)
    printf 'unexpected fleet-wide bd call: %s\n' "$*" >&2
    exit 2
    ;;
  show)
    [ -f "$fixture/show-$2.json" ] || exit 1
    cat "$fixture/show-$2.json"
    ;;
  *)
    printf 'unexpected bd call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/bd"
}

test_extension_enforces_assignment_and_reinjects_state() {
  local repo="$TMP_ROOT/pi-repo" home="$TMP_ROOT/pi-home" fixture="$TMP_ROOT/pi-fixture" fakebin out
  mkdir -p "$repo/.pi/extensions" "$home/state" "$fixture"
  cp "$EXTENSION" "$repo/.pi/extensions/beads-enforcement.ts"
  printf '{"type":"module"}\n' > "$repo/package.json"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Firstmate Tests'
  printf '[{"id":"fm-ready","status":"open"}]\n' > "$fixture/ready.json"
  printf '[{"id":"fm-blocked","status":"open","blocked_by":["fm-gate"],"blocked_by_count":1}]\n' > "$fixture/blocked.json"
  printf '[{"id":"fm-work","title":"assigned","status":"open","labels":[]}]\n' > "$fixture/show-fm-work.json"
  fakebin=$(fm_fakebin "$TMP_ROOT/pi-fakebin")
  write_fake_bd "$fakebin" "$fixture"
  out=$(PLUGIN="$repo/.pi/extensions/beads-enforcement.ts" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    FM_BEAD_ID=fm-work BD_FIXTURE="$fixture" BEADS_ACTOR='Firstmate Tests' PATH="$fakebin:$PATH" \
    node --experimental-strip-types --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let followUp = "";
let compactMessage = "";
const pi = {
  on(name, handler) {
    handlers.set(name, handler);
  },
  sendMessage(message) {
    compactMessage = message.content;
  },
  async sendUserMessage(message, options) {
    if (options?.deliverAs !== "followUp") throw new Error("Beads warning was not a follow-up");
    followUp = message;
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start", reason: "startup" }, {});
if (!compactMessage.includes("BEADS ASSIGNED BEAD") || compactMessage.includes("fm-blocked")) {
  throw new Error("session_start did not inject only the assigned Bead state");
}
const before = await handlers.get("before_agent_start")({
  type: "before_agent_start",
  prompt: "Assigned bead: fm-work",
  systemPrompt: "BASE SYSTEM",
}, {});
if (before.systemPrompt.includes("fm-ready") || before.systemPrompt.includes("fm-blocked")) {
  throw new Error("unrelated fleet Beads leaked into assigned context");
}
if (!before.systemPrompt.includes('"fm-work"')) throw new Error("assigned bead was not verified");
await handlers.get("agent_settled")({ type: "agent_settled" }, {});
if (!followUp.includes("assigned bead fm-work that was never claimed")) {
  throw new Error(`missing claim follow-up: ${followUp}`);
}
await handlers.get("session_compact")({ type: "session_compact" }, {});
if (!compactMessage.includes("BEADS ASSIGNED BEAD")) throw new Error("compaction did not re-inject assigned Bead state");
if (compactMessage.includes("fm-blocked")) throw new Error("compaction injected unrelated fleet state");
EOF
  )
  [ -z "$out" ] || fail "extension assignment test printed output: $out"
  pass "Pi extension injects only assigned Bead state, enforces an unclaimed bead, and re-injects after compaction"
}

test_extension_allows_work_and_dependency_blocked_beads() {
  local repo="$TMP_ROOT/pi-work-repo" home="$TMP_ROOT/pi-work-home" fixture="$TMP_ROOT/pi-work-fixture" fakebin out
  mkdir -p "$repo/.pi/extensions" "$home/state" "$fixture"
  cp "$EXTENSION" "$repo/.pi/extensions/beads-enforcement.ts"
  printf '{"type":"module"}\n' > "$repo/package.json"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Firstmate Tests'
  printf '[]\n' > "$fixture/ready.json"
  printf '[]\n' > "$fixture/blocked.json"
  printf '[{"id":"fm-work","status":"in_progress","dependency_count":0,"labels":[]}]\n' > "$fixture/show-fm-work.json"
  fakebin=$(fm_fakebin "$TMP_ROOT/pi-work-fakebin")
  write_fake_bd "$fakebin" "$fixture"
  out=$(PLUGIN="$repo/.pi/extensions/beads-enforcement.ts" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    BD_FIXTURE="$fixture" BEADS_ACTOR='Firstmate Tests' PATH="$fakebin:$PATH" \
    node --experimental-strip-types --input-type=module 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
let followUps = 0;
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  sendMessage() {},
  async sendUserMessage() { followUps += 1; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start", reason: "startup" }, {});
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "bead: fm-work", systemPrompt: "BASE" }, {});
await handlers.get("tool_call")({ type: "tool_call", toolCallId: "1", toolName: "bash", input: { command: "printf work" } }, {});
await handlers.get("tool_call")({ type: "tool_call", toolCallId: "2", toolName: "edit", input: {} }, {});
await handlers.get("agent_settled")({ type: "agent_settled" }, {});
if (followUps !== 0) throw new Error("completed work incorrectly received a no-work follow-up");
const activity = readFileSync(`${process.env.FM_HOME}/state/.pi-beads-activity.json`, "utf8");
if (!activity.includes("pi-beads-activity.v1")) throw new Error("activity state was not persisted");
EOF
  )
  [ -z "$out" ] || fail "extension work test printed output: $out"

  printf '[{"id":"fm-work","status":"in_progress","dependency_count":1,"labels":["blocked"]}]\n' > "$fixture/show-fm-work.json"
  out=$(PLUGIN="$repo/.pi/extensions/beads-enforcement.ts" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    BD_FIXTURE="$fixture" BEADS_ACTOR='Firstmate Tests' PATH="$fakebin:$PATH" \
    node --experimental-strip-types --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
let followUps = 0;
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  sendMessage() {},
  async sendUserMessage() { followUps += 1; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start", reason: "startup" }, {});
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "bead: fm-work", systemPrompt: "BASE" }, {});
await handlers.get("agent_settled")({ type: "agent_settled" }, {});
if (followUps !== 0) throw new Error("dependency-blocked bead incorrectly received a no-work follow-up");
EOF
  )
  [ -z "$out" ] || fail "extension dependency-blocked test printed output: $out"
  pass "Pi extension allows completed work and dependency-blocked beads to settle without false enforcement"
}

test_extension_warns_on_foreign_and_stale_claims() {
  local repo="$TMP_ROOT/pi-claim-repo" home="$TMP_ROOT/pi-claim-home" fixture="$TMP_ROOT/pi-claim-fixture" fakebin out
  mkdir -p "$repo/.pi/extensions" "$home/state" "$fixture"
  cp "$EXTENSION" "$repo/.pi/extensions/beads-enforcement.ts"
  printf '{"type":"module"}\n' > "$repo/package.json"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Firstmate Tests'
  printf '[]\n' > "$fixture/ready.json"
  printf '[]\n' > "$fixture/blocked.json"
  printf '[{"id":"fm-claim","status":"in_progress","assignee":"Other Agent","dependency_count":0,"labels":[]}]\n' > "$fixture/show-fm-claim.json"
  printf '{"schema":"pi-beads-activity.v1","beads":{"fm-claim":{"lastActivityAt":"2020-01-01T00:00:00.000Z","lastToolCallAt":"2020-01-01T00:00:00.000Z"}}}\n' > "$home/state/.pi-beads-activity.json"
  fakebin=$(fm_fakebin "$TMP_ROOT/pi-claim-fakebin")
  write_fake_bd "$fakebin" "$fixture"
  out=$(PLUGIN="$repo/.pi/extensions/beads-enforcement.ts" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    FM_BEADS_STALE_MS=1 BD_FIXTURE="$fixture" BEADS_ACTOR='Firstmate Tests' PATH="$fakebin:$PATH" \
    node --experimental-strip-types --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  sendMessage() {},
  async sendUserMessage() {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start", reason: "startup" }, {});
const before = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "bead: fm-claim", systemPrompt: "BASE" }, {});
if (!before.systemPrompt.includes("already claimed by another agent: Other Agent")) {
  throw new Error(`foreign claim warning missing: ${before.systemPrompt}`);
}
if (!before.systemPrompt.includes("without a tool call (last tool call:")) {
  throw new Error(`stale claim warning missing: ${before.systemPrompt}`);
}
EOF
  )
  [ -z "$out" ] || fail "foreign/stale claim test printed output: $out"
  pass "Pi extension warns on a foreign claim and a persisted stale claim"
}

test_extension_stays_silent_without_assignment() {
  local repo="$TMP_ROOT/pi-unassigned-repo" home="$TMP_ROOT/pi-unassigned-home" fixture="$TMP_ROOT/pi-unassigned-fixture" fakebin out
  mkdir -p "$repo/.pi/extensions" "$home/state" "$fixture"
  cp "$EXTENSION" "$repo/.pi/extensions/beads-enforcement.ts"
  printf '{"type":"module"}\n' > "$repo/package.json"
  git -C "$repo" init -q
  fakebin=$(fm_fakebin "$TMP_ROOT/pi-unassigned-fakebin")
  write_fake_bd "$fakebin" "$fixture"
  out=$(PLUGIN="$repo/.pi/extensions/beads-enforcement.ts" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    BD_FIXTURE="$fixture" BEADS_ACTOR='Firstmate Tests' PATH="$fakebin:$PATH" \
    node --experimental-strip-types --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
let sent = false;
const pi = {
  on(name, handler) { handlers.set(name, handler); },
  sendMessage() { sent = true; },
  async sendUserMessage() { sent = true; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start", reason: "startup" }, {});
const before = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "Review the repository", systemPrompt: "BASE" }, {});
if (before !== undefined) throw new Error("unassigned session received Beads context");
await handlers.get("session_compact")({ type: "session_compact" }, {});
if (sent) throw new Error("unassigned session received a Beads message");
EOF
  )
  [ -z "$out" ] || fail "unassigned extension test printed output: $out"
  pass "Pi extension stays silent and makes no fleet-wide Beads query without an assignment"
}

write_loop_fake_bd() {
  local fakebin=$1
  cat > "$fakebin/bd" <<'SH'
#!/usr/bin/env bash
set -u
state=${BD_LOOP_STATE:?}
log=${BD_LOOP_LOG:?}
printf '%s\n' "$*" >> "$log"
case "${1:-}" in
  list)
    first=1
    printf '['
    if [ -e "$state/sentinel" ]; then
      first=0
      printf '{"id":"fm-sentinel","status":"open","labels":["watch-loop"],"metadata":{"watch_loop_role":"review-sentinel"}}'
    fi
    if [ -e "$state/finding" ]; then
      [ "$first" -eq 1 ] || printf ','
      printf '{"id":"fm-loop-alpha","status":"open","labels":["watch-loop"],"metadata":{"watch_loop_role":"finding","loop_id":"loop-alpha"}}'
    fi
    printf ']\n'
    ;;
  create)
    case "$*" in
      *"Loop health findings require review"*) touch "$state/sentinel"; printf 'fm-sentinel\n' ;;
      *) touch "$state/finding"; printf 'fm-loop-alpha\n' ;;
    esac
    ;;
  update)
    touch "$state/finding"
    ;;
  reopen)
    touch "$state/finding"
    ;;
  dep)
    if [ "${2:-}" = list ]; then
      if [ -e "$state/dependency" ]; then printf '[{"id":"fm-sentinel","dependency_type":"blocks"}]\n'; else printf '[]\n'; fi
    else
      touch "$state/dependency"
    fi
    ;;
  *)
    printf 'unexpected loop bd call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/bd"
}

test_loop_wrapper_projects_and_updates_findings() {
  local home="$TMP_ROOT/loop-home" fakebin pass1 pass2 out log
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$TMP_ROOT/loop-fakebin")
  log="$home/state/bd.log"
  write_loop_fake_bd "$fakebin"
  pass1="$home/pass-one.sh"
  pass2="$home/pass-two.sh"
  printf '#!/usr/bin/env bash\nprintf '\''{"loops":[{"id":"loop-alpha","name":"Alpha","status":"stalled","finding":"queue stopped"},{"id":"loop-beta","status":"converging"}]}\\n'\''\n' > "$pass1"
  printf '#!/usr/bin/env bash\nprintf '\''{"loops":[{"id":"loop-alpha","name":"Alpha","status":"drifting","finding":"state diverged"}]}\\n'\''\n' > "$pass2"
  chmod +x "$pass1" "$pass2"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" BD_LOOP_STATE="$home/state" BD_LOOP_LOG="$log" \
    "$LOOP" --pass "$pass1") || fail "loop wrapper failed its first projection: $out"
  assert_contains "$out" 'watch-loop: loop-alpha -> fm-loop-alpha (stalled)' "first evolve finding was not projected"
  assert_present "$home/state/.fm-evolve-loop-report.json" "evolve report was not retained"
  assert_present "$home/state/dependency" "finding was not made visible to bd blocked"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" BD_LOOP_STATE="$home/state" BD_LOOP_LOG="$log" \
    "$LOOP" --pass "$pass2") || fail "loop wrapper failed its update projection: $out"
  assert_contains "$out" 'projected 1 unhealthy loop(s)' "updated evolve finding was not reported"
  assert_grep 'update fm-loop-alpha' "$log" "existing loop finding was recreated instead of updated"
  pass "graph-of-loops wrapper creates a watch-loop finding, adds a blocked dependency, and updates it"
}

test_loop_wrapper_leaves_healthy_report_alone() {
  local home="$TMP_ROOT/loop-healthy-home" fakebin pass out
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$TMP_ROOT/loop-healthy-fakebin")
  write_loop_fake_bd "$fakebin"
  pass="$home/pass.sh"
  printf '#!/usr/bin/env bash\nprintf '\''{"loops":[{"id":"loop-good","status":"converging"}]}\\n'\''\n' > "$pass"
  chmod +x "$pass"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" BD_LOOP_STATE="$home/state" BD_LOOP_LOG="$home/state/bd.log" \
    "$LOOP" --pass "$pass") || fail "healthy loop wrapper failed: $out"
  assert_contains "$out" 'healthy loops required no action' "healthy loop was not a no-op"
  assert_absent "$home/state/sentinel" "healthy loop unexpectedly created a review sentinel"
  pass "graph-of-loops wrapper leaves converging loops without Beads mutation"
}

test_fleet_view_surfaces_blocked_beads() {
  local home="$TMP_ROOT/view-home" fakebin out
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fakebin=$(fm_fakebin "$TMP_ROOT/view-fakebin")
  cat > "$fakebin/bd" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = blocked ]; then
  printf '[{"id":"fm-loop-alpha","title":"Loop health: Alpha","labels":["watch-loop"],"blocked_by":["fm-sentinel"]}]\n'
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/bd"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-view.sh") \
    || fail "fleet view failed with blocked Beads: $out"
  assert_contains "$out" '## Blocked Beads' "fleet view omitted the blocked Beads section"
  assert_contains "$out" 'fm-loop-alpha' "fleet view omitted the stalled loop bead"
  pass "fleet view surfaces stalled loop Beads from bd blocked"
}

test_extension_enforces_assignment_and_reinjects_state
test_extension_allows_work_and_dependency_blocked_beads
test_extension_warns_on_foreign_and_stale_claims
test_extension_stays_silent_without_assignment
test_loop_wrapper_projects_and_updates_findings
test_loop_wrapper_leaves_healthy_report_alone
test_fleet_view_surfaces_blocked_beads
