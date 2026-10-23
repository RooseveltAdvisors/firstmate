import { afterEach, beforeEach, expect, test } from 'bun:test';
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve, basename } from 'node:path';

const script = resolve(import.meta.dir, '../bin/fm-explained-twice.sh');
const digest = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex');
let root: string, store: string, db: string, sources: string, output: string, bin: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'weekly-bead-'));
  store = join(root, 'store'); db = join(store, '.beads', 'embeddeddolt');
  sources = join(root, 'sources.json'); output = join(root, 'data', 'run'); bin = join(root, 'bin');
  mkdirSync(db, {recursive: true}); mkdirSync(bin);
  writeFileSync(join(store, 'issue.json'), JSON.stringify({id: 'fm-driver', status: 'open', due_at: '2026-10-01T00:00:00Z', metadata: {unrelated: 'preserved'}}));
  writeFileSync(sources, JSON.stringify({stores: [{directory: store, databasePath: db}], sessions: [],
    driver: {id: 'fm-driver', directory: store, databasePath: db}}));
  const bd = join(bin, 'bd');
  writeFileSync(bd, `#!/usr/bin/env bun
import {appendFileSync, existsSync, readFileSync, writeFileSync} from 'node:fs';
const args = process.argv.slice(2), store = args[args.indexOf('-C') + 1];
appendFileSync(store + '/calls.jsonl', JSON.stringify(args) + '\\n');
if (Object.keys(process.env).some(k => k.startsWith('BEADS_') || k === 'BD_DATABASE')) throw Error('inherited store override');
if (process.cwd() !== store || args[args.indexOf('--db') + 1] !== store + '/.beads/embeddeddolt') throw Error('store not pinned');
if (!args.includes('--sandbox') || !args.includes('--json')) throw Error('unbounded command');
const command = args.find(x => ['where', 'list', 'show', 'update'].includes(x));
if (command !== 'update' && !args.includes('--readonly')) throw Error('read not readonly');
if (process.env.HANG_BD === command) await Bun.sleep(3000);
if (process.env.FAIL_BD === command) { console.error('Dolt lock held: fixture store unreachable'); process.exit(2); }
if (command === 'where') console.log(JSON.stringify({path: store + '/.beads', database_path: process.env.WRONG_DB || store + '/.beads/embeddeddolt'}));
else if (command === 'list') {
  // Real bd 1.3.2: --closed-after and --closed-before are both strict.
  const after = Date.parse(args[args.indexOf('--closed-after') + 1]), before = Date.parse(args[args.indexOf('--closed-before') + 1]);
  const closed = existsSync(store + '/closed.json') ? JSON.parse(readFileSync(store + '/closed.json', 'utf8')) : [];
  console.log(JSON.stringify(closed.filter((i: any) => Date.parse(i.closed_at) > after && Date.parse(i.closed_at) < before)));
} else if (command === 'show') {
  const closed = existsSync(store + '/closed.json') ? JSON.parse(readFileSync(store + '/closed.json', 'utf8')) : [];
  const ids = args.filter(a => a.startsWith('--id=')).map(a => a.slice(5)), hits = closed.filter((i: any) => ids.includes(i.id));
  console.log(hits.length ? JSON.stringify(hits) : process.env.MISSING_BEAD ? '[]' : '[' + readFileSync(store + '/issue.json', 'utf8') + ']');
}
else if (command === 'update') {
  if (args.at(-1) !== 'fm-driver' || args.at(-2) !== '--') throw Error('wrong driving bead');
  const issue = JSON.parse(readFileSync(store + '/issue.json', 'utf8'));
  issue.metadata = JSON.parse(args[args.indexOf('--metadata') + 1]);
  issue.due_at = args[args.indexOf('--due') + 1].replace(/\\.\\d{3}Z$/, 'Z');
  // JSON object key order is not a Beads API guarantee.
  issue.metadata.weekly_review = Object.fromEntries(Object.entries(issue.metadata.weekly_review).sort());
  writeFileSync(store + '/issue.json', JSON.stringify(issue));
  console.log(JSON.stringify(issue));
} else throw Error('unexpected command');
`);
  chmodSync(bd, 0o755);
});
afterEach(() => { rmSync(root, {recursive: true, force: true}); });
function run(extra: Record<string, string> = {}, dir = output, prefix: string[] = []) {
  return Bun.spawnSync([...prefix, 'bash', script, 'weekly', '--work-dir', dir, '--sources', sources], {
    stdout: 'pipe', stderr: 'pipe', timeout: 20000,
    env: {...process.env, PATH: bin + ':' + process.env.PATH, BEADS_DIR: '/wrong-store', BD_DATABASE: 'wrong-database', ...extra},
  });
}
const issue = () => JSON.parse(readFileSync(join(store, 'issue.json'), 'utf8'));
const calls = (): string[][] => readFileSync(join(store, 'calls.jsonl'), 'utf8').trim().split('\n').map(s => JSON.parse(s));
const text = (r: ReturnType<typeof run>) => r.stdout.toString() + r.stderr.toString();
function success(r: ReturnType<typeof run>) { expect(text(r)).not.toContain('error:'); expect(r.exitCode).toBe(0); }
const DAY = 86400000, at = (ms: number) => new Date(ms).toISOString();
const lockFile = () => join(tmpdir(), `fm-weekly-${digest(JSON.stringify({id: 'fm-driver', directory: store, databasePath: db}))}.lock`);
// Rewrites a finished run as if it had run at ranAt, keeping its artifacts valid.
function backdate(file: string, ranAt: string, window = {since: at(Date.parse(ranAt) - 7 * DAY), until: ranAt}) {
  const artifact = {...JSON.parse(readFileSync(file, 'utf8')), ran_at: ranAt, window};
  writeFileSync(file, JSON.stringify(artifact));
  return artifact;
}
function stampBead(file: string, ranAt: string, due: string, serialize = false, beadDue = due) {
  const bead = issue(), stamp = {artifact_path: file, artifact_sha256: digest(readFileSync(file)), ran_at: ranAt, next_due_at: due};
  bead.metadata.weekly_review = serialize ? JSON.stringify(stamp) : stamp; bead.due_at = beadDue;
  writeFileSync(join(store, 'issue.json'), JSON.stringify(bead));
}

