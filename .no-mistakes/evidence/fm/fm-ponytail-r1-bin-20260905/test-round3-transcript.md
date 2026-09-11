# Test round: fixtures/stdlib/dead-function/one-caller-lib round (branch fm/fm-ponytail-r1-bin)

Environment: umask 022, LC_ALL=C (host-locale/umask quirks documented in round 1; public-followup run under default locale).

## Fixture fixes applied in the worktree (test-related only)
- tests/fm-bearings-board.test.sh:661: replaced `cp "$ROOT/.tasks.toml" ...` with `fm_test_write_tasks_config "$home"` (missed call site of the round-2 fix; the tracked .tasks.toml no longer exists).
- tests/fm-test-run.test.sh `init_primary_and_linked_worktree`: fixture repos now also copy `bin/fm-stdlib.sh` (fm-test-run.sh gained a stdlib dependency, so fake repos sourcing it failed with "No such file or directory").

## Suite results (all PASS)
- tests/fm-stdlib.test.sh (includes "sha256_file fails explicitly when no SHA-256 tool is available")
- tests/fm-gitignore-config.test.sh (scratchpad ignore + clean porcelain)
- tests/fm-gotmp.test.sh (no more duplicate-ln stderr noise)
- tests/fm-captain-hold-lifecycle.test.sh (incl. concrete-origin bind composed-identity coverage)
- tests/fm-backlog-atomicity.test.sh
- tests/fm-bearings-board.test.sh
- tests/fm-backlog-handoff.test.sh
- tests/fm-test-run.test.sh
- tests/fm-public-followup.test.sh (default locale)
- tests/fm-secondmate-harness.test.sh, tests/fm-secondmate-sync.test.sh, tests/fm-remote-transport-lanes.test.sh, tests/fm-session-start.test.sh (ff-lib consumers exercising the stdlib path_is_ancestor_of)

## Behavioral spot checks
- `git check-ignore` confirms projects/, state/, data/, scratchpad*, .no-mistakes/, .lavish/,
  .fm-secondmate-home, .fm-secondmate-parent, .DS_Store, .tasks.toml are all ignored again;
  `git status --porcelain` shows only the two intentional test-fixture edits above.
- `bash bin/fm-bearings-board.sh --help` renders the captain-facing help and exits 0.
