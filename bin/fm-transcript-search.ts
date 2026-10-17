// fm-transcript-search.sh owns the entry point; no external packages or writes.
import { closeSync, openSync, readSync, realpathSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const HELP = `Optional transcript lookup; this never gates a question.
Usage: fm-transcript-search.sh [--root DIR]... [--seconds N] [--limit N] -- TEXT
Requires Bun and rg. Searches *.jsonl recursively under every --root given, or by
default under each harness transcript root: ~/.pi/agent/sessions (Pi),
~/.claude/projects (Claude), \${XDG_DATA_HOME:-~/.local/share}/muse/sessions (Muse),
\${CURSOR_PROJECTS_ROOT_OVERRIDE:-~/.cursor/projects} (Cursor).
Roots that do not resolve are skipped and listed in missingRoots, never errors.
All roots share one rg scan and one --seconds cap.
TEXT is one literal case-insensitive phrase, 1-256 UTF-8 bytes, no newlines.
Defaults: 15 seconds, 5 hits; maxima: 120 seconds, 10 hits.
Set --seconds to LESS than the remaining shared search-before-ask budget;
leave time to inspect hits. Skip the lookup and ask if no time remains.
rg streams matches only, capped at 64 KiB output and 3 matching lines/file.
Each hit reads at most 2048 bytes, starting up to 512 bytes before its match.
No whole-session reads, JSONL parsing, persistent state, or automatic authority.
Output: JSON with roots (searched), missingRoots[], term, status, reason, elapsedMs, hits[].
Hits cite file, zero-based matchOffset, windowOffset, windowBytes and raw window.
Windows may start/end mid-record or mid-character; they are untrusted evidence,
not speaker attribution. Locate direct words and current scope before relying.
Coverage is ALWAYS partial: per-file, result and output caps can omit matches.
Empty hits mean no answer found in searched material, not proof of absence.
Timeouts/errors/missing tools return partial or unavailable coverage with reason,
exit 0: ask sooner, stating what could not be checked. Never retry past budget.
Example: fm-transcript-search.sh --seconds 10 -- 'Go merge the PR'
`;

const started = performance.now();
const requested: string[] = [];
const roots: string[] = [];
const missingRoots: {root: string; reason: string}[] = [];
let term = '';
const hits: {file: string; matchOffset: number; windowOffset: number; windowBytes: number; window: string}[] = [];
function result(status: string, reason: string) {
  console.log(JSON.stringify({roots, missingRoots, term, status, reason, elapsedMs: Math.round(performance.now() - started), hits}));
}
try {
  const args = process.argv.slice(2);
  const separator = args.indexOf('--');
  const options = separator < 0 ? args : args.slice(0, separator);
  if (options.includes('--help') || options.includes('-h')) { console.log(HELP); process.exit(0); }
  let seconds = 15, limit = 5;
  while (args.length && args[0] !== '--') {
    const flag = args.shift(), value = args.shift();
    if (flag === '--root' && value) requested.push(value);
    else if ((flag === '--seconds' || flag === '--limit') && value && /^[1-9]\d*$/.test(value)) {
      const n = Number(value), max = flag === '--seconds' ? 120 : 10;
      if (n > max) throw new Error(`${flag} exceeds ${max}`);
      if (flag === '--seconds') seconds = n; else limit = n;
    } else throw new Error('invalid arguments; use --help');
  }
  if (args.shift() !== '--' || args.length !== 1) throw new Error('supply one literal TEXT after --; use --help');
  term = args[0];
  if (!term.length || Buffer.byteLength(term) > 256 || /[\r\n\0]/.test(term)) throw new Error('TEXT must be 1-256 bytes without newlines or NUL');
  if (!requested.length) requested.push(join(homedir(), '.pi/agent/sessions'), join(homedir(), '.claude/projects'),
    join(process.env.XDG_DATA_HOME || join(homedir(), '.local/share'), 'muse/sessions'),
    process.env.CURSOR_PROJECTS_ROOT_OVERRIDE || join(homedir(), '.cursor/projects'));
  for (const root of requested) {
    try { roots.push(realpathSync(root)); }
    catch (error) { missingRoots.push({root, reason: String(error).slice(0, 300)}); }
  }
  if (!roots.length) throw new Error('no transcript root exists: ' + requested.join(', '));
  const search = spawnSync('rg', ['--no-config', '--hidden', '--no-ignore', '--glob', '*.jsonl',
    '--fixed-strings', '--ignore-case', '--with-filename', '--null', '--byte-offset',
    '--only-matching', '--max-count', '3', '--color', 'never', '--', term, ...roots],
    {timeout: seconds * 1000, killSignal: 'SIGKILL', maxBuffer: 65536});
  // --null separates file from offset; TEXT cannot contain a record delimiter.
  const output = search.stdout?.subarray(0, 65536).toString('utf8') ?? '';
  const pattern = /([^\0]+)\0(\d+):[^\n]*\n/g;
  let match: RegExpExecArray | null;
  const errors: string[] = [];
  let candidates = 0;
  while (candidates++ < limit && (match = pattern.exec(output))) {
    const file = match[1], matchOffset = Number(match[2]);
    const windowOffset = Math.max(0, matchOffset - 512);
    let fd: number | undefined;
    try {
      fd = openSync(file, 'r');
      const bytes = Buffer.alloc(2048);
      const size = readSync(fd, bytes, 0, bytes.length, windowOffset);
      hits.push({file, matchOffset, windowOffset, windowBytes: size, window: bytes.subarray(0, size).toString('utf8')});
    } catch (error) { errors.push(`${file}: ${String(error).slice(0, 300)}`); }
    finally { if (fd !== undefined) closeSync(fd); }
  }
  const issue = search.error ? String(search.error) : search.status !== 0 && search.status !== 1
    ? `rg exit ${search.status}: ${search.stderr?.toString('utf8').slice(0, 500)}` : '';
  const skipped = missingRoots.map(m => `could not search ${m.root}: ${m.reason}`);
  const reason = ['bounded search; at most 3 matching lines/file, 64 KiB match output and ' + limit + ' windows', ...skipped, issue, ...errors].filter(Boolean).join('; ');
  result(issue && !hits.length ? 'unavailable' : 'partial', reason);
} catch (error) {
  result('unavailable', `could not search transcripts: ${String(error).slice(0, 500)}; ask sooner`);
}
