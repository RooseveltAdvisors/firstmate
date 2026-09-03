#!/usr/bin/env bash
# Portable structural validation for the fleet-cleanup skill artifact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Read through the loader-facing .claude/skills symlink rather than the tracked
# directory, so this also proves the skill is reachable the way a harness loads it.
SKILL="$ROOT/.claude/skills/fleet-cleanup/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-fleet-cleanup-skill)
FRONTMATTER="$TMP_ROOT/frontmatter.yaml"

[ -r "$SKILL" ] || fail "fleet-cleanup skill is not readable at .claude/skills/fleet-cleanup/SKILL.md"

awk '
  NR == 1 && $0 != "---" { exit 1 }
  NR == 1 { next }
  /^---$/ { closed = 1; exit }
  { print }
  END { if (!closed) exit 1 }
' "$SKILL" > "$FRONTMATTER" || fail "fleet-cleanup skill has no closed YAML frontmatter block"

# Flatten the frontmatter into normalized `path=value` pairs before asserting, so
# nesting is actually proven. Independent greps for `metadata:` and `internal: true`
# both pass on a file whose metadata.internal is false, and pinning indentation
# fails a semantically identical reflow. POSIX awk only (CI runs mawk), which also
# avoids a YAML dependency that neither CI nor tests/lib.sh already carries.
MODEL="$TMP_ROOT/frontmatter.model"
awk '
  function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
  {
    if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
    pos = match($0, /[^[:space:]]/)
    if (pos == 0) next
    indent = pos - 1
    ci = index($0, ":")
    if (ci == 0) next
    key = trim(substr($0, pos, ci - pos))
    val = trim(substr($0, ci + 1))
    if (indent > 0) {
      if (parent != "") print parent "." key "=" val
      next
    }
    # A block scalar (>- or |) is prose: its indented lines are not child keys.
    if (val ~ /^[>|]/) { parent = ""; next }
    # A key with no value opens a block mapping.
    if (val == "") { parent = key; next }
    # A one-line flow mapping is the same contract written differently.
    if (val ~ /^\{.*\}$/) {
      inner = substr(val, 2, length(val) - 2)
      n = split(inner, pairs, ",")
      for (i = 1; i <= n; i++) {
        pc = index(pairs[i], ":")
        if (pc > 0) print key "." trim(substr(pairs[i], 1, pc - 1)) "=" trim(substr(pairs[i], pc + 1))
      }
      parent = ""
      next
    }
    print key "=" val
    parent = ""
  }
' "$FRONTMATTER" > "$MODEL"

grep -qx 'name=fleet-cleanup' "$MODEL" \
  || fail "fleet-cleanup skill frontmatter name must match its directory"
grep -qx 'user-invocable=false' "$MODEL" \
  || fail "fleet-cleanup skill must declare itself agent-only"
grep -qx 'metadata.internal=true' "$MODEL" \
  || fail "fleet-cleanup skill must set metadata.internal=true so installers do not surface it"
grep -q '^description' "$FRONTMATTER" \
  || fail "fleet-cleanup skill frontmatter must carry a description"

# A skill nothing loads is dead weight, so the declared trigger must be registered.
# This is deliberately a text match: AGENTS.md is prose and nothing in bin/ consumes
# the section 13 trigger list (bin/fm-test-run.sh keys on the SKILL.md path, not the
# trigger). Replace this with a real-consumer assertion if such a consumer ever exists.
# shellcheck disable=SC2016 # Backticks are literal Markdown here, not a subshell.
grep -q '^- `fleet-cleanup` - load ' "$ROOT/AGENTS.md" \
  || fail "fleet-cleanup skill has no load trigger declared in AGENTS.md section 13"

pass "fleet-cleanup skill is reachable, agent-only, installer-internal, and has a declared load trigger"
