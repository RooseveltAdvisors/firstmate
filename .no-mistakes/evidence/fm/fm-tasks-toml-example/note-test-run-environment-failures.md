# Targeted test run: environment-only failures (not caused by this branch)

Run from the run worktree, branch `fm/fm-tasks-toml-example`, target `3ad567b3`.

## Green (branch-relevant suites)

- `bash tests/fm-bootstrap.test.sh` — rc=0, all 36 pass, including the 8 new
  `tasks_config_*` cases (see `test-fm-bootstrap.log`).
- `bash tests/fm-update.test.sh` — rc=0, all 21 pass, including T3f, T3g,
  T13, T14, T15 (see `test-fm-update.log`).
- `bash tests/fm-secondmate-sync.test.sh` — rc=0, all 35 pass, including
  T3b, T11b, R1c (see `test-fm-secondmate-sync.log`).
- `bash tests/fm-tasks-axi.test.sh` — rc=0, all 9 pass
  (see `test-fm-tasks-axi.log`).

## tests/fm-test-run.test.sh fails on this host for two pre-existing reasons

Log: `test-fm-test-run.log` (default locale, en_US.UTF-8).

1. **Locale sensitivity of `bin/fm-test-run.sh --check-coverage` (pre-existing).**
   Under the host default locale, GNU `comm` rejects the guard's
   `LC_ALL=C sort`-ordered inputs ("comm: file 2 is not in sorted order" /
   "comm: input is not in sorted order") and the script exits 1 under
   `set -e`; the test file (which runs under `set -e`) then exits silently at
   `out=$(bin/fm-test-run.sh --check-coverage)` inside
   `test_portable_shard_union_and_coverage_guard`.
   Proof it predates the branch: the BASE commit's own copy of the script
   behaves identically —
   `git show 65e2aa443a42108689eee260a0d792608ec3540b:bin/fm-test-run.sh`
   run in a disposable checkout gives the same failure:

   ```
   BASE --check-coverage (default locale) rc=1
   comm: file 2 is not in sorted order
   comm: input is not in sorted order
   BASE --check-coverage (LC_ALL=C) rc=0
   FM_TEST_COVERAGE ok total=243 parallel=24 ...
   ```

   The branch's diff to `bin/fm-test-run.sh` touches only the
   `families_for_changed_path` selection arms (used by `--changed`), which
   the coverage guard never consults. The branch's own added test in this
   file does pass in the default-locale run:
   `ok - a fast-forward library change selects the families that actually cover it`.

2. **`tests/fm-session-lock-ancestry.test.sh` fails standalone on this host.**
   Re-running the suite with `LC_ALL=C` gets past the coverage guard and fails
   only at `test_jobs_admits_a_concurrent_safe_family`, because that test runs
   the real `tests/fm-session-lock-ancestry.test.sh`, which fails on this
   machine with `not ok - the pty-host was not reparented to init after the
   daemon ended`. Standalone: `bash tests/fm-session-lock-ancestry.test.sh`
   → rc=1 with the same line (log: `test-fm-session-lock-ancestry.log`).
   That file and the session-lock code are untouched by this branch — a
   host-behavior (pty daemon reparenting) failure, not a regression here.

Both failures are environmental/pre-existing; neither is introduced or
exposed by this change's edits.
