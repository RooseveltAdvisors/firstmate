# Weekly rule conformance

Generated 2026-10-18T15:01:21.037Z.
Window: [2026-10-11T15:01:21.038Z, 2026-10-18T15:01:21.038Z), UTC derivation times.
Window timestamp: 2026-10-18T15:01:07Z (latest included observation, or window start when empty; not execution time).
7 rows included; 0 outside the window.
Unresolved reference parts in violate/miss findings: 1 (counted apart from verdicts; each is marked source=unresolved).
Counts are observations, never a safety score; missing observations do not prove compliance.
Proposals only; no rule edits, gates, scheduling, or enforcement.
Any change requires the captain's explicit word.
Registry: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md"; sha256=d1a65205624262ad203bf5beb0e3b20d5d19b99fbb2d972df1f3e5f1a5ef71dc.
Log: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/conformance.log"; sha256=d95bac92432462a0831aa799a480b96f91c7ad100851d1cc2484b7614203e92e.

## search-before-ask

a question to the captain names the stores searched
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: absence of the phrase does not prove no search happened
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":62.

## ui-done-gate

UI-done findings route through the gate, not the worker
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: does not judge the *quality* of a gate decision
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":63.

## watchdog

a red transition produces a wake
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: cannot see a transition that never completed — detection follows completion by design
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":64.

## auto-bead

a local verification failure becomes a bead before the reply
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: a refusal reported verbatim is `miss` + note, not a silent gap
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":65.

## explained-twice

repeated captain corrections produce a proposal
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: **judgment-bearing**: "same correction" is semantic; counts need a human read
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":66.

## timestamped-heads

heads are quoted with a read time
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: proves the *read*, not that nothing moved before it
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":67.

## disclose-not-rewrite

defects disclosed instead of history rewritten
Status: observations-only.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=1.
Unresolved reference parts: 0.
What it cannot show: cannot detect a disclosure never attempted
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":68.
No-signature observation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/conformance.log":7; reference="git:sha256:7e9d7ccb1bcf9e1f9b85f3feb09702925dd65c233f5cf5548e757b928ed18b7e:state=07f4e6d7a3d2dbccdcfb1ae0d958344d909f9a33fa5e2ef62fa6b50a954e759f"; reason=Bounded local reflog cannot establish remote force-push absence or transcript disclosure.

## strip-at-merge

squash merges carry no agent trailers
Status: observations-only.
Counts: follow=1; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: none — strongest signature in the set
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":69.

## no-waiver-merges

merges never used `--allow-red` / `--admin`
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: a waiver requested and *declined* still shows as no-waiver — record the decline in the row
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":70.

## green-claims

"green" claims cite raw run ids, not deduped name counts
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: verifies the citation, not whether every run was read
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":71.

## current-head-recount

thread/check counts are re-read at the head a report names
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: only valid at the read time; re-reading later proves *now*, then
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":72.

## two-attempt-cap

CI re-runs max 2, unrelatedness evidenced first
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: does not judge whether unrelatedness evidence was *sufficient* — semantic
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":73.

## refusal-verbatim

gate refusals are reported verbatim, not dropped or rephrased through
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: cannot see a refusal that never reached a transcript
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":74.

## no-hand-edit-enforcement

control changes ship as PRs, never hand-edited then tested
Status: observations-only.
Counts: follow=0; violate=1; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 1.
What it cannot show: a hand-edit later reverted is invisible to history alone
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":75.

- violate at 2026-10-18T15:01:07Z.
  Citation 1: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/conformance.log":6; source reference="git:sha256:7e9d7ccb1bcf9e1f9b85f3feb09702925dd65c233f5cf5548e757b928ed18b7e:state=07f4e6d7a3d2dbccdcfb1ae0d958344d909f9a33fa5e2ef62fa6b50a954e759f:enforcement=acb1ea2628779427fc83eef4c1479d2028ec9f5521a8769a619567a8975bcd78".
  Single source only: the log row/reference; no second reachable source in the supplied locators or collector map.
  Source gap: Caller-supplied locator ignored: native collector reference; only its collector-map bindings are cited
  Source gap: source=unresolved:git:sha256:7e9d7ccb1bcf9e1f9b85f3feb09702925dd65c233f5cf5548e757b928ed18b7e:state=07f4e6d7a3d2dbccdcfb1ae0d958344d909f9a33fa5e2ef62fa6b50a954e759f:enforcement=acb1ea2628779427fc83eef4c1479d2028ec9f5521a8769a619567a8975bcd78 (Git state snapshot; a current checkout cannot replay the recorded state)

## fail-before-pass-after

a FAIL closes only with a test that failed before and passed after
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: pairing is mechanical; whether the test *changed* is semantic
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":76.

## stop-at-safety-boundary

a drill stops and reports instead of pushing through
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: cannot prove a *partial* push-through that left no side-effect record
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":77.

## no-phi-in-receipts

receipts/beads carry whitelist fields only
Status: no-observations.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=0.
Unresolved reference parts: 0.
What it cannot show: pattern-matching misses novel identifiers
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":78.

## one-worktree

a task reuses its recorded worktree; no second checkout
Status: observations-only.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=1.
Unresolved reference parts: 0.
What it cannot show: a second checkout outside the pool may leave no meta trace
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":79.
No-signature observation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/conformance.log":5; reference="git:sha256:7e9d7ccb1bcf9e1f9b85f3feb09702925dd65c233f5cf5548e757b928ed18b7e:state=07f4e6d7a3d2dbccdcfb1ae0d958344d909f9a33fa5e2ef62fa6b50a954e759f"; reason=No task metadata supplied for worktree comparison.

## first-step-first

an order's first step precedes adjacent work
Status: no-signature.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=1.
Unresolved reference parts: 0.
What it cannot show: transcript timestamps give only a partial, judgment-dependent signal
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":80.
No-signature reason: **`no-signature`** — requires reading *intent* in my own messages before acting
Zero observed violations is not a measurable compliance result for this rule.
No-signature observation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/conformance.log":1; reference="registry:sha256:d1a65205624262ad203bf5beb0e3b20d5d19b99fbb2d972df1f3e5f1a5ef71dc"; reason=Registry explicitly declares no independent signature.

## report-standards

a report is complete and adequate
Status: no-signature.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=1.
Unresolved reference parts: 0.
What it cannot show: *sub-check IS derivable*: each cited run id / merge sha can be verified against the API (see `green-claims`)
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":81.
No-signature reason: **`no-signature`** for adequacy — the artifact is my own prose
Zero observed violations is not a measurable compliance result for this rule.
No-signature observation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/conformance.log":2; reference="registry:sha256:d1a65205624262ad203bf5beb0e3b20d5d19b99fbb2d972df1f3e5f1a5ef71dc"; reason=Registry explicitly declares no independent signature.

## never-bypass-a-refusal

no rephrasing to defeat a gate refusal
Status: no-signature.
Counts: follow=0; violate=0; miss=0; out-of-scope=0; no-signature=1.
Unresolved reference parts: 0.
What it cannot show: near-miss calls are judgment; log them as notes, not verdicts
Registry citation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/registry.md":82.
No-signature reason: **`no-signature`** — distinguishing a genuine retry from evasion needs reading intent
Zero observed violations is not a measurable compliance result for this rule.
No-signature observation: "/tmp/tmp.b5YHedaWtt/fh/data/rule-conformance/conformance.log":3; reference="registry:sha256:d1a65205624262ad203bf5beb0e3b20d5d19b99fbb2d972df1f3e5f1a5ef71dc"; reason=Registry explicitly declares no independent signature.

