# Observation Coverage Matrix

This document records the per-harness observation coverage classification across Firstmate adapters.

## Classification Model

The coverage model distinguishes three levels of observability:

- Full request trace: Harness exposes streaming or request hooks providing provider, model, timing, and token counts.
- Session events only: Harness exposes coarse lifecycle events like turn start and turn end without per-stream metrics.
- Neither (gap): Harness exposes no stable programmatic event seam for out-of-band capture.

Gaps are stated honestly without claiming complete capture from transcripts alone.

## Adapter Matrix

| Harness / Adapter | Coverage Level | Mechanism | Notes |
|---|---|---|---|
| `pi` | Full request trace | Pi extension hook (`provider_stream_event` and `message_end`) | Native stream event support writes metadata record to local spool. |
| `pi-signed` | Full request trace | Pi extension hook (`provider_stream_event` and `message_end`) | Same extension surface as standard Pi with signature verification. |
| `claude` | Session events only | Transcript tailing and process lifecycle | Per-turn transcripts capture coarse timing but lack native stream hooks. |
| `codex` | Session events only | Transcript inspection | Turn-level event markers without granular streaming telemetry. |
| `opencode` | Session events only | Event listener | Session lifecycle events only. |
| `grok` | Neither (gap) | None | Terminal output only with no extension API. |
| `kimi` | Neither (gap) | None | Terminal output only with no extension API. |
| `cursor` | Session events only | Workspace event hook | File and session change markers without model stream capture. |
| `gemini` | Neither (gap) | None | Crewmate-only adapter with no extension hooks. |
| `muse` | Neither (gap) | None | Crewmate-only adapter with no extension hooks. |
| `rovo` | Neither (gap) | None | Crewmate-only adapter with no extension hooks. |
| `agy` | Neither (gap) | None | Crewmate-only adapter with no extension hooks. |
| `devin` | Neither (gap) | None | Remote session boundary with no local telemetry hook. |
| `provider-native tools` | Neither (gap) | None | Direct provider tool calls bypass local harness hooks. |
| `remote model calls` | Neither (gap) | None | Remote execution bypasses local Firstmate observer. |

## Failure Rule and Invariants

Observation failures degrade safely to evidence gaps and alert pages.
Under no circumstances does an observation failure block model calls or divert sensitive content into general logs.
Trace identity correlation relies on W3C headers minted per [`trace-context.md`](trace-context.md).
