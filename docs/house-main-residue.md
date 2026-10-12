# House main ↔ upstream PR map

## Status 2026-09-26

The residue model below ("`origin/main` plus one commit per unmerged
feature") describes the **PR-backed subset only**, as structured on
2026-09-16. It is no longer the whole story:

```
house main  8c27c8cb == fork/main (RooseveltAdvisors/firstmate)
upstream    e9a6675e  (kunchenguid/firstmate; remote `origin` == `upstream`)
behind 0 / ahead 492 = 6 PR-backed residue commits (table below)
                    + ~480 Jev/Pattern guard commits (893 new files, no upstream PRs)
```

- **Daily converge:** `fm-upstream-sync.timer` (every 24h) fetches upstream,
  additive-merges it into house main, and asserts every merged PR of ours is an
  ancestor of local main. Log: `~/.local/state/firstmate/upstream-sync.log`.
  Merge, never rebase - house main is published as `fork/main`.
- **2026-09-26 converge:** `7f83e85d` (108 upstream commits, 22 conflicts),
  then `51f42209` + fix `8c27c8cb`; pushed to `fork` only, `kunchenguid/firstmate`
  untouched. Parked WIP: `fm/wip-parked-20260926-pre-upstream-converge`.
- **Host follow-up:** `fm-tasks-axi-upgrade` - the merged tree floors at
  tasks-axi 0.2.6 while the host fork is 0.2.5 (11 suites red host-as-is).
- Vault mirror: `1. Projects/Zeta — Firstmate Agent Stack/2026-09-26 House
  main ↔ upstream daily converge (watch + delegation).md`.

## Ahead commits (bottom → tip)

The table below is the **PR-backed residue** (still true as of 2026-09-26:
all six PRs remain open or closed-unmerged). It is not the full ahead count.

When a PR merges to `origin/main`, drop the matching house commit
(rebase house main onto new `origin/main`, or rebuild residue without
that feature).

## Ahead commits (bottom → tip)

| Commit subject | PR | State | Notes |
|----------------|----|-------|-------|
| fix(config): make .tasks.toml per-home and ship a tracked example | **#3840** | open | Template rename + fixture `cp` updates. Bootstrap *materialize* of the example lives in #3718 (shared `bin/fm-bootstrap.sh`). |
| feat(bin): attribute Beads audit-trail actors at every boundary | **#3712** | closed, unmerged | Actor export helpers + `tests/fm-beads-actor.test.sh`. Spawn/captain-hold actor lines live in #4225 (shared files). |
| feat(herdr): opt-in human-readable task-tab labels for new workers | **#3458** | open | `bin/backends/herdr.sh` + herdr tests/docs. Spawn label wiring lives in #4225 (shared `bin/fm-spawn.sh`). |
| feat(sweep): stale-claim reclaim sweep with capacity holds | **#4225** | open | Primary open tracker (also #4224; supersedes closed #3720). Owns full house delta of `fm-spawn.sh`, `fm-captain-hold.sh`, `fm-teardown.sh` (includes #3712 actor + #3458 labels + #3657 retire implementation on those shared files). |
| fix(bin): require per-target authority to retire a secondmate home | **#3657** | open | Also #4219. Fleet-view/remote/docs/safety tests. Teardown flag implementation is in the #4225 commit (shared file). |
| feat(bootstrap): report no-mistakes gate-remote drift at session start | **#3718** | open | `NO_MISTAKES_MIRROR` + full house `bin/fm-bootstrap.sh` (includes #3840 materialize). |
| docs: house-main feature-to-PR residue map | house-meta | house-only | This file. Not for upstream. |

## Not in residue (already upstream or never on tip)

| PR | Why absent |
|----|------------|
| #3702 local-only clone refresh | Not in tip diff vs current `origin/main` |
| #3416 / #3582 omit `--file` | Landed upstream (#3582) |
| #3417 / #3782 backlog adapters | Landed upstream |
| #4027 bounded backlog reads | Landed in the catch-up merge |

## Shared-file caveat

These paths cannot be split cleanly at the tip, so **one PR commit carries the full house blob** and sibling PRs document the hitchhiker hunks:

| File | Carried under | Also contains hunks for |
|------|---------------|-------------------------|
| `bin/fm-spawn.sh` | #4225 | #3712 actor, #3458 labels |
| `bin/fm-captain-hold.sh` | #4225 | #3712 actor |
| `bin/fm-teardown.sh` | #4225 | #3657 retire-secondmate |
| `bin/fm-bootstrap.sh` | #3718 | #3840 tasks.toml materialize |
| `docs/configuration.md` / `AGENTS.md` | #3718 | several |

When dropping a commit after its PR merges, re-diff these files against new `origin/main` and keep any hunks that still belong to remaining open PRs.

## Backups

- `backup/house-main-before-feature-split` — single mega-residue + inventory (pre this split)
- `backup/house-main-residue-1deb10f0` — pre-collapse 156-commit history tip
- `backup/house-main-20260914` — pre origin catch-up merge

## Operator loop

```text
git fetch origin
# for each house commit whose PR is merged:
#   rebase onto origin/main, dropping that commit
# or: rebuild residue from remaining open PRs only
git rev-list --left-right --count main...origin/main   # want: N 0, N = open features + house-meta
```
