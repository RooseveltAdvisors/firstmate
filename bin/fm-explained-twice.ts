// fm-explained-twice.sh owns the entry point. Help below owns the procedure,
// flags, review schema, limits, and count semantics. No external packages.
import { closeSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { conformance } from './fm-weekly-conformance';
import { completeWeeklyCycle, weeklyRun, type Driver, type WeeklyRun } from './fm-weekly-bead';

const HELP = `Live corrections: bounded extraction -> semantic review -> proposals only.
Usage: bin/fm-explained-twice.sh [list|scan|weekly|conformance|show|report] [options]
No arguments lists recent session files by modification time (not filename date).
All subcommands accept --help. Requires Bun and Git; weekly also requires bd.

list [--sessions-dir DIR] [--limit N]
  Defaults: ~/.pi/agent/sessions, 20 files. Metadata only; no session content.
scan --work-dir DIR --session FILE [--offset BYTE] [--bytes N] [--since UTC]
     [--state-dir DIR] [--state-limit N]
  Appends a bounded window to DIR/corpus.json, deduplicating overlapping reads.
  Default: last 1048576 bytes, since seven days ago; maximum 4194304 bytes.
  --offset selects an explicit forward window. Partial edge records are skipped.
  Never page an entire large session: use focused windows and record the gaps.
  Retains user text and assistant context, never tool results or thinking blocks.
  Includes ALL user messages, not a topic/correction keyword classifier.
  Optional state input reads only pending-replies/ and terminal-outcomes/;
  default 200 recent records, maximum 1000, each bounded to 65536 bytes.
  Their summaries are context, never evidence of captain authorship.
  Missing sources fail; skipped/malformed records and coverage are recorded.
weekly --work-dir DIR --sources FILE [--week YYYY-MM-DD] [--bead-limit N]
       [--conformance-dir DIR] [--citations FILE] [--repo DIR]
  Firstmate invokes this on demand each week; no timer, cron, or daemon.
  Defaults to the current UTC Monday through the next Monday (exclusive).
  --week selects any UTC date in the target week. DIR must be new or empty.
  FILE explicitly enumerates stores and focused session windows, for example:
  {"stores":[{"directory":"/home/operator/firstmate",
    "databasePath":"/home/operator/firstmate/.beads/embeddeddolt"},
    {"directory":"/home/operator/git/wiseman",
    "databasePath":"/home/operator/git/wiseman/.beads/embeddeddolt"},
    {"directory":"/home/operator/firstmate/projects/portal",
    "databasePath":"/home/operator/firstmate/projects/portal/.beads/embeddeddolt"}],
   "sessions":[{"file":"/logs/session.jsonl","bytes":1048576,"offset":0}],
   "stateDir":"/home/operator/firstmate/state"}
  stores and sessions arrays are required; stateDir is optional. No CWD default.
  Optional "driver":{"id":"fm-hjr0r","directory":"/home/operator/firstmate",
    "databasePath":"/home/operator/firstmate/.beads/embeddeddolt"} selects ONE
  existing driving bead, independently of the stores being reviewed.
  A driver cycle omits --week and reviews the rolling window from the bead's
  last stamped run time (or seven days earlier, first time) to this run time.
  After all outputs succeed, weekly-run.json records the captured run time and
  output hashes; metadata.weekly_review stamps its absolute path and SHA256 on
  that bead, with due_at exactly seven days after the captured UTC run second
  (Beads persists due dates at whole-second resolution).
  The stamp and date are one update, verified by bd show. No bead is created.
  The next cycle's window starts where this one ends, so cycles neither gap nor
  overlap. Reinvoking before due_at verifies the stamped artifact without
  updating the date or making another run, even with a different work-dir.
  After a failed bead update, retry with the SAME sources and work-dir to reuse
  weekly-run.json and its original run time. Missing/changed artifacts refuse.
  Missing/locked/unreachable beads or stores fail visibly; outputs survive, and
  no successful cycle is reported without readback. Overlapping runs refuse
  through a transient per-bead lock; a lock left by an exited run is taken over.
  There is no polling or schedule installation.
  Without driver the existing weekly intake stays read-only toward all boards.
  Due dates do not hide ready beads; Firstmate checks due_at on bd ready rows.
  This stamps invocation evidence, not completion of the later semantic review.
  Each store is resolved and checked against databasePath using bd where;
  BEADS_* and BD_DATABASE overrides are removed; each read pins both directory
  and database.
  Reads closed_at in the week, not updated_at; limit defaults to 200 per store,
  maximum 1000. Extra rows, timeouts (30 seconds), errors, or output over 4 MiB
  refuse the run. bd show --include-comments in batches of ten supplies records;
  each record (maximum 4 MiB) becomes a private, verifiable snapshot.
  Snapshots are recorded observations, not a guarantee the live board is unchanged.
  Closure, bug type, repeated wording, or a retrospective count prove no recurrence.
  Review bead lessons alongside live corrections using the SAME report procedure.
  Beads are reported/lane evidence, never direct captain authorship or new threads;
  locate the original direct corrections before claiming the existing trigger.
  --conformance-dir adds the conformance leg to this SAME review window, writing
  conformance.md and conformance.json alongside corpus.json. It is opt-in so
  existing store/correction reviews need no conformance inputs to continue.
conformance --work-dir DIR [--conformance-dir DIR] [--since UTC] [--until UTC]
            [--citations FILE] [--repo DIR]
  Standalone leg of the weekly review; no bd or semantic review required.
  Default input: FM_HOME/data/rule-conformance (else CWD/data/rule-conformance).
  Reads registry.md and conformance.log only; never rewrites or collects rows.
  Default window: prior seven days, half-open [since, until), UTC derivation
  times. --until alone selects the seven days ending there; --since overrides
  the start. Outputs conformance.md and conformance.json under private data/.
  Every rule includes all five raw verdict counts and its registry limit.
  No-signature status/reasons stay explicit, even when no rows were observed.
  Every violate/miss cites its exact log line/reference and reachable artifacts.
  Optional conformance-notes.md resolves collector references with path/content
  hashes and transcript byte bounds. Git path digests identify CHECKOUT paths,
  never content; commit IDs bind content. --repo locates legacy "git show SHA"
  references only and is labelled caller-supplied. Reference parts without a
  collector binding (including unreplayable Git state snapshots) are marked
  source=unresolved:REF and counted separately from verdicts.
  --citations supplies explicit locators only for legacy/external rows the
  collector cannot resolve; native artifact/transcript/git/registry references
  never take caller locators. Format:
  [{"reference":"exact source reference from row","file":"/source/evidence",
    "offset":0,"bytes":1024}]. Bounds optional; whole files max 4 MiB.
  Caller locators are attributed as supplied, not inferred semantic evidence.
  Missing/changed/unreadable sources are reported; single-source findings say
  so explicitly. No namespace search, guessed paths, or padded citations.
  Read caps: registry 1 MiB, log 16 MiB, notes 4 MiB, locators 1 MiB/1000 rows.
  Malformed registry/log rows refuse with line findings, never skip silently.
  JSON includes actual generated_at and window.timestamp (latest included row,
  or window start if empty). The latter is coverage, never execution time;
  historical reports preserve their real generation time rather than backdate.
  Nothing gates, applies, schedules, or recommends automatic enforcement.
show --work-dir DIR --id ID [--full]
  Shows one event, its byte source, corr refs and nearby collected messages.
  Preview limit: 1500 characters. --full prints all retained text.
report --work-dir DIR --review FILE
  Verifies selected source bytes again, writes DIR/proposals.md, never the targets.
  DIR must resolve inside private data/, ignored if inside a Git worktree.
  Outputs refuse symlinks and tracked files.
  Existing corpus/report artifacts must be ordinary single-link files.

Procedure (on demand, normally over the past week):
1. List recent sessions, then scan focused windows in relevant sessions.
   Include optional state records to locate corr references and instruction text.
   Use record timestamps, not the session filename, to select the review period.
   Inspect show --full and nearby context before deciding whether text corrects
   an earlier fact/behavior. Find variants semantically; identical words alone
   do not establish correction, authorship, or a changed condition.
2. Write the following review JSON in private task data. Each evidence item
   selects an exact verbatim substring; speaker and kind are REVIEWER judgments.
   User role is transport only. Corr does not identify the captain by itself.
   Do not label forwarded captain words, reported totals, quoted transcripts,
   an agent addressing 'captain', tool output, or a launch brief as direct
   captain corrections. Name the actual speaker and justify the classification.
   Two asks are questions unless the second includes a rebuke/restated rule.
3. Group by the same corrected fact/behavior, then count distinct corr threads.
   Declare thread aliases explicitly: check-in suffixes can be new corr refs
   in the SAME conversation. Give the mapping's evidence in threads[].reason.
   One thread contributes at most one captain correction to the trigger, even
   across sessions. Lane repetition and uncertain attribution stay separate.
   Never turn a retrospective 'three times' claim into three occurrences.
4. Inspect the current owner and neighboring skills. Propose a replacement to
   the existing owner language, explain why the neighbor is wrong, and check
   whether the rule already exists. Set target/edit to null if no good home
   exists. For AGENTS.md/CLAUDE.md proposals name the existing section in section
   and explain in whyOwner why it owns the rule. If none fits, use target/edit
   null and say 'no good home exists'; never invent a section.
   No instruction files are edited. One-time corrections get no edit.
5. Run report, read proposals.md, and hand it to the instruction owner/human.
   Report fewer findings or incomplete coverage plainly. No automatic schedule.

Review schema (version 1):
{"version":1,"reviewer":"name","notes":"coverage/acceptance-set gaps",
 "threads":[{"id":"conversation-id","refs":["corr-ref","corr-ref-checkin2"],
 "reason":"same task and counterparty, verified from the message context"}],
 "groups":[{"id":"stable-id","title":"corrected fact or behavior",
 "target":".agents/skills/OWNER/SKILL.md or AGENTS.md or CLAUDE.md or null",
 "section":"existing section name for AGENTS.md/CLAUDE.md proposals",
 "edit":"exact proposed replacement text, or null when withheld",
 "whyOwner":"current owner inspected; location and reason, or no good home",
 "whyNotNeighbour":"neighbor inspected and why it does not own this rule",
 "evidence":[{"event":"ID from scan","thread":"conversation-id or null",
 "quote":"exact substring",
 "speaker":"captain|lane|unknown",
 "kind":"correction|instruction|question|reported-correction",
 "reason":"authorship evidence AND why this corrects or merely repeats"}]}]}
Only direct captain corrections in two distinct unambiguous corr threads qualify.
All selected occurrences are cited, including repeats excluded from the trigger.

Examples:
  bin/fm-explained-twice.sh list --limit 10
  bin/fm-explained-twice.sh scan --work-dir /tmp/data/review --session /logs/session.jsonl --bytes 1048576
  bin/fm-explained-twice.sh report --work-dir /tmp/data/review --review /tmp/data/review/review.json
`;

type Event = { id: string; file: string; offset: number; length: number; hash: string;
  timestamp: string; role: string; text: string; corr: string[]; origin: 'session' | 'state' | 'bead';
  bead?: { id: string; store: string; databasePath: string } };
type Window = { file: string; size: number; start: number; end: number; since: string;
  records: number; retained: number; malformed: number; partialEdges: number; oversized: boolean };
type Corpus = { version: 1; windows: Window[]; events: Event[]; notes: string[];
  week?: { since: string; until: string } };
type Evidence = { event: string; thread: string | null; quote: string; speaker: string; kind: string; reason: string };
type Group = { id: string; title: string; target: string | null; edit: string | null;
  section?: string; whyOwner: string; whyNotNeighbour: string; evidence: Evidence[] };
const MAX_BYTES = 4194304;
const hash = (x: string | Buffer) => createHash('sha256').update(x).digest('hex');
const q = (x: unknown) => JSON.stringify(x);
function requireThat(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}
function textField(x: unknown, label: string): asserts x is string {
  requireThat(typeof x === 'string' && x.trim().length > 0, `${label} must be nonempty text`);
}
function integer(x: string | undefined, fallback: number, max: number, allowZero = false) {
  if (x === undefined) return fallback;
  requireThat(/^\d+$/.test(x), `invalid integer: ${x}`);
  const n = Number(x);
  requireThat(Number.isSafeInteger(n) && n >= (allowZero ? 0 : 1) && n <= max, `integer out of range: ${x}`);
  return n;
}
function readRange(file: string, start: number, length: number): Buffer {
  requireThat(length >= 0 && length <= MAX_BYTES, 'read exceeds bounded window');
  const fd = openSync(file, 'r');
  try {
    const bytes = Buffer.alloc(length);
    let read = 0;
    while (read < length) {
      const n = readSync(fd, bytes, read, length - read, start + read);
      if (!n) break;
      read += n;
    }
    return bytes.subarray(0, read);
  } finally { closeSync(fd); }
}
function fields(raw: Buffer, origin: Event['origin']) {
  if (origin === 'bead') {
    const { store, databasePath, issue } = JSON.parse(raw.toString('utf8'));
    requireThat(typeof issue.id === 'string' && /^[a-zA-Z0-9_:\-]+(?:\.[a-zA-Z0-9_:\-]+)*$/.test(issue.id), 'invalid bead id');
    textField(store, 'bead store'); textField(databasePath, 'bead database');
    requireThat(issue.status === 'closed' && Number.isFinite(Date.parse(issue.closed_at)), 'bead must have closed_at');
    return { text: JSON.stringify(issue, null, 2), role: 'record', corr: [], timestamp: issue.closed_at,
      bead: { id: issue.id, store, databasePath } };
  }
  if (origin === 'state') {
    const body = raw.toString('utf8');
    const get = (key: string) => body.match(new RegExp(`^${key}=(.*)$`, 'm'))?.[1] || '';
    const epoch = Number(get('created_epoch'));
    return { text: body, role: 'record', corr: get('corr_id') ? [get('corr_id')] : [],
      timestamp: Number.isFinite(epoch) && epoch > 0 ? new Date(epoch * 1000).toISOString() : '' };
  }
  const entry = JSON.parse(raw.toString('utf8'));
  const message = entry.type === 'message' ? entry.message : null;
  if (!message || !['user', 'assistant'].includes(message.role)) return null;
  const content = message.content;
  const text = typeof content === 'string' ? content : Array.isArray(content)
    ? content.filter((c: any) => c.type === 'text' && typeof c.text === 'string').map((c: any) => c.text).join('\n') : '';
  if (!text) return null;
  // Only header corr refs: quoted/embedded examples in the body are not a thread.
  const routing = text.slice(0, 2000).match(/^Reply to me at:\n(?:herdr[^\n]*\n|(?:session|pane_id|workspace_id|tab_id|tab label|agent|title):[^\n]*\n|\n){1,20}(corr=[^\n]*)/);
  const header = routing?.[1] || text.split('\n', 1)[0];
  const corr = [...header.matchAll(/\bcorr=([a-zA-Z0-9_:\-]+)/g)].map(m => m[1]);
  return { text, role: message.role, corr: [...new Set(corr)], timestamp: entry.timestamp || '' };
}
function event(file: string, offset: number, raw: Buffer, origin: Event['origin']): Event | null {
  const data = fields(raw, origin);
  return data ? { ...data, file, offset, length: raw.length, hash: hash(raw),
    id: hash(`${file}:${offset}:${hash(raw)}`).slice(0, 20), origin } : null;
}
function safeDir(path: string) {
  const p = resolve(path);
  requireThat(p.split('/').includes('data') && !p.split('/').includes('.agents') && !p.split('/').includes('skills'),
    '--work-dir must be private data/ material, outside instruction directories');
  // Resolve existing ancestors before creating anything, to reject escaped symlinks.
  let ancestor = p;
  while (!existsSync(ancestor)) ancestor = dirname(ancestor);
  const resolved = resolve(realpathSync(ancestor), p.slice(ancestor.length).replace(/^\//, ''));
  requireThat(resolved.split('/').includes('data') && !resolved.split('/').includes('.agents') && !resolved.split('/').includes('skills'),
    '--work-dir resolves outside private data/ material');
  mkdirSync(p, { recursive: true, mode: 0o700 });
  const actual = realpathSync(p);
  const git = spawnSync('git', ['-C', actual, 'rev-parse', '--show-toplevel'], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C' } });
  requireThat(!git.error && (git.status === 0 || git.stderr.includes('not a git repository')),
    `cannot verify private output location: ${git.error?.message || git.stderr}`);
  if (git.status === 0) {
    const ignored = spawnSync('git', ['-C', actual, 'check-ignore', '--quiet', actual + '/']);
    const tracked = spawnSync('git', ['-C', actual, 'ls-files', '--', actual], { encoding: 'utf8' });
    requireThat(ignored.status === 0 && tracked.status === 0 && !tracked.stdout.trim(), '--work-dir must be ignored private data/, with no tracked files');
  }
  return actual;
}
function save(file: string, value: string) {
  try {
    const s = lstatSync(file);
    requireThat(s.isFile() && !s.isSymbolicLink() && s.nlink === 1, `output is not an ordinary single-link file: ${file}`);
  } catch (e: any) { if (e.code !== 'ENOENT') throw e; }
  writeFileSync(file, value, { mode: 0o600 });
}
function loadCorpus(file: string): Corpus {
  const c = JSON.parse(readFileSync(file, 'utf8'));
  requireThat(c.version === 1 && Array.isArray(c.events) && Array.isArray(c.windows) && Array.isArray(c.notes), 'invalid corpus schema');
  return c;
}
function verify(e: Event) {
  const raw = readRange(e.file, e.offset, e.length);
  requireThat(hash(raw) === e.hash, `source changed or disappeared: ${e.file} byte ${e.offset}; rescan this window`);
  const reread = event(e.file, e.offset, raw, e.origin);
  requireThat(reread && JSON.stringify(reread) === JSON.stringify(e), `corpus does not match source: ${e.id}; rescan`);
}
function list(dir: string, limit: number) {
  const found: { file: string; size: number; modified: number }[] = [];
  let visited = 0;
  function walk(path: string) {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      requireThat(++visited <= 50000, 'session discovery limit exceeded; narrow --sessions-dir');
      const file = join(path, entry.name);
      if (entry.isDirectory()) walk(file);
      else if (entry.isFile() && file.endsWith('.jsonl')) {
        const s = statSync(file);
        found.push({ file, size: s.size, modified: s.mtimeMs });
      }
    }
  }
  walk(realpathSync(dir));
  found.sort((a, b) => b.modified - a.modified || a.file.localeCompare(b.file));
  console.log(`sessions: ${Math.min(limit, found.length)} of ${found.length}\nsessions[${Math.min(limit, found.length)}]{file,bytes,modified}:`);
  for (const f of found.slice(0, limit)) console.log(`  ${q(f.file)},${f.size},${q(new Date(f.modified).toISOString())}`);
  if (found.length) console.log(`next: ${q(`bin/fm-explained-twice.sh scan --work-dir /tmp/data/corrections --session '${found[0].file.replaceAll("'", "'\\''")}'`)}`);
}
function scanSession(c: Corpus, file: string, offset: number | undefined, bytes: number, since: string) {
  const size = statSync(file).size;
  const start = offset ?? Math.max(0, size - bytes);
  requireThat(start <= size, '--offset is beyond EOF');
  const raw = readRange(file, start, Math.min(bytes, size - start));
  const w: Window = { file, size, start, end: start + raw.length, since, records: 0, retained: 0, malformed: 0, partialEdges: 0, oversized: false };
  let at = 0;
  if (start > 0 && readRange(file, start - 1, 1)[0] !== 10) {
    const edge = raw.indexOf(10);
    at = edge < 0 ? raw.length : edge + 1;
    w.partialEdges++;
  }
  while (at < raw.length) {
    const end = raw.indexOf(10, at);
    if (end < 0) { w.partialEdges++; break; }
    const line = raw.subarray(at, end);
    if (line.length) {
      w.records++;
      try {
        const e = event(file, start + at, line, 'session');
        if (e && Number.isFinite(Date.parse(e.timestamp)) && Date.parse(e.timestamp) >= Date.parse(since)) { c.events.push(e); w.retained++; }
      } catch (error) {
        w.malformed++;
        console.error(`skipped malformed JSONL: ${file} byte ${start + at}: ${String(error).slice(0, 180)}`);
      }
    }
    at = end + 1;
  }
  c.windows.push(w);
}
function scanState(c: Corpus, root: string, limit: number, since: string) {
  for (const name of ['pending-replies', 'terminal-outcomes']) {
    const dir = join(root, name);
    const files = readdirSync(dir, { withFileTypes: true }).filter(e => e.isFile()).map(e => {
      const file = join(dir, e.name);
      return { file, stat: statSync(file) };
    }).sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs || a.file.localeCompare(b.file));
    c.notes.push(`${dir}: sampled ${Math.min(files.length, limit)} of ${files.length} records by mtime; record created_epoch controls --since.`);
    for (const f of files.slice(0, limit)) {
      const oversized = f.stat.size > 65536;
      const w: Window = { file: f.file, size: f.stat.size, start: 0, end: oversized ? 0 : f.stat.size,
        since, records: oversized ? 0 : 1, retained: 0, malformed: 0, partialEdges: 0, oversized };
      if (!oversized) {
        const e = event(f.file, 0, readRange(f.file, 0, f.stat.size), 'state');
        if (e && e.timestamp && e.timestamp >= since) { c.events.push(e); w.retained++; }
      }
      c.windows.push(w);
    }
  }
}
function weekWindow(date?: string) {
  requireThat(date === undefined || /^\d{4}-\d{2}-\d{2}$/.test(date), '--week must be YYYY-MM-DD');
  const start = new Date(date ? date + 'T00:00:00Z' : Date.now());
  requireThat(Number.isFinite(start.getTime()) && (!date || start.toISOString().startsWith(date)), 'invalid week date');
  start.setUTCHours(0, 0, 0, 0);
  start.setUTCDate(start.getUTCDate() - (start.getUTCDay() + 6) % 7);
  return {since: start.toISOString(), until: new Date(start.getTime() + 7 * 86400000).toISOString()};
}
function weekly(dir: string, sourcesFile: string, window: {since: string; until: string}, limit: number): Corpus {
  requireThat(readdirSync(dir).length === 0, 'weekly needs a new or empty --work-dir; keep prior reviews separate');
  const {since, until} = window;
  requireThat(statSync(sourcesFile).size <= 65536, 'sources manifest exceeds 65536 bytes');
  const sources = JSON.parse(readFileSync(sourcesFile, 'utf8'));
  requireThat(Array.isArray(sources.stores) && sources.stores.length > 0 && sources.stores.length <= 100,
    'sources must explicitly enumerate 1-100 stores');
  requireThat(Array.isArray(sources.sessions) && sources.sessions.length <= 100, 'sources must explicitly enumerate up to 100 session windows');
  const c: Corpus = { version: 1, windows: [], events: [], notes: [], week: { since, until } };
  c.notes.push(`Weekly review window: [${since}, ${until}). Invoked on demand; no schedule installed.`);
  // A subprocess can otherwise inherit a different lane's board from BEADS_DIR.
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('BEADS_') && key !== 'BD_DATABASE'));
  function bd(directory: string, databasePath: string, args: string[]) {
    const result = spawnSync('bd', ['--readonly', '--sandbox', '-C', directory, '--db', databasePath, ...args, '--json'],
      { cwd: directory, env, encoding: 'utf8', maxBuffer: MAX_BYTES, timeout: 30000 });
    requireThat(!result.error && result.status === 0,
      `beads read refused for ${directory}: ${result.stderr || result.error?.message || `exit ${result.status}`}`);
    if (result.stderr.trim()) { console.error(result.stderr.trim()); c.notes.push(`${directory}: ${result.stderr.trim()}`); }
    return JSON.parse(result.stdout);
  }
  const stores = new Set<string>();
  for (const source of sources.stores) {
    textField(source.directory, 'store directory'); textField(source.databasePath, 'store databasePath');
    const directory = realpathSync(source.directory), databasePath = realpathSync(source.databasePath);
    requireThat(!stores.has(databasePath), `duplicate store: ${databasePath}`);
    stores.add(databasePath);
    const identity = bd(directory, databasePath, ['where']);
    requireThat(typeof identity.database_path === 'string' && realpathSync(identity.database_path) === databasePath &&
      typeof identity.path === 'string' && realpathSync(identity.path) === realpathSync(join(directory, '.beads')),
      `store identity mismatch for ${directory}: ${q(identity)}`);
    const listed = bd(directory, databasePath, ['list', '--status', 'closed', '--closed-after', since,
      '--closed-before', until, '--sort', 'closed', '--limit', String(limit + 1)]);
    requireThat(Array.isArray(listed) && listed.length <= limit, `store exceeds bead limit ${limit} or returned invalid rows: ${directory}; narrow review manually`);
    const listedIds = new Set<string>();
    for (const issue of listed) {
      requireThat(typeof issue.id === 'string' && /^[a-zA-Z0-9_:\-]+(?:\.[a-zA-Z0-9_:\-]+)*$/.test(issue.id), 'invalid bead id');
      requireThat(!listedIds.has(issue.id), `duplicate bead in store ${directory}: ${issue.id}`);
      listedIds.add(issue.id);
    }
    const issues: any[] = [];
    for (let at = 0; at < listed.length; at += 10) {
      const batch = listed.slice(at, at + 10);
      const details = bd(directory, databasePath,
        ['show', '--include-comments', '--brief-deps', ...batch.map(issue => `--id=${issue.id}`)]);
      requireThat(Array.isArray(details) && details.length === batch.length, `incomplete bead details: ${directory}`);
      issues.push(...details);
    }
    c.notes.push(`Store ${directory}; database ${databasePath}; bd where verified; ${issues.length} closed records including comments returned for [${since}, ${until}); limit ${limit}.`);
    const seen = new Set<string>();
    for (const issue of issues) {
      requireThat(typeof issue.id === 'string' && /^[a-zA-Z0-9_:\-]+(?:\.[a-zA-Z0-9_:\-]+)*$/.test(issue.id), 'invalid bead id');
      requireThat(listedIds.has(issue.id) && !seen.has(issue.id), `unexpected/duplicate bead details in store ${directory}: ${issue.id}`);
      seen.add(issue.id);
      requireThat(!issue.comments_omitted, `comments omitted for ${directory}: ${issue.id}`);
      requireThat(issue.status === 'closed' && Number.isFinite(Date.parse(issue.closed_at)), `invalid closed bead: ${issue.id}`);
      const closed = Date.parse(issue.closed_at);
      // Enforce half-open boundaries even when a bd version includes an endpoint.
      if (closed < Date.parse(since) || closed >= Date.parse(until)) {
        c.notes.push(`Excluded ${directory} bead ${issue.id}: closed_at ${issue.closed_at} outside week.`);
        continue;
      }
      const raw = Buffer.from(JSON.stringify({ store: directory, databasePath, issue }));
      requireThat(raw.length <= MAX_BYTES, `bead exceeds ${MAX_BYTES} bytes: ${directory} ${issue.id}`);
      // External Beads child IDs can contain dots. Never use them as paths:
      // only the validated digest key participates in a filesystem operation.
      const key = hash(`${databasePath}:${issue.id}`);
      requireThat(/^[a-zA-Z0-9_:\-]+$/.test(key), 'invalid snapshot key');
      const file = join(dir, `bead-${key}.json`);
      save(file, raw.toString('utf8'));
      c.events.push(event(file, 0, raw, 'bead')!);
      c.windows.push({ file, size: raw.length, start: 0, end: raw.length, since,
        records: 1, retained: 1, malformed: 0, partialEdges: 0, oversized: false });
    }
  }
  for (const source of sources.sessions) {
    textField(source.file, 'session file');
    requireThat(source.offset === undefined || (Number.isSafeInteger(source.offset) && source.offset >= 0), 'invalid session offset');
    requireThat(source.bytes === undefined || (Number.isSafeInteger(source.bytes) && source.bytes > 0 && source.bytes <= MAX_BYTES), 'invalid session bytes');
    scanSession(c, realpathSync(source.file), source.offset, source.bytes ?? 1048576, since);
  }
  if (sources.stateDir !== undefined) { textField(sources.stateDir, 'stateDir'); scanState(c, realpathSync(sources.stateDir), 200, since); }
  c.events = [...new Map(c.events.filter(e => Date.parse(e.timestamp) < Date.parse(until)).map(e => [e.id, e])).values()];
  c.notes.push('Weekly events are restricted to the half-open review window; session window retained counts precede the upper-bound filter. Bead snapshots are reported evidence only; closed once is not recurrence.');
  return c;
}
function report(c: Corpus, reviewFile: string) {
  const review = JSON.parse(readFileSync(reviewFile, 'utf8'));
  requireThat(review.version === 1 && Array.isArray(review.groups) && Array.isArray(review.threads), 'invalid review schema');
  textField(review.reviewer, 'reviewer');
  const aliases = new Map<string, string>();
  const conversations = new Map<string, string>();
  for (const t of review.threads) {
    requireThat(typeof t.id === 'string' && /^[a-zA-Z0-9_:\-]+$/.test(t.id) && !conversations.has(t.id), 'invalid/duplicate thread id');
    textField(t.reason, 'thread mapping reason');
    requireThat(Array.isArray(t.refs) && t.refs.length > 0, 'thread needs corr refs');
    conversations.set(t.id, t.reason);
    for (const ref of t.refs) {
      requireThat(typeof ref === 'string' && /^[a-zA-Z0-9_:\-]+$/.test(ref) && !aliases.has(ref), 'invalid or ambiguous corr alias');
      aliases.set(ref, t.id);
    }
  }
  const ids = new Set<string>();
  const rendered: { qualified: boolean; body: string }[] = [];
  for (const g of review.groups as Group[]) {
    requireThat(typeof g.id === 'string' && /^[a-zA-Z0-9_:\-]+$/.test(g.id) && !ids.has(g.id), 'invalid or duplicate group id');
    ids.add(g.id);
    for (const key of ['title', 'whyOwner', 'whyNotNeighbour'] as const) textField(g[key], key);
    requireThat(Array.isArray(g.evidence) && g.evidence.length > 0, 'group needs evidence');
    requireThat(g.target === null || g.target === 'AGENTS.md' || g.target === 'CLAUDE.md' || (typeof g.target === 'string' && /^\.agents\/skills\/[a-zA-Z0-9_:\-]+\/SKILL\.md$/.test(g.target)), 'target must be AGENTS.md, CLAUDE.md, a skill file, or null');
    requireThat(g.edit === null || (g.target !== null && typeof g.edit === 'string' && g.edit.trim()), 'edit needs a target and nonempty text, or null');
    const threads = new Set<string>();
    const laneThreads = new Set<string>();
    const seen = new Set<string>();
    let corrections = 0, lane = 0;
    const citations: string[] = [];
    for (const item of g.evidence) {
      requireThat(['captain', 'lane', 'unknown'].includes(item.speaker), 'invalid speaker');
      requireThat(['correction', 'instruction', 'question', 'reported-correction'].includes(item.kind), 'invalid evidence kind');
      textField(item.quote, 'quote'); textField(item.reason, 'reason');
      requireThat(typeof item.event === 'string', 'evidence event must be a string');
      requireThat(item.thread === null || (typeof item.thread === 'string' && conversations.has(item.thread)),
        `thread must be null or a declared thread id: ${item.event}`);
      const e = c.events.find(e => e.id === item.event);
      requireThat(e, `unknown event: ${item.event}`);
      verify(e);
      if (c.week) requireThat(Date.parse(e.timestamp) >= Date.parse(c.week.since) && Date.parse(e.timestamp) < Date.parse(c.week.until), 'evidence outside weekly window');
      requireThat(e.text.includes(item.quote), `quote is not verbatim: ${item.event}`);
      if (item.thread !== null) requireThat(e.corr.length === 1 && aliases.get(e.corr[0]) === item.thread,
        `thread must match the declared corr alias: ${item.event}`);
      const identity = hash(`${e.timestamp}:${e.role}:${e.text}`);
      requireThat(!seen.has(identity), `duplicate/replayed event in group ${g.id}`);
      seen.add(identity);
      if (item.speaker === 'captain' && item.kind === 'correction') {
        requireThat(e.origin === 'session' && e.role === 'user', 'only direct session user text can be captain correction evidence');
        corrections++;
        if (item.thread !== null) threads.add(item.thread);
      }
      if (item.speaker === 'lane') { lane++; if (item.thread !== null) laneThreads.add(item.thread); }
      const bead = e.bead ? ` bead=${e.bead.id}; store=${e.bead.store}; database=${e.bead.databasePath};` : '';
      const prefix = `- ${item.speaker} / ${item.kind}; ${e.timestamp || 'timestamp unknown'};${bead} corr=${e.corr.join(',') || 'unavailable (excluded from trigger)'}; thread=${item.thread || 'unmapped (excluded from trigger)'}; ${e.file} bytes ${e.offset}-${e.offset + e.length - 1}; event ${e.id}.`;
      citations.push(`${prefix}\n${item.quote.split('\n').map(line => `  > ${line}`).join('\n')}\n  Classification: ${item.reason}`);
    }
    const qualified = threads.size >= 2;
    if (qualified && g.target) textField(g.edit, 'qualifying group proposed edit');
    if (qualified && (g.target === 'AGENTS.md' || g.target === 'CLAUDE.md')) textField(g.section, 'existing instruction section');
    let body = `## ${g.title}\n\nCaptain corrections: ${corrections} sourced messages in ${threads.size} eligible distinct corr threads; trigger ${qualified ? 'MET' : 'NOT MET'}.\nLane repetition: ${lane} sourced messages in ${laneThreads.size} distinct corr threads, excluded from the captain count.\n\n${citations.join('\n\n')}\n\nOwner assessment: ${g.target || 'no good home exists'}.\n${g.whyOwner}\nNeighbor assessment: ${g.whyNotNeighbour}\n`;
    if (qualified) body += g.target ? `\n${g.section ? `Existing section: ${g.section}.\n` : ''}Proposed replacement text (proposal only):\n\n${g.edit!.split('\n').map(line => `> ${line}`).join('\n')}\n` : '\nNo edit proposed: no good home exists; human ownership decision needed.\n';
    else body += '\nNo edit proposed: fewer than two independently sourced captain-correction threads.\n';
    rendered.push({ qualified, body });
  }
  const count = rendered.filter(r => r.qualified).length;
  const coverage = c.windows.map(w => {
    const bead = c.events.find(e => e.file === w.file && e.origin === 'bead')?.bead;
    return `- ${bead ? `bead=${bead.id}; store=${bead.store}; ` : ''}${w.file}: bytes [${w.start}, ${w.end}) of ${w.size}; since ${w.since}; ${w.records} complete records, ${w.retained} retained, ${w.malformed} malformed, ${w.partialEdges} partial edges, oversized=${w.oversized}.`;
  });
  const mappings = [...conversations].map(([id, reason]) => `- ${id}: ${[...aliases].filter(([, t]) => t === id).map(([ref]) => `corr=${ref}`).join(', ')}.\n  ${reason}`);
  return `# Explained twice: proposals\n\nGenerated ${new Date().toISOString()}.\nReviewer: ${review.reviewer}.\n${count} qualifying repeated-correction groups; ${rendered.length - count} groups below threshold.\nCounts are limited to cited evidence, not estimates of an entire session or shift.\nOnly distinct corr threads with direct captain corrections contribute to the trigger.\nSemantic classification is a reviewer judgment, not an automatic authorship inference.\nNo instruction files were edited.\n\n${review.notes || 'No additional review notes.'}\n\n${rendered.sort((a, b) => Number(b.qualified) - Number(a.qualified)).map(r => r.body).join('\n')}\n## Thread identity review\n\n${mappings.join('\n')}\n\n## Coverage and gaps\n\nThese are bounded windows, not a complete session audit.\nRepeated or overlapping windows do not increase occurrence counts.\n${coverage.join('\n')}\n${c.notes.map(n => `- ${n}`).join('\n')}\n`;
}

