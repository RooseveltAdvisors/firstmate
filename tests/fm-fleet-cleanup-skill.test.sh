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

grep -qx 'name: fleet-cleanup' "$FRONTMATTER" \
  || fail "fleet-cleanup skill frontmatter name must match its directory"
grep -qx 'user-invocable: false' "$FRONTMATTER" \
  || fail "fleet-cleanup skill must declare itself agent-only"
grep -qx 'metadata:' "$FRONTMATTER" \
  || fail "fleet-cleanup skill frontmatter must carry a metadata block"
grep -qx '  internal: true' "$FRONTMATTER" \
  || fail "fleet-cleanup skill must set metadata.internal=true so installers do not surface it"
grep -q '^description:' "$FRONTMATTER" \
  || fail "fleet-cleanup skill frontmatter must carry a description"

# A skill nothing loads is dead weight, so the declared trigger must be registered.
grep -q '^- `fleet-cleanup` - load ' "$ROOT/AGENTS.md" \
  || fail "fleet-cleanup skill has no load trigger declared in AGENTS.md section 13"

pass "fleet-cleanup skill is reachable, agent-only, installer-internal, and has a declared load trigger"