test('artifact path is readable and due is exactly seven days after captured run time', () => {
  const started = Date.now(); success(run());
  const bead = issue(), stamp = bead.metadata.weekly_review;
  expect(stamp.artifact_path).toBe(join(output, 'weekly-run.json'));
  const bytes = readFileSync(stamp.artifact_path), artifact = JSON.parse(bytes.toString());
  expect(stamp.artifact_sha256).toBe(digest(bytes));
  expect(artifact.window).toEqual({since: at(Date.parse(artifact.ran_at) - 7 * DAY), until: artifact.ran_at});
  expect(JSON.parse(readFileSync(join(output, 'corpus.json'), 'utf8')).week).toEqual(artifact.window);
  expect(Date.parse(artifact.ran_at)).toBeGreaterThanOrEqual(Math.floor(started / 1000) * 1000);
  expect(Date.parse(bead.due_at) - Date.parse(artifact.ran_at)).toBe(7 * 86400000);
  expect(Date.parse(stamp.next_due_at)).toBe(Date.parse(bead.due_at));
  expect(bead.metadata.unrelated).toBe('preserved');
  for (const a of artifact.artifacts) expect(digest(readFileSync(a.path))).toBe(a.sha256);
  const updates = calls().filter(a => a.includes('update'));
  expect(updates).toHaveLength(1);
  expect(updates[0]).toContain('--due'); expect(updates[0]).toContain('--metadata');
});

test('invocation before the bead is due again, even into another directory, keeps one bead, artifact and due date', () => {
  success(run()); const before = issue(), original = readFileSync(join(output, 'weekly-run.json'), 'utf8');
  success(run()); success(run({}, join(root, 'data', 'other')));
  expect(issue()).toEqual(before);
  expect(readFileSync(join(output, 'weekly-run.json'), 'utf8')).toBe(original);
  expect(existsSync(join(root, 'data', 'other', 'corpus.json'))).toBe(false);
  expect(calls().filter(a => a.includes('update'))).toHaveLength(1);
  expect(calls().some(a => a.includes('create'))).toBe(false);
});

test('failed update preserves the artifact; retry dates from the original run, not retry time', () => {
  const before = issue(); const failed = run({FAIL_BD: 'update'});
  expect(failed.exitCode).not.toBe(0); expect(text(failed)).toContain('Dolt lock held: fixture store unreachable');
  expect(text(failed)).not.toContain('weekly_cycle:'); expect(issue()).toEqual(before);
  const file = join(output, 'weekly-run.json'), artifact = JSON.parse(readFileSync(file, 'utf8'));
  // Use a valid retained run timestamp several hours earlier. A retry must
  // honor that artifact, not recompute +7d from the new invocation clock.
  const original = Math.floor(Date.parse(artifact.ran_at) / 1000) * 1000 - 5 * 3600000 - 1000;
  backdate(file, at(original));
  success(run());
  expect(Date.parse(issue().due_at)).toBe(original + 7 * DAY);
});

