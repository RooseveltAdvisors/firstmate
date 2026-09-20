# Test evidence - bead fm-o8ta (config-reread loop + false-done ship DoD)

Branch `fm/fm-improve-o8ta-falsedone`, base `a09090d1` -> target `56a6531d`.

| File | What it shows |
| --- | --- |
| `config-reread-before-fix.txt` | Real `bin/fm-config-push.sh` CLI transcript against the **base** tree: 5 pushes, **5 CONFIG_REREAD pointers** delivered to the live secondmate, 3 of them byte-identical repeats - the reported loop. |
| `config-reread-after-fix.txt` | Same scenario against the **fixed** tree: **2 CONFIG_REREAD pointers**, one per genuinely distinct payload (`codex`, then `grok`). Drift is still corrected (final destination value matches the primary). |
| `config-reread-loop-repro.sh` | The driver that produced both transcripts. `ROOT=<checkout> bash config-reread-loop-repro.sh "<label>"`. |
| `ship-brief-definition-of-done.txt` | The generated worker brief's `# Definition of done` from the real `bin/fm-brief.sh` CLI, before vs after, for `--mode no-mistakes` and `--mode direct-PR`. |
| `regression-before-after.txt` | Each new/updated test run in isolation on base (fails) and on the fix (passes). |
| `targeted-test-run.txt` | Final targeted suite run, 4 scripts, 0 failures. |

## The scenario the transcripts drive

Primary `config/crew-harness` is `codex`; one live secondmate home. Minute 1 pushes the
new value. Minutes 2-4 the live secondmate edits its own gitignored
`config/crew-harness` to `pi` (expected local drift) and a push follows each time.
Minute 5 the captain changes the primary value to `grok` - the control that proves a
real change still reaches the agent.
