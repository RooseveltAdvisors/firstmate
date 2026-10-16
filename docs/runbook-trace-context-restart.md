# Fleet Restart Runbook for Trace Context Enablement

This runbook documents the manual fleet restart procedure required when enabling W3C trace context propagation across the fleet.

## Purpose

Phase 3 observation requires every task to carry a W3C trace identity.
Trace context enablement is home-session-scoped as documented in [`trace-context.md`](trace-context.md).
Because each home resolves its configuration at session start and freezes that decision for the duration of the session, changing the configuration across the fleet requires a coordinated restart.

## Prerequisites

1. Ensure `config/trace-context` exists in each host FM_HOME configuration directory.
2. Verify that no active critical task is in an un-checkpointed state.
3. Confirm that the operator has administrative terminal access to each managed host.

## Restart Procedure

Follow these steps on each fleet member in order:

1. Send quiet notification or wait for currently active crew tasks to finish.
2. Gracefully stop the current Firstmate session using standard session management.
3. Verify that the session lock file under `state/.lock` is released.
4. Launch the new Firstmate session using the standard host startup command.
5. Inspect `state/.trace-context-effective` to verify that the value is recorded as `on`.
6. Confirm that the new session lock pid matches the active process.

## Verification

After restarting each home, verify that new spawns propagate trace context:

1. Spawn a test scout or inspect the first child launch.
2. Verify that `TRACEPARENT` is present in the child environment before launch.
3. Inspect `state/<id>.meta` for the new task and confirm that `traceparent=` is recorded.
4. Verify that downstream observation spools record matching `trace_id` and `span_id` values.