try {
  const args = process.argv.slice(2);
  if (args.includes('--help') || args.includes('-h')) { console.log(HELP); process.exit(0); }
  const command = args[0] && !args[0].startsWith('--') ? args.shift()! : 'list';
  const allowed: Record<string, string[]> = { list: ['sessions-dir', 'limit'], scan: ['work-dir', 'session', 'offset', 'bytes', 'since', 'state-dir', 'state-limit'], weekly: ['work-dir', 'sources', 'week', 'bead-limit', 'conformance-dir', 'citations', 'repo'], conformance: ['work-dir', 'conformance-dir', 'since', 'until', 'citations', 'repo'], show: ['work-dir', 'id', 'full'], report: ['work-dir', 'review'] };
  requireThat(allowed[command], `unknown command: ${command}; use list, scan, weekly, conformance, show or report`);
  const options: Record<string, string> = {};
  while (args.length) {
    const key = args.shift()!.replace(/^--/, '');
    requireThat(allowed[command].includes(key) && !(key in options), `unknown/duplicate option: ${key}`);
    if (key === 'full') options[key] = '1';
    else { requireThat(args.length && !args[0].startsWith('--'), `--${key} requires a value`); options[key] = args.shift()!; }
  }
  if (command === 'list') { list(options['sessions-dir'] || join(homedir(), '.pi/agent/sessions'), integer(options.limit, 20, 1000)); }
  else {
    textField(options['work-dir'], '--work-dir');
    const dir = safeDir(options['work-dir']);
    const corpusFile = join(dir, 'corpus.json');
    function saveConformance(week?: {since: string; until: string}) {
      const output = conformance(options, week);
      save(join(dir, 'conformance.json'), JSON.stringify(output.result, null, 2) + '\n');
      save(join(dir, 'conformance.md'), output.markdown);
      console.log(`conformance: ${q(join(dir, 'conformance.md'))}\nconformance_rows: ${output.result.rows}\nconformance_window: ${q(output.result.window)}\ninstruction_edits: 0`);
    }
    if (command === 'weekly') {
      textField(options.sources, '--sources');
      requireThat(statSync(options.sources).size <= 65536, 'sources manifest exceeds 65536 bytes');
      const sourcesBytes = readFileSync(options.sources), sources = JSON.parse(sourcesBytes.toString('utf8'));
      const ranAt = new Date(Math.floor(Date.now() / 1000) * 1000).toISOString();
      const runFile = join(dir, 'weekly-run.json');
      requireThat(sources.driver === undefined || options.week === undefined, 'a driver cycle reviews since its last stamped run; omit --week');
      function invoke(window: {since: string; until: string}, driver?: Driver) {
        if (driver && existsSync(runFile)) {
          const saved = weeklyRun(runFile, driver);
          requireThat(saved.run.sources_sha256 === hash(sourcesBytes), 'retry requires the same sources manifest');
          return runFile;
        }
        const c = weekly(dir, options.sources, window, integer(options['bead-limit'], 200, 1000));
        save(corpusFile, JSON.stringify(c, null, 2) + '\n');
        if (options['conformance-dir']) saveConformance(c.week);
        if (driver) {
          const paths = [corpusFile, ...(options['conformance-dir'] ? [join(dir, 'conformance.json'), join(dir, 'conformance.md')] : [])];
          const run: WeeklyRun = {version: 2, kind: 'weekly-instruction-review', window, ran_at: ranAt,
            sources_sha256: hash(sourcesBytes), driver, artifacts: paths.map(path => ({path, sha256: hash(readFileSync(path))}))};
          save(runFile, JSON.stringify(run, null, 2) + '\n');
        }
        console.log(`corpus: ${q(corpusFile)}\nweek: ${q(c.week)}\nclosed_beads: ${c.events.filter(e => e.origin === 'bead').length}\nuser_messages: ${c.events.filter(e => e.role === 'user').length}\ninstruction_edits: 0\nnext: ${q('Review show --full, write review.json, then run report with this --work-dir; no classification is automatic.')}`);
        return runFile;
      }
      if (sources.driver !== undefined) {
        const cycle = completeWeeklyCycle(sources.driver, ranAt, (driver, window) => invoke(window, driver));
        console.log(`weekly_cycle: ${q(cycle)}`);
      } else invoke(weekWindow(options.week));
    } else if (command === 'conformance') {
      saveConformance();
    } else if (command === 'scan') {
      textField(options.session, '--session');
      const since = new Date(options.since || Date.now() - 7 * 86400000).toISOString();
      const c: Corpus = existsSync(corpusFile) ? loadCorpus(corpusFile) : { version: 1, windows: [], events: [], notes: [] };
      requireThat(!c.week, 'weekly corpus is fixed; use a new work-dir to change its sources');
      scanSession(c, realpathSync(options.session), options.offset === undefined ? undefined : integer(options.offset, 0, Number.MAX_SAFE_INTEGER, true), integer(options.bytes, 1048576, MAX_BYTES), since);
      if (options['state-dir']) scanState(c, realpathSync(options['state-dir']), integer(options['state-limit'], 200, 1000), since);
      c.events = [...new Map(c.events.map(e => [e.id, e])).values()];
      save(corpusFile, JSON.stringify(c, null, 2) + '\n');
      const users = c.events.filter(e => e.role === 'user');
      console.log(`corpus: ${q(corpusFile)}\nwindows: ${c.windows.length}\nuser_messages: ${users.length}\nevents[${Math.min(20, users.length)}]{id,corr,preview}:`);
      for (const e of users.slice(-20)) console.log(`  ${e.id},${q(e.corr.join(','))},${q(e.text.slice(0, 140))}`);
      console.log(`next: ${q(`bin/fm-explained-twice.sh show --work-dir '${dir.replaceAll("'", "'\\''")}' --id ${users.at(-1)?.id || 'ID'}`)}`);
    } else {
      const c = loadCorpus(corpusFile);
      if (command === 'show') {
        textField(options.id, '--id');
        requireThat(/^[a-zA-Z0-9_:\-]+$/.test(options.id), 'invalid event id');
        const selected = c.events.find(e => e.id === options.id);
        requireThat(selected, `event not found: ${options.id}; scan the desired window first`);
        const neighbors = c.events.filter(e => e.file === selected.file).sort((a, b) => a.offset - b.offset);
        const index = neighbors.findIndex(e => e.id === options.id);
        for (const e of neighbors.slice(Math.max(0, index - 1), index + 2)) {
          console.log(`event: ${e.id}\nsource: ${q(`${e.file} bytes ${e.offset}-${e.offset + e.length - 1}`)}\nrole: ${e.role}\ncorr: ${q(e.corr)}\ntext: ${q(options.full ? e.text : e.text.slice(0, 1500))}\ncharacters: ${e.text.length}`);
        }
      } else {
        textField(options.review, '--review');
        const markdown = report(c, options.review);
        const output = join(dir, 'proposals.md');
        save(output, markdown);
        console.log(`report: ${q(output)}\ninstruction_edits: 0`);
      }
    }
  }
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`fm-explained-twice: ${message}`);
  console.log(`error: ${q(message)}\nnext: ${q('bin/fm-explained-twice.sh --help')}`);
  process.exitCode = 1;
}
