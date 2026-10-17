# Explained twice: proposals

Generated 2026-10-17T21:13:45.420Z.
Reviewer: live gate reviewer.
1 qualifying repeated-correction groups; 0 groups below threshold.
Counts are limited to cited evidence, not estimates of an entire session or shift.
Only distinct corr threads with direct captain corrections contribute to the trigger.
Semantic classification is a reviewer judgment, not an automatic authorship inference.
No instruction files were edited.

No additional review notes.

## Station code is Cedar

Captain corrections: 2 sourced messages in 2 eligible distinct corr threads; trigger MET.
Lane repetition: 1 sourced messages in 0 distinct corr threads, excluded from the captain count.

- captain / correction; 2026-10-15T10:00:00.000Z; corr=order-a; thread=a; /tmp/fmw.BzeH/session.jsonl bytes 0-177; event 5ec02bf6c45db4ceb1e2.
  > The station code is Cedar. Stop using Birch.
  Classification: direct

- captain / correction; 2026-10-16T10:00:00.000Z; corr=order-b; thread=b; /tmp/fmw.BzeH/session.jsonl bytes 179-363; event 9487c84b21df2c8007ea.
  > You still used Birch. The correct station is Cedar.
  Classification: direct

- lane / reported-correction; 2026-10-17T21:13:16Z; bead=alpha-d0o; store=/tmp/fmw.BzeH/alpha; database=/tmp/fmw.BzeH/alpha/.beads/embeddeddolt; corr=unavailable (excluded from trigger); thread=unmapped (excluded from trigger); /tmp/fmw.BzeH/data/wk/bead-e2c3b737b3d33e26e75289880a4028ccc423d92d5cb20f94b919fd0e618ae80c.json bytes 0-70778; event 3b6cc18f1c1bb449c04d.
  > Lane used Birch again
  Classification: bead

Owner assessment: CLAUDE.md.
Station section owns it.
Neighbor assessment: Not a skill.

Existing section: Station convention.
Proposed replacement text (proposal only):

> Use Cedar.

## Thread identity review

- a: corr=order-a.
  order A
- b: corr=order-b.
  order B

## Coverage and gaps

These are bounded windows, not a complete session audit.
Repeated or overlapping windows do not increase occurrence counts.
- bead=alpha-d0o; store=/tmp/fmw.BzeH/alpha; /tmp/fmw.BzeH/data/wk/bead-e2c3b737b3d33e26e75289880a4028ccc423d92d5cb20f94b919fd0e618ae80c.json: bytes [0, 70779) of 70779; since 2026-10-12T00:00:00.000Z; 1 complete records, 1 retained, 0 malformed, 0 partial edges, oversized=false.
- bead=beta-26c; store=/tmp/fmw.BzeH/beta; /tmp/fmw.BzeH/data/wk/bead-f7dd475120f3685276d87ad7c542633f452f37ef8afa1065f2ff7e95555349ad.json: bytes [0, 746) of 746; since 2026-10-12T00:00:00.000Z; 1 complete records, 1 retained, 0 malformed, 0 partial edges, oversized=false.
- /tmp/fmw.BzeH/session.jsonl: bytes [0, 365) of 365; since 2026-10-12T00:00:00.000Z; 2 complete records, 2 retained, 0 malformed, 0 partial edges, oversized=false.
- Weekly review window: [2026-10-12T00:00:00.000Z, 2026-10-19T00:00:00.000Z), UTC Monday to Monday. Invoked on demand; no schedule installed.
- Store /tmp/fmw.BzeH/alpha; database /tmp/fmw.BzeH/alpha/.beads/embeddeddolt; bd where verified; 1 closed records including comments returned for [2026-10-12T00:00:00.000Z, 2026-10-19T00:00:00.000Z); limit 200.
- Store /tmp/fmw.BzeH/beta; database /tmp/fmw.BzeH/beta/.beads/embeddeddolt; bd where verified; 1 closed records including comments returned for [2026-10-12T00:00:00.000Z, 2026-10-19T00:00:00.000Z); limit 200.
- Weekly events are restricted to the half-open UTC week; session window retained counts precede the upper-bound filter. Bead snapshots are reported evidence only; closed once is not recurrence.
