import { afterEach, beforeEach, expect, test } from 'bun:test';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
import {appendFileSync, readFileSync, writeFileSync} from 'node:fs';
const args = process.argv.slice(2), store = args[args.indexOf('-C') + 1];
appendFileSync(store + '/calls.jsonl', JSON.stringify(args) + '\\n');
if (Object.keys(process.env).some(k => k.startsWith('BEADS_') || k === 'BD_DATABASE')) throw Error('inherited store override');
if (process.cwd() !== store || args[args.indexOf('--db') + 1] !== store + '/.beads/embeddeddolt') throw Error('store not pinned');
if (!args.includes('--sandbox') || !args.includes('--json')) throw Error('unbounded command');
const command = args.find(x => ['where', 'list', 'show', 'update'].includes(x));
if (command !== 'update' && !args.includes('--readonly')) throw Error('read not readonly');
if (process.env.FAIL_BD === command) { console.error('Dolt lock held: fixture store unreachable'); process.exit(2); }
if (command === 'where') console.log(JSON.stringify({path: store + '/.beads', database_path: process.env.WRONG_DB || store + '/.beads/embeddeddolt'}));
else if (command === 'list') console.log('[]');
else if (command === 'show') console.log(process.env.MISSING_BEAD ? '[]' : '[' + readFileSync(store + '/issue.json', 'utf8') + ']');
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
  return Bun.spawnSync([...prefix, 'bash', script, 'weekly', '--work-dir', dir, '--sources', sources, '--week', '2026-10-18'], {
    stdout: 'pipe', stderr: 'pipe', timeout: 20000,
    env: {...process.env, PATH: bin + ':' + process.env.PATH, BEADS_DIR: '/wrong-store', BD_DATABASE: 'wrong-database', ...extra},
  });
}
const issue = () => JSON.parse(readFileSync(join(store, 'issue.json'), 'utf8'));
const calls = (): string[][] => readFileSync(join(store, 'calls.jsonl'), 'utf8').trim().split('\n').map(s => JSON.parse(s));
const text = (r: ReturnType<typeof run>) => r.stdout.toString() + r.stderr.toString();
function success(r: ReturnType<typeof run>) { expect(text(r)).not.toContain('error:'); expect(r.exitCode).toBe(0); }

test('artifact path is readable and due is exactly seven days after captured run time', () => {
  const started = Date.now(); success(run());
  const bead = issue(), stamp = bead.metadata.weekly_review;
  expect(stamp.artifact_path).toBe(join(output, 'weekly-run.json'));
  const bytes = readFileSync(stamp.artifact_path), artifact = JSON.parse(bytes.toString());
  expect(stamp.artifact_sha256).toBe(digest(bytes));
  expect(artifact.week).toBe('2026-10-12T00:00:00.000Z');
  expect(Date.parse(artifact.ran_at)).toBeGreaterThanOrEqual(Math.floor(started / 1000) * 1000);
  expect(Date.parse(bead.due_at) - Date.parse(artifact.ran_at)).toBe(7 * 86400000);
  expect(Date.parse(stamp.next_due_at)).toBe(Date.parse(bead.due_at));
  expect(bead.metadata.unrelated).toBe('preserved');
  for (const a of artifact.artifacts) expect(digest(readFileSync(a.path))).toBe(a.sha256);
  const updates = calls().filter(a => a.includes('update'));
  expect(updates).toHaveLength(1);
  expect(updates[0]).toContain('--due'); expect(updates[0]).toContain('--metadata');
});

test('same-week double invocation, even into another directory, keeps one bead, artifact and due date', () => {
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
  // Use a valid retained run timestamp several days earlier. A retry must
  // honor that artifact, not recompute +7d from the new invocation clock.
  artifact.ran_at = '2026-10-15T12:34:56.000Z'; writeFileSync(file, JSON.stringify(artifact));
  success(run());
  expect(issue().due_at).toBe('2026-10-22T12:34:56Z');
});

test('recover a serialized pending stamp at Beads second precision without advancing again', () => {
  expect(run({FAIL_BD: 'update'}).exitCode).not.toBe(0);
  const file = join(output, 'weekly-run.json'), artifact = JSON.parse(readFileSync(file, 'utf8'));
  artifact.ran_at = '2026-10-18T21:30:48.496Z'; writeFileSync(file, JSON.stringify(artifact));
  const before = issue(); before.due_at = '2026-10-25T21:30:48Z';
  before.metadata.weekly_review = JSON.stringify({week: artifact.week, artifact_path: file,
    artifact_sha256: digest(readFileSync(file)), ran_at: artifact.ran_at, next_due_at: '2026-10-25T21:30:48.496Z'});
  writeFileSync(join(store, 'issue.json'), JSON.stringify(before));
  success(run()); success(run());
  const after = issue();
  expect(after.due_at).toBe(before.due_at);
  expect(after.metadata.weekly_review.artifact_sha256).toBe(digest(readFileSync(file)));
  expect(after.metadata.weekly_review.ran_at).toBe(artifact.ran_at);
  expect(calls().filter(a => a.includes('list'))).toHaveLength(1);
  expect(calls().filter(a => a.includes('update'))).toHaveLength(2); // one failed, one recovery
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
  const driver = {id: 'fm-driver', directory: store, databasePath: db};
  const lock = join(tmpdir(), `fm-weekly-${digest(JSON.stringify(driver))}`);
  mkdirSync(lock);
  try {
    const before = issue(), r = run();
    expect(r.exitCode).not.toBe(0); expect(text(r)).toContain('EEXIST'); expect(issue()).toEqual(before);
    expect(calls().some(a => a.includes('update'))).toBe(false);
  } finally { rmSync(lock, {recursive: true}); }
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
