// A second, independent Pi session in the same lab home (not in the owner's
// process ancestry, so it does not own the fleet lock): real Pi SDK, real
// supervision-branch extension. It starts and shuts down while the owner's
// branch is mid-turn; the owner's turn record must survive.
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

process.title = "pi";
process.env.PI_CODING_AGENT = "true";
process.env.AI_AGENT = "pi";
const E = process.env;
const read = (path) => { try { return readFileSync(path, "utf8"); } catch { return null; } };
const sdk = await import(pathToFileURL(`${E.PI_PKG}/dist/index.js`).href);
process.env.FM_ROOT_OVERRIDE = E.CODE_ROOT;
const branchMod = await import(pathToFileURL(`${E.FIXTURE}/.pi/extensions/fm-branch-supervision.ts`).href);
delete process.env.FM_ROOT_OVERRIDE;
const agentDir = `${E.WORK}/secondary-agent`;
const settings = sdk.SettingsManager.create(E.FM_HOME, agentDir);
const loader = new sdk.DefaultResourceLoader({
  cwd: E.CODE_ROOT, agentDir, settingsManager: settings, extensionFactories: [branchMod.default],
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
});
await loader.reload();
const runtime = await sdk.ModelRuntime.create({ authPath: `${agentDir}/auth.json`, modelsPath: `${agentDir}/models.json` });
const registry = new sdk.ModelRegistry(runtime);
await registry.refresh();
const model = registry.find("fm-lab-llm", "fm-lab-model");
const before = read(`${E.FM_HOME}/state/.branch-turn`);
const { session } = await sdk.createAgentSession({
  cwd: E.CODE_ROOT, agentDir, settingsManager: settings, resourceLoader: loader,
  sessionManager: sdk.SessionManager.create(E.CODE_ROOT, `${E.WORK}/secondary-sessions`),
  modelRuntime: runtime, model, sessionStartEvent: { type: "session_start", reason: "startup" },
});
await session.bindExtensions({ onError: () => {} });
const lockPid = (read(`${E.FM_HOME}/state/.lock`) ?? "").trim();
await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
await session.dispose();
const after = read(`${E.FM_HOME}/state/.branch-turn`);
const line = `secondary pid=${process.pid} lockPid=${lockPid} owner=${lockPid === String(process.pid)} turn-before=${JSON.stringify(before)} turn-after=${JSON.stringify(after)}`;
writeFileSync(`${E.WORK}/secondary-done`, `${line}\n`);
console.log(line);
process.exit(0);
