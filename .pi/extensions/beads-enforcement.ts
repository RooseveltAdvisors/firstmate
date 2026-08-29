import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const stateDir = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const activityPath = `${stateDir}/.pi-beads-activity.json`;
const staleAfterMs = Number(process.env.FM_BEADS_STALE_MS || 2 * 60 * 60 * 1000);
const maxContextBytes = 64 * 1024;
const beadIdPattern = /\b(?:bd|fm)-[A-Za-z0-9][A-Za-z0-9_-]*\b/g;
const validBeadId = /^(?:bd|fm)-[A-Za-z0-9][A-Za-z0-9_-]*$/;

type Bead = {
  id?: unknown;
  title?: unknown;
  status?: unknown;
  assignee?: unknown;
  labels?: unknown;
  dependency_count?: unknown;
  blocked_by_count?: unknown;
  blocked_by?: unknown;
  updated_at?: unknown;
  metadata?: unknown;
};

type Activity = {
  lastActivityAt: string;
  lastToolCallAt?: string;
};

type ActivityFile = {
  schema: "pi-beads-activity.v1";
  beads: Record<string, Activity>;
};

type CommandResult = {
  code: number;
  stdout: string;
  stderr: string;
};

type BeadsSnapshot = {
  ready: unknown;
  blocked: unknown;
  error?: string;
  capturedAt: string;
};

const EMPTY_SNAPSHOT: BeadsSnapshot = {
  ready: [],
  blocked: [],
  capturedAt: "",
};

let activities = loadActivities();

function logError(message: string, error?: unknown): void {
  const detail = error instanceof Error ? error.message : error === undefined ? "" : String(error);
  console.error(`beads enforcement: ${message}${detail ? `: ${detail}` : ""}`);
}

function nowIso(): string {
  return new Date().toISOString();
}

function loadActivities(): ActivityFile {
  if (!existsSync(activityPath)) return { schema: "pi-beads-activity.v1", beads: {} };
  try {
    const parsed = JSON.parse(readFileSync(activityPath, "utf8")) as Partial<ActivityFile>;
    if (parsed.schema !== "pi-beads-activity.v1" || !parsed.beads || typeof parsed.beads !== "object") {
      logError(`ignoring malformed activity file ${activityPath}`);
      return { schema: "pi-beads-activity.v1", beads: {} };
    }
    return { schema: "pi-beads-activity.v1", beads: parsed.beads as Record<string, Activity> };
  } catch (error) {
    logError(`could not read activity file ${activityPath}`, error);
    return { schema: "pi-beads-activity.v1", beads: {} };
  }
}

function saveActivities(): void {
  try {
    mkdirSync(stateDir, { recursive: true });
    const temporary = `${activityPath}.${process.pid}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(activities, null, 2)}\n`, { mode: 0o600 });
    renameSync(temporary, activityPath);
  } catch (error) {
    logError(`could not persist activity state at ${activityPath}`, error);
  }
}

function runCommand(command: string, args: string[]): Promise<CommandResult> {
  return new Promise((resolveResult) => {
    execFile(command, args, { cwd: root, maxBuffer: 1024 * 1024 }, (error, stdout, stderr) => {
      const code = typeof error?.code === "number" ? error.code : error ? 1 : 0;
      resolveResult({ code, stdout: String(stdout || ""), stderr: String(stderr || "") });
    });
  });
}

async function runBdJson(args: string[], description: string): Promise<unknown | undefined> {
  const result = await runCommand("bd", args);
  if (result.code !== 0) {
    logError(`${description} failed${result.stderr.trim() ? ` - ${result.stderr.trim()}` : ""}`);
    return undefined;
  }
  try {
    return JSON.parse(result.stdout);
  } catch (error) {
    logError(`${description} returned invalid JSON`, error);
    return undefined;
  }
}

function firstBead(value: unknown): Bead | undefined {
  if (Array.isArray(value)) return value[0] as Bead | undefined;
  if (value && typeof value === "object") return value as Bead;
  return undefined;
}

function beadId(value: unknown): string | undefined {
  const id = String(value || "");
  return validBeadId.test(id) ? id : undefined;
}

function idsIn(text: string): string[] {
  return [...new Set(text.match(beadIdPattern) || [])];
}

function assignedIdIn(text: string): string | undefined {
  const explicit = text.match(
    /\b(?:assigned\s+)?bead(?:\s+id)?\s*[:=]\s*((?:bd|fm)-[A-Za-z0-9][A-Za-z0-9_-]*)\b/i,
  );
  if (explicit && beadId(explicit[1])) return explicit[1];
  const ids = idsIn(text);
  return ids.length === 1 ? ids[0] : undefined;
}