test('a legacy serialized stamp and calendar-week artifact are read, then normalized once', () => {
  success(run());
  // The first live cycle left a version-1 artifact with a calendar week, a
  // sub-second ran_at, and its weekly_review stamp stored as a JSON string.
  const file = join(output, 'weekly-run.json'), {window, ...rest} = JSON.parse(readFileSync(file, 'utf8'));
  const ranAt = at(Math.floor(Date.now() / 1000) * 1000 - 3600000 + 496);
  writeFileSync(file, JSON.stringify({...rest, version: 1, week: '2026-10-12T00:00:00.000Z', ran_at: ranAt}));
  const due = at(Math.floor(Date.parse(ranAt) / 1000) * 1000 + 7 * DAY);
  stampBead(file, ranAt, at(Date.parse(ranAt) + 7 * DAY), true, due);
  const lists = calls().filter(a => a.includes('list')).length;
  success(run()); success(run());
  const after = issue();
  expect(Date.parse(after.due_at)).toBe(Date.parse(due));
  expect(after.metadata.weekly_review).toEqual({artifact_path: file, artifact_sha256: digest(readFileSync(file)), ran_at: ranAt, next_due_at: due});
  expect(calls().filter(a => a.includes('list'))).toHaveLength(lists);
  expect(calls().filter(a => a.includes('update'))).toHaveLength(2); // first cycle, one normalization
});

test.each([0, 3 * 3600000 + 17 * 60000 + 9000, DAY - 1000])('cycles fired %pms late tile [previous run, this run) without gap or overlap', late => {
  success(run());
  const first = join(output, 'weekly-run.json'), previous = Math.floor(Date.now() / 1000) * 1000 - 7 * DAY - late;
  const prior = backdate(first, at(previous));
  stampBead(first, prior.ran_at, at(previous + 7 * DAY));
  const next = join(root, 'data', 'next');
  success(run({}, next));
  const artifact = JSON.parse(readFileSync(join(next, 'weekly-run.json'), 'utf8'));
  expect(artifact.window.since).toBe(prior.window.until);
  expect(artifact.window.until).toBe(artifact.ran_at);
  expect(JSON.parse(readFileSync(join(next, 'corpus.json'), 'utf8')).week).toEqual(artifact.window);
  const list = calls().filter(a => a.includes('list')).at(-1)!;
  expect(list[list.indexOf('--closed-after') + 1]).toBe(at(Date.parse(prior.window.until) - 1000));
  expect(list[list.indexOf('--closed-before') + 1]).toBe(artifact.ran_at);
  expect(Date.parse(issue().due_at)).toBe(Date.parse(artifact.ran_at) + 7 * DAY);
  expect(issue().metadata.weekly_review.artifact_path).toBe(join(next, 'weekly-run.json'));
});

test('a bead closed exactly at the cycle boundary appears in exactly one cycle', () => {
  success(run());
  const first = join(output, 'weekly-run.json'), boundary = Math.floor(Date.now() / 1000) * 1000 - 7 * DAY - 3600000;
  const prior = backdate(first, at(boundary));
  stampBead(first, prior.ran_at, at(boundary + 7 * DAY));
  writeFileSync(join(store, 'closed.json'), JSON.stringify([{id: 'fm-edge', status: 'closed', closed_at: at(boundary).replace(/\.000Z$/, 'Z'), comments: []}]));
  const next = join(root, 'data', 'next');
  success(run({}, next));
  const corpus = (dir: string) => JSON.parse(readFileSync(join(dir, 'corpus.json'), 'utf8'));
  expect(JSON.stringify(corpus(next).events)).toContain('fm-edge');
  expect(corpus(next).notes.join('\n')).not.toContain('Excluded');
});

