// Public entry point and complete input contract: fm-rule-conformance.sh --help.
import { closeSync, existsSync, lstatSync, mkdirSync, openSync, readSync, realpathSync, rmdirSync, statSync, writeSync, fsyncSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { dirname, resolve, sep } from 'node:path';

const HELP = `On-demand conformance collector. Logging only; no gates or background work.
Usage: fm-rule-conformance.sh --manifest FILE --output DIR --registry FILE
       fm-rule-conformance.sh --help
No arguments reports whether FM_HOME/data/rule-conformance/conformance.log exists.
Requires Bun and Git. Output DIR must be under an untracked, ignored data/ directory
when inside Git; outside Git it must still be under data/. Refuses symlink output
paths, hardlinked output files and concurrent collectors; never steals a lock.
Appends conformance.log and conformance-notes.md. Notes map opaque artifact
references to source paths, hashes, bounds and fixed explanations, never payload.
Log fields: rule | derivation UTC | verdict | reference. Existing bytes are never
rewritten. Deduplicates (rule, reference), including seed rows, under one lock.
Changed source bytes are a new observation. References never contain input text,
filenames, bead bodies, task identifiers or provider/patient identifiers.

Manifest JSON enumerates sources, never verdicts (all arrays optional):
{
 "transcripts":[{"file":"/sessions/session.jsonl","offset":0,"bytes":65536}],
 "gateEvents":["/home/state/evidence/actions/action-ledger.jsonl"],
 "git":[{"repo":"/repo","commits":["FULL_SHA"],"meta":"/home/state/task.meta",
          "enforcementPaths":["bin/fm-action-gate.sh"]}],
 "runData":[{"checks":"/checks.json","run":"/run.json",
              "deliveries":"/home/state/.watch-deliveries.log",
              "transcript":{"file":"/sessions/session.jsonl","offset":0},
              "merge":"/merge-result.json"}],
 "localLogs":[{"file":"/timing.json","beads":"/bd-list.json",
                "before":"/before.log","after":"/after.log"}],
 "github":[{"repo":"owner/repo","head":"FULL_SHA","run":123}]
}
checks is the native check-runs response, run the workflow-run API response;
merge is a merge API result. github reads those first two endpoints via gh-axi
GET and snapshots exact JSON in DIR; it never merges or mutates GitHub.
localLogs.file accepts fm-test-run timing JSON or raw FM_TEST_END lines.
beads is native bd list --all --limit 0 --json output; no bead bodies are copied.
before/after accept raw FM_TEST_END evidence for the SAME test with ordered UTC
times. No pairing is guessed from filenames or prose saying FAIL/PASS.
git.meta reads only the worktree= field and compares git worktree list --porcelain.
enforcementPaths selects paths for a read-only dirty-state check; clean state
alone never proves all changes came through PRs. Full commit SHAs only.

Every file read is bounded: 4 MiB ordinary artifact, 1 MiB manifest/registry;
transcripts default 64 KiB, maximum 256 KiB, one window per session per invocation.
Transcript windows skip partial edges, malformed records, thinking and tool-call
arguments. Only Pi message.role assistant text is a claim; toolResult is separate.
No window or missing phrase proves absence across a session. The parser never
labels a question as direct captain communication from role/text alone.
Input arrays max 100 each. Git/API commands timeout after 15s, output max 4 MiB.
Unobservable signatures produce no-signature/out-of-scope with fixed reasons in
notes, including semantic ordering, read-time API joins and missing whitelist.
The three registry no-signature rules are always recorded against the registry.
Unsupported registry rules fail rather than silently losing coverage.

Examples:
  fm-rule-conformance.sh --manifest /tmp/sources.json --output /home/fm/data/rule-conformance --registry /home/fm/data/rule-conformance/registry.md
  fm-rule-conformance.sh --manifest /tmp/git-only.json --output /tmp/proof/data/rule-conformance --registry /home/fm/data/rule-conformance/registry.md
`;
type Verdict = 'follow' | 'violate' | 'miss' | 'out-of-scope' | 'no-signature';
type Window = {file: string; offset?: number; bytes?: number};
type Row = {rule: string; verdict: Verdict; ref: string; note: string};
const GROUPS = {
  transcript: ['search-before-ask', 'timestamped-heads', 'refusal-verbatim', 'two-attempt-cap', 'report-standards', 'explained-twice', 'stop-at-safety-boundary'],
  gate: ['ui-done-gate'],
  run: ['watchdog', 'green-claims', 'current-head-recount', 'no-waiver-merges', 'two-attempt-cap'],
  git: ['strip-at-merge', 'no-hand-edit-enforcement', 'one-worktree', 'disclose-not-rewrite'],
  local: ['auto-bead', 'fail-before-pass-after', 'no-phi-in-receipts'],
  none: ['first-step-first', 'report-standards', 'never-bypass-a-refusal'],
};
const MAX = 4194304;
const rows: Row[] = [];
const paths = new Map<string, string>();
const digest = (s: string | Buffer) => createHash('sha256').update(s).digest('hex');
const add = (rule: string, verdict: Verdict, ref: string, note: string) => rows.push({rule, verdict, ref, note});
const unknown = (rules: string[], ref: string, note: string, verdict: Verdict = 'no-signature') => rules.forEach(r => add(r, verdict, ref, note));
function fail(message: string): never { throw new Error(message); }
function list(v: any, name: string): any[] {
  if (v === undefined) return [];
  if (!Array.isArray(v) || v.length > 100) fail(`invalid ${name}: expected at most 100 entries`);
  return v;
}
function str(v: any): string { if (typeof v !== 'string' || !v || /[\r\n\0]/.test(v)) fail('invalid source path or argument'); return v; }
function command(args: string[], cwd?: string): string {
  const p = spawnSync(args[0], args.slice(1), {cwd, timeout: 15000, maxBuffer: MAX, env: {...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0', GH_PROMPT_DISABLED: '1'}});
  if (p.error || p.status !== 0) fail(`source command failed (${args[0]}); no verdict appended`);
  return p.stdout.toString('utf8');
}
function read(file: string, cap = MAX): Buffer {
  file = realpathSync(str(file));
  const fd = openSync(file, 'r');
  try {
    const size = statSync(file).size;
    if (!statSync(file).isFile() || size > cap) fail('source is not a bounded regular file');
    const b = Buffer.alloc(size + 1);
    const n = readSync(fd, b, 0, b.length, 0);
    if (n > size) fail('source grew during read; select a stable snapshot');
    return b.subarray(0, n);
  } finally { closeSync(fd); }
}
function artifact(file: string): {text: string; ref: string} {
  const b = read(file), ref = `artifact:sha256:${digest(realpathSync(file))}:${digest(b)}`;
  paths.set(ref, `path=${JSON.stringify(realpathSync(file))}; sha256=${digest(b)}`);
  return {text: b.toString('utf8'), ref};
}
function json(text: string): any { try { return JSON.parse(text); } catch { return null; } }
function load(file?: string): {text: string; ref: string; doc: any} | undefined {
  if (!file) return;
  const a = artifact(file); return {...a, doc: json(a.text)};
}
function joined(...refs: (string | undefined)[]): string { return refs.filter(Boolean).join('+'); }

// Parser 1: one bounded Pi JSONL window, preserving byte locations and roles.
const sessions = new Set<string>();
function transcript(w: Window) {
  const file = realpathSync(str(w.file));
  if (sessions.has(file)) fail('only one bounded window per session per invocation');
  sessions.add(file);
  const size = statSync(file).size, bytes = w.bytes ?? 65536, offset = w.offset ?? Math.max(0, size - bytes);
  if (!statSync(file).isFile() || !Number.isInteger(bytes) || bytes < 1 || bytes > 262144 || !Number.isSafeInteger(offset) || offset < 0 || offset > size) fail('invalid transcript window');
  const fd = openSync(file, 'r'), b = Buffer.alloc(bytes + (offset > 0 ? 1 : 0));
  let n: number;
  try { n = readSync(fd, b, 0, b.length, Math.max(0, offset - 1)); } finally { closeSync(fd); }
  const prefix = offset > 0 ? 1 : 0, body = b.subarray(prefix, n);
  const ref = `transcript:sha256:${digest(file)}:offset=${offset}:bytes=${body.length}:sha256=${digest(body)}`;
  paths.set(ref, `path=${JSON.stringify(file)}; offset=${offset}; bytes=${body.length}; sha256=${digest(body)}; coverage=partial`);
  const messages: {role: string; text: string; timestamp: string; ref: string}[] = [];
  let pos = 0;
  while (pos < body.length) {
    const end = body.indexOf(10, pos);
    if (end < 0) break; // Even a final unterminated line is not a complete record.
    if (pos > 0 || offset === 0 || b[0] === 10) {
      const d = json(body.subarray(pos, end).toString('utf8'));
      if (d?.type === 'message' && ['assistant', 'toolResult'].includes(d.message?.role)) {
        const content = d.message.content;
        const text = typeof content === 'string' ? content : Array.isArray(content) ? content.filter((c: any) => c.type === 'text' && typeof c.text === 'string').map((c: any) => c.text).join('\n') : '';
        messages.push({role: d.message.role, text, timestamp: d.timestamp, ref: `${ref}:record=${offset + pos}`});
      }
    }
    pos = end + 1;
  }
  return {ref, messages};
}
function parseTranscript(w: Window) {
  const t = transcript(w);
  unknown(GROUPS.transcript, t.ref, 'Bounded transport records do not establish captain-directed questions, read-time head bindings, complete retry absence, correction identity, or mutation absence.');
  // Positive surface evidence only; never promote a quote to proof of a read.
  for (const m of t.messages.filter(m => m.role === 'assistant')) {
    if (/\b[0-9a-f]{40}\b/i.test(m.text)) add('timestamped-heads', 'no-signature', m.ref, 'Head quote found; matching independent head read and timestamp binding required.');
    if (/\bgreen\b/i.test(m.text)) add('green-claims', 'no-signature', m.ref, 'Claim candidate found; check-runs snapshot at the quoted head/read time required.');
  }
}

// Parser 2: code-written action ledger. A decision is not itself UI routing.
function parseGate(file: string) {
  const a = artifact(file); let seen = 0, offset = 0;
  for (const line of a.text.split('\n')) {
    const d = json(line);
    if (d && typeof d.timestamp === 'string' && ['ALLOW', 'DENY', 'HUMAN_REVIEW'].includes(d.decision) && typeof d.action_class === 'string') {
      seen++;
      add('ui-done-gate', 'out-of-scope', `${a.ref}:byte=${offset}`, 'Action decision parsed; native action-ledger has no UI-done finding identity or routing event.');
    }
    offset += Buffer.byteLength(line) + 1;
  }
  if (!seen) add('ui-done-gate', 'no-signature', a.ref, 'No recognized code-written action decision.');
}

// Parser 3: native check-runs/workflow-run data, with cross-artifact joins.
function parseRuns(s: any) {
  const checks = load(s.checks), run = load(s.run), deliveries = load(s.deliveries), merge = load(s.merge);
  const t = s.transcript ? transcript(s.transcript) : undefined;
  const ref = joined(checks?.ref, run?.ref, deliveries?.ref, merge?.ref, t?.ref);
  if (!ref) fail('runData requires a source artifact');
  const rr = run?.doc;
  const validRun = rr && Number.isSafeInteger(rr.id) && /^[0-9a-f]{40}$/i.test(rr.head_sha) && Number.isSafeInteger(rr.run_attempt) && rr.run_attempt >= 1;
  if (validRun && rr.run_attempt > 3) add('two-attempt-cap', 'violate', ref, 'Workflow-run API reports more than two reruns (run_attempt minus the original attempt).');
  else add('two-attempt-cap', 'no-signature', ref, 'Attempt count alone cannot establish unrelatedness evidence before each rerun.');
  const cs = checks?.doc;
  const complete = cs && Array.isArray(cs.check_runs) && Number.isSafeInteger(cs.total_count) && cs.total_count === cs.check_runs.length && cs.check_runs.every((c: any) => Number.isSafeInteger(c.id) && /^[0-9a-f]{40}$/i.test(c.head_sha));
  // A later snapshot cannot prove a historical claim. Do not compare raw prose
  // against today's API and claim that this recreates the read-time observation.
  unknown(['green-claims', 'current-head-recount'], ref, complete ? 'Complete check-runs page parsed; transcript claim/read-time binding is not independently recorded.' : 'Missing, truncated or malformed native check-runs response.');
  add('watchdog', 'no-signature', ref, 'A completed red run alone does not identify a red transition; delivery ledger lacks a structured run/head transition binding.');
  add('no-waiver-merges', 'no-signature', ref, merge?.doc?.merged === true ? 'Successful merge result omits whether admin/allow-red was used; complete request/decline transcript required.' : 'No successful merge result paired with a complete waiver request/decline record.');
}

// Parser 4: Git itself supplies commit trailers, worktrees and dirty state.
function parseGit(s: any) {
  const repo = realpathSync(str(s.repo));
  command(['git', 'rev-parse', '--show-toplevel'], repo);
  for (const sha of list(s.commits, 'commits')) {
    if (typeof sha !== 'string' || !/^[0-9a-f]{40}$/i.test(sha)) fail('commits must be full hexadecimal SHAs');
    const message = command(['git', 'show', '-s', '--format=%B', sha, '--'], repo);
    const ref = `git:sha256:${digest(repo)}:commit=${sha.toLowerCase()}`;
    paths.set(ref, `repo=${JSON.stringify(repo)}; git show -s --format=%B ${sha} --; sha256=${digest(message)}`);
    // Count agent trailers using the same identity family as strip tooling;
    // human coauthors are allowed by that tool's public contract.
    const count = message.split('\n').filter(line => {
      const match = /^\s*Co-Authored-By:\s*(.*)$/i.exec(line);
      if (!match) return false;
      const identity = match[1].trim().toLowerCase();
      const name = identity.split('<')[0].trim(), email = /<([^>]+)>/.exec(identity)?.[1] ?? '';
      return /^(cursor|cursor agent|claude|claude code|github copilot|copilot|codex|chatgpt|gemini|google gemini|grok|openai|firstmate-worker|commandcodebot)$/.test(name) || /^(noreply@anthropic\.com|cursoragent@.+|noreply@openai\.com|copilot@github\.com|worker@firstmate\.local|noreply@commandcode\.ai)$/.test(email);
    }).length;
    add('strip-at-merge', count ? 'violate' : 'follow', ref, `Selected merge commit contains ${count} recognized agent attribution lines; selection does not prove merge provenance.`);
  }
  const worktrees = command(['git', 'worktree', 'list', '--porcelain'], repo);
  const status = command(['git', 'status', '--porcelain=v1', '--untracked-files=all'], repo);
  const reflog = command(['git', 'reflog', '-n', '100', '--format=%H %gs'], repo);
  const ref = `git:sha256:${digest(repo)}:state=${digest(worktrees + status + reflog)}`;
  paths.set(ref, `repo=${JSON.stringify(repo)}; git worktree list --porcelain + git status --porcelain=v1 --untracked-files=all + git reflog -n 100 --format=%H\ %gs; snapshot-sha256=${digest(worktrees + status + reflog)}`);
  if (s.meta) {
    const meta = artifact(s.meta), matches = [...meta.text.matchAll(/^worktree=(.+)$/gm)];
    const named = matches.length === 1 ? matches[0][1] : '';
    const present = worktrees.split('\n').filter(l => l === `worktree ${named}`).length;
    add('one-worktree', named && present === 1 ? 'no-signature' : named ? 'miss' : 'no-signature', joined(ref, meta.ref), 'Recorded worktree compared with Git inventory; a matching entry cannot attribute other checkouts to this task.');
  } else add('one-worktree', 'no-signature', ref, 'No task metadata supplied for worktree comparison.');
  const enforcement = list(s.enforcementPaths, 'enforcementPaths');
  if (enforcement.length) {
    const changed = command(['git', 'status', '--porcelain=v1', '--untracked-files=all', '--', ...enforcement.map(str)], repo);
    const er = `${ref}:enforcement=${digest(JSON.stringify(enforcement) + changed)}`;
    add('no-hand-edit-enforcement', changed ? 'violate' : 'no-signature', er, changed ? 'Selected enforcement paths have local dirty state.' : 'No local dirty state; full PR merge provenance is not available from Git alone.');
  } else add('no-hand-edit-enforcement', 'no-signature', ref, 'Enforcement path set not supplied.');
  add('disclose-not-rewrite', 'no-signature', ref, 'Bounded local reflog cannot establish remote force-push absence or transcript disclosure.');
}

// Parser 5: tool-written local timing/evidence logs and native bead-list output.
type TestEnd = {test: string; time: number; exit: number};
function endings(text: string): TestEnd[] {
  const d = json(text);
  if (d && Array.isArray(d.scripts) && typeof d.finished_at === 'string') return d.scripts.filter((s: any) => typeof s.path === 'string' && Number.isInteger(s.exit)).map((s: any) => ({test: s.path, time: Date.parse(d.finished_at), exit: s.exit}));
  return [...text.matchAll(/^FM_TEST_END (\S+) (\S+) exit=(\d+) duration_ms=\d+ gate_skip=(?:true|false)$/gm)].map(m => ({test: m[2], time: Date.parse(m[1]), exit: Number(m[3])}));
}
function parseLocal(s: any) {
  const a = artifact(str(s.file)), beads = load(s.beads), before = load(s.before), after = load(s.after);
  const ref = joined(a.ref, beads?.ref, before?.ref, after?.ref);
  const failures = endings(a.text).filter(t => t.exit !== 0 && Number.isFinite(t.time));
  if (!failures.length) add('auto-bead', 'out-of-scope', ref, 'No recognized local failing test in this artifact.');
  else if (Array.isArray(beads?.doc)) {
    // Bead attachment matches are positive evidence only: neither a list nor a
    // receipt proves filing happened before the captain-facing reply.
    const attached = beads.doc.some((b: any) => typeof b.external_ref === 'string' && /^fm-verification:[0-9a-f]{64}$/.test(b.external_ref) && ((b.description ?? '') + '\n' + (b.notes ?? '')).includes(realpathSync(s.file)));
    add('auto-bead', 'no-signature', ref, attached ? 'Native bead attachment found; reply ordering not supplied.' : 'No matching verification attachment in supplied bead-list snapshot; store/time coverage and reply ordering are unproven.');
  } else add('auto-bead', 'no-signature', ref, 'Local failure parsed; native bd-list snapshot and reply ordering unavailable.');
  const bs = before ? endings(before.text) : [], as = after ? endings(after.text) : [];
  const pairs = bs.flatMap(b => as.filter(a => a.test === b.test && b.exit !== 0 && a.exit === 0 && Number.isFinite(b.time) && Number.isFinite(a.time) && b.time < a.time));
  add('fail-before-pass-after', pairs.length ? 'follow' : 'no-signature', ref, pairs.length ? 'Same test has an ordered failing then passing FM_TEST_END/timing record; this does not establish code changes or closure.' : 'No ordered same-test failure/pass pair in supplied native evidence.');
  add('no-phi-in-receipts', 'no-signature', ref, 'Registry names a whitelist but supplies no fields/value grammar or authoritative whitelist reference; no payload copied.');
}

function safeDirectory(dir: string) {
  dir = resolve(str(dir));
  if (!dir.split(sep).includes('data')) fail('output must be under private data/');
  let path = sep;
  for (const part of dir.split(sep).filter(Boolean)) {
    path = resolve(path, part);
    if (existsSync(path) && lstatSync(path).isSymbolicLink()) fail('symlink output path refused');
  }
  mkdirSync(dir, {recursive: true, mode: 0o700});
  const p = spawnSync('git', ['rev-parse', '--show-toplevel'], {cwd: dir, timeout: 15000, maxBuffer: MAX});
  if (p.status === 0) {
    // Git quiet mode accepts one pathname only. Each destination must pass;
    // checking both without -q would establish only that at least one is ignored.
    const ignored = ['conformance.log', 'conformance-notes.md'].map(name =>
      spawnSync('git', ['check-ignore', '-q', '--', resolve(dir, name)], {cwd: dir}));
    if (ignored.some(p => p.status !== 0) || command(['git', 'ls-files', '--', dir + '/'], dir).trim()) fail('output must be ignored and untracked');
  }
  return dir;
}
function appendFile(file: string, text: string) {
  if (existsSync(file) && (!lstatSync(file).isFile() || lstatSync(file).isSymbolicLink() || lstatSync(file).nlink !== 1)) fail('unsafe output file');
  const fd = openSync(file, 'a', 0o600);
  try {
    const b = Buffer.from(text); let offset = 0;
    while (offset < b.length) offset += writeSync(fd, b, offset, b.length - offset);
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
function historyKeys(file: string): Set<string> {
  const seen = new Set<string>();
  if (!existsSync(file)) return seen;
  const fd = openSync(file, 'r'), buffer = Buffer.alloc(65536);
  let pending = '';
  try {
    let n: number;
    while ((n = readSync(fd, buffer, 0, buffer.length, null)) > 0) {
      pending += buffer.subarray(0, n).toString('utf8');
      let end: number;
      while ((end = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, end); pending = pending.slice(end + 1);
        if (!line.trim() || line.startsWith('#')) continue;
        const fields = line.split('|').map(s => s.trim());
        if (fields.length !== 4) fail('malformed existing log; left unchanged');
        seen.add(fields[0] + '\0' + fields[3]);
      }
      if (pending.length > 65536) fail('oversized existing log row; left unchanged');
    }
    if (pending) fail('unterminated existing log; left unchanged');
  } finally { closeSync(fd); }
  return seen;
}
async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help') || args.includes('-h')) { console.log(HELP); return; }
  if (!args.length) {
    const file = process.env.FM_HOME ? resolve(process.env.FM_HOME, 'data/rule-conformance/conformance.log') : '';
    console.log(`log: ${file && existsSync(file) ? 'present' : 'not selected or absent'}\nhelp: fm-rule-conformance.sh --help`); return;
  }
  const options: Record<string, string> = {};
  while (args.length) {
    const k = args.shift()!, v = args.shift();
    if (!['--manifest', '--output', '--registry'].includes(k) || !v || options[k]) fail('expected --manifest FILE --output DIR --registry FILE');
    options[k] = str(v);
  }
  if (!options['--manifest'] || !options['--output'] || !options['--registry']) fail('expected --manifest FILE --output DIR --registry FILE');
  const manifest = json(read(options['--manifest'], 1048576).toString());
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) fail('invalid manifest');
  const known = new Set(['transcripts', 'gateEvents', 'git', 'runData', 'localLogs', 'github']);
  if (Object.keys(manifest).some(k => !known.has(k))) fail('unknown manifest field; verdict input is forbidden');
  const registry = read(options['--registry'], 1048576), regText = registry.toString();
  const ruleIDs = [...regText.matchAll(/^\| `([a-z-]+)` \|/gm)].map(m => m[1]);
  const expected = new Set(Object.values(GROUPS).flat());
  if (ruleIDs.length !== expected.size || new Set(ruleIDs).size !== expected.size || ruleIDs.some(r => !expected.has(r))) fail('unsupported registry rule set');
  const out = safeDirectory(options['--output']), lock = resolve(out, '.collector.lock');
  mkdirSync(lock, {mode: 0o700});
  try {
    const registryRef = `registry:sha256:${digest(registry)}`;
    paths.set(registryRef, `path=${JSON.stringify(realpathSync(options['--registry']))}; sha256=${digest(registry)}`);
    unknown(GROUPS.none, registryRef, 'Registry explicitly declares no independent signature.');
    for (const w of list(manifest.transcripts, 'transcripts')) parseTranscript(w);
    for (const f of list(manifest.gateEvents, 'gateEvents')) parseGate(str(f));
    for (const g of list(manifest.git, 'git')) parseGit(g);
    for (const s of list(manifest.runData, 'runData')) parseRuns(s);
    for (const s of list(manifest.localLogs, 'localLogs')) parseLocal(s);
    for (const s of list(manifest.github, 'github')) {
      if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(s.repo) || !/^[0-9a-f]{40}$/i.test(s.head) || (s.run !== undefined && (!Number.isSafeInteger(s.run) || s.run < 1))) fail('invalid GitHub repository/head/run');
      const snapshot = (endpoint: string) => {
        const raw = command(['gh-axi', 'api', endpoint, '--full', '--jq', '"FM_JSON:" + tojson']);
        // A non-JSON sentinel selects gh-axi's api_response envelope; --full
        // disables truncation. Decode its JSON-quoted scalar without a TOON
        // dependency. A bare tojson is re-encoded as arbitrary TOON structures.
        const body = /^  body: (".*")$/m.exec(raw);
        const value = body ? json(body[1]) : null;
        if (typeof value !== 'string' || !value.startsWith('FM_JSON:') || !/^  truncated: false$/m.test(raw)) fail('GitHub JSON envelope missing or truncated');
        const text = value.slice('FM_JSON:'.length);
        if (!json(text)) fail('GitHub source returned non-JSON; supply a native API snapshot');
        const file = resolve(out, `api-${digest(text)}.json`);
        if (!existsSync(file)) { const fd = openSync(file, 'wx', 0o600); try { writeSync(fd, text); } finally { closeSync(fd); } }
        return file;
      };
      const checks = snapshot(`/repos/${s.repo}/commits/${s.head}/check-runs?per_page=100&filter=all`);
      const run = s.run ? snapshot(`/repos/${s.repo}/actions/runs/${s.run}`) : undefined;
      parseRuns({checks, run});
    }
    const log = resolve(out, 'conformance.log'), notes = resolve(out, 'conformance-notes.md');
    // Validate both destinations before touching either. Do not repair malformed
    // or unterminated history by rewriting it or merging a new row into it.
    for (const f of [log, notes]) if (existsSync(f) && (!lstatSync(f).isFile() || lstatSync(f).isSymbolicLink() || lstatSync(f).nlink !== 1)) fail('unsafe output file');
    const seen = historyKeys(log);
    const stamp = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
    const fresh = rows.filter(r => { const key = r.rule + '\0' + r.ref; if (seen.has(key)) return false; seen.add(key); return true; });
    const noteText = fresh.map(r => `${r.rule} | ${r.ref} | ${r.note}\n`).join('') + (fresh.length ? [...paths].map(([ref, source]) => `${ref} | ${source}\n`).join('') : '');
    // Notes first: interruption cannot leave a row without a resolvable citation.
    if (noteText) appendFile(notes, noteText);
    if (fresh.length) appendFile(log, fresh.map(r => `${r.rule} | ${stamp} | ${r.verdict} | ${r.ref}\n`).join(''));
    console.log(`appended: ${fresh.length}\nduplicate: ${rows.length - fresh.length}`);
  } finally { rmdirSync(lock); }
}
main().catch(error => { console.error(String(error)); console.log('error: collection failed; inspect stderr and select bounded native artifacts'); process.exitCode = 1; });
