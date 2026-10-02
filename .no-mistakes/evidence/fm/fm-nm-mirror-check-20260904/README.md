# Test-phase evidence: NO_MISTAKES_MIRROR bootstrap change

Branch `fm/fm-nm-mirror-check-20260904`, head `a1553be4`, base `8690c411`.

All product scenarios were driven against the real scripts (`bin/fm-bootstrap.sh`,
`bin/fm-session-start.sh`) from this worktree, against a disposable lab home
minted with `bin/fm-lab-home.sh create` at `/tmp/fm-lab.zMw1Y6` (registry,
clones, and firstmate checkouts were fixtures; `NM_HOME` was pinned to the lab
except in the labelled default-root scenarios). The lab was removed at the end
of the evidence turn; the worktree is clean.

## Scenario -> evidence map

| Scenario | Evidence |
|---|---|
| Drift reported at real session start (firstmate + project legs, exact 6-line contract) | `session-start-digest.log` (BOOTSTRAP section), `scenario-drive.log` S1+S2 |
| Healthy home / out-of-scope postures / never-cloned entries silent | `scenario-drive.log` S1 silences + S3 |
| Spaced registry names reported under their full name (regression vs pre-fix `78297d97`) | `scenario-drive.log` S1 (`my portal`) + S7 (old script omits it) |
| Non-clone-root plain directory never reported (project leg + firstmate leg; regression vs `78297d97`) | `scenario-drive.log` S7 |
| Root normalization: trailing-slash `NM_HOME`, bare `/` root | `scenario-drive.log` S4a, S4b |
| Default root `~/.no-mistakes` when `NM_HOME` unset | `scenario-drive.log` S5 |
| Detect-only: full bootstrap run mutates nothing | `scenario-drive.log` S6 |
| Legacy bracket-less registry row still checked; non-git `FM_ROOT` silent | `scenario-addendum.log` |
| Conflict-free against current upstream main | `upstream-main-sha.txt` + S9 in `scenario-drive.log` |
| Docs: read-only qualifier still follows its TANGLE sentence | `scenario-drive.log` S8 |
| Required checks green at final head / attestation binding that head | `remote-branch-sha.txt` (branch not pushed yet - outer push/CI/attestation phases own this) |

## Commands run

- `bash drive-scenarios.sh` -> `scenario-drive.log` (23/23 assertions PASS)
- `env ... bin/fm-session-start.sh` (timeout 180, exit 0) -> `session-start-digest.log`
- `bash tests/fm-bootstrap.test.sh` -> `test-fm-bootstrap.log` (exit 0,
  includes `ok - bootstrap reports no-mistakes gate-remote drift outside the resolved root`)
- `bash tests/fm-startup-memory-budget.test.sh` -> `test-fm-startup-memory-budget.log` (exit 0)
- `bash tests/fm-secondmate-sync.test.sh` -> `test-fm-secondmate-sync.log` (exit 0)
- `git ls-remote origin refs/heads/main` / `refs/heads/fm/fm-nm-mirror-check-20260904` (read-only)
- `git merge-base --is-ancestor origin/main HEAD` -> true

The skill-doc trigger updates (`.agents/skills/bootstrap-diagnostics/SKILL.md`,
`agent-skill-trigger-index/SKILL.md`) were reviewed for contract consistency;
whether an agent loads the skill on seeing the line is model interpretation and
is not deterministically testable (per the test-quality rule).
