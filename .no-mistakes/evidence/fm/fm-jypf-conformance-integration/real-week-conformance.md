# Weekly rule conformance

Generated 2026-10-18T15:00:53.753Z.
Window: [2026-10-12T00:00:00Z, 2026-10-19T00:00:00Z), UTC derivation times.
Window timestamp: 2026-10-18T10:09:00Z (latest included observation, or window start when empty; not execution time).
3 rows included; 0 outside the window.
Unresolved reference parts in violate/miss findings: 2 (counted apart from verdicts; each is marked source=unresolved).
Counts are observations, never a safety score; missing observations do not prove compliance.
Proposals only; no rule edits, gates, scheduling, or enforcement.
Any change requires the captain's explicit word.
Registry: "/tmp/tmp.b5YHedaWtt/in/registry.md"; sha256=d1a65205624262ad203bf5beb0e3b20d5d19b99fbb2d972df1f3e5f1a5ef71dc.
Log: "/tmp/tmp.b5YHedaWtt/in/conformance.log"; sha256=d3825c5196cc346b0592287010023ac818b1177a55f998f8a9a2f0217877dd11.

## search-before-ask

a question to the captain names the stores searched
Status: observations-only.
Counts: follow=0; violate=1; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 1.
What it cannot show: absence of the phrase does not prove no search happened
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":62.

- violate at 2026-10-18T10:07:00Z.
  Citation 1: "/tmp/tmp.b5YHedaWtt/in/conformance.log":4; source reference="transcript --home-jon-git-wiseman-- 2026-10-16T14-56-04-648Z: same merge-authority question asked 3x before locating the captain's written order".
  Single source only: the log row/reference; no second reachable source in the supplied locators or collector map.
  Source gap: source=unresolved:transcript --home-jon-git-wiseman-- 2026-10-16T14-56-04-648Z: same merge-authority question asked 3x before locating the captain's written order (no content-addressed collector binding)

## ui-done-gate

UI-done findings route through the gate, not the worker
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: does not judge the *quality* of a gate decision
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":63.

## watchdog

a red transition produces a wake
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: cannot see a transition that never completed — detection follows completion by design
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":64.

## auto-bead

a local verification failure becomes a bead before the reply
Status: observations-only.
Counts: follow=0; violate=0; miss=1; out-of-scope=0; no-signature=0.
Unresolved reference parts: 1.
What it cannot show: a refusal reported verbatim is `miss` + note, not a silent gap
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":65.

- miss at 2026-10-18T10:09:00Z.
  Citation 1: "/tmp/tmp.b5YHedaWtt/in/conformance.log":5; source reference="fm-test-run CI-remote: no local FM_HOME at failure time; beads fm-mtdon + fm-g3vfm filed by firstmate afterwards (recorder refused verbatim, evidence preserved)".
  Single source only: the log row/reference; no second reachable source in the supplied locators or collector map.
  Source gap: source=unresolved:fm-test-run CI-remote: no local FM_HOME at failure time; beads fm-mtdon + fm-g3vfm filed by firstmate afterwards (recorder refused verbatim, evidence preserved) (no content-addressed collector binding)

## explained-twice

repeated captain corrections produce a proposal
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: **judgment-bearing**: "same correction" is semantic; counts need a human read
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":66.

## timestamped-heads

heads are quoted with a read time
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: proves the *read*, not that nothing moved before it
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":67.

## disclose-not-rewrite

defects disclosed instead of history rewritten
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: cannot detect a disclosure never attempted
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":68.

## strip-at-merge

squash merges carry no agent trailers
Status: observations-only.
Counts: follow=1; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: none — strongest signature in the set
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":69.

## no-waiver-merges

merges never used `--allow-red` / `--admin`
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: a waiver requested and *declined* still shows as no-waiver — record the decline in the row
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":70.

## green-claims

"green" claims cite raw run ids, not deduped name counts
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: verifies the citation, not whether every run was read
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":71.

## current-head-recount

thread/check counts are re-read at the head a report names
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: only valid at the read time; re-reading later proves *now*, then
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":72.

## two-attempt-cap

CI re-runs max 2, unrelatedness evidenced first
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: does not judge whether unrelatedness evidence was *sufficient* — semantic
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":73.

## refusal-verbatim

gate refusals are reported verbatim, not dropped or rephrased through
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: cannot see a refusal that never reached a transcript
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":74.

## no-hand-edit-enforcement

control changes ship as PRs, never hand-edited then tested
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: a hand-edit later reverted is invisible to history alone
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":75.

## fail-before-pass-after

a FAIL closes only with a test that failed before and passed after
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: pairing is mechanical; whether the test *changed* is semantic
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":76.

## stop-at-safety-boundary

a drill stops and reports instead of pushing through
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: cannot prove a *partial* push-through that left no side-effect record
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":77.

## no-phi-in-receipts

receipts/beads carry whitelist fields only
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: pattern-matching misses novel identifiers
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":78.

## one-worktree

a task reuses its recorded worktree; no second checkout
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: a second checkout outside the pool may leave no meta trace
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":79.

## first-step-first

an order's first step precedes adjacent work
Status: no-signature.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: transcript timestamps give only a partial, judgment-dependent signal
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":80.
No-signature reason: **`no-signature`** — requires reading *intent* in my own messages before acting
Zero observed violations is not a measurable compliance result for this rule.

## report-standards

a report is complete and adequate
Status: no-signature.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: *sub-check IS derivable*: each cited run id / merge sha can be verified against the API (see `green-claims`)
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":81.
No-signature reason: **`no-signature`** for adequacy — the artifact is my own prose
Zero observed violations is not a measurable compliance result for this rule.

## never-bypass-a-refusal

no rephrasing to defeat a gate refusal
Status: no-signature.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: near-miss calls are judgment; log them as notes, not verdicts
Registry citation: "/tmp/tmp.b5YHedaWtt/in/registry.md":82.
No-signature reason: **`no-signature`** — distinguishing a genuine retry from evasion needs reading intent
Zero observed violations is not a measurable compliance result for this rule.

