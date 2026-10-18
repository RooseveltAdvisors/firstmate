// Invoked-cycle completion only. fm-explained-twice.sh --help owns configuration.
import { mkdirSync, rmdirSync, realpathSync, lstatSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

export type Driver = { id: string; directory: string; databasePath: string };
export type WeeklyRun = { version: 1; kind: 'weekly-instruction-review'; week: string; ran_at: string;
  sources_sha256: string; driver: Driver; artifacts: { path: string; sha256: string }[] };
const sha = (bytes: string | Buffer) => createHash('sha256').update(bytes).digest('hex');
function check(ok: unknown, message: string): asserts ok { if (!ok) throw new Error(message); }
function read(file: string) {
  const s = lstatSync(file);
  check(s.isFile() && s.nlink === 1 && s.size <= 4194304 && realpathSync(file) === resolve(file), `invalid weekly artifact: ${file}`);
  return readFileSync(file);
}
export function weeklyRun(file: string, driver: Driver, week: string) {
  check(typeof file === 'string' && resolve(file) === file && file.split('/').includes('data') &&
    file === join(dirname(file), 'weekly-run.json'), 'invalid weekly run artifact path');
  const bytes = read(file), run: WeeklyRun = JSON.parse(bytes.toString('utf8'));
  check(run.version === 1 && run.kind === 'weekly-instruction-review' && run.week === week &&
    JSON.stringify(run.driver) === JSON.stringify(driver) && /^[a-f0-9]{64}$/.test(run.sources_sha256), 'weekly artifact identity mismatch');
  check(typeof run.ran_at === 'string' && new Date(run.ran_at).toISOString() === run.ran_at, 'invalid weekly run timestamp');
  check(Array.isArray(run.artifacts) && run.artifacts.length >= 1 && run.artifacts.length <= 3 &&
    run.artifacts.some(a => a.path === join(dirname(file), 'corpus.json')), 'weekly artifact needs its corpus');
  const seen = new Set<string>();
  for (const a of run.artifacts) {
    check(['corpus.json', 'conformance.json', 'conformance.md'].some(name => a.path === join(dirname(file), name)) &&
      !seen.has(a.path), 'unexpected or duplicate weekly artifact');
    seen.add(a.path);
    check(sha(read(a.path)) === a.sha256, `weekly artifact changed: ${a.path}`);
  }
  // Beads persists due_at at whole-second resolution. Retained artifacts from
  // earlier invocations may contain a higher-resolution observation time.
  return { run, digest: sha(bytes), next: new Date(Math.floor(Date.parse(run.ran_at) / 1000) * 1000 + 7 * 86400000).toISOString() };
}

// A transient per-bead lock serializes overlapping invocations, even with
// different work directories. Contention refuses immediately; no polling.
export function completeWeeklyCycle(config: unknown, week: string, invoke: (driver: Driver) => string) {
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
  const lock = join(tmpdir(), `fm-weekly-${sha(JSON.stringify(driver))}`);
  mkdirSync(lock, {mode: 0o700});
  try {
    function show() {
      const rows = bd(['show', `--id=${driver.id}`]);
      check(Array.isArray(rows) && rows.length === 1 && rows[0].id === driver.id, `weekly driver missing: ${driver.id}`);
      check(['open', 'in_progress', 'deferred'].includes(rows[0].status), `weekly driver is not open: ${driver.id}`);
      return rows[0];
    }
    const before = show(), raw = before.metadata?.weekly_review;
    // bd --set-metadata treats values as strings; a previously unconfirmed
    // update may need conversion to the object written by --metadata below.
    const serialized = typeof raw === 'string', previous = serialized ? JSON.parse(raw) : raw;
    let pendingArtifact: string | undefined;
    if (previous) {
      check(typeof previous.week === 'string' && previous.week <= week, 'weekly driver already records a later week');
      if (previous.week === week) {
        check(typeof previous.artifact_path === 'string', 'weekly driver has no artifact path');
        const saved = weeklyRun(previous.artifact_path, driver, week);
        check(saved.digest === previous.artifact_sha256 && Math.floor(Date.parse(previous.next_due_at) / 1000) * 1000 === Date.parse(saved.next) &&
          saved.run.ran_at === previous.ran_at && Date.parse(before.due_at) === Date.parse(saved.next), 'weekly driver stamp/due mismatch');
        if (!serialized) return {artifact: previous.artifact_path as string, due: saved.next, already_complete: true};
        pendingArtifact = previous.artifact_path;
      }
    }
    const artifact = pendingArtifact || invoke(driver), saved = weeklyRun(artifact, driver, week);
    const stamp = {week, artifact_path: artifact, artifact_sha256: saved.digest, ran_at: saved.run.ran_at, next_due_at: saved.next};
    // Stamp and date belong to ONE update. Never create/close a bead or use a
    // relative date, which would advance again when retrying a completed run.
    bd(['update', '--metadata', JSON.stringify({...before.metadata, weekly_review: stamp}), '--due', saved.next, '--', driver.id], true);
    const after = show();
    check(Object.entries(stamp).every(([key, value]) => after.metadata?.weekly_review?.[key] === value) &&
      Date.parse(after.due_at) === Date.parse(saved.next), 'weekly bead update not confirmed by readback');
    return {artifact, due: saved.next, already_complete: false};
  } finally { rmdirSync(lock); }
}
