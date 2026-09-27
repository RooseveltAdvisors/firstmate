# Live CI landing-gate drives (bin/fm-jev-ci-workflow-guard.py)

## 1) zero-CI repo + passing local tests => APPROVED_FOR_LANDING
```console
Jev Landing Gate: APPROVED_FOR_LANDING [ZERO_CI]
Notes: Zero-CI repository verified. Local tests passed (2 passed, 0 failed) under tap/shell.
Can Merge: True
Tests: tap/shell - 2 passed, 0 failed
exit=0
```

## 2) zero-CI repo + failing local tests => BLOCKED_TESTS_FAILING; --strict refuses the landing
```console
Jev Landing Gate: BLOCKED_TESTS_FAILING [ZERO_CI]
Notes: Zero-CI repository, but local tests failed (1 failed, 0 errors).
Can Merge: False
Tests: tap/shell - 1 passed, 1 failed
exit=0
strict exit=1
```

## 3) repo with active PR-triggered workflows, no live PR check rollup => CI_GATE_REQUIRED (strict exit 1)
```console
Jev Landing Gate: CI_GATE_REQUIRED [CI_ACTIVE]
Notes: Repository has 1 active CI workflows. Standard CI green check rollup required before landing.
Can Merge: False
exit=0
strict exit=1
```

## 4) machine-consumed JSON verdict on this very repository (real workflows)
```console
{"verdict":"CI_GATE_REQUIRED","decision":"REQUIRE_CI","ci_status":"CI_ACTIVE","can_merge":false}
```