test('a due cycle reviews observations after the previous run and before this run only', () => {
  success(run());
  const first = join(output, 'weekly-run.json'), previous = Math.floor(Date.now() / 1000) * 1000 - 7 * DAY - 3600000;
  const prior = backdate(first, at(previous));
  stampBead(first, prior.ran_at, at(previous + 7 * DAY));
  const session = join(root, 'session.jsonl'), message = (ms: number, content: string) =>
    JSON.stringify({type: 'message', timestamp: at(ms), message: {role: 'user', content}});
  writeFileSync(session, [message(previous - 1000, 'corr=before reviewed last cycle'), message(previous, 'corr=edge first instant'),
    message(previous + 3 * DAY, 'corr=inside this cycle'), message(Date.now() + DAY, 'corr=future after this run')].join('\n') + '\n');
  const manifest = JSON.parse(readFileSync(sources, 'utf8'));
  writeFileSync(sources, JSON.stringify({...manifest, sessions: [{file: session}]}));
  const next = join(root, 'data', 'next'), r = run({}, next);
  success(r); expect(text(r)).toContain('user_messages: 2');
  const texts = JSON.parse(readFileSync(join(next, 'corpus.json'), 'utf8')).events.map((e: any) => e.text);
  expect(texts.some((t: string) => t.includes('edge first instant'))).toBe(true);
  expect(texts.some((t: string) => t.includes('inside this cycle'))).toBe(true);
  expect(texts.some((t: string) => t.includes('before reviewed') || t.includes('future after'))).toBe(false);
});

test('an empty window still reports its bounds and zero observations', () => {
  const r = run(); success(r);
  const corpus = JSON.parse(readFileSync(join(output, 'corpus.json'), 'utf8'));
  expect(text(r)).toContain('closed_beads: 0'); expect(text(r)).toContain('user_messages: 0');
  expect(text(r)).toContain(`week: ${JSON.stringify(corpus.week)}`);
  expect(corpus.events).toEqual([]);
  expect(corpus.notes).toContain(`Weekly review window: [${corpus.week.since}, ${corpus.week.until}). Invoked on demand; no schedule installed.`);
});

test('a due bead whose due_at plain bd ready rolled to now+1d still fires its cycle', () => {
  success(run());
  const first = join(output, 'weekly-run.json'), previous = Math.floor(Date.now() / 1000) * 1000 - 7 * DAY - 3600000;
  const prior = backdate(first, at(previous));
  stampBead(first, prior.ran_at, at(previous + 7 * DAY), false, at(Math.floor(Date.now() / 1000) * 1000 + DAY));
  const next = join(root, 'data', 'rolled');
  success(run({}, next));
  const artifact = JSON.parse(readFileSync(join(next, 'weekly-run.json'), 'utf8'));
  expect(artifact.window.since).toBe(prior.ran_at);
  expect(Date.parse(issue().due_at)).toBe(Date.parse(artifact.ran_at) + 7 * DAY);
  expect(issue().metadata.weekly_review.artifact_path).toBe(join(next, 'weekly-run.json'));
});

test('reusing a completed cycle work-dir once the bead is due refuses instead of replaying', () => {
  success(run());
  const file = join(output, 'weekly-run.json'), previous = Math.floor(Date.now() / 1000) * 1000 - 7 * DAY;
  const prior = backdate(file, at(previous));
  stampBead(file, prior.ran_at, at(previous + 7 * DAY));
  const before = issue(), r = run();
  expect(r.exitCode).not.toBe(0);
  expect(text(r)).toContain(`weekly artifact window does not continue the stamped cycle: ${file}`);
  expect(text(r)).not.toContain('weekly_cycle:');
  expect(issue()).toEqual(before); expect(calls().filter(a => a.includes('update'))).toHaveLength(1);
});

test('a driver cycle refuses an explicit --week', () => {
  const r = Bun.spawnSync(['bash', script, 'weekly', '--work-dir', output, '--sources', sources, '--week', '2026-10-18'],
    {stdout: 'pipe', stderr: 'pipe', env: {...process.env, PATH: bin + ':' + process.env.PATH}});
  expect(r.exitCode).not.toBe(0); expect(text(r)).toContain('omit --week');
});

test.each(['show', 'where'])('unreachable %s refuses verbatim before writing or re-dating', command => {
  const before = issue(), r = run({FAIL_BD: command});
  expect(r.exitCode).not.toBe(0); expect(text(r)).toContain('Dolt lock held: fixture store unreachable');
  expect(issue()).toEqual(before); expect(existsSync(join(output, 'weekly-run.json'))).toBe(false);
  expect(calls().some(a => a.includes('update'))).toBe(false);
});

test('missing bead and mismatched store refuse without re-dating', () => {
  const before = issue();
  expect(text(run({MISSING_BEAD: '1'}))).toContain('weekly driver missing: fm-driver');
  expect(text(run({WRONG_DB: store}))).toContain('weekly driver store identity mismatch');
  expect(issue()).toEqual(before); expect(calls().some(a => a.includes('update'))).toBe(false);
});

