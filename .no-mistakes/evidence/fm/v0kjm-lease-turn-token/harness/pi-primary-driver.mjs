// fm-v0kjm live drive: one Pi primary process built from the REAL installed Pi
// SDK (the same package the local `pi` CLI runs), loading the REAL firstmate
// supervision-branch extension and Pi watch extension, with REAL bash tools
// running the REAL firstmate scripts against a disposable lab FM_HOME.
//
// Only two things are not production: the model endpoint is a local scripted
// OpenAI-compatible HTTP server on 127.0.0.1 (so each model "decision" is
// deterministic), and the watcher arm is the repo's own live-probe stub
// (tests/fm-pi-branch-live-e2e.test.sh) that prints a wake reason on demand.
// The durable wake row itself is appended by the real fm_wake_append.
//
// MODE=target expects the fix; MODE=base records the pre-fix behavior.
import { createServer } from "node:http";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";

const execFileAsync = promisify(execFile);

// Mirror the Pi CLI's own process setup (dist/cli/setup.js setupCli()).
process.title = "pi";
process.env.PI_CODING_AGENT = "true";
process.env.AI_AGENT = "pi";

const E = process.env;
const LAB = E.FM_HOME;
const STATE = `${LAB}/state`;
const CODE_ROOT = E.CODE_ROOT;
const FIXTURE = E.FIXTURE;
const WORK = E.WORK;
const MODE = E.MODE;
const LOG = E.DRIVER_LOG;
const TASK = "fm-g2jj0";
const REFUSAL = `error: claim refused - task '${TASK}' is leased to the branch supervision actor (state/.lease-${TASK})`;
const GUARD_REFUSAL = `error: steer (fm-send) refused - task '${TASK}' is leased to the branch supervision actor (state/.lease-${TASK})`;

const log = (tag, value) => appendFileSync(LOG, `${new Date().toISOString()} ${tag} ${typeof value === "string" ? value : JSON.stringify(value)}\n`);
const read = (path) => { try { return readFileSync(path, "utf8"); } catch { return null; } };
const observations = [];
const observe = (name, actual, expected) => {
  const ok = expected === undefined ? null : expected(actual);
  observations.push({ name, ok, actual });
  log(`observe ${ok === null ? "info" : ok ? "PASS" : "FAIL"} ${name}`, actual);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const waitFor = async (predicate, label, ms = 60000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await predicate()) return;
    await sleep(50);
  }
  throw new Error(`timeout waiting for ${label}`);
};
// An observer shell outside any supervision actor, like an operator's terminal.
const observer = async (args) => {
  try {
    const { stdout, stderr } = await execFileAsync("bash", [`${CODE_ROOT}/bin/fm-lease.sh`, ...args], { env: { ...process.env, FM_HOME: LAB } });
    return { rc: 0, out: (stdout + stderr).trim() };
  } catch (error) {
    return { rc: error.code, out: `${error.stdout ?? ""}${error.stderr ?? ""}`.trim() };
  }
};

// ---------------------------------------------------------------- local model
const textOf = (message) => typeof message?.content === "string"
  ? message.content
  : (message?.content ?? []).map((part) => part.text ?? "").join("\n");
let callSeq = 0;
const tool = (name, args) => ({ kind: "tool", name, args });
const say = (text) => ({ kind: "text", text });
const fail429 = () => ({ kind: "error", status: 429, body: { error: { message: "Monthly usage limit reached", type: "insufficient_quota" } } });
let mainSteps = [];
let branchSteps = [];
const handledWakeMessages = new Set();
let fallbackSteps = [];
const requests = { main: 0, branch: 0 };