function readBriefFromEnvironment(): string {
  const explicitId = process.env.FM_BEAD_ID;
  if (explicitId) return `bead: ${explicitId}`;

  const candidates = [
    process.env.FM_BRIEF_PATH,
    process.env.FM_BRIEF_FILE,
    process.env.FM_TASK_BRIEF,
    process.env.FM_BEAD_BRIEF,
  ].filter((candidate): candidate is string => Boolean(candidate));
  const taskId = process.env.FM_TASK_ID;
  if (taskId && /^[A-Za-z0-9_:-]+$/.test(taskId)) {
    candidates.push(`${process.env.FM_DATA_OVERRIDE || `${fmHome}/data`}/${taskId}/brief.md`);
  }

  const inlineBrief = process.env.FM_BRIEF;
  if (inlineBrief && !existsSync(inlineBrief)) return inlineBrief;
  if (inlineBrief) candidates.unshift(inlineBrief);
  for (const candidate of candidates) {
    try {
      return readFileSync(candidate, "utf8");
    } catch (error) {
      logError(`could not read brief ${candidate}`, error);
    }
  }
  return "";
}

function currentActor(): string[] {
  let gitActor = "";
  try {
    gitActor = execFileSync("git", ["config", "--get", "user.name"], { cwd: root, encoding: "utf8" }).trim();
  } catch (error) {
    logError("could not determine the git actor", error);
  }
  const candidates = [process.env.BEADS_ACTOR, process.env.USER, process.env.LOGNAME, gitActor];
  return [...new Set(candidates.filter(Boolean).map((candidate) => String(candidate).trim().toLowerCase()))];
}

function labelsOf(bead: Bead): string[] {
  return Array.isArray(bead.labels) ? bead.labels.map(String) : [];
}

function hasBlocker(bead: Bead): boolean {
  const dependencyCount = Number(bead.dependency_count || bead.blocked_by_count || 0);
  const blockedBy = Array.isArray(bead.blocked_by) ? bead.blocked_by.length : 0;
  return dependencyCount > 0 || blockedBy > 0 || labelsOf(bead).includes("blocked") || bead.status === "blocked";
}

function claimedByAnother(bead: Bead): string | undefined {
  const assignee = String(bead.assignee || "").trim();
  if (!assignee) return undefined;
  if (currentActor().includes(assignee.toLowerCase())) return undefined;
  return assignee;
}

function formatContext(snapshot: BeadsSnapshot, bead: Bead | undefined, warnings: string[]): string {
  const ready = JSON.stringify(snapshot.ready, null, 2);
  const blocked = JSON.stringify(snapshot.blocked, null, 2);
  const assigned = bead
    ? `Assigned bead state:\n${JSON.stringify(bead, null, 2)}`
    : "Assigned bead state: none";
  const error = snapshot.error ? `\nSnapshot error: ${snapshot.error}` : "";
  const warningText = warnings.length > 0 ? `\nWarnings:\n- ${warnings.join("\n- ")}` : "";
  let content = [
    "BEADS TASK LANDSCAPE (captured by Pi Beads enforcement)",
    `Captured at: ${snapshot.capturedAt || nowIso()}`,
    "Ready work:",
    ready,
    "Blocked work:",
    blocked,
    assigned,
    `${error}${warningText}`,
  ].join("\n\n");
  if (Buffer.byteLength(content, "utf8") > maxContextBytes) {
    content = `${Buffer.from(content, "utf8").slice(0, maxContextBytes).toString("utf8")}\n[Beads context truncated at ${maxContextBytes} bytes.]`;
  }
  return content;
}

async function captureSnapshot(): Promise<BeadsSnapshot> {
  const ready = await runBdJson(["ready", "--json"], "bd ready --json");
  const blocked = await runBdJson(["blocked", "--json"], "bd blocked --json");
  const errors: string[] = [];
  if (ready === undefined) errors.push("bd ready --json unavailable");
  if (blocked === undefined) errors.push("bd blocked --json unavailable");
  return {
    ready: ready ?? [],
    blocked: blocked ?? [],
    error: errors.length > 0 ? errors.join("; ") : undefined,
    capturedAt: nowIso(),
  };
}

async function showBead(id: string): Promise<Bead | undefined> {
  const shown = await runBdJson(["show", id, "--json"], `bd show ${id}`);
  return firstBead(shown);
}

function activityFor(id: string): Activity | undefined {
  return activities.beads[id];
}

function ensureActivity(id: string): void {
  if (activityFor(id)) return;
  const timestamp = nowIso();
  activities.beads[id] = { lastActivityAt: timestamp, lastToolCallAt: timestamp };
  saveActivities();
}

function recordToolActivity(id: string): void {
  const timestamp = nowIso();
  activities.beads[id] = { lastActivityAt: timestamp, lastToolCallAt: timestamp };
  saveActivities();
}

function staleWarning(id: string, bead: Bead): string | undefined {
  if (bead.status !== "in_progress") return undefined;
  const activity = activityFor(id);
  if (!activity?.lastToolCallAt) return undefined;
  const lastToolCall = Date.parse(activity.lastToolCallAt);
  if (!Number.isFinite(lastToolCall) || Date.now() - lastToolCall <= staleAfterMs) return undefined;
  const staleMinutes = staleAfterMs / (60 * 1000);
  const durationText = staleMinutes >= 60 ? `more than ${Math.round(staleMinutes / 60)} hour(s)` : `more than ${Math.round(staleMinutes)} minute(s)`;
  return `Bead ${id} has been in_progress for ${durationText} without a tool call (last tool call: ${activity.lastToolCallAt}).`;
}

