# Live supervision-guard drives (bin/fm-jev-guard.sh / .py)

The guard's classifier transport is pointed at a local deterministic SystemOne endpoint
(FM_JEV_TS_BASE) with a dummy key: the real HTTP round-trip runs, no fleet credential is used.

## 1) benign supervisor action fast-passed (allow, exit 0)
```console
allow	fast_path_whitelist	Approved supervisor tool or benign inspection		
exit=0
```

## 2) adversarial (R44): a mutating rg --pre and git branch -D are NOT fast-passed - they reach the classifier
```console
allow	fail_open_no_key	TYPESAFE_API_KEY unavailable; failing open		
exit=0
allow	fail_open_no_key	TYPESAFE_API_KEY unavailable; failing open		
exit=0
allow	fast_path_whitelist	Approved supervisor tool or benign inspection		
exit=0
```

## 3) classifier deny verdict end-to-end: remote service restart => exit 2 + require_delegation/svc_ops
```console
stdout: {"decision":"deny","reason":"[require_delegation] Command violates supervisor boundary in w1 (svc_ops). Hands-on execution must be delegated to Second Mates. (Domain: svc_ops; Suggested: bin/fm-send.sh svc-ops '<task instructions>')"}
stderr: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[require_delegation] Command violates supervisor boundary in w1 (svc_ops). Hands-on execution must be delegated to Second Mates. (Domain: svc_ops; Suggested: bin/fm-send.sh svc-ops '<task instructions>')"}
exit=2
```

## 4) Claude transport (PreToolUse JSON on stdin) => permissionDecision deny on stderr, empty stdout, exit 2
```console
stdout: []
stderr: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[require_delegation] Command violates supervisor boundary in w1 (svc_ops). Hands-on execution must be delegated to Second Mates. (Domain: svc_ops; Suggested: bin/fm-send.sh svc-ops '<task instructions>')"}
exit=2
```

## 5) boundary: inside a linked git worktree the guard is inert (exit 0, silent, no classifier call)
```console
stdout/stderr: []
exit=0
```

## 6) malformed transport fails open (exit 0)
```console
exit=0
```
