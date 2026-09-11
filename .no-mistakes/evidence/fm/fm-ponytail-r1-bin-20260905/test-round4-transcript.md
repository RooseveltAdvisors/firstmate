# Test round 4 — targeted validation after review round 3 fixes

Worktree: `/home/jon/.no-mistakes/worktrees/46339c0817e0/01M263SGD6TNHB7GM72588XN2C`
HEAD: `91be582a` (branch `fm/fm-ponytail-r1-bin-20260905`), clean `git status --porcelain`.

Environment: `umask 022` (avoids fm-procevent private-dir guard on group-writable test homes) and `LC_ALL=C` (avoids locale-sensitive `comm` in fm-test-run.sh) — both quirks verified pre-existing at base, documented in `environment-locale-findings.md`.

## Suites run (all passing)

| Suite | Result | Covers |
|---|---|---|
| `tests/fm-gitignore-config.test.sh` | all ok, rc=0 | Round-3 fix: restored upstream ignore rules (`projects/ state/ data/ scratchpad* .no-mistakes/ .lavish/ .fm-secondmate-home .fm-secondmate-parent .DS_Store`) plus `.tasks.toml` untrack |
| `tests/fm-gotmp.test.sh` | all ok, rc=0, zero `ln: failed ... File exists` stderr lines | Round-1 fix: duplicate `ln -s` removed in both fixture blocks |
| `tests/fm-stdlib.test.sh` | all ok, rc=0 (incl. "sha256_file fails explicitly when no SHA-256 tool is available") | New consolidated stdlib |
| `tests/fm-test-run.test.sh` | all ok, rc=0 | Round-3 fix: fixture copies `bin/fm-stdlib.sh` into fake repos |
| `tests/fm-bearings-board.test.sh` | all ok, rc=0 | Round-3 fix: `fm_test_write_tasks_config` call site |
| `tests/fm-captain-hold-lifecycle.test.sh` | 50 ok, rc=0, incl. "a concrete-origin binding resolves a short key through the composed legacy identity" | Round-2 user-approved bind `<source> <origin>` coverage + legacy-record compatibility port |
| `tests/fm-bootstrap.test.sh` | all ok, rc=0 | ff-lib now sources stdlib; `path_is_ancestor_of` used via `bin/fm-ff-lib.sh` |
| `tests/fm-fleet-snapshot-view.test.sh` | all ok, rc=0 | ff-lib consumer regression check |

## End-to-end gitignore behavior check (consumer-level)

From the repo root with captain-private dirs created live:

```
mkdir -p state data projects scratchpad-test .no-mistakes .lavish
git status --porcelain   # -> empty (clean home; guarded sync paths unblocked)
git check-ignore -v state data projects scratchpad-test .no-mistakes .lavish .tasks.toml
# .gitignore:2:state/	state
# .gitignore:3:data/	data
# .gitignore:1:projects/	projects
# .gitignore:4:scratchpad*	scratchpad-test
# .gitignore:5:.no-mistakes/	.no-mistakes
# .gitignore:6:.lavish/	.lavish
# .gitignore:16:.tasks.toml	.tasks.toml
```

Confirms the restored upstream coverage takes effect through the real consumer (`git`), and the approved `.tasks.toml` untrack correction is retained. Transient dirs removed afterwards; worktree clean again.

## Prior-round evidence

- `concrete-origin-bind-evidence.md` — bind `<source> <origin>` composed-identity behavior proof
- `final-targeted-sweep-transcript.txt`, `test-round3-transcript.md` — earlier sweeps
- `environment-locale-findings.md` — pre-existing LC_ALL/umask quirks