function resetWorkCounters(): { commandsRan: boolean; filesEdited: boolean } {
  return { commandsRan: false, filesEdited: false };
}

export default function (pi: ExtensionAPI) {
  let snapshotPromise: Promise<BeadsSnapshot> | undefined;
  let snapshot: BeadsSnapshot = EMPTY_SNAPSHOT;
  let assignedBeadId: string | undefined;
  let assignedBead: Bead | undefined;
  let assignmentWarnings: string[] = [];
  let work = resetWorkCounters();
  let enforcementFollowUpActive = false;

  const verifyAssignment = async (id: string): Promise<void> => {
    assignedBeadId = id;
    assignedBead = await showBead(id);
    assignmentWarnings = [];
    if (!assignedBead) {
      assignmentWarnings.push(`Assigned bead ${id} does not exist.`);
      return;
    }
    const status = String(assignedBead.status || "");
    if (status !== "open" && status !== "in_progress") {
      assignmentWarnings.push(`Assigned bead ${id} is ${status || "in an unknown state"}; it must be open or in_progress.`);
    }
    const other = claimedByAnother(assignedBead);
    if (other) assignmentWarnings.push(`Assigned bead ${id} is already claimed by another agent: ${other}.`);
    if (status === "in_progress") ensureActivity(id);
    const stale = staleWarning(id, assignedBead);
    if (stale) assignmentWarnings.push(stale);
  };

  const findEnvironmentAssignment = (): string | undefined => {
    const brief = readBriefFromEnvironment();
    if (!brief) return undefined;
    const explicitId = process.env.FM_BEAD_ID;
    if (explicitId && !beadId(explicitId)) {
      assignmentWarnings = [`FM_BEAD_ID is not a valid bead ID: ${explicitId}.`];
      logError(`invalid FM_BEAD_ID ${explicitId}`);
      return undefined;
    }
    return assignedIdIn(brief);
  };

  pi.on("session_start", async () => {
    snapshotPromise = captureSnapshot();
    snapshot = await snapshotPromise;
    const environmentAssignment = findEnvironmentAssignment();
    if (environmentAssignment) await verifyAssignment(environmentAssignment);
  });

  pi.on("before_agent_start", async (event) => {
    if (snapshotPromise) await snapshotPromise;
    snapshot = await captureSnapshot();

    const prompt = String(event.prompt || "");
    const promptAssignment = assignedIdIn(prompt);
    if (promptAssignment && promptAssignment !== assignedBeadId) {
      work = resetWorkCounters();
      await verifyAssignment(promptAssignment);
    }
    if (assignedBeadId && promptAssignment === assignedBeadId) await verifyAssignment(assignedBeadId);

    const context = formatContext(snapshot, assignedBead, assignmentWarnings);
    return { systemPrompt: `${event.systemPrompt}\n\n${context}` };
  });

  pi.on("tool_call", (event) => {
    if (!assignedBeadId) return {};
    const toolName = String(event.toolName);
    if (toolName === "bash" || toolName === "powershell") work.commandsRan = true;
    if (toolName === "edit" || toolName === "write") work.filesEdited = true;
    recordToolActivity(assignedBeadId);
    return {};
  });

  pi.on("session_compact", async () => {
    snapshot = await captureSnapshot();
    if (assignedBeadId) await verifyAssignment(assignedBeadId);
    const content = formatContext(snapshot, assignedBead, assignmentWarnings);
    try {
      pi.sendMessage({
        customType: "beads-enforcement",
        content,
        display: false,
        details: { schema: "pi-beads-enforcement.v1", capturedAt: snapshot.capturedAt },
      });
    } catch (error) {
      logError("could not re-inject Beads state after compaction", error);
    }
  });

  pi.on("agent_settled", async () => {
    if (enforcementFollowUpActive || !assignedBeadId) return;
    const id = assignedBeadId;
    const bead = await showBead(id);
    if (!bead) return;
    assignedBead = bead;
    const warnings: string[] = [];
    const stale = staleWarning(id, bead);
    if (stale) warnings.push(stale);
    const blocked = hasBlocker(bead);
    const status = String(bead.status || "");
    if (status === "open" && !blocked) {
      warnings.push(`You have an assigned bead ${id} that was never claimed. Claim it with \`bd update ${id} --claim\` or explain why it cannot proceed.`);
    } else if (status === "in_progress" && !work.filesEdited && !work.commandsRan && !blocked) {
      warnings.push(`Your bead ${id} is in_progress but no work was performed. Either make progress, mark it blocked with \`bd update ${id} --add-label blocked\`, or close it.`);
    }
    work = resetWorkCounters();
    if (warnings.length === 0) return;

    enforcementFollowUpActive = true;
    try {
      await pi.sendUserMessage(`Beads enforcement follow-up:\n\n${warnings.join("\n")}`, { deliverAs: "followUp" });
    } catch (error) {
      logError(`could not deliver Beads follow-up for ${id}`, error);
    } finally {
      enforcementFollowUpActive = false;
    }
  });
}
