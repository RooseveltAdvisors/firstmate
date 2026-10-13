#!/usr/bin/env bash
# fm-gui-containment.test.sh - Scope Area 4: GUI Containment tests.
#
# SI Control Phase 3:
#   1. Implement Section 5: GUI Containment.
#   2. Dedicated automation accounts only: no personal browser profiles, no profile cloning.
#   3. Deny-on-non-automation-context router guard:
#      - Rejects personal browser sessions (captain login)
#      - Rejects unknown / unmapped context aliases
#      - Rejects non-allowlisted hosts
#      - Rejects unverifiable spaces / host-context mismatches
#      - Allows verified automation accounts on allowlisted hosts
#   4. Evidence collection: records all routing decisions and refusals in ledger.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

GUI_ROUTER="$ROOT/bin/fm-gui-router.sh"
GUI_LIB="$ROOT/bin/fm-gui-guard-lib.sh"
LABHOME="$ROOT/bin/fm-lab-home.sh"

TMP=$(fm_test_tmproot fm-gui-containment)

# Create marked lab home
LAB="$TMP/labhome"
bash "$LABHOME" create "$LAB" >/dev/null 2>&1 || fail "fm-lab-home create failed"

# Prepare test GUI containment router map
ROUTER_MAP="$TMP/gui-map.json"
cat > "$ROUTER_MAP" <<'JSON'
{
  "version": 1,
  "allowed_hosts": [
    "mbp",
    "agt-2",
    "agt-8"
  ],
  "contexts": {
    "agt_auto_deploy": {
      "host": "agt-2",
      "profile": "Profile 2",
      "space": "Automation-Deploy",
      "account_type": "automation",
      "allowed_actions": ["deploy", "audit"]
    },
    "agt_auto_audit": {
      "host": "agt-8",
      "profile": "Profile 3",
      "space": "Automation-Audit",
      "account_type": "automation",
      "allowed_actions": ["audit"]
    }
  },
  "blocked_contexts": {
    "captain_personal": {
      "account_type": "personal",
      "reason": "Personal session access strictly forbidden"
    },
    "default_browser_profile": {
      "account_type": "personal",
      "reason": "Default personal browser session prohibited"
    }
  }
}
JSON

# 1. Personal context rejection (Captain Decision 4: No personal browser sessions)
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" check "$ROUTER_MAP" "captain_personal" "mbp" >/dev/null 2>&1 && fail "captain_personal context must REFUSE"
pass "gui router: captain_personal session strictly REFUSED"

env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" check "$ROUTER_MAP" "default_browser_profile" "mbp" >/dev/null 2>&1 && fail "default_browser_profile must REFUSE"
pass "gui router: default personal profile strictly REFUSED"

# 2. Unmapped context alias rejection (fails closed)
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" check "$ROUTER_MAP" "rogue_unknown_alias" "agt-2" >/dev/null 2>&1 && fail "unmapped alias must REFUSE"
pass "gui router: unmapped context alias REFUSES (fails closed)"

# 3. Non-allowlisted host rejection
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" check "$ROUTER_MAP" "agt_auto_deploy" "untrusted-vps" >/dev/null 2>&1 && fail "untrusted host must REFUSE"
pass "gui router: non-allowlisted host REFUSES"

# 4. Host-context mismatch rejection
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" check "$ROUTER_MAP" "agt_auto_deploy" "agt-8" >/dev/null 2>&1 && fail "host context mismatch must REFUSE"
pass "gui router: host mismatch for alias REFUSES"

# 5. Missing router map file rejection
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" check "$TMP/nonexistent-map.json" "agt_auto_deploy" "agt-2" >/dev/null 2>&1 && fail "missing router map must REFUSE"
pass "gui router: missing router map REFUSES"

# 6. Valid automation context check passes
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" check "$ROUTER_MAP" "agt_auto_deploy" "agt-2" >/dev/null 2>&1 || fail "valid automation context should pass check"
pass "gui router: valid automation context PASSES check"

# 7. Valid automation command execution
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" run "$ROUTER_MAP" "agt_auto_deploy" "agt-2" echo "gui-action-dispatched" >/dev/null 2>&1 || fail "valid automation command execution failed"
pass "gui router: valid automation command executes"

# 8. Refusal command execution fails closed (does NOT execute child command)
CANARY_FILE="$TMP/canary.txt"
rm -f "$CANARY_FILE"
env FM_HOME="$LAB" FM_GATE_REFUSE_BYPASS=1 \
  bash "$GUI_ROUTER" run "$ROUTER_MAP" "captain_personal" "mbp" touch "$CANARY_FILE" >/dev/null 2>&1 && fail "refused context must not execute"
[ ! -f "$CANARY_FILE" ] || fail "canary file created by refused command execution"
pass "gui router: refused context stops execution before command invocation"

# 9. Evidence ledger contains all router decisions and refusals
LEDGER="$LAB/state/evidence/gui/gui-router-ledger.jsonl"
[ -f "$LEDGER" ] || fail "GUI evidence ledger was not created"
lines=$(wc -l < "$LEDGER")
[ "$lines" -ge 7 ] || fail "expected at least 7 entries in GUI evidence ledger, got $lines"
pass "gui router: records all checks and refusals in evidence ledger"

# Every ledger entry carries exactly the opaque routing fields
jq -s -e 'all(.[]; keys == ["context_alias","host","outcome","reason","task_id","timestamp"])' "$LEDGER" >/dev/null ||
  fail "GUI ledger entries carry fields beyond the opaque routing fields"
pass "gui router: ledger contains only opaque account aliases, no personal identities"

echo "ok: Scope Area 4 GUI containment tests passed completely"
