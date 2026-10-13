// Firstmate Observation Layer extension for Pi.
//
// SI Control Phase 3: Scope Area 1 - Section 2.3 Record schema (PHI-free by construction).
//
// Captures model call metadata: provider, model, timing, status, usage.
// Correlated by task ID, trace ID, and policy decision.
// Strictly metadata only: prompt text, completion text, tool arguments,
// file contents, credentials, and patient identifiers are forbidden.
//
// Spools locally to $FM_HOME/state/observation/spool.jsonl.
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export interface ObservationMetadataRecord {
  identity: {
    task_id: string;
    trace_id: string;
    span_id: string;
    bead_id: string | null;
    runtime_identity: {
      harness: "pi";
      adapter: "pi";
    };
    parent_task_id: string | null;
  };
  call: {
    provider: string;
    model: string;
    start_time: string;
    end_time: string;
    duration_ms: number;
    status: "ok" | "error" | "timeout" | "aborted";
    error_class: string | null;
  };
  usage: {
    input_tokens: number;
    output_tokens: number;
    reasoning_tokens: number;
    cache_tokens: number;
  };
  policy: {
    decision_id: string | null;
    decision: "allow" | "deny" | "review" | null;
    policy_version: string | null;
    jev_risk_flags: string[];
  };
  retention: {
    retention_policy_class: string;
  };
}

export function parseTraceparent(raw?: string): { trace_id: string; span_id: string } {
  if (!raw) {
    return {
      trace_id: "00000000000000000000000000000000",
      span_id: "0000000000000000",
    };
  }
  const parts = raw.split("-");
  if (parts.length >= 4 && parts[1] && parts[2]) {
    return {
      trace_id: parts[1],
      span_id: parts[2],
    };
  }
  return {
    trace_id: "00000000000000000000000000000000",
    span_id: "0000000000000000",
  };
}

export function buildObservationRecord(params: {
  taskId?: string;
  traceparent?: string;
  provider: string;
  model: string;
  startTime: string;
  endTime: string;
  durationMs: number;
  status: "ok" | "error" | "timeout" | "aborted";
  errorClass?: string | null;
  inputTokens?: number;
  outputTokens?: number;
  reasoningTokens?: number;
  cacheTokens?: number;
}): ObservationMetadataRecord {
  const { trace_id, span_id } = parseTraceparent(params.traceparent);
  return {
    identity: {
      task_id: params.taskId || "task-ambient",
      trace_id,
      span_id,
      bead_id: null,
      runtime_identity: {
        harness: "pi",
        adapter: "pi",
      },
      parent_task_id: null,
    },
    call: {
      provider: params.provider,
      model: params.model,
      start_time: params.startTime,
      end_time: params.endTime,
      duration_ms: params.durationMs,
      status: params.status,
      error_class: params.errorClass ?? null,
    },
    usage: {
      input_tokens: params.inputTokens ?? 0,
      output_tokens: params.outputTokens ?? 0,
      reasoning_tokens: params.reasoningTokens ?? 0,
      cache_tokens: params.cacheTokens ?? 0,
    },
    policy: {
      decision_id: null,
      decision: null,
      policy_version: "2026-10-12",
      jev_risk_flags: [],
    },
    retention: {
      retention_policy_class: "metadata_general_90d",
    },
  };
}

export function writeSpoolRecord(record: ObservationMetadataRecord, customSpoolPath?: string): void {
  try {
    const home = process.env.FM_HOME || ".";
    const spoolFile = customSpoolPath || join(home, "state", "observation", "spool.jsonl");
    mkdirSync(dirname(spoolFile), { recursive: true });
    appendFileSync(spoolFile, JSON.stringify(record) + "\n", "utf8");
  } catch {
    // Failure rule (§2.6): A failed observation write never blocks the model call.
  }
}

export default function (pi: ExtensionAPI) {
  let callStartTime = new Date().toISOString();
  let callStartMs = Date.now();
  let currentProvider = "unknown";
  let currentModel = "unknown";

  pi.on?.("turn_start", () => {
    callStartTime = new Date().toISOString();
    callStartMs = Date.now();
  });

  pi.on?.("provider_stream_event", (event: { data?: { provider?: string; model?: string } }) => {
    if (event?.data?.provider) currentProvider = event.data.provider;
    if (event?.data?.model) currentModel = event.data.model;
  });

  pi.on?.("message_end", (event: { message?: { role?: string; provider?: string; model?: string; usage?: { inputTokens?: number; outputTokens?: number } } }) => {
    if (event?.message?.role !== "assistant") return;
    const endMs = Date.now();
    const durationMs = Math.max(0, endMs - callStartMs);
    const endTime = new Date().toISOString();

    const provider = event.message.provider || currentProvider;
    const model = event.message.model || currentModel;
    const inputTokens = event.message.usage?.inputTokens ?? 0;
    const outputTokens = event.message.usage?.outputTokens ?? 0;

    const record = buildObservationRecord({
      taskId: process.env.FM_TASK_ID,
      traceparent: process.env.TRACEPARENT,
      provider,
      model,
      startTime: callStartTime,
      endTime,
      durationMs,
      status: "ok",
      inputTokens,
      outputTokens,
    });

    writeSpoolRecord(record);
  });
}