const server = createServer(async (req, res) => {
  let body = "";
  for await (const chunk of req) body += chunk;
  const payload = JSON.parse(body);
  const actor = (payload.tools ?? []).some((t) => t.function?.name === "fm_branch_report") ? "branch" : "main";
  requests[actor] += 1;
  const last = payload.messages.at(-1);
  log(`model-request ${actor}#${requests[actor]}`, { lastRole: last?.role, last: textOf(last).slice(0, 1200) });
  let step;
  if (actor === "main") {
    // The watcher's fallback delivery of a wake the branch did not settle is
    // the moment main repairs; each such delivery loads the repair turn once.
    const users = payload.messages.map((m, i) => [m, i]).filter(([m]) => m.role === "user");
    const [lastUser, index] = users.at(-1) ?? [];
    if (lastUser && textOf(lastUser).includes("FIRSTMATE WATCHER WAKE") && !handledWakeMessages.has(index)) {
      handledWakeMessages.add(index);
      mainSteps = [...fallbackSteps];
    }
    step = mainSteps.shift() ?? say("ACK");
  } else {
    step = branchSteps.shift() ?? fail429();
  }
  if (typeof step === "function") step = await step(payload);
  log(`model-reply ${actor}#${requests[actor]}`, step.kind === "tool" ? { tool: step.name, args: step.args } : step);
  if (step.kind === "error") {
    res.writeHead(step.status, { "content-type": "application/json" });
    res.end(JSON.stringify(step.body));
    return;
  }
  const chunk = (delta, finish) => `data: ${JSON.stringify({
    id: `fm-lab-${callSeq}`, object: "chat.completion.chunk", created: 1, model: "fm-lab-model",
    choices: [{ index: 0, delta, finish_reason: finish }],
  })}\n\n`;
  res.writeHead(200, { "content-type": "text/event-stream" });
  if (step.kind === "tool") {
    callSeq += 1;
    res.write(chunk({ role: "assistant", content: null, tool_calls: [{ index: 0, id: `call_${callSeq}`, type: "function", function: { name: step.name, arguments: JSON.stringify(step.args) } }] }, null));
    res.write(chunk({}, "tool_calls"));
  } else {
    res.write(chunk({ role: "assistant", content: step.text }, null));
    res.write(chunk({}, "stop"));
  }
  res.end("data: [DONE]\n\n");
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const port = server.address().port;
const models = JSON.stringify({ providers: { "fm-lab-llm": {
  baseUrl: `http://127.0.0.1:${port}/v1`, api: "openai-completions", apiKey: "fm-lab-placeholder",
  models: [{ id: "fm-lab-model", name: "fm lab scripted model", contextWindow: 400000, maxTokens: 4096 }],
} } });
// Main's own agent dir and the branch's isolated runtime (PI_CODING_AGENT_DIR)
// both name only this local endpoint; no real credential is ever read.
writeFileSync(`${WORK}/main-agent/models.json`, models);
writeFileSync(`${E.PI_CODING_AGENT_DIR}/models.json`, models);
writeFileSync(`${WORK}/llm-port`, String(port));
log("llm", `scripted model endpoint http://127.0.0.1:${port}/v1 (mode=${MODE}, code root ${CODE_ROOT})`);

// ------------------------------------------------------------- Pi primary
const sdk = await import(pathToFileURL(`${E.PI_PKG}/dist/index.js`).href);
process.env.FM_ROOT_OVERRIDE = CODE_ROOT;
const branchMod = await import(pathToFileURL(`${FIXTURE}/.pi/extensions/fm-branch-supervision.ts`).href);
process.env.FM_ROOT_OVERRIDE = FIXTURE;
const watchMod = await import(pathToFileURL(`${FIXTURE}/.pi/extensions/fm-primary-pi-watch.ts`).href);
delete process.env.FM_ROOT_OVERRIDE;
const offers = [];
const settings = sdk.SettingsManager.create(LAB, `${WORK}/main-agent`);
const loader = new sdk.DefaultResourceLoader({
  cwd: CODE_ROOT, agentDir: `${WORK}/main-agent`, settingsManager: settings,
  extensionFactories: [branchMod.default, watchMod.default, (pi) => {
    pi.events.on("fm-branch-supervision:dispatch", (offer) => { offers.push(offer); });
  }],
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
});
await loader.reload();
const loadErrors = loader.getExtensions().errors;
if (loadErrors.length) throw new Error(`extension load errors: ${JSON.stringify(loadErrors)}`);
const mainRuntime = await sdk.ModelRuntime.create({ authPath: `${WORK}/main-agent/auth.json`, modelsPath: `${WORK}/main-agent/models.json` });
const registry = new sdk.ModelRegistry(mainRuntime);
await registry.refresh();
const model = registry.find("fm-lab-llm", "fm-lab-model");
if (!model) throw new Error("main runtime did not resolve the local model");
const extensionErrors = [];
const { session } = await sdk.createAgentSession({
  cwd: CODE_ROOT, agentDir: `${WORK}/main-agent`, settingsManager: settings, resourceLoader: loader,
  sessionManager: sdk.SessionManager.create(CODE_ROOT, `${WORK}/main-sessions`),
  modelRuntime: mainRuntime, model, sessionStartEvent: { type: "session_start", reason: "startup" },
});
await session.bindExtensions({ onError: (error) => { extensionErrors.push(String(error?.error ?? error?.message ?? error)); log("extension-error", String(error?.error ?? error)); } });
log("pi", `Pi SDK ${E.PI_VERSION} primary pid=${process.pid} tools=${session.getActiveToolNames?.().join(",") ?? "?"}`);

// Turn 1 - session start, as a primary does it: take the fleet lock with the
// real bin/fm-lock.sh from main's own bash tool, then arm the watcher.
mainSteps = [tool("bash", { command: "bin/fm-lock.sh; echo lock-rc=$?; cat \"$FM_HOME/state/.lock\"" }), tool("fm_watch_arm_pi", {}), say("Session started; watcher armed.")];
await session.prompt("Captain: start the session.");
await waitFor(() => existsSync(E.FM_LIVE_WATCH_LOG) && read(E.FM_LIVE_WATCH_LOG).includes("arm pid="), "watcher arm");
observe("real fm-lock.sh recorded this Pi process as the session-lock holder", read(`${STATE}/.lock`)?.trim(), (v) => v === String(process.pid));

const appendWake = async (reason) => {
  // The crewmate's signal file, then the real durable queue append the watcher
  // performs for it, then the arm prints the reason.
  appendFileSync(`${STATE}/${TASK}.status`, `${reason}\n`);
  await execFileAsync("bash", ["-c", `. "${CODE_ROOT}/bin/fm-wake-lib.sh"; fm_wake_append signal ${TASK}.status "$1"`, "_", reason], { env: { ...process.env, STATE } });
  writeFileSync(E.FM_LIVE_WATCH_TRIGGER, `${reason}\n`);
};

const mainRepairCommand = (label) =>
  `echo "== ${label}: lease before =="; bin/fm-lease.sh check ${TASK}; ` +
  `echo "branch-turn record: $(cat "$FM_HOME/state/.branch-turn" 2>/dev/null || echo absent)"; ` +
  `bin/fm-lease.sh claim ${TASK}; echo "main-claim-rc=$?"; ` +
  `bin/fm-send.sh ${TASK} "repair from main: resume from your last checkpoint"; echo "main-steer-rc=$?"; ` +
  `bin/fm-lease.sh check ${TASK}; bin/fm-lease.sh release ${TASK}; echo "main-release-rc=$?"`;
const lastToolResult = (payload) => textOf([...payload.messages].reverse().find((m) => m.role === "tool"));

// ------------------------------------------------- wake 1: the incident shape
// The branch claims the task mid-turn, then its turn dies on a provider error
// before it can release. Main, still alive and holding the lock, then repairs.
let mid1 = null;
let mainMidTurn = null;
let fallbackResult = null;
branchSteps = [
  tool("bash", { command: `bin/fm-lease.sh claim ${TASK}; echo "branch-claim-rc=$?"; echo "lease: $(cat "$FM_HOME/state/.lease-${TASK}")"; echo "FM_BRANCH_REPORT_TURN=$FM_BRANCH_REPORT_TURN"; echo "branch-turn record: $(cat "$FM_HOME/state/.branch-turn" 2>/dev/null || echo absent)"` }),
  async (payload) => {
    mid1 = {
      branchToolResult: lastToolResult(payload),
      turnRecord: read(`${STATE}/.branch-turn`),
      lease: read(`${STATE}/.lease-${TASK}`),
      check: await observer(["check", TASK]),
    };
    // Main's own mid-turn repair attempt, through main's real model turn and bash tool.
    mainSteps = [tool("bash", { command: mainRepairCommand("main mid-turn") }), (p) => { mainMidTurn = lastToolResult(p); return say("Main is refused while the branch handles fm-g2jj0."); }];
    await session.prompt("Captain: fm-g2jj0 looks stuck - steer it to resume.");
    return fail429();
  },
];
fallbackSteps = [tool("bash", { command: mainRepairCommand("main after the branch turn died") }), (p) => { fallbackResult = lastToolResult(p); return say("Repaired fm-g2jj0."); }];
await appendWake(`signal: ${TASK} blocked - waiting on a steer`);
await waitFor(() => offers.length === 1, "wake 1 offer");
observe("wake 1 offered to and accepted by the branch", offers[0].accepted, (v) => v === true);
const settle1 = await offers[0].settlement.then(() => "resolved", (error) => `rejected: ${error.message}`);
observe("wake 1 branch turn died on the provider error (settlement rejected to the watcher)", settle1, (v) => v.startsWith("rejected: supervision branch provider failed after construction"));
await waitFor(() => fallbackResult !== null, "main's repair turn after the watcher fallback", 90000);
await waitFor(() => !session.isStreaming, "main idle after repair");

const turnRe = /^turn=\d+\.\d+\n$/;
observe("mid-turn: the branch turn record names this wake", mid1.turnRecord, (v) => MODE === "base" ? v === null : turnRe.test(v ?? ""));
const turnId = (mid1.turnRecord ?? "").trim().slice("turn=".length);
observe("mid-turn: the branch's own bash env carried exactly that turn id", mid1.branchToolResult, (v) => MODE === "base" ? v.includes("FM_BRANCH_REPORT_TURN=\n") || /FM_BRANCH_REPORT_TURN=\s*$/m.test(v) : v.includes(`FM_BRANCH_REPORT_TURN=${turnId}`));
observe("mid-turn: the branch's lease records the turn token as field 4", mid1.lease, (v) => MODE === "base" ? (v ?? "").split("\t").length === 3 : (v ?? "").trimEnd().endsWith(`\tturn:${turnId}`) && v.startsWith(`branch\t${process.pid}\t`));
observe("mid-turn: an operator check reads the branch lease live", mid1.check, (v) => v.rc === 0 && v.out.startsWith(`branch ${process.pid} `) && v.out.endsWith(" live"));
observe("mid-turn: main's claim is refused with the incident's exact refusal", mainMidTurn, (v) => (v ?? "").includes(REFUSAL) && (v ?? "").includes("main-claim-rc=6"));
observe("mid-turn: main's guarded steer (fm-send) is refused by the lease guard", mainMidTurn, (v) => (v ?? "").includes(GUARD_REFUSAL) && (v ?? "").includes("main-steer-rc=6"));
observe("after the branch died: no branch turn record remains", read(`${STATE}/.branch-turn`), (v) => v === null);
if (MODE === "base") {
  observe("after the branch died (pre-fix): main's claim is STILL refused with the incident's refusal", fallbackResult, (v) => v.includes(REFUSAL) && v.includes("main-claim-rc=6"));
  observe("after the branch died (pre-fix): main's steer is STILL refused", fallbackResult, (v) => v.includes(GUARD_REFUSAL) && v.includes("main-steer-rc=6"));
} else {
  observe("after the branch died: the leftover branch lease reads stale although the Pi pid lives and holds the lock", fallbackResult, (v) => new RegExp(`== main after the branch turn died: lease before ==\\nbranch ${process.pid} \\d+ stale`).test(v));
  observe("after the branch died: main's claim succeeds", fallbackResult, (v) => v.includes("main-claim-rc=0") && !v.includes("claim refused"));
  observe("after the branch died: main's guarded steer (fm-send) is durably delivered", fallbackResult, (v) => v.includes("main-steer-rc=0") && !v.includes("refused"));
}
const inboxCount = Number((await execFileAsync("bash", ["-c", `find "$1" -type f -name '*.msg' 2>/dev/null | wc -l`, "_", `${STATE}/${TASK}.inbox`])).stdout.trim());
observe("main's repair steer left a durable inbox record (target) / none (base)", inboxCount, (v) => MODE === "base" ? v === 0 : v >= 1);

// ----------------------------------- wake 2: a normal turn that forgets to release
// The branch claims, steers, reports, and ends cleanly - but never releases.
// Its lease must die with the turn, and the session-start sweep must reclaim it.
await execFileAsync("bash", [`${CODE_ROOT}/bin/fm-lease.sh`, "release", TASK], { env: { ...process.env, FM_HOME: LAB } }).catch(() => {});
let mid2 = null;
const wake2 = `signal: ${TASK} checkpoint written - continue`;
branchSteps = [
  tool("bash", { command: `bin/fm-lease.sh claim ${TASK}; echo "branch-claim-rc=$?"; bin/fm-send.sh ${TASK} "branch: carry on from the checkpoint"; echo "branch-steer-rc=$?"` }),
  async (payload) => {
    mid2 = { branchToolResult: lastToolResult(payload), turnRecord: read(`${STATE}/.branch-turn`), lease: read(`${STATE}/.lease-${TASK}`) };
    return tool("fm_branch_report", { task: TASK, verdict: "routine", summary: "steered fm-g2jj0 to carry on from its checkpoint", wake: wake2 });
  },
  say("Handled the checkpoint wake."),
];
await appendWake(wake2);
await waitFor(() => offers.length === 2, "wake 2 offer");
const settle2 = await offers[1].settlement.then(() => "resolved", (error) => `rejected: ${error.message}`);
observe("wake 2: a normal branch turn settles cleanly", settle2, (v) => v === "resolved");
observe("wake 2 mid-turn: the branch claimed and steered under its own lease", mid2?.branchToolResult, (v) => (v ?? "").includes("branch-claim-rc=0") && (v ?? "").includes("branch-steer-rc=0"));
observe("wake 2 mid-turn: its lease carried the turn token", mid2?.lease, (v) => MODE === "base" ? (v ?? "").split("\t").length === 3 : /\tturn:\d+\.\d+\n$/.test(v ?? ""));
observe("wake 2 settled: the branch turn record is removed", read(`${STATE}/.branch-turn`), (v) => v === null);
const check2 = await observer(["check", TASK]);
observe("wake 2 settled: the unreleased branch lease reads stale (target) / live (base)", check2, (v) => v.rc === 0 && v.out.endsWith(MODE === "base" ? " live" : " stale"));
const sweep = await observer(["sweep"]);
observe("session-start sweep reclaims the ended turn's lease (target) / keeps it (base)", { sweep, leaseAfter: read(`${STATE}/.lease-${TASK}`) }, (v) => v.sweep.rc === 0 && (MODE === "base" ? v.leaseAfter !== null : v.leaseAfter === null));

// ---------------- wake 3: a second Pi session in the same home must not interfere
// While the owner's branch is mid-turn, a separate Pi process that does NOT own
// the fleet lock starts and shuts down in this home (outside this process's
// ancestry). Its shutdown must not remove the owner's live turn record.
await execFileAsync("bash", [`${CODE_ROOT}/bin/fm-lease.sh`, "release", TASK], { env: { ...process.env, FM_HOME: LAB, FM_SUPERVISION_ACTOR: "branch", FM_LEASE_HOLDER_PID: String(process.pid) } }).catch(() => {});
await observer(["sweep"]);
let mid3 = null;
const wake3 = `signal: ${TASK} needs a nudge`;
branchSteps = [
  tool("bash", { command: `bin/fm-lease.sh claim ${TASK}; echo "branch-claim-rc=$?"` }),
  async () => {
    const before = read(`${STATE}/.branch-turn`);
    writeFileSync(`${WORK}/mid-turn-3`, before ?? "");
    await waitFor(() => existsSync(`${WORK}/secondary-done`), "secondary Pi session start/shutdown", 120000);
    mid3 = { before, after: read(`${STATE}/.branch-turn`), check: await observer(["check", TASK]), secondary: read(`${WORK}/secondary-done`) };
    return tool("bash", { command: `bin/fm-lease.sh release ${TASK}; echo "branch-release-rc=$?"` });
  },
  tool("fm_branch_report", { task: TASK, verdict: "routine", summary: "nudged fm-g2jj0", wake: wake3 }),
  say("Handled the nudge wake."),
];
await appendWake(wake3);
await waitFor(() => offers.length === 3, "wake 3 offer");
const settle3 = await offers[2].settlement.then(() => "resolved", (error) => `rejected: ${error.message}`);
observe("wake 3: the owner's turn settles cleanly after the secondary session came and went", settle3, (v) => v === "resolved");
observe("wake 3: the secondary session did not own the lock", mid3?.secondary, (v) => (v ?? "").includes("owner=false"));
observe("wake 3: the secondary session's shutdown left the owner's live turn record intact", mid3, (v) => MODE === "base" ? v.before === null : (v.before ?? "") !== "" && v.after === v.before);
observe("wake 3: the owner's lease stayed live across the secondary shutdown", mid3?.check, (v) => v.rc === 0 && v.out.endsWith(" live"));
observe("wake 3 settled: the owner's turn record is removed at settlement", read(`${STATE}/.branch-turn`), (v) => v === null);

// --------------------------------------------------------------- shutdown
await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
await session.dispose();
observe("no extension errors were raised", extensionErrors, (v) => v.length === 0);
observe("model requests served by the local endpoint", requests, undefined);
server.close();
const failed = observations.filter((o) => o.ok === false);
writeFileSync(`${WORK}/observations.json`, JSON.stringify({ mode: MODE, observations }, null, 2));
console.log(`${failed.length ? "DRIVE_FAIL" : "DRIVE_OK"} mode=${MODE} checks=${observations.filter((o) => o.ok !== null).length} failed=${failed.length}`);
for (const o of observations) console.log(`${o.ok === null ? "INFO" : o.ok ? "PASS" : "FAIL"} ${o.name}`);
process.exit(failed.length ? 1 : 0);