test('changed/unreadable stamped artifact refuses a completed-week replay', () => {
  success(run()); const before = issue();
  writeFileSync(join(output, 'corpus.json'), '{}');
  const changed = run(); expect(changed.exitCode).not.toBe(0); expect(text(changed)).toContain('weekly artifact changed:');
  rmSync(join(output, 'weekly-run.json'));
  const missing = run(); expect(missing.exitCode).not.toBe(0); expect(text(missing)).toContain('ENOENT');
  expect(issue()).toEqual(before); expect(calls().filter(a => a.includes('update'))).toHaveLength(1);
});

test('an overlapping invocation refuses immediately without opening another cycle', () => {
  writeFileSync(lockFile(), String(process.pid));
  try {
    const before = issue(), r = run();
    expect(r.exitCode).not.toBe(0); expect(text(r)).toContain(`weekly driver locked by running pid ${process.pid}: ${lockFile()}`);
    expect(issue()).toEqual(before); expect(calls().some(a => a.includes('update'))).toBe(false);
  } finally { rmSync(lockFile(), {force: true}); }
});

const claimFile = () => `${lockFile()}.claim.${lstatSync(lockFile()).ino}`;
test.each([String(process.pid), 'not-a-pid'])('a takeover guard owned by %s refuses without touching the bead or dead main lock', owner => {
  const dead = Bun.spawnSync(['true']).pid, guard = `${lockFile()}.takeover`;
  writeFileSync(lockFile(), String(dead)); writeFileSync(guard, owner);
  try {
    const before = issue(), r = run();
    expect(r.exitCode).not.toBe(0);
    expect(text(r)).toContain(`weekly driver locked by ${owner === String(process.pid) ? `running pid ${owner}` : 'an unreadable pid'}: ${guard}`);
    expect(readFileSync(lockFile(), 'utf8')).toBe(String(dead));
    expect(readFileSync(guard, 'utf8')).toBe(owner);
    expect(issue()).toEqual(before); expect(calls().some(a => a.includes('update'))).toBe(false);
    expect(existsSync(join(output, 'weekly-run.json'))).toBe(false);
  } finally { rmSync(guard, {force: true}); rmSync(lockFile(), {force: true}); }
});

test('dead main and takeover owners are both reclaimed and audited before completing one cycle', () => {
  const dead = Bun.spawnSync(['true']).pid, guard = `${lockFile()}.takeover`;
  let code: string | undefined;
  try { process.kill(dead, 0); } catch (error: any) { code = error.code; }
  expect(code).toBe('ESRCH');
  writeFileSync(lockFile(), String(dead)); writeFileSync(guard, String(dead));
  try {
    const r = run(); success(r);
    for (const path of [lockFile(), guard]) {
      expect(text(r)).toContain(`taking over stale weekly lock from exited pid ${dead}: ${path}`);
      expect(existsSync(path)).toBe(false);
    }
    expect(issue().metadata.weekly_review.artifact_path).toBe(join(output, 'weekly-run.json'));
    expect(calls().filter(a => a.includes('update'))).toHaveLength(1);
  } finally { rmSync(guard, {force: true}); rmSync(lockFile(), {force: true}); }
});

test('only one run may take over a stale lock; a concurrent live taker refuses', () => {
  const dead = Bun.spawnSync(['true']).pid;
  writeFileSync(lockFile(), String(dead)); writeFileSync(claimFile(), String(process.pid));
  try {
    const before = issue(), r = run();
    expect(r.exitCode).not.toBe(0); expect(text(r)).toContain(`weekly driver locked by running pid ${process.pid}: ${claimFile()}`);
    expect(readFileSync(lockFile(), 'utf8')).toBe(String(dead));
    expect(readFileSync(claimFile(), 'utf8')).toBe(String(process.pid));
    expect(issue()).toEqual(before); expect(calls().some(a => a.includes('update'))).toBe(false);
  } finally { rmSync(claimFile(), {force: true}); rmSync(lockFile(), {force: true}); }
});

test('a run killed holding both the lock and its takeover claim leaves the next run able to complete the cycle', () => {
  const dead = Bun.spawnSync(['true']).pid;
  writeFileSync(lockFile(), String(dead)); writeFileSync(claimFile(), String(dead));
  const claim = claimFile();
  try {
    const r = run(); success(r);
    expect(text(r)).toContain(`taking over stale weekly lock from exited pid ${dead}: ${claim}`);
    expect(text(r)).toContain(`taking over stale weekly lock from exited pid ${dead}: ${lockFile()}`);
    expect(existsSync(lockFile())).toBe(false); expect(existsSync(claim)).toBe(false);
    expect(issue().metadata.weekly_review.artifact_path).toBe(join(output, 'weekly-run.json'));
  } finally { rmSync(claim, {force: true}); rmSync(lockFile(), {force: true}); }
});

