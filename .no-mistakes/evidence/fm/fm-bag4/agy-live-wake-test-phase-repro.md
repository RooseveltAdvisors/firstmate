# Test-phase live-wake reproduction (agy crew turn-end hook)

Independent test-phase reproduction of the "Live wake" section in
docs/verification/agy.md, validating the evidence added by commit 66cd5674.
Same method as the record: real installed agy 1.2.2 (/home/jon/.local/bin/agy),
a scratch lab under /tmp with a throwaway HOME, and no hand-fed payload as
evidence. The only Stop events were agy's own.

## Lab setup

```
LAB=/tmp/agy-wake-testphase; H=$LAB/home; WS=$LAB/ws; STATE=$LAB/state
mkdir -p $H/.gemini $H/.gemini/config $WS $STATE
cp gemini-credentials.json google_accounts.json installation_id settings.json
   state.json projects.json into $H/.gemini/
cp config/config.json into $H/.gemini/config/
cp antigravity-cli/antigravity-oauth-token antigravity-cli/settings.json
   antigravity-cli/installation_id into $H/.gemini/antigravity-cli/
# real home (with its moshi operator hook) was never read-modify-written
TOK=fm.eqhcDwGNZByP
HOME=$H bin/fm-agy-turnend-hook.sh install
  -> installed: firstmate-turn-end in /tmp/agy-wake-testphase/home/.gemini/config/hooks.json
printf '%s\n' "$STATE/task1.turn-ended" > "$H/.gemini/antigravity-cli/fm-turn-end.d/$TOK"
printf 'token=%s\n' "$TOK" > "$WS/.fm-agy-turnend"
# marker before launch: absent (verified)
```

## Passes

1. First turn: a fresh agy home first showed the color-scheme picker and the
   Terms of Service dialog; both were answered by hand, then the folder-trust
   dialog was answered in-session and the queued brief ran to
   AGY_LIVE_WAKE_OK. Marker stayed ABSENT. This matches the record's
   documented first-turn edge: until agy confirms a workspace in-session the
   Stop payload carries an empty workspacePaths and the hook stays silent.
   (My trust pre-registration for this pass had also written the wrong path,
   so no pre-registered match existed.)
2. Diagnostic pass: to see the payloads I wrapped the installed hook with a
   tee-to-file wrapper that forwarded the payload unchanged. Two payloads were
   captured from agy's own Stop events, both with the exact shape the hook
   needs: `"fullyIdle":true,"workspacePaths":["/tmp/agy-wake-testphase/ws"]`.
   With the wrapper forwarding correctly, one real turn
   (AGY_LIVE_WAKE_3) produced the marker (created 11:02:36).
3. Clean pass: the wrapper was removed by re-running
   `HOME=$H bin/fm-agy-turnend-hook.sh install`, which restored the pristine
   hook bytes (verified by diff against the wrapper's target). One real turn:

```
11:08:48.680439163  submit "Reply with exactly AGY_LIVE_WAKE_OK_FINAL and nothing else"
11:09:14.687372725  marker present, mtime 2026-09-15 11:09:13.082000017

$ ls -la --time-style=full-iso "$STATE"
-rw-rw-r-- 1 jon jon    0 2026-09-15 11:09:13.082000017 -0400 task1.turn-ended
```

   The reply AGY_LIVE_WAKE_OK_FINAL rendered, the composer settled idle, and
   the marker was touched inside the turn window by agy's own Stop event
   delivered to the unmodified installed hook. See
   agy-wake-pane-final.txt and agy-wake-lab-state.txt.

(An intermediate attempt at the clean pass hung in "Working..." for ~7
minutes on a trivial reply - backend latency, not the hook - and was
interrupted and resubmitted successfully.)

## Result

The live wake claimed by docs/verification/agy.md reproduces end to end:
real agy binary, installed hook from this change, registered task token,
marker `state/<id>.turn-ended` created by agy's own Stop event.
