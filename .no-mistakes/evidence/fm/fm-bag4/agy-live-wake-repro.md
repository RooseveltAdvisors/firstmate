# Independent live-wake reproduction of docs/verification/agy.md "Live wake" section

Test phase reproduction of the captured evidence added by commit 3c6a5618.
Same method as the record: real installed agy 1.2.2 (/home/jon/.local/bin/agy),
scratch /tmp lab, installed hook from the change under test, no hand-fed payload.
No synthesized JSON was piped into the hook; the only Stop event was agy's own.

## Setup (exact commands)

```
LAB=/tmp/agy-wake-lab; H=$LAB/home; WS=$LAB/ws; STATE=$LAB/state; TOK=fm.W8b0AU6TQ6lW
mkdir -p "$LAB/home" "$LAB/ws" "$LAB/state"
# copy ~/.gemini auth/config state into the lab HOME (heavy data dirs excluded)
# register workspace in the lab's trustedWorkspaces (what bin/fm-agy-trust.sh does pre-spawn)
HOME=$H bin/fm-agy-turnend-hook.sh install
  -> installed: firstmate-turn-end in /tmp/agy-wake-lab/home/.gemini/config/hooks.json
printf '%s\n' "$STATE/task1.turn-ended" > "$H/.gemini/antigravity-cli/fm-turn-end.d/$TOK"
printf 'token=%s\n' "$TOK" > "$WS/.fm-agy-turnend"
# marker state before launch: [ -e "$STATE/task1.turn-ended" ] -> yes-absent
```

## Launch

```
date +%T.%N   -> 17:16:22.024413308
tmux -L agywake new-session -d -s agy-wake -c "$WS" \
  "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS HOME=$H \
   agy --prompt-interactive 'Reply with exactly AGY_LIVE_WAKE_OK and nothing else' \
   --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions"
date +%T.%N   -> 17:16:22.851295122
```

## Pane after 8s (agy's own reply and idle composer)

```

  AGY_LIVE_WAKE_OK

────────────────────────────────────────────────────────────────────────────────
>
────────────────────────────────────────────────────────────────────────────────
? for shortcuts                                           Gemini 3.8 Flash · low
```

## Marker created by agy's Stop event through the installed hook

```
$ ls -la --time-style=full-iso "$STATE"
total 8
drwxrwxr-x 2 jon jon 4096 2026-09-13 17:16:26.428875101 -0400 .
drwxrwxr-x 5 jon jon 4096 2026-09-13 17:16:06.197787764 -0400 ..
-rw-rw-r-- 1 jon jon    0 2026-09-13 17:16:26.428999900 -0400 task1.turn-ended
```

Launch at 17:16:22, marker created at 17:16:26 - inside the turn window, after
the reply rendered, with no other writer: agy's own Stop hook touched it.

## Cleanup

tmux server killed, /tmp/agy-wake-lab removed, worktree left clean.
