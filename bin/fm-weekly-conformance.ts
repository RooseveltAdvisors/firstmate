// Read-only conformance leg of fm-explained-twice.sh; that CLI owns the contract.
import { existsSync, openSync, closeSync, fstatSync, readSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const verdicts = ['follow', 'violate', 'miss', 'out-of-scope', 'no-signature'] as const;
type Verdict = typeof verdicts[number];
type Rule = { id: string; rule: string; signature: string; limit: string; line: number };
type Row = { rule: string; timestamp: string; verdict: Verdict; reference: string; line: number };
type Locator = { reference: string; file: string; offset?: number; bytes?: number };
const sha = (x: string | Buffer) => createHash('sha256').update(x).digest('hex');
const check = (ok: unknown, message: string): void => { if (!ok) throw new Error(message); };
const quote = (x: string) => JSON.stringify(x).replaceAll('<', '\\u003c');
function read(file: string, cap: number, offset = 0, bytes?: number) {
  const fd = openSync(file, 'r');
  try {
    const s = fstatSync(fd), length = bytes ?? s.size;
    check(s.isFile() && Number.isSafeInteger(offset) && offset >= 0 && Number.isSafeInteger(length) && length >= 0 && length <= cap && offset + length <= s.size,
      `source is not a bounded regular file/window: ${file}`);
    const b = Buffer.alloc(length);
    let at = 0;
    while (at < length) {
      const n = readSync(fd, b, at, length - at, offset + at);
      check(n > 0, `source changed during read: ${file}`); at += n;
    }
    return b;
  } finally { closeSync(fd); }
}
function utc(value: string) {
  check(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?Z$/.test(value), `expected ISO8601 UTC: ${value}`);
  const n = Date.parse(value);
  check(Number.isFinite(n) && new Date(n).toISOString().slice(0, 19) === value.slice(0, 19), `invalid UTC date: ${value}`);
  return n;
}
function registryRows(text: string): Rule[] {
  const rules: Rule[] = [];
  let table = false;
  text.split('\n').forEach((line, i) => {
    if (/^\|\s*id\s*\|\s*rule\s*\|\s*observable signature.*\|\s*what it cannot show\s*\|\s*$/i.test(line)) { table = true; return; }
    if (!table) return;
    if (!line.trim()) { table = false; return; }
    check(line.startsWith('|'), `registry finding at line ${i + 1}: expected a rule table row`);
    if (/^\|[-\s:|]+\|$/.test(line)) return;
    const fields = line.split(/(?<!\\)\|/).slice(1, -1).map(s => s.trim().replaceAll('\\|', '|'));
    check(fields.length === 4 && fields.every(Boolean), `registry finding at line ${i + 1}: expected four nonempty columns`);
    const id = /^`([a-zA-Z0-9_:\-]+)`$/.exec(fields[0])?.[1];
    check(id && !rules.some(r => r.id === id), `registry finding at line ${i + 1}: invalid or duplicate rule id`);
    rules.push({id: id!, rule: fields[1], signature: fields[2], limit: fields[3], line: i + 1});
  });
  check(rules.length > 0, 'registry finding: no parseable rules table');
  return rules;
}

export function conformance(options: Record<string, string>, week?: { since: string; until: string }) {
  const generated = new Date();
  // One captured clock value defines the rolling week and a genuine run stamp.
  const until = week?.until || options.until || new Date(generated.getTime() + 1).toISOString();
  const since = week?.since || options.since || new Date(utc(until) - 7 * 86400000).toISOString();
  const start = utc(since), end = utc(until);
  check(start < end, 'conformance window must have since < until');
  const directory = resolve(options['conformance-dir'] || join(process.env.FM_HOME || process.cwd(), 'data/rule-conformance'));
  const registry = realpathSync(join(directory, 'registry.md')), log = realpathSync(join(directory, 'conformance.log'));
  const registryBytes = read(registry, 1048576), logBytes = read(log, 16777216);
  const rules = registryRows(registryBytes.toString('utf8'));
  const rows: Row[] = [];
  let excluded = 0;
  logBytes.toString('utf8').split('\n').forEach((line, i) => {
    if (!line.trim() || line.trimStart().startsWith('#')) return;
    const fields = line.split('|').map(s => s.trim());
    check(fields.length === 4 && fields.every(Boolean), `log finding at line ${i + 1}: expected four fields`);
    const [rule, timestamp, verdict, reference] = fields;
    check(rules.some(r => r.id === rule), `log finding at line ${i + 1}: unknown rule ${rule}`);
    check(verdicts.includes(verdict as Verdict), `log finding at line ${i + 1}: unknown verdict ${verdict}`);
    const time = utc(timestamp);
    if (time < start || time >= end) { excluded++; return; }
    rows.push({rule, timestamp, verdict: verdict as Verdict, reference, line: i + 1});
  });
  // Read only the collector's explicit map, never search endpoint namespaces.
  const notesFile = join(directory, 'conformance-notes.md');
  const notes = existsSync(notesFile) ? read(notesFile, 4194304).toString('utf8').split('\n') : [];
  const mappings = new Map<string, string>(), reasons = new Map<string, string>();
  for (const line of notes) {
    const fields = line.split(' | ');
    if (fields.length === 2) mappings.set(fields[0], fields[1]);
    if (fields.length === 3) reasons.set(fields[0] + '\0' + fields[1], fields[2]);
  }
  const locators: Locator[] = options.citations ? JSON.parse(read(options.citations, 1048576).toString('utf8')) : [];
  check(Array.isArray(locators) && locators.length <= 1000, '--citations must contain at most 1000 explicit source locators');
  for (const l of locators) check(l && typeof l.reference === 'string' && typeof l.file === 'string', 'invalid citation locator');
  function sources(reference: string) {
    const citations: string[] = [], gaps: string[] = [];
    function fileCitation(file: string, offset = 0, bytes?: number, expected?: string, identity?: string) {
      try {
        const path = realpathSync(file), b = read(path, 4194304, offset, bytes), hash = sha(b);
        check(!expected || expected === hash, `content digest changed: ${path}`);
        check(!identity || identity === sha(path), `path digest mismatch: ${path}`);
        citations.push(`${quote(path)}; bytes [${offset}, ${offset + b.length}); sha256=${hash}`);
      } catch (e) { gaps.push(String(e)); }
    }
    for (const l of locators.filter(l => l.reference === reference)) {
      const before = citations.length;
      fileCitation(l.file, l.offset, l.bytes);
      if (citations.length > before) citations[citations.length - 1] += '; caller-supplied association (not independently established by the opaque reference)';
    }
    for (const ref of reference.split('+')) {
      const base = ref.replace(/:record=\d+$/, '');
      const detail = mappings.get(ref) || mappings.get(base);
      const file = detail && /(?:^|; )path=("(?:\\.|[^"\\])*")/.exec(detail)?.[1];
      const git = /^git:sha256:([a-f0-9]{64}):commit=([a-f0-9]{40,64})$/.exec(ref);
      const legacyGit = /^(?:git show )([a-f0-9]{40,64})(?:\s|$)/.exec(ref);
      if (git || legacyGit) {
        const repoText = detail && /^repo=("(?:\\.|[^"\\])*")/.exec(detail)?.[1];
        const repo = repoText ? JSON.parse(repoText) : options.repo;
        if (!repo) { gaps.push('Git repository not supplied; reference identifies no reachable checkout'); continue; }
        try {
          const path = realpathSync(repo), commit = git?.[2] || legacyGit![1];
          check(!git || sha(path) === git[1], 'Git repo-path digest mismatch (not a content hash)');
          const r = spawnSync('git', ['-C', path, 'show', '-s', '--format=%B', commit, '--'],
            {encoding: 'buffer', timeout: 15000, maxBuffer: 4194304, env: {...process.env, GIT_OPTIONAL_LOCKS: '0', GIT_TERMINAL_PROMPT: '0'}});
          check(!r.error && r.status === 0, `Git commit unavailable: ${commit}`);
          citations.push(`git repo=${quote(path)}; commit=${commit}; command=git show -s --format=%B; message-sha256=${sha(r.stdout)}`);
        } catch (e) { gaps.push(String(e)); }
      } else if (file) {
        const path = JSON.parse(file);
        const transcript = /^transcript:sha256:([a-f0-9]{64}):offset=(\d+):bytes=(\d+):sha256=([a-f0-9]{64})$/.exec(base);
        const artifact = /^artifact:sha256:([a-f0-9]{64}):([a-f0-9]{64})$/.exec(base);
        const reg = /^registry:sha256:([a-f0-9]{64})$/.exec(base);
        if (transcript) fileCitation(path, Number(transcript[2]), Number(transcript[3]), transcript[4], transcript[1]);
        else if (artifact) fileCitation(path, 0, undefined, artifact[2], artifact[1]);
        else if (reg) fileCitation(path, 0, undefined, reg[1]);
        else gaps.push(`Unrecognized source binding: ${ref}`);
      } else if (ref.startsWith('/')) fileCitation(ref);
    }
    return {citations: [...new Set(citations)], gaps};
  }
  const perRule = rules.map(rule => {
    const selected = rows.filter(row => row.rule === rule.id);
    const counts = Object.fromEntries(verdicts.map(v => [v, selected.filter(row => row.verdict === v).length]));
    const noSignature = /`no-signature`/.test(rule.signature);
    const findings = selected.filter(row => row.verdict === 'violate' || row.verdict === 'miss').map(row => ({...row, ...sources(row.reference)}));
    const unobservable = selected.filter(row => row.verdict === 'no-signature').map(row => ({line: row.line, reference: row.reference,
      reason: reasons.get(rule.id + '\0' + row.reference) || (noSignature ? rule.signature : 'Reason unavailable in collector notes; row is no-signature, never a successful check.')}));
    return {...rule, status: noSignature ? 'no-signature' : selected.length ? 'observations-only' : 'no-observations', counts, findings, unobservable};
  });
  // A window marker is coverage, never a fabricated execution time. Historical
  // runs retain the actual generated_at alongside this in-window observation.
  const windowTimestamp = rows.length ? rows.reduce((a, b) => utc(a.timestamp) > utc(b.timestamp) ? a : b).timestamp : since;
  const result = {version: 1, kind: 'weekly-rule-conformance', generated_at: generated.toISOString(),
    window: {since, until, timestamp: windowTimestamp}, rows: rows.length, excluded,
    inputs: {registry: {path: registry, sha256: sha(registryBytes)}, log: {path: log, sha256: sha(logBytes)}}, rules: perRule};
  let markdown = `# Weekly rule conformance\n\nGenerated ${result.generated_at}.\nWindow: [${since}, ${until}), UTC derivation times.\nWindow timestamp: ${windowTimestamp} (latest included observation, or window start when empty; not execution time).\n${rows.length} rows included; ${excluded} outside the window.\nCounts are observations, never a safety score; missing observations do not prove compliance.\nProposals only; no rule edits, gates, scheduling, or enforcement.\nAny change requires the captain's explicit word.\nRegistry: ${quote(registry)}; sha256=${sha(registryBytes)}.\nLog: ${quote(log)}; sha256=${sha(logBytes)}.\n\n`;
  for (const rule of perRule) {
    markdown += `## ${rule.id}\n\n${rule.rule}\nStatus: ${rule.status}.\nCounts: ${verdicts.map(v => `${v}=${rule.counts[v]}`).join('; ')}.\nWhat it cannot show: ${rule.limit}\nRegistry citation: ${quote(registry)}:${rule.line}.\n`;
    if (rule.status === 'no-signature') markdown += `No-signature reason: ${rule.signature}\nZero observed violations is not a measurable compliance result for this rule.\n`;
    for (const row of rule.unobservable) markdown += `No-signature observation: ${quote(log)}:${row.line}; reference=${quote(row.reference)}; reason=${row.reason}\n`;
    for (const finding of rule.findings) {
      markdown += `\n- ${finding.verdict} at ${finding.timestamp}.\n  Citation 1: ${quote(log)}:${finding.line}; source reference=${quote(finding.reference)}.\n`;
      finding.citations.forEach((citation, i) => { markdown += `  Citation ${i + 2}: ${citation}.\n`; });
      if (!finding.citations.length) markdown += '  Single source only: the log row/reference; no second reachable source in the supplied locators or collector map.\n';
      for (const gap of finding.gaps) markdown += `  Source gap: ${gap}\n`;
    }
    markdown += '\n';
  }
  return {result, markdown};
}
