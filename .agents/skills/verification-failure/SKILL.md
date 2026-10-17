---
name: verification-failure
description: >-
  Load when recording a visual-QA rejection, failing test or CI check, disproved
  agent claim, or genuine finding deferred, blocked, corrected later, or handed
  to another lane, before writing its report or reply.
user-invocable: false
metadata:
  internal: true
---

# Verification failures

Record findings at the failure-recording step, before composing a reply, status report, or handoff about them.
Use `bin/fm-verification-record.sh`; its header and `--help` own arguments, store selection, evidence snapshots, deduplication, and refusal mechanics.
`bin/fm-test-run.sh` invokes it automatically for failed scripts with an owning `FM_TASK_ID`; other verification sources call the same recorder as they record their verdict.
There is no reply-time hook.

A visual rejection, red test or CI check, disproved agent claim, or genuine defect that outlives this pass needs a durable bead.
Fix functional, security, and data-integrity defects when authorized; retain findings that are deferred, blocked, corrected later, or needed by another lane.
Passing checks create nothing.
Cosmetic or theoretical nits resolved as WONTFIX create nothing.

Capture the failed command or named check, a readable local evidence file, and the owning task ID.
For visual QA, retain the screenshot; for CI, save the failure log with its run URL/ID and commit SHA; for a disproved claim or deferred finding, retain the original claim/check and the contrary evidence.
Select the store by the defect's domain, never by the current worktree: Portal uses the Portal project store, fleet tooling uses the wiseman store, and firstmate home defects use that home's store.
Name an explicit project root when its actual location differs from the recorder's defaults; never search one store and declare a bead absent everywhere.
Workers keep evidence in their authorized task directory and ask firstmate to file when their write boundary or action gate prevents updating the domain store.
Do not bypass a gate or change domains to gain write access.

Call the recorder synchronously as the failure is recorded and retain its JSON receipt.
It creates or updates the bead keyed by owning task, failed command, and normalized original evidence path; reuse that path for reruns and append new logs rather than choosing a new temporary filename each time.
The receipt's bead ID comes from `bd list` in the selected store after the evidence attachment is confirmed.
Only then compose the report, citing that exact bead ID and store.
Never cite an ID from create output, a status line, or a spawn message as proof of filing.

If recording refuses, report the refusal verbatim together with the failed command, evidence path, owning task ID, and selected store so an authorized lane can file it.
Say explicitly that no bead was confirmed and keep the finding open; a refusal is a result, never permission to drop evidence or claim filing succeeded.
