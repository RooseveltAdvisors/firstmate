#!/usr/bin/env bash
# Throwaway manual driver (test-phase evidence, NOT repo source).
# Drives the REAL bin/fm-session-lock-lib.sh process-identity interface for
# intent item 3: `kimi-code` (Kimi 2.4.1's live process name) must resolve to
# the kimi family through the UNANCHORED `kimi` alternative in FM_HARNESS_RE -
# no dedicated ^kimi-code$ alternative - and FM_HARNESS_NAMES must stay in
# sync with FM_HARNESS_RE (the file's stated invariant).
set -u
ROOT={run-worktree}
FAILURES=0
check() { if [ "$1" = ok ]; then printf 'ok - %s\n' "$2"; else printf 'NOT OK - %s\n' "$2"; FAILURES=$((FAILURES + 1)); fi; }

# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"

echo "FM_HARNESS_RE=[$FM_HARNESS_RE]"
echo "FM_HARNESS_NAMES=[${FM_HARNESS_NAMES[*]}]"

echo "--- Kimi 2.4.1 process names resolve to the kimi family (oracle: intent item 3 + docs/verification/runtime-backends.md Kimi 2.4.1 process-name contract) ---"
if fm_harness_process_matches 'kimi-code' 'kimi-code'; then
  check ok "a process whose comm is kimi-code is recognized as a harness (via the unanchored kimi alternative)"
else
  check fail "a process whose comm is kimi-code is recognized as a harness (via the unanchored kimi alternative)"
fi
if fm_harness_process_matches 'kimi' 'kimi --auto'; then
  check ok "a process whose comm is kimi is still recognized (historical name preserved)"
else
  check fail "a process whose comm is kimi is still recognized (historical name preserved)"
fi

echo "--- FM_HARNESS_NAMES / FM_HARNESS_RE sync (plausible wrong: a name table that drifts from the regex so one consumer recognizes what the other does not) ---"
for name in "${FM_HARNESS_NAMES[@]}"; do
  # regex side accepts every listed executable name
  if fm_harness_process_matches "$name" "$name"; then
    check ok "RE side accepts the FM_HARNESS_NAMES entry '$name'"
  else
    check fail "RE side accepts the FM_HARNESS_NAMES entry '$name'"
  fi
  # names side resolves every listed name as a path component
  got=$(fm_harness_path_name "/opt/$name/bin/tool" || true)
  [ "$got" = "$name" ] && check ok "path side resolves the FM_HARNESS_NAMES entry '$name'" \
    || check fail "path side resolves the FM_HARNESS_NAMES entry '$name' (got '$got')"
done
# every regex family token has a NAMES entry (kimi-code deliberately does not:
# it is a live process name, not an executable name; the launcher is `kimi`)
for fam in claude codex opencode grok kimi pi; do
  found=no
  for name in "${FM_HARNESS_NAMES[@]}"; do [ "$name" = "$fam" ] && found=yes; done
  [ "$found" = yes ] && check ok "FM_HARNESS_NAMES carries the regex family '$fam'" \
    || check fail "FM_HARNESS_NAMES carries the regex family '$fam'"
done

echo "--- negatives: unrelated commands are not claimed ---"
if fm_harness_process_matches 'bash' 'bash -lc foo'; then
  check fail "an ordinary bash process is not claimed as a harness"
else
  check ok "an ordinary bash process is not claimed as a harness"
fi
if fm_harness_process_matches 'sleep' 'sleep 300'; then
  check fail "an ordinary sleep process is not claimed as a harness"
else
  check ok "an ordinary sleep process is not claimed as a harness"
fi
got=$(fm_harness_path_name "~/bin/tool" || true)
[ -z "$got" ] && check ok "an ordinary path resolves no harness name" \
  || check fail "an ordinary path resolves no harness name (got '$got')"

echo
echo "RESULT: $FAILURES failure(s)"
exit "$FAILURES"
