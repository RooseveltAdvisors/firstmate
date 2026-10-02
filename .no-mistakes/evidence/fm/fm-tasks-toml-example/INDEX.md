# Live validation evidence — fm/fm-tasks-toml-example (target 3ad567b3)

All scenarios were driven against the real scripts (the product) in disposable
lab homes / synthetic git worlds under $TMPDIR, torn down after the run.
"Remote host" legs ran the real host-side code through a local `FM_SSH_BIN`
transport stand-in (`fm-remote-secondmate-control.sh` executed from the world's
remote code root), since no second machine is available here.

| # | Scenario | Evidence file |
|---|----------|---------------|
| 1 | Fresh home session start silently materializes `.tasks.toml` byte-identical to `.tasks.toml.example` (marked lab home, `bin/fm-session-start.sh`, gate contract: env -u overrides, lab marker) | `s1-session-start.txt` |
| 2 | The real `tasks-axi` consumes the materialized config: 11 add/start/done cycles keep 10 done rows (done_keep=10) and archive the 11th to `data/done-archive.md` | `s2-tasks-axi-consumes-config.txt` |
| 3 | A pre-existing customized `.tasks.toml` survives a session start byte-for-byte, no TASKS_CONFIG line | `s3-evidence.txt`, `s3-session-start-existing-config.txt` |
| 4 | Unwritable home: bootstrap completes rc=0, prints `TASKS_CONFIG: could not create ...`, leaves no partial/temp file | `s4-evidence.txt`, `s4-bootstrap-unwritable.txt` |
| 5 | Relocated (renamed) data dir: config lands at the data dir's parent with readdressed paths; tasks-axi archives into the renamed dir, not FM_HOME | `s5-evidence.txt`, `s5-bootstrap-relocated.txt` |
| 6 | `bin/fm-update.sh` carries `.tasks.toml` across the untracking advance for the PRIMARY checkout and a secondmate worktree home, reports `TASKS_CONFIG: restored ...` for both, files byte-identical | `s6-fm-update-carry.txt` |
| 7 | Adversarial: customized still-tracked `.tasks.toml` blocks the advance with a reason naming the file + recovery command; HEAD unchanged; customization intact | `s7-evidence.txt`, `s7-fm-update-dirty.txt` |
| 8 | Adversarial: a live writer (post-merge hook) during the advance window is never reverted; no restore falsely claimed (0 TASKS_CONFIG lines) | `s8-evidence.txt`, `s8-fm-update-live-writer.txt` |
| 9 | Remote lane success: operator stdout carries both host diagnostics AND the parseable `remote secondmate sm1: updated on ...` line; remote code root + remote home both kept byte-identical config | `s9-remote-update-success.txt` (+ empty `.err`) |
| 10 | Remote lane failure: real skip reason reported (`... sync skipped: dirty working tree`), diagnostic surfaced separately, never presented as the reason; dirty home untouched | `s10-remote-update-failure.txt`, `s10-remote-update-failure.err` |
| 11 | `bin/fm-test-run.sh --changed --list` schedules this change's own tests (fm-bootstrap/fm-update/fm-secondmate-sync/fm-test-run) | `s11-test-run-changed-selection.txt` |

Supporting targeted suite runs: `test-fm-bootstrap.log`,
`test-fm-update.log`, `test-fm-secondmate-sync.log`, `test-fm-tasks-axi.log`
(all green). Environment-only failures in `test-fm-test-run.log` are explained,
with a base-commit reproduction, in `note-test-run-environment-failures.md`.
