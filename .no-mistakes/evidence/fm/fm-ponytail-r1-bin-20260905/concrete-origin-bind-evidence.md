# Evidence: concrete-origin bind composed-identity coverage (fm/fm-ponytail-r1-bin)

## 1. New test passes on the change (umask 022)
```
ok - a concrete-origin binding resolves a short key through the composed legacy identity
suite exit: 0
```

## 2. Mutation check — test fails when the composed <origin>-decision-<key> identity is broken
Mutation applied to bin/fm-captain-hold.sh legacy_hold_id(): appended '-MUTATED' to the composed id, then reverted.
```
not ok - a pinned channel's short key did not close the composed captain-held task (missing: 'state: done')
```
Worktree restored after the mutation (git diff on bin/fm-captain-hold.sh clean).
