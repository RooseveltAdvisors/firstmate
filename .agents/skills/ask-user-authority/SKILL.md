---
name: ask-user-authority
description: >-
  Agent-only search-before-ask checklist and decision procedure for ask-user findings.
  Use before asking the captain or a supervisor a question answerable from record.
  Use before deciding any ask-user finding.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill owns the search-before-ask checklist and the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Search before asking

Before asking the captain or a supervisor a question answerable from record, use this checklist:

1. Name the fact you need and make one brief search pass, capped at two minutes total across all three sources, including discovery and reading hits.
2. Search beads: enumerate the existing stores in the task's known workspace and project roots, then use `bd search` or `bd list` from each relevant store's directory.
   `bd` resolves its store from cwd; name the store paths rather than assuming the current worktree's board is the only one.
   Keep discovery within those known roots rather than scanning the whole machine.
3. Search the Obsidian vault at `$HOME/Obsidian/second-brain` for the same fact using a few specific terms or likely notes.
   First check that the resolved vault directory exists and is readable on this host.
   If it is missing or unreachable, skip it and say in the question that the vault was unreachable, naming the resolved path you checked; never report an empty search of a vault you could not access.
4. Search session transcripts for the same fact across every harness transcript root, rather than only the current session or your own harness.
   Use `bin/fm-transcript-search.sh --help` for the bounded, read-only search helper; give it at most the time remaining in the shared two-minute budget.
   By default it scans the Pi, Claude, Muse, and Cursor roots its help names in one capped search, skips any root missing on this host, and reports `roots` searched and `missingRoots` not searched.
   Search a few distinctive words from the likely answer; inspect only bounded windows and cite the file and zero-based byte offset returned with each hit.
   Never load an entire session or page through a large session to satisfy this checklist.
   Read hits as evidence: distinguish direct captain words from quoted text, launch briefs, agent summaries, and tool output, and check later corrections and the current scope before relying on an old answer.
   A hit is not fresh approval or an expansion of decision authority.
   If a window cannot establish the speaker or scope within the budget, say so and ask.
   Treat a timeout, output cap, unreadable source, or missing tool as incomplete coverage, never as proof that the fact is absent.
5. In the question itself, name the stores, vault locations, transcript roots, and terms searched, and state relevant findings, an empty search, or what could not be checked.
   Name every transcript root not searched, such as a missing one, so the question never implies full transcript coverage.
   For example: "I searched beads in <store paths>, the Obsidian vault at <path>, and transcripts under <roots> for <terms>; could not search <missing roots>; no answer found in the searched material (transcript coverage was partial: <reason>).
   Which value should I use?"

This is a checklist prompt, never a gate or a reason to refuse a question.
Ask sooner when urgent, when a source or tool is unavailable, or when searching would delay asking; state what you searched and what you could not check in the question.
Do not create a store, index, or search service to satisfy this checklist, and do not change who owns a decision or how it must be escalated.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