test('simultaneous reclaimers of a dead-owner lock complete exactly one cycle', async () => {
  const dead = Bun.spawnSync(['true']).pid;
  writeFileSync(lockFile(), String(dead));
  try {
    const runs = [1, 2, 3].map(i => Bun.spawn(['bash', script, 'weekly', '--work-dir', join(root, 'data', `racer-${i}`), '--sources', sources],
      {stdout: 'pipe', stderr: 'pipe', env: {...process.env, PATH: bin + ':' + process.env.PATH}}));
    const results = await Promise.all(runs.map(async r => ({code: await r.exited, text: await new Response(r.stdout).text() + await new Response(r.stderr).text()})));
    expect(results.filter(r => r.code === 0).length).toBeGreaterThanOrEqual(1);
    for (const r of results.filter(r => r.code !== 0)) expect(r.text).toMatch(/weekly driver lock(ed by running pid \d+| changed during takeover):/);
    expect(calls().filter(a => a.includes('update'))).toHaveLength(1);
    expect(existsSync(lockFile())).toBe(false);
  } finally { rmSync(lockFile(), {force: true}); }
});

test('a lock without a readable owner pid refuses rather than being reclaimed', () => {
  writeFileSync(lockFile(), 'not-a-pid');
  try {
    const before = issue(), r = run();
    expect(r.exitCode).not.toBe(0); expect(text(r)).toContain(`weekly driver locked by an unreadable pid: ${lockFile()}`);
    expect(readFileSync(lockFile(), 'utf8')).toBe('not-a-pid');
    expect(issue()).toEqual(before); expect(calls().some(a => a.includes('update'))).toBe(false);
  } finally { rmSync(lockFile(), {force: true}); }
});

test('a run killed while holding the lock leaves the next run able to complete the cycle', async () => {
  const child = Bun.spawn(['bash', script, 'weekly', '--work-dir', output, '--sources', sources],
    {stdout: 'ignore', stderr: 'ignore', env: {...process.env, PATH: bin + ':' + process.env.PATH, HANG_BD: 'show'}});
  for (let i = 0; i < 200 && !existsSync(lockFile()); i++) await Bun.sleep(25);
  const pid = Number(readFileSync(lockFile(), 'utf8'));
  process.kill(pid, 'SIGKILL'); await child.exited;
  for (let i = 0; i < 200; i++) { try { process.kill(pid, 0); await Bun.sleep(25); } catch { break; } }
  expect(existsSync(lockFile())).toBe(true);
  const r = run({}, join(root, 'data', 'after-kill'));
  success(r); expect(text(r)).toContain(`taking over stale weekly lock from exited pid ${pid}`);
  expect(existsSync(lockFile())).toBe(false);
  expect(issue().metadata.weekly_review.artifact_path).toBe(join(root, 'data', 'after-kill', 'weekly-run.json'));
});

test('no scheduler process or schedule file is opened during a real CLI cycle', () => {
  const traceTool = Bun.spawnSync(['which', 'strace'], {stdout: 'pipe', stderr: 'pipe'});
  if (traceTool.exitCode !== 0) {
    console.error('strace unavailable: syscall-level no-scheduler proof not run on this host');
    return;
  }
  const trace = join(root, 'syscalls.log');
  success(run({}, output, ['strace', '-f', '-e', 'trace=process,file', '-o', trace]));
  const syscalls = readFileSync(trace, 'utf8');
  const executables = [...syscalls.matchAll(/execve\("([^"]+)"/g)].map(m => basename(m[1]));
  expect(executables.length).toBeGreaterThan(0);
  // Only the foreground CLI, its shell path helper, and existing Git/Beads
  // store operations may run. A background scheduler would fail this list.
  expect(executables.every(name => ['bash', 'bun', 'dirname', 'git', 'bd'].includes(name))).toBe(true);
  expect(syscalls).not.toMatch(/(?:openat|open|creat)\([^\n]*(?:\/systemd\/|\/cron(?:tab|\.|\/)|\/init\.d\/)/);
  expect(calls().filter(a => a.includes('update'))).toHaveLength(1);
});
