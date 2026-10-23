// Invoked-cycle completion only. fm-explained-twice.sh --help owns configuration.
import { closeSync, existsSync, fstatSync, linkSync, openSync, renameSync, unlinkSync, writeFileSync, realpathSync, lstatSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

export type Driver = { id: string; directory: string; databasePath: string };
export type Window = { since: string; until: string };
// Version 1 artifacts declared a calendar week; one exists from the first live
// cycle and remains readable. Version 2 declares the cycle window it reviewed.
export type WeeklyRun = { version: 2; kind: 'weekly-instruction-review'; window: Window; ran_at: string;
  sources_sha256: string; driver: Driver; artifacts: { path: string; sha256: string }[] };
const DAY = 86400000;
const sha = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex');
const iso = (value: unknown) => typeof value === 'string' && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
function check(ok: unknown, message: string): asserts ok { if (!ok) throw new Error(message); }
function read(file: string) {
  const s = lstatSync(file);
  check(s.isFile() && s.nlink === 1 && s.size <= 4194304 && realpathSync(file) === resolve(file), `invalid weekly artifact: ${file}`);
  return readFileSync(file);
}
export function weeklyRun(file: string, driver: Driver) {
  check(typeof file === 'string' && resolve(file) === file && file.split('/').includes('data') &&
    file === join(dirname(file), 'weekly-run.json'), 'invalid weekly run artifact path');
  const bytes = read(file), run = JSON.parse(bytes.toString('utf8'));
  check(run.kind === 'weekly-instruction-review' && JSON.stringify(run.driver) === JSON.stringify(driver) &&
    /^[a-f0-9]{64}$/.test(run.sources_sha256), 'weekly artifact identity mismatch');
  check(iso(run.ran_at), 'invalid weekly run timestamp');
  const window: Window = run.version === 1 && iso(run.week)
    ? {since: run.week, until: new Date(Date.parse(run.week) + 7 * DAY).toISOString()} : run.window;
  check((run.version === 1 || (run.version === 2 && iso(window?.since) && window.until === run.ran_at)) &&
    Date.parse(window.since) < Date.parse(window.until), 'invalid weekly run window');
  check(Array.isArray(run.artifacts) && run.artifacts.length >= 1 && run.artifacts.length <= 3 &&
    run.artifacts.some((a: any) => a.path === join(dirname(file), 'corpus.json')), 'weekly artifact needs its corpus');
  const seen = new Set<string>();
  for (const a of run.artifacts) {
    check(['corpus.json', 'conformance.json', 'conformance.md'].some(name => a.path === join(dirname(file), name)) &&
      !seen.has(a.path), 'unexpected or duplicate weekly artifact');
    seen.add(a.path);
    check(sha(read(a.path)) === a.sha256, `weekly artifact changed: ${a.path}`);
  }
  // Beads persists due_at at whole-second resolution. Retained artifacts from
  // earlier invocations may contain a higher-resolution observation time.
  return { run: run as WeeklyRun, window, digest: sha(bytes),
    next: new Date(Math.floor(Date.parse(run.ran_at) / 1000) * 1000 + 7 * DAY).toISOString() };
}

// A transient per-bead lock serializes overlapping invocations, even with
// different work directories. Contention refuses immediately; no polling.
// Each lock file names its owner pid. A lock whose owner is confirmed exited
// (ESRCH) is replaced; a live, unprobeable (EPERM) or unreadable owner keeps
// it held. A claim keyed by the dead lock's inode makes one run its sole
// replacer, and a claim left by a killed replacer is replaced the same way.
// The takeover guard serializes lock acquisition and follows the same owner
// checks, including recovery after a run dies holding both files.
// Each cycle reviews [previous ran_at, ranAt) and re-dates the bead to
// ranAt + 7d, so consecutive cycles tile time without gaps or overlap.
export function completeWeeklyCycle(config: unknown, ranAt: string, invoke: (driver: Driver, window: Window) => string) {
  const value = config as Driver;
  check(value && typeof value.id === 'string' && /^[a-zA-Z0-9_:\-]+$/.test(value.id) &&
    typeof value.directory === 'string' && typeof value.databasePath === 'string', 'invalid weekly driver; require id, directory, databasePath');
  const driver: Driver = {id: value.id, directory: realpathSync(value.directory), databasePath: realpathSync(value.databasePath)};
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('BEADS_') && k !== 'BD_DATABASE'));
  function bd(args: string[], write = false): any {
    const r = spawnSync('bd', [...(write ? [] : ['--readonly']), '--sandbox', '-C', driver.directory, '--db', driver.databasePath, '--json', ...args],
      {cwd: driver.directory, env, encoding: 'utf8', timeout: 30000, maxBuffer: 4194304});
    check(!r.error && r.status === 0, `weekly bead refused for ${driver.directory} ${driver.id}: ${r.stderr || r.error?.message || `exit ${r.status}`}`);
    if (r.stderr) console.error(r.stderr);
    return JSON.parse(r.stdout);
  }
  const where = bd(['where']);
  check(typeof where.database_path === 'string' && realpathSync(where.database_path) === driver.databasePath &&
    typeof where.path === 'string' && realpathSync(where.path) === realpathSync(join(driver.directory, '.beads')), 'weekly driver store identity mismatch');
  const lock = join(tmpdir(), `fm-weekly-${sha(JSON.stringify(driver))}.lock`);
  // One descriptor gives the owner pid and the inode of the same lock file.
  function owner(path: string) {
    const fd = openSync(path, 'r');
    try { return {pid: Number(readFileSync(fd, 'utf8')), ino: fstatSync(fd).ino}; } finally { closeSync(fd); }
  }
  const release = (path: string) => { if (existsSync(path) && owner(path).pid === process.pid) unlinkSync(path); };
  function acquire(path: string) {
    const own = `${path}.${process.pid}`;
    writeFileSync(own, String(process.pid), {mode: 0o600});
    try {
      try { linkSync(own, path); return; } catch (error: any) { if (error?.code !== 'EEXIST') throw error; }
      const {pid, ino} = owner(path), valid = Number.isSafeInteger(pid) && pid > 0;
      let gone = false;
      if (valid) try { process.kill(pid, 0); } catch (probe: any) { gone = probe?.code === 'ESRCH'; }
      check(gone, `weekly driver locked by ${valid ? `running pid ${pid}` : 'an unreadable pid'}: ${path}; remove it only if no weekly run is active`);
      acquire(`${path}.claim.${ino}`);
      try {
        check(lstatSync(path).ino === ino, `weekly driver lock changed during takeover: ${path}`);
        console.error(`taking over stale weekly lock from exited pid ${pid}: ${path}`);
        renameSync(own, path);
      } finally { release(`${path}.claim.${ino}`); }
    } finally { if (existsSync(own)) unlinkSync(own); }
  }
  const takeover = `${lock}.takeover`;
  acquire(takeover);
  try { acquire(lock); } finally { release(takeover); }
  try {
    function show() {
      const rows = bd(['show', `--id=${driver.id}`]);
      check(Array.isArray(rows) && rows.length === 1 && rows[0].id === driver.id, `weekly driver missing: ${driver.id}`);
      check(['open', 'in_progress', 'deferred'].includes(rows[0].status), `weekly driver is not open: ${driver.id}`);
      return rows[0];
    }
    const before = show(), raw = before.metadata?.weekly_review;
    // The first live cycle's readback failed after bd --set-metadata stored
    // weekly_review as a JSON string. That stamp exists on a real bead; any
    // successful update below rewrites it in the object form.
    const serialized = typeof raw === 'string', previous = serialized ? JSON.parse(raw) : raw;
    let normalized: string | undefined;
    if (previous) {
      const due = Math.floor(Date.parse(previous.next_due_at) / 1000) * 1000;
      check(typeof previous.artifact_path === 'string' && iso(previous.ran_at) && Number.isFinite(due) &&
        Date.parse(previous.ran_at) <= Date.parse(ranAt), 'weekly driver has an invalid stamp');
      // Due-ness comes from the stamp: plain `bd ready` rolls an overdue
      // bead's due_at forward, so the bead's own date cannot decide it.
      if (Date.parse(ranAt) < due) {
        const saved = weeklyRun(previous.artifact_path, driver);
        check(saved.digest === previous.artifact_sha256 && due === Date.parse(saved.next) &&
          saved.run.ran_at === previous.ran_at && Date.parse(before.due_at) === Date.parse(saved.next), 'weekly driver stamp/due mismatch');
        if (!serialized) return {artifact: previous.artifact_path as string, due: saved.next, already_complete: true};
        normalized = previous.artifact_path;
      }
    }
    const since: string = previous?.ran_at ?? new Date(Date.parse(ranAt) - 7 * DAY).toISOString();
    const artifact = normalized ?? invoke(driver, {since, until: ranAt});
    const saved = weeklyRun(artifact, driver);
    check(normalized || (saved.run.version === 2 && saved.window.since ===
      (previous ? previous.ran_at : new Date(Date.parse(saved.run.ran_at) - 7 * DAY).toISOString())),
      `weekly artifact window does not continue the stamped cycle: ${artifact}; use a new --work-dir`);
    const stamp = {artifact_path: artifact, artifact_sha256: saved.digest, ran_at: saved.run.ran_at, next_due_at: saved.next};
    // Stamp and date belong to ONE update. Never create/close a bead or use a
    // relative date, which would advance again when retrying a completed run.
    bd(['update', '--metadata', JSON.stringify({...before.metadata, weekly_review: stamp}), '--due', saved.next, '--', driver.id], true);
    const after = show();
    check(Object.entries(stamp).every(([key, value]) => after.metadata?.weekly_review?.[key] === value) &&
      Date.parse(after.due_at) === Date.parse(saved.next), 'weekly bead update not confirmed by readback');
    return {artifact, due: saved.next, already_complete: false};
  } finally { release(lock); }
}
