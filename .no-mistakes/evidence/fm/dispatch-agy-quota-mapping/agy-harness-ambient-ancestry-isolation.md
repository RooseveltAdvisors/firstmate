# tests/fm-agy-harness.test.sh isolated against ambient agy ancestry

## The hazard, made real

A copy of bash named `agy` (real ps reports comm=agy) launches the suite as a child process, faithfully simulating a suite run from inside a live agy TUI. Verified from inside that wrapper:

```
inner ancestry: [comm agy]   # fm-harness.sh ancestry, run inside the wrapper
```

## Before the fix (base commit 804394e test file)

```
not ok - an inherited AGENT=1 must never claim the agy identity, got 'agy'
```

The old case ran `$HARNESS` against raw ambient process truth, so the verdict depended on where the suite happened to be launched from. It fails for anyone running the suite inside agy, regardless of the behavior under test.

## After the fix (target commit 031ffc2, full suite)

```
ok cases: 30
failures: none (no 'not ok' lines; case 3 pinned to a neutral ps shim: ok - fm-harness.sh: no inherited launcher marker claims the agy identity)
```

The changed case pins a neutral `ps` so the AGENT=1 verdict no longer depends on ambient ancestry, while sibling cases still drive agy detection through their own explicit ps fixtures.
