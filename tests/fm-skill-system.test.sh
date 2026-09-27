#!/usr/bin/env bash
# tests/fm-skill-system.test.sh - generated skill map and symlink composition.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-skill-system)
MAP="$ROOT/bin/fm-skill-map.sh"
COMPOSE="$ROOT/bin/fm-skill-compose.sh"

assert_file_contains() {
  local file=$1 needle=$2 msg=$3
  grep -F -- "$needle" "$file" >/dev/null 2>&1 || fail "$msg"
}

assert_file_not_contains() {
  local file=$1 needle=$2 msg=$3
  if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    fail "$msg"
  fi
}

readlink_real() {
  local path=$1 target dir
  target=$(readlink "$path") || return 1
  case "$target" in
    /*) cd "$target" && pwd -P ;;
    *) dir=$(dirname "$path"); cd "$dir/$target" && pwd -P ;;
  esac
}

write_skill() {  # <dir> <name> <description-mode>
  local dir=$1 name=$2 mode=${3:-plain}
  mkdir -p "$dir"
  case "$mode" in
    folded)
      cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: >-
  folded
  description
metadata:
  test: true
---
body must not be read by the map
EOF
      ;;
    crlf)
      printf '%s\r\n' \
        '---' \
        "name: $name" \
        "description: $name description" \
        '---' \
        'body must not be read by the map' > "$dir/SKILL.md"
      ;;
    *)
      cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: $name description
---
body must not be read by the map
EOF
      ;;
  esac
}

test_skill_map_generates_flat_deduped_registry() {
  local home="$TMP_ROOT/map-home" user_home="$TMP_ROOT/user-home" before_count after_count
  mkdir -p "$home/data" "$home/projects/alpha/.claude/skills" "$home/projects/alpha/.agents/skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$home/projects/alpha/.claude/skills/project-skill" project-skill folded
  write_skill "$home/projects/alpha/.claude/skills/crlf-skill" crlf-skill crlf
  ln -s ../../.claude/skills/project-skill "$home/projects/alpha/.agents/skills/project-skill-link"
  [ -d "$home/projects/alpha/.agents/skills/project-skill-link" ] \
    || fail "canonical-path de-duplication fixture symlink does not resolve"
  write_skill "$user_home/.claude/skills/user-skill" user-skill plain

  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "skill map generation failed"
  cp "$home/data/skill-map.md" "$home/data/skill-map.before"
  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "second skill map generation failed"
  cmp -s "$home/data/skill-map.before" "$home/data/skill-map.md" \
    || fail "skill map regeneration was not byte-idempotent"

  assert_file_contains "$home/data/skill-map.md" '## firstmate' "firstmate skill group missing"
  assert_file_contains "$home/data/skill-map.md" 'firstmate-coding-guidelines' "firstmate internal skill missing"
  assert_file_contains "$home/data/skill-map.md" '## projects/alpha' "project skill group missing"
  assert_file_contains "$home/data/skill-map.md" '- project-skill — folded description — ' "folded description was not collapsed"
  assert_file_contains "$home/data/skill-map.md" '- crlf-skill — crlf-skill description — ' "CRLF frontmatter skill was not mapped"
  assert_file_contains "$home/data/skill-map.md" '## user' "user skill group missing"
  assert_file_contains "$home/data/skill-map.md" '- user-skill — user-skill description — ' "user skill missing"

  before_count=$(grep -c '^- project-skill ' "$home/data/skill-map.md")
  after_count=$before_count
  [ "$after_count" -eq 1 ] || fail "canonical-path de-duplication failed for symlinked project skill"

  pass "skill map scans frontmatter, groups sources, de-dupes canonical paths, and is idempotent"
}

test_skill_compose_reconciles_symlink_set_and_removes() {
  local home="$TMP_ROOT/compose-home" source="$TMP_ROOT/canonical — source" add_dir skills_dir alpha_real beta_real first_target second_target
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  write_skill "$source/beta" beta plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  beta_real=$(cd "$source/beta" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
- beta — beta description — $beta_real
EOF

  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha beta >/dev/null \
    || fail "initial skill composition failed"
  add_dir="$home/config/skill-compose/claude/home"
  skills_dir="$add_dir/.claude/skills"
  [ -L "$skills_dir/alpha" ] || fail "alpha was not composed as a symlink"
  [ -L "$skills_dir/beta" ] || fail "beta was not composed as a symlink"
  [ "$(readlink_real "$skills_dir/alpha")" = "$alpha_real" ] || fail "alpha symlink does not point at canonical source"
  [ "$(readlink_real "$skills_dir/beta")" = "$beta_real" ] || fail "beta symlink does not point at canonical source"
  [ "$(readlink "$skills_dir/alpha")" = "$alpha_real" ] || fail "map delimiter in canonical path was not preserved"
  [ -f "$skills_dir/alpha/SKILL.md" ] || fail "composed alpha skill is not loadable through the symlink"

  first_target=$(readlink "$skills_dir/alpha")
  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha beta >/dev/null \
    || fail "idempotent skill composition failed"
  second_target=$(readlink "$skills_dir/alpha")
  [ "$first_target" = "$second_target" ] || fail "idempotent run rewrote alpha to a different target"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null \
    || fail "subset reconciliation failed"
  [ -L "$skills_dir/alpha" ] || fail "alpha was removed during subset reconciliation"
  [ ! -e "$skills_dir/beta" ] && [ ! -L "$skills_dir/beta" ] || fail "stale beta symlink survived subset reconciliation"
  [ -d "$beta_real" ] || fail "canonical beta source was removed instead of only its symlink"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" --remove alpha >/dev/null \
    || fail "skill un-compose failed"
  [ ! -e "$skills_dir/alpha" ] && [ ! -L "$skills_dir/alpha" ] || fail "alpha symlink survived --remove"
  [ -d "$alpha_real" ] || fail "canonical alpha source was removed by --remove"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha beta >/dev/null \
    || fail "failed to prepare successful clear"
  FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear >/dev/null \
    || fail "skill set clear failed"
  [ ! -e "$add_dir" ] || fail "--clear left the managed composition set behind"
  [ -d "$alpha_real" ] && [ -d "$beta_real" ] \
    || fail "--clear removed a canonical skill source"

  pass "skill compose creates canonical symlinks, reconciles, removes, and clears without touching sources"
}

test_skill_compose_accepts_internal_double_dots_without_traversal() {
  local home="$TMP_ROOT/double-dot-home" source="$TMP_ROOT/double-dot-source" alpha_real composed
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF

  FM_HOME="$home" "$COMPOSE" --target-home "$home" --set task-fix..bug alpha >/dev/null \
    || fail "internal double dots in a composed set name were rejected"
  composed="$home/config/skill-compose/claude/task-fix..bug/.claude/skills/alpha"
  [ -L "$composed" ] || fail "double-dot set did not compose its requested skill"
  [ "$(readlink_real "$composed")" = "$alpha_real" ] || fail "double-dot set symlink lost its canonical target"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set .. alpha >/dev/null 2>&1; then
    fail "traversal set name was accepted"
  fi
  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set ../escape alpha >/dev/null 2>&1; then
    fail "slash traversal set name was accepted"
  fi
  [ ! -e "$home/config/skill-compose/escape" ] || fail "traversal set escaped the Claude composition directory"

  pass "skill compose accepts internal double dots while refusing traversal"
}

test_skill_compose_refuses_non_symlink_collision() {
  local home="$TMP_ROOT/collision-home" source="$TMP_ROOT/collision-source" alpha_real skills_dir
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  skills_dir="$home/config/skill-compose/claude/home/.claude/skills"
  mkdir -p "$skills_dir/alpha"
  if FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null 2>"$home/collision.err"; then
    fail "skill compose replaced a non-symlink collision"
  fi
  assert_file_contains "$home/collision.err" 'refusing to replace non-symlink entry' "collision refusal did not explain the unsafe entry"
  [ -d "$skills_dir/alpha" ] || fail "collision directory was removed"
  [ -d "$alpha_real" ] || fail "canonical alpha source was disturbed after collision refusal"

  pass "skill compose refuses non-symlink collisions"
}

test_skill_compose_prevalidates_before_reconciliation() {
  local home="$TMP_ROOT/prevalidation-home" source="$TMP_ROOT/prevalidation-source" alpha_real beta_real mode skills_dir overlong
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  write_skill "$source/beta" beta plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  beta_real=$(cd "$source/beta" && pwd -P)
  overlong=$(printf 'x%.0s' {1..201})
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
- beta — beta description — $beta_real
- $overlong — overlong description — $alpha_real
EOF

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set invalid alpha bad..name >/dev/null 2>&1; then
    fail "compose accepted an unsafe skill name"
  fi
  [ ! -e "$home/config/skill-compose/claude/invalid" ] \
    || fail "invalid compose arguments created a partial managed set"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set "$overlong" alpha >/dev/null 2>&1; then
    fail "compose accepted an overlong set name"
  fi
  [ ! -e "$home/config/skill-compose/claude/$overlong" ] \
    || fail "overlong set name created managed state"

  FM_HOME="$home" "$COMPOSE" --target-home "$home" --set long-skill alpha >/dev/null \
    || fail "failed to prepare overlong skill-name fixture"
  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set long-skill beta "$overlong" >/dev/null 2>&1; then
    fail "compose accepted an overlong skill name"
  fi
  [ -L "$home/config/skill-compose/claude/long-skill/.claude/skills/alpha" ] \
    || fail "overlong skill name reconciled the managed set"
  [ ! -e "$home/config/skill-compose/claude/long-skill/.claude/skills/beta" ] \
    || fail "overlong skill name partially added another requested skill"

  for mode in compose remove clear; do
    FM_HOME="$home" "$COMPOSE" --target-home "$home" --set "$mode" alpha beta >/dev/null \
      || fail "failed to prepare $mode prevalidation fixture"
    skills_dir="$home/config/skill-compose/claude/$mode/.claude/skills"
    mkdir "$skills_dir/z-collision"
  done

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set remove --remove alpha bad..name >/dev/null 2>&1; then
    fail "remove accepted an unsafe skill name"
  fi
  [ -L "$home/config/skill-compose/claude/remove/.claude/skills/alpha" ] \
    || fail "invalid remove arguments deleted an earlier valid skill"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set clear --clear alpha >/dev/null 2>&1; then
    fail "clear accepted a skill name"
  fi
  [ -L "$home/config/skill-compose/claude/clear/.claude/skills/alpha" ] \
    || fail "invalid clear arguments mutated the managed set"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set compose beta >/dev/null 2>&1; then
    fail "compose reconciled through a non-symlink collision"
  fi
  [ -L "$home/config/skill-compose/claude/compose/.claude/skills/alpha" ] \
    || fail "failed compose removed a stale skill before validating the full set"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set remove --remove alpha >/dev/null 2>&1; then
    fail "remove reconciled through a non-symlink collision"
  fi
  [ -L "$home/config/skill-compose/claude/remove/.claude/skills/alpha" ] \
    || fail "failed remove deleted a skill before validating the full set"

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --set clear --clear >/dev/null 2>&1; then
    fail "clear reconciled through a non-symlink collision"
  fi
  [ -L "$home/config/skill-compose/claude/clear/.claude/skills/alpha" ] \
    || fail "failed clear deleted a skill before validating the full set"

  pass "skill compose prevalidates failures before mutating managed sets"
}

test_skill_compose_refuses_unverified_harnesses() {
  local home="$TMP_ROOT/harness-home" source="$TMP_ROOT/harness-source" alpha_real
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF

  if FM_HOME="$home" "$COMPOSE" --target-home "$home" --harness codex alpha \
    >"$home/harness.out" 2>"$home/harness.err"; then
    fail "skill composition accepted an unverified Codex load point"
  fi
  assert_file_contains "$home/harness.err" 'has no verified per-home load point' \
    "unsupported harness refusal did not explain the missing load point"
  [ ! -e "$home/config/skill-compose" ] \
    || fail "unsupported harness refusal created composition state"

  pass "skill compose refuses harnesses without a verified per-home load point"
}

test_locked_session_start_refreshes_map_and_read_only_skips() {
  local world="$TMP_ROOT/session-world" root home user_home fakebin skill out holder
  root="$world/root"
  home="$world/home"
  user_home="$world/user"
  fakebin="$world/fakebin"
  skill="$root/.agents/skills/session-skill"
  mkdir -p "$skill" "$home/state" "$home/data" "$home/config" \
    "$home/projects" "$user_home/.claude/skills" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial --allow-empty
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_skill "$skill" session-skill plain
  fm_fake_exit0 "$fakebin" tmux node chrome-devtools-axi gh gh-axi treehouse no-mistakes lavish-axi
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' /usr/local/bin/claude ;;
  *"args="*) printf '%s\n' claude ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-session-start.sh") \
    || fail "locked session start failed while refreshing the skill map"
  assert_file_contains "$home/data/skill-map.md" '- session-skill — session-skill description — ' \
    "locked session start did not refresh the generated skill map"
  # The map's source group is the scanned source, not a label derived from the
  # containing git repository, even though $root is a git repo with no remote.
  assert_file_contains "$home/data/skill-map.md" '## firstmate' \
    "the skill map did not group this repo's skills under their source group"
  assert_file_not_contains "$home/data/skill-map.md" '## root' \
    "the skill map labelled a group from its containing git repository"

  # A reported skip must reach the digest, naming the skill, rather than being
  # swallowed or reduced to a blank line.
  mkdir -p "$root/.agents/skills/broken"
  printf -- '---\nname: broken\n' > "$root/.agents/skills/broken/SKILL.md"
  if ! out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-session-start.sh"); then
    fail "locked session start failed because one skill was skipped"
  fi
  case "$out" in
    *"$root/.agents/skills/broken/SKILL.md"*) ;;
    *) fail "the session digest did not surface the skipped skill the map reported" ;;
  esac
  case "$out" in
    *'refresh failed'*) fail "the digest called a written-with-skips map a refresh failure" ;;
    *) ;;
  esac
  rm -rf "$root/.agents/skills/broken"

  printf '%s\n' 'sentinel map must survive read-only session start' > "$home/data/skill-map.md"
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  if ! out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-session-start.sh"); then
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "read-only session start failed while checking the skill-map boundary"
  fi
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" 'READ-ONLY SESSION' \
    "session-start lock fixture did not enter read-only mode"
  [ "$(cat "$home/data/skill-map.md")" = 'sentinel map must survive read-only session start' ] \
    || fail "read-only session start mutated the private skill map"

  pass "locked session start refreshes the skill map and read-only start leaves it untouched"
}

test_skill_compose_serializes_same_set_reconciliation() {
  local home="$TMP_ROOT/locked-home" source="$TMP_ROOT/locked-source" alpha_real beta_real
  local fakebin="$TMP_ROOT/locked-fakebin" real_awk gate first_pid second_pid skills_dir
  mkdir -p "$home/data" "$fakebin"
  write_skill "$source/alpha" alpha plain
  write_skill "$source/beta" beta plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  beta_real=$(cd "$source/beta" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
- beta — beta description — $beta_real
EOF
  real_awk=$(command -v awk)
  gate="$home/awk-gate"
  cat > "$fakebin/awk" <<EOF
#!/usr/bin/env bash
if [ -n "\${FM_TEST_AWK_GATE:-}" ] && /bin/mkdir "\$FM_TEST_AWK_GATE.owner" 2>/dev/null; then
  /usr/bin/touch "\$FM_TEST_AWK_GATE.entered"
  while [ ! -e "\$FM_TEST_AWK_GATE.release" ]; do sleep 0.02; done
fi
exec "$real_awk" "\$@"
EOF
  chmod +x "$fakebin/awk"

  FM_HOME="$home" FM_TEST_AWK_GATE="$gate" PATH="$fakebin:$PATH" \
    "$COMPOSE" --target-home "$home" alpha >/dev/null &
  first_pid=$!
  for _ in $(seq 1 100); do
    [ -e "$gate.entered" ] && break
    sleep 0.02
  done
  [ -e "$gate.entered" ] || fail "first composition did not enter the serialized reconciliation"

  FM_HOME="$home" FM_TEST_AWK_GATE="$gate" PATH="$fakebin:$PATH" \
    "$COMPOSE" --target-home "$home" beta >/dev/null &
  second_pid=$!
  sleep 0.2
  skills_dir="$home/config/skill-compose/claude/home/.claude/skills"
  [ ! -e "$skills_dir/beta" ] && [ ! -L "$skills_dir/beta" ] \
    || fail "second composition mutated the set while the first reconciliation was active"

  touch "$gate.release"
  wait "$first_pid" || fail "first serialized composition failed"
  wait "$second_pid" || fail "second serialized composition failed"
  [ -L "$skills_dir/beta" ] || fail "second serialized composition did not publish its requested set"
  [ ! -e "$skills_dir/alpha" ] && [ ! -L "$skills_dir/alpha" ] \
    || fail "serialized reconciliation left a stale skill from the first request"
  [ "$(readlink_real "$skills_dir/beta")" = "$beta_real" ] \
    || fail "serialized reconciliation published beta with the wrong canonical target"

  pass "skill compose serializes concurrent reconciliation of one set"
}

test_skill_map_bounds_frontmatter_and_reports_skips() {
  local home="$TMP_ROOT/loud-home" user_home="$TMP_ROOT/loud-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/valid-skill" valid-skill plain

  # Frontmatter opened and never closed, followed by megabytes of body whose own
  # `description:` line the parser must never reach.
  mkdir -p "$skills/unterminated"
  {
    printf '%s\n' '---' 'name: unterminated' 'description: header description'
    yes 'padding line that belongs to the skill body' | head -n 80000
    printf '%s\n' 'description: BODY_WAS_PARSED'
  } > "$skills/unterminated/SKILL.md"

  mkdir -p "$skills/unreadable"
  write_skill "$skills/unreadable" unreadable plain
  chmod 000 "$skills/unreadable/SKILL.md"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e
  chmod 644 "$skills/unreadable/SKILL.md"

  [ "$status" -ne 0 ] \
    || fail "map generation stayed silent about malformed and unreadable skills"
  case "$out" in
    *"$skills/unterminated/SKILL.md"*) ;;
    *) fail "map generation did not name the unterminated skill it skipped: $out" ;;
  esac
  case "$out" in
    *"$skills/unreadable/SKILL.md"*) ;;
    *) fail "map generation did not name the unreadable skill it skipped: $out" ;;
  esac
  assert_file_not_contains "$home/data/skill-map.md" 'BODY_WAS_PARSED' \
    "unterminated frontmatter was read through the skill body"
  assert_file_not_contains "$home/data/skill-map.md" '- unterminated — ' \
    "a skill whose frontmatter is never closed was mapped anyway"
  assert_file_contains "$home/data/skill-map.md" '- valid-skill — ' \
    "a valid sibling skill was dropped along with the malformed ones"

  chmod 000 "$skills/unreadable/SKILL.md"
  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$COMPOSE" --target-home "$home" --refresh-map valid-skill 2>&1)
  status=$?
  set -e
  chmod 644 "$skills/unreadable/SKILL.md"
  [ "$status" -eq 0 ] \
    || fail "a reported skill skip blocked composition of the skills that did parse: $out"
  [ -L "$home/config/skill-compose/claude/home/.claude/skills/valid-skill" ] \
    || fail "composition alongside a reported skip did not publish the valid skill"

  pass "skill map is closed-delimiter bound, names every skipped skill, and still composes"
}

test_skill_map_reports_unreadable_skill_md_kinds() {
  local home="$TMP_ROOT/kinds-home" user_home="$TMP_ROOT/kinds-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/valid-skill" valid-skill plain

  # A SKILL.md that exists but is not a readable regular file is a skill this scan
  # cannot read, so each kind must be reported rather than dropped.
  mkdir -p "$skills/dir-skill-md/SKILL.md"
  mkdir -p "$skills/dangling"
  ln -s /nonexistent/target "$skills/dangling/SKILL.md"
  mkdir -p "$skills/fifo"
  mkfifo "$skills/fifo/SKILL.md"
  # An unsearchable skill folder hides its own SKILL.md from every stat, so the
  # folder itself must be reported rather than vanishing.
  mkdir -p "$skills/unsearchable"
  write_skill "$skills/unsearchable" unsearchable plain
  chmod 000 "$skills/unsearchable"
  # A folder with no SKILL.md at all is not a skill and must stay unreported.
  mkdir -p "$skills/not-a-skill-folder"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e
  chmod 755 "$skills/unsearchable"

  [ "$status" -ne 0 ] || fail "map generation stayed silent about unreadable SKILL.md kinds: $out"
  case "$out" in
    *"$skills/dir-skill-md/SKILL.md"*) ;;
    *) fail "a SKILL.md that is a directory was skipped without being named: $out" ;;
  esac
  case "$out" in
    *"$skills/dangling/SKILL.md"*) ;;
    *) fail "a dangling SKILL.md symlink was skipped without being named: $out" ;;
  esac
  case "$out" in
    *"$skills/fifo/SKILL.md"*) ;;
    *) fail "a SKILL.md that is a FIFO was skipped without being named: $out" ;;
  esac
  case "$out" in
    *"$skills/unsearchable"*) ;;
    *) fail "an unsearchable skill folder was skipped without being named: $out" ;;
  esac
  case "$out" in
    *not-a-skill-folder*) fail "a folder with no SKILL.md was reported as a skipped skill: $out" ;;
    *) ;;
  esac
  case "$out" in
    *'4 skill(s) skipped'*) ;;
    *) fail "the skipped count did not match the four unreadable skills: $out" ;;
  esac
  assert_file_contains "$home/data/skill-map.md" '- valid-skill — ' \
    "the valid sibling skill was dropped alongside the unreadable ones"

  pass "skill map names every unreadable SKILL.md kind and counts each one"
}

test_skill_map_stops_reading_at_its_frontmatter_bound() {
  local home="$TMP_ROOT/bound-home" user_home="$TMP_ROOT/bound-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Frontmatter that IS properly closed, but whose closing delimiter sits beyond
  # the generator's byte bound. Only the bound can refuse this one: the
  # closed-delimiter check alone would accept it after reading the whole file.
  mkdir -p "$skills/past-bound"
  {
    printf '%s\n' '---' 'name: past-bound' 'description: past-bound description'
    yes '  padding: this indented line sits inside the frontmatter block' | head -n 2000
    printf '%s\n' '---' 'body'
  } > "$skills/past-bound/SKILL.md"
  [ "$(wc -c < "$skills/past-bound/SKILL.md")" -gt 65536 ] \
    || fail "the past-bound fixture is not larger than the generator's byte bound"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] \
    || fail "frontmatter closed past the byte bound was accepted, so nothing bounds the read: $out"
  case "$out" in
    *"$skills/past-bound/SKILL.md"*) ;;
    *) fail "the past-bound skill was not named as skipped: $out" ;;
  esac
  assert_file_not_contains "$home/data/skill-map.md" '- past-bound — ' \
    "a skill whose frontmatter closes past the byte bound was mapped anyway"

  pass "skill map stops reading each SKILL.md at its frontmatter byte bound"
}

test_skill_map_refuses_a_delimiter_manufactured_by_the_bound() {
  local home="$TMP_ROOT/trunc-home" user_home="$TMP_ROOT/trunc-user" skills out status pad header
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Frontmatter that is never closed, plus a longer run of dashes placed so the
  # byte bound cuts it to exactly three. The bound must not manufacture the
  # closing delimiter it exists to require.
  # The run starts at offset 65533, so bytes 65533..65535 are "---" and the
  # truncated final line looks exactly like a closing delimiter.
  mkdir -p "$skills/manufactured"
  header="$TMP_ROOT/manufactured.header"
  printf -- '---\nname: manufactured\ndescription: manufactured description\n' > "$header"
  pad=$((65532 - $(wc -c < "$header")))
  [ "$pad" -gt 0 ] || fail "the manufactured-close fixture header does not fit under the bound"
  {
    cat "$header"
    head -c "$pad" /dev/zero | tr '\0' 'x'
    printf -- '\n-------\nbody\n'
  } > "$skills/manufactured/SKILL.md"
  [ "$(head -c 65536 "$skills/manufactured/SKILL.md" | tail -c 4)" = "$(printf -- '\n---')" ] \
    || fail "the manufactured-close fixture does not truncate to a bare --- at the bound"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] \
    || fail "a dash run truncated by the byte bound was accepted as a closing delimiter: $out"
  assert_file_not_contains "$home/data/skill-map.md" '- manufactured — ' \
    "unclosed frontmatter was mapped because the bound manufactured its delimiter"

  pass "skill map refuses a closing delimiter manufactured by truncation"
}

test_skill_map_refuses_unusable_skill_names() {
  local home="$TMP_ROOT/names-home" user_home="$TMP_ROOT/names-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/alpha-skill" alpha-skill plain

  # A name carrying the map's own separator would shadow or redirect another skill
  # when the map is read back, so it must never reach the map.
  mkdir -p "$skills/separator"
  printf -- '---\nname: alpha-skill — hijacked\ndescription: d\n---\nbody\n' \
    > "$skills/separator/SKILL.md"
  # A block-scalar name used to be emitted as the literal block indicator.
  mkdir -p "$skills/blockname"
  printf -- '---\nname: >-\n  real-name\ndescription: d\n---\nbody\n' \
    > "$skills/blockname/SKILL.md"
  # A name ending in an em dash forms a separator against the renderer's own
  # spacing, so the reader splits inside the name and resolves the wrong folder.
  mkdir -p "$skills/boundary"
  printf -- '---\nname: alpha-skill \xe2\x80\x94\ndescription: attacker skill\n---\nATTACKER\n' \
    > "$skills/boundary/SKILL.md"
  # A leading em dash is the mirror image of the same trick.
  mkdir -p "$skills/leading"
  printf -- '---\nname: \xe2\x80\x94 alpha-skill\ndescription: attacker skill\n---\nATTACKER\n' \
    > "$skills/leading/SKILL.md"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "unusable skill names were accepted silently: $out"
  assert_file_not_contains "$home/data/skill-map.md" 'hijacked' \
    "a name carrying the map separator reached the map"
  assert_file_not_contains "$home/data/skill-map.md" '- >- — ' \
    "a block-scalar name was emitted as the literal block indicator"
  assert_file_contains "$home/data/skill-map.md" '- alpha-skill — alpha-skill description — ' \
    "the legitimate skill was lost or shadowed by the unusable names"
  assert_file_not_contains "$home/data/skill-map.md" 'attacker skill' \
    "a name forming a separator at the field boundary reached the map"

  # The legitimate name must still resolve to its own folder, not an attacker's,
  # and must not have become ambiguous.
  FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" alpha-skill \
    >/dev/null || fail "a crafted name made the legitimate skill unresolvable"
  [ "$(readlink_real "$home/config/skill-compose/claude/home/.claude/skills/alpha-skill")" \
    = "$(cd "$skills/alpha-skill" && pwd -P)" ] \
    || fail "the trusted skill name resolved to a folder the crafted name chose"

  pass "skill map refuses every skill name that could form the record separator"
}

test_skill_map_keeps_em_dash_descriptions_out_of_the_separator() {
  local home="$TMP_ROOT/desc-home" user_home="$TMP_ROOT/desc-user" skills
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Valid human YAML whose description carries em dashes where the old single
  # spaced-separator replacement could not reach, or re-formed one.
  mkdir -p "$skills/trailing"
  printf -- '---\nname: trailing\ndescription: Audit the thing \xe2\x80\x94\n---\nbody\n' \
    > "$skills/trailing/SKILL.md"
  mkdir -p "$skills/doubled"
  printf -- '---\nname: doubled\ndescription: a \xe2\x80\x94 \xe2\x80\x94 b\n---\nbody\n' \
    > "$skills/doubled/SKILL.md"

  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "a description carrying an em dash was refused instead of sanitized"

  # Each record must still carry exactly three separators, so the reader's split
  # finds the real canonical folder.
  local name
  for name in trailing doubled; do
    FM_HOME="$home" "$COMPOSE" --target-home "$home" --map "$home/data/skill-map.md" "$name" \
      >/dev/null || fail "an em-dash description made $name unresolvable"
    [ "$(readlink_real "$home/config/skill-compose/claude/home/.claude/skills/$name")" \
      = "$(cd "$skills/$name" && pwd -P)" ] \
      || fail "an em-dash description redirected $name away from its canonical folder"
  done

  pass "skill map sanitizes every em dash out of a description rather than refusing it"
}

test_skill_compose_refuses_a_relative_mapped_path() {
  local home="$TMP_ROOT/relpath-home" out status
  mkdir -p "$home/data"
  cat > "$home/data/skill-map.md" <<'MAPEOF'
# Skill map

## fixture
- relskill — d — relative/decoy/path
MAPEOF
  set +e
  out=$(cd "$home" && FM_HOME="$home" "$COMPOSE" --target-home "$home" \
    --map "$home/data/skill-map.md" relskill 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a relative mapped path was composed: $out"
  case "$out" in
    *'not absolute'*) ;;
    *) fail "the refusal did not name the relative mapped path: $out" ;;
  esac

  pass "skill compose refuses a mapped skill path that is not absolute"
}

test_skill_map_reports_an_unreadable_source_directory() {
  local home="$TMP_ROOT/srcdir-home" user_home="$TMP_ROOT/srcdir-user" skills out status
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"
  write_skill "$skills/one" one plain
  write_skill "$skills/two" two plain
  write_skill "$user_home/.claude/skills/user-skill" user-skill plain
  chmod 0111 "$skills"

  set +e
  out=$(HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet 2>&1)
  status=$?
  set -e
  chmod 0755 "$skills"

  [ "$status" -ne 0 ] \
    || fail "an unreadable skill source directory dropped every skill silently: $out"
  case "$out" in
    *"$skills"*) ;;
    *) fail "the unreadable source directory was not named: $out" ;;
  esac
  assert_file_contains "$home/data/skill-map.md" '- user-skill — ' \
    "a readable source was dropped along with the unreadable one"

  pass "skill map names an unreadable skill source directory instead of reporting no skills"
}

test_skill_map_accepts_a_delimiter_at_end_of_file() {
  local home="$TMP_ROOT/eof-home" user_home="$TMP_ROOT/eof-user" skills
  skills="$home/projects/alpha/.claude/skills"
  mkdir -p "$home/data" "$skills" "$user_home/.claude/skills"
  printf '%s\n' '- alpha [no-mistakes] - fixture project' > "$home/data/projects.md"

  # Valid, fully closed frontmatter whose last byte is the closing delimiter.
  # The truncation guard must not refuse a delimiter at a real end of file.
  mkdir -p "$skills/no-trailing-newline"
  printf -- '---\nname: no-trailing-newline\ndescription: valid frontmatter\n---' \
    > "$skills/no-trailing-newline/SKILL.md"

  HOME="$user_home" CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "a closing delimiter at a real end of file was refused as truncated"
  assert_file_contains "$home/data/skill-map.md" '- no-trailing-newline — valid frontmatter — ' \
    "valid frontmatter ending at the closing delimiter was not mapped"

  pass "skill map accepts a closing delimiter at a real end of file"
}

test_skill_compose_clear_collapses_a_legacy_set() {
  local home="$TMP_ROOT/legacy-home" source="$TMP_ROOT/legacy-source" alpha_real add_dir out
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null \
    || fail "failed to prepare the legacy clear fixture"
  add_dir="$home/config/skill-compose/claude/home"
  # A set composed by a version that still generated manifest.tsv.
  printf 'alpha\t%s\n' "$alpha_real" > "$add_dir/manifest.tsv"

  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear) \
    || fail "clear failed on a legacy set"
  [ ! -e "$add_dir" ] \
    || fail "clear reported success but left the legacy set root behind: $out ($(find "$add_dir"))"
  [ -d "$alpha_real" ] || fail "clear removed the canonical skill source"

  pass "skill compose clear collapses a set left behind by a manifest-writing version"
}

test_skill_compose_clear_reports_what_it_could_not_remove() {
  local home="$TMP_ROOT/clearhonest-home" source="$TMP_ROOT/clearhonest-source"
  local alpha_real add_dir skills_dir out
  mkdir -p "$home/data"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  FM_HOME="$home" "$COMPOSE" --target-home "$home" alpha >/dev/null \
    || fail "failed to prepare the honest-clear fixture"
  add_dir="$home/config/skill-compose/claude/home"
  skills_dir="$add_dir/.claude/skills"
  # Something the helper does not own, such as a file Claude itself wrote under
  # the added directory, keeps the set root alive after every link is gone.
  printf '%s\n' '{}' > "$add_dir/settings.local.json"

  out=$(FM_HOME="$home" "$COMPOSE" --target-home "$home" --clear) \
    || fail "clear failed with an unowned file in the set root"
  [ ! -e "$skills_dir/alpha" ] && [ ! -L "$skills_dir/alpha" ] \
    || fail "clear left a composed skill link behind"
  case "$out" in
    *'still holds'*) ;;
    *) fail "clear claimed success while the set root survived: $out" ;;
  esac
  case "$out" in
    *settings.local.json*) ;;
    *) fail "clear did not name what kept the set root alive: $out" ;;
  esac
  [ -d "$alpha_real" ] || fail "clear removed the canonical skill source"

  pass "skill compose clear reports the set root it could not remove"
}

test_skill_map_scans_hidden_projects_and_config_dir_without_home() {
  local home="$TMP_ROOT/discovery-home" user_home="$TMP_ROOT/discovery-user"
  mkdir -p "$home/data" "$home/projects/.hidden/.claude/skills" "$user_home/.claude/skills"
  printf '%s\n' '- .hidden [no-mistakes] - registered dot-prefixed project' > "$home/data/projects.md"
  write_skill "$home/projects/.hidden/.claude/skills/hidden-skill" hidden-skill plain
  write_skill "$user_home/.claude/skills/config-dir-skill" config-dir-skill plain

  env -u HOME CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "skill map generation failed with HOME unset"

  assert_file_contains "$home/data/skill-map.md" '- hidden-skill — ' \
    "a registered dot-prefixed project was not scanned"
  assert_file_contains "$home/data/skill-map.md" '- config-dir-skill — ' \
    "CLAUDE_CONFIG_DIR skills were skipped because HOME was unset"

  pass "skill map scans registered dot-prefixed projects and honors CLAUDE_CONFIG_DIR without HOME"
}

test_skill_compose_refuses_symlinked_managed_ancestry() {
  local home="$TMP_ROOT/escape-home" target="$TMP_ROOT/escape-target"
  local source="$TMP_ROOT/escape-source" alpha_real tracked out status level
  mkdir -p "$home/data" "$target/config/skill-compose/claude/home/.claude"
  write_skill "$source/alpha" alpha plain
  alpha_real=$(cd "$source/alpha" && pwd -P)
  cat > "$home/data/skill-map.md" <<EOF
# Skill map

## fixture
- alpha — alpha description — $alpha_real
EOF
  # The tracked tree holds only symlinks, exactly like a real .agents/skills set,
  # so nothing but the ancestry check itself can refuse this composition.
  tracked="$target/.agents/skills"
  mkdir -p "$tracked"
  write_skill "$source/keep" keep plain
  ln -s "$(cd "$source/keep" && pwd -P)" "$tracked/keep"

  # Every managed level must be refused, not just the innermost one: the compose
  # lock's own mkdir -p creates the upper levels, so a symlink at any of them
  # would be followed on the way down.
  for level in \
    config \
    config/skill-compose \
    config/skill-compose/claude \
    config/skill-compose/claude/home \
    config/skill-compose/claude/home/.claude \
    config/skill-compose/claude/home/.claude/skills; do
    rm -rf "$target/config"
    mkdir -p "$target/$(dirname "$level")"
    ln -s "$tracked" "$target/$level"

    set +e
    out=$(FM_HOME="$home" "$COMPOSE" --target-home "$target" alpha 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] \
      || fail "composition followed the symlinked managed path $level instead of refusing: $out"
    case "$out" in
      *'refusing to compose through a symlinked managed path'*) ;;
      *) fail "refusal for $level did not name the symlinked managed path: $out" ;;
    esac
    [ -L "$tracked/keep" ] \
      || fail "refused composition at $level deleted an unrelated skill from the tracked tree"
    [ ! -e "$tracked/alpha" ] && [ ! -L "$tracked/alpha" ] \
      || fail "refused composition at $level wrote a composed link into the tracked tree"
  done

  pass "skill compose refuses a symlink at every managed ancestry level before any mutation"
}

test_zeta_obsidian_consumer_composes_from_cold_home() {
  local home="$TMP_ROOT/zeta-home" user_home="$TMP_ROOT/zeta-user"
  local target="$TMP_ROOT/zeta-target" skills_dir name
  mkdir -p "$home/data" "$home/projects/.zeta/.claude/skills" "$user_home/.claude/skills" "$target"
  printf '%s\n' '- .zeta [no-mistakes] - Zeta distribution clone' > "$home/data/projects.md"
  write_skill "$home/projects/.zeta/.claude/skills/verify" verify plain
  for name in obsidian-cli obsidian-bases obsidian-markdown; do
    write_skill "$user_home/.claude/skills/$name" "$name" plain
  done

  env -u HOME CLAUDE_CONFIG_DIR="$user_home/.claude" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$MAP" --output "$home/data/skill-map.md" --quiet \
    || fail "cold-home map generation failed for the Zeta and Obsidian consumer"

  FM_HOME="$home" "$COMPOSE" --target-home "$target" --map "$home/data/skill-map.md" \
    verify obsidian-cli obsidian-bases obsidian-markdown >/dev/null \
    || fail "the Zeta and Obsidian skill set did not compose"

  skills_dir="$target/config/skill-compose/claude/home/.claude/skills"
  for name in verify obsidian-cli obsidian-bases obsidian-markdown; do
    [ -L "$skills_dir/$name" ] || fail "$name was not composed as a symlink"
    [ -f "$skills_dir/$name/SKILL.md" ] \
      || fail "$name is not loadable through the composed overlay"
  done

  pass "the Zeta project skill and Obsidian user skills compose into one loadable cold-home overlay"
}

test_skill_map_generates_flat_deduped_registry
test_skill_map_bounds_frontmatter_and_reports_skips
test_skill_map_reports_unreadable_skill_md_kinds
test_skill_map_stops_reading_at_its_frontmatter_bound
test_skill_map_refuses_a_delimiter_manufactured_by_the_bound
test_skill_map_refuses_unusable_skill_names
test_skill_map_keeps_em_dash_descriptions_out_of_the_separator
test_skill_map_reports_an_unreadable_source_directory
test_skill_map_accepts_a_delimiter_at_end_of_file
test_skill_map_scans_hidden_projects_and_config_dir_without_home
test_zeta_obsidian_consumer_composes_from_cold_home
test_skill_compose_reconciles_symlink_set_and_removes
test_skill_compose_accepts_internal_double_dots_without_traversal
test_skill_compose_refuses_non_symlink_collision
test_skill_compose_refuses_a_relative_mapped_path
test_skill_compose_refuses_symlinked_managed_ancestry
test_skill_compose_clear_collapses_a_legacy_set
test_skill_compose_clear_reports_what_it_could_not_remove
test_skill_compose_prevalidates_before_reconciliation
test_skill_compose_refuses_unverified_harnesses
test_locked_session_start_refreshes_map_and_read_only_skips
test_skill_compose_serializes_same_set_reconciliation
