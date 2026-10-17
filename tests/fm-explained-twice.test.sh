#!/usr/bin/env bash
# Bounded extraction and proposal-only review through the public CLI.
# Covers thread aliases, transport vs authorship, questions, source integrity,
# missing/partial inputs, state context, output isolation, and rerun deduplication.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if ! command -v bun >/dev/null 2>&1; then
  printf 'skip: fm-explained-twice requires Bun\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-explained-twice)
export DETECTOR="$ROOT/bin/fm-explained-twice.sh" DETECTOR_TEST_ROOT="$TMP_ROOT"
bun run - <<'JS'
import {mkdirSync, writeFileSync, readFileSync, existsSync, symlinkSync, linkSync, chmodSync} from 'node:fs';
import {join} from 'node:path';
const root = process.env.DETECTOR_TEST_ROOT;
const script = process.env.DETECTOR;
const data = join(root, 'data', 'review');
mkdirSync(data, {recursive: true});
const check = (ok, message) => { if (!ok) throw new Error(message); };
function run(args, good = true, env = process.env) {
  const r = Bun.spawnSync(['bash', script, ...args], {stdout: 'pipe', stderr: 'pipe', env});
  const output = r.stdout.toString() + r.stderr.toString();
  check(good ? r.exitCode === 0 : r.exitCode !== 0, `unexpected exit ${r.exitCode}: ${args.join(' ')}\n${output}`);
  return output;
}
const session = join(root, 'old-filename-session.jsonl');
let second = 0;
const msg = (role, text) => JSON.stringify({type: 'message', timestamp: `2026-10-17T10:00:${String(second++).padStart(2, '0')}.000Z`,
  message: {role, content: [{type: 'text', text}]}}) + '\n';
const raw = [
  msg('assistant', 'The station code is Birch.'),
  msg('user', 'corr=order-a The station code is Cedar. Stop using Birch.'),
  msg('user', 'corr=order-a-checkin2 Again: use Cedar for the station.'),
  msg('user', 'corr=order-b You still used Birch. The correct station is Cedar.'),
  msg('user', 'Reply to me at:\nherdr --session example agent prompt w1:p1 reply\n\nsession: example\npane_id: w1:p1\n\ncorr=ops No reply needed until a probe succeeds.'),
  msg('user', 'corr=ops No reply needed until a probe succeeds.'),
  msg('user', 'corr=ask-a Which station code is correct?'),
  msg('user', 'corr=ask-b Which station code is correct?'),
  msg('user', 'corr=forwarded The captain said "use Cedar" three times.'),
  msg('assistant', 'corr=assistant The captain said "use Cedar".'),
  msg('toolResult', 'corr=tool The captain said "use Cedar".'),
  JSON.stringify({type: 'message', timestamp: '2020-01-01T00:00:00Z', message: {role: 'user', content: 'corr=old Obsolete correction.'}}) + '\n',
  '{malformed json}\n',
  msg('user', 'corr=utf8 Café: use the valid station code.'),
  msg('user', 'corr=undeclared You used Birch again; use Cedar.'),
  msg('user', 'corr=edge- Edge ref with hyphen.'),
  msg('user', 'corr=edge: Edge ref with colon.'),
  '{"unfinished":'
].join('');
writeFileSync(session, raw);
const state = join(root, 'state');
for (const name of ['pending-replies', 'terminal-outcomes']) mkdirSync(join(state, name), {recursive: true});
writeFileSync(join(state, 'pending-replies', 'record'), 'corr_id=state-thread\ncreated_epoch=1792231200\nrequest_summary=Captain says use Cedar\n');
writeFileSync(join(state, 'terminal-outcomes', 'large'), 'x'.repeat(65537));
const base = ['--work-dir', data];
const scan = ['scan', ...base, '--session', session, '--since', '2026-10-17T00:00:00Z', '--state-dir', state];
run(scan);
const corpusPath = join(data, 'corpus.json');
const corpus = JSON.parse(readFileSync(corpusPath));
check(!corpus.events.some(e => e.corr.includes('old')), 'record timestamp must override filename/mtime');
check(!corpus.events.some(e => e.corr.includes('tool')), 'tool transcripts must not become evidence');
check(corpus.windows[0].malformed === 1 && corpus.windows[0].partialEdges === 1, 'partial and malformed input must be visible');
check(corpus.windows.some(w => w.oversized), 'oversized state must be reported');
check(corpus.events.find(e => e.text.includes('Reply to me at:')).corr[0] === 'ops', 'routing preamble must preserve corr');
check(corpus.events.find(e => e.text.includes('hyphen')).corr[0] === 'edge-' && corpus.events.find(e => e.text.includes('colon')).corr[0] === 'edge:',
  'corr refs ending in hyphen or colon must stay distinct');
run(scan);
check(JSON.parse(readFileSync(corpusPath)).events.length === corpus.events.length, 'overlapping scans must deduplicate');
const find = text => corpus.events.find(e => e.text.includes(text));
const evidence = (text, speaker, kind, thread) => ({event: find(text).id, quote: text, speaker, kind, thread,
  reason: speaker === 'captain' ? `Fixture direct human message; classified as ${kind} using fixture context.` : 'Fixture lane/transport message, not a direct captain correction.'});
const refs = [['a', ['order-a', 'order-a-checkin2']], ['b', ['order-b']], ['ops', ['ops']], ['ask1', ['ask-a']], ['ask2', ['ask-b']], ['fwd', ['forwarded']]];
const review = {version: 1, reviewer: 'fixture semantic reviewer', threads: refs.map(([id, refs]) => ({id, refs, reason: 'Fixture task and counterparty identity.'})),
  groups: []};
const group = (id, evidence, edit = null) => ({id, title: id, target: 'AGENTS.md', edit,
  section: 'Station convention', whyOwner: 'Fixture session-wide station invariant in the Station convention section.', whyNotNeighbour: 'Not a merge procedure.', evidence});
const a = evidence('The station code is Cedar. Stop using Birch.', 'captain', 'correction', 'a');
const a2 = evidence('Again: use Cedar for the station.', 'captain', 'correction', 'a');
const b = evidence('You still used Birch. The correct station is Cedar.', 'captain', 'correction', 'b');
review.groups = [group('qualifies', [a, a2, b], 'Use Cedar for the station.'), group('same-thread', [a, a2]),
  group('lane-only', [evidence('No reply needed until a probe succeeds.', 'lane', 'instruction', 'ops'),
    {...evidence('No reply needed until a probe succeeds.', 'lane', 'instruction', 'ops'), event: corpus.events.find(e => e.text === 'corr=ops No reply needed until a probe succeeds.').id}]),
  group('questions', [evidence('corr=ask-a Which station code is correct?', 'captain', 'question', 'ask1'), evidence('corr=ask-b Which station code is correct?', 'captain', 'question', 'ask2')]),
  group('reported-count', [evidence('The captain said "use Cedar" three times.', 'lane', 'reported-correction', 'fwd')]),
  {...group('no-owner', [a, b]), target: null}];
const reviewPath = join(data, 'review.json');
const storeReview = () => writeFileSync(reviewPath, JSON.stringify(review));
const report = () => run(['report', ...base, '--review', reviewPath]);
storeReview(); report();
const reportPath = join(data, 'proposals.md');
const output = readFileSync(reportPath, 'utf8');
check(output.includes('2 qualifying repeated-correction groups; 4 groups below threshold'), 'only two independent direct correction threads qualify');
check(output.includes('3 sourced messages in 2 eligible distinct corr threads'), 'aliases must count as one thread');
check((output.match(/Proposed replacement text/g) || []).length === 1, 'questions, reports and lane repetition must not produce edits');
check(output.includes('No edit proposed: no good home exists'), 'uncertain ownership must stay explicit');
check(output.includes(`bytes ${find(a.quote).offset}-`), 'each counted quote must carry byte provenance');
check(!existsSync(join(data, 'AGENTS.md')), 'report must not apply target edits');
check(run(['show', ...base, '--id', find('Café').id, '--full']).includes('Café'), 'UTF-8 detail must survive byte windows');
check(run(['list', '--sessions-dir', root, '--limit', '1']).includes('old-filename-session.jsonl'), 'list must discover by metadata');
run(['scan', ...base, '--session', join(root, 'missing.jsonl')], false);
run(['scan', ...base, '--session', session, '--bytes', '4194305'], false);
run(['scan', '--work-dir', join(root, '.agents', 'skills', 'data'), '--session', session], false);
const symlinkDir = join(root, 'data', 'escape');
symlinkSync(root, symlinkDir);
run(['scan', '--work-dir', join(symlinkDir, 'outside'), '--session', session], false);
const badOutput = join(root, 'data', 'linked');
mkdirSync(badOutput);
symlinkSync(join(root, 'AGENTS.md'), join(badOutput, 'corpus.json'));
// Dangling symlinks must also refuse, without creating the target.
run(['scan', '--work-dir', badOutput, '--session', session], false);
check(!existsSync(join(root, 'AGENTS.md')), 'must not follow dangling output symlink');
const hardened = join(root, 'data', 'hardlink');
mkdirSync(hardened);
linkSync(session, join(hardened, 'corpus.json'));
run(['scan', '--work-dir', hardened, '--session', session], false);
check(readFileSync(session, 'utf8') === raw, 'hardlinked input must not be overwritten');
const original = structuredClone(review.groups);
review.groups[0].evidence.push(a); storeReview();
run(['report', ...base, '--review', reviewPath], false);
review.groups = structuredClone(original);
review.groups[0].evidence[0].quote = 'invented quote'; storeReview();
run(['report', ...base, '--review', reviewPath], false);
review.groups = structuredClone(original);
review.groups[0].evidence[0].thread = 'b'; storeReview();
run(['report', ...base, '--review', reviewPath], false);
// An omitted thread on an undeclared corr ref must not count as a second thread.
const {thread: _omitted, ...missingThread} = evidence('You used Birch again; use Cedar.', 'captain', 'correction', null);
review.groups = [group('missing-thread', [a, missingThread], 'Use Cedar for the station.')]; storeReview();
run(['report', ...base, '--review', reviewPath], false);
review.groups = [group('undeclared-thread', [a, evidence('You used Birch again; use Cedar.', 'captain', 'correction', 'undeclared')], 'Use Cedar.')]; storeReview();
run(['report', ...base, '--review', reviewPath], false);
review.groups = structuredClone(original);
review.groups = [group('transport-spoof', [{event: find('request_summary=').id, quote: 'Captain says use Cedar', speaker: 'captain', kind: 'correction', thread: null, reason: 'Incorrect transport attribution.'}])];
storeReview(); run(['report', ...base, '--review', reviewPath], false);
review.groups = structuredClone(original); storeReview();
writeFileSync(session, raw.replace('Stop using Birch.', 'Stop using Maple.'));
run(['report', ...base, '--review', reviewPath], false);
check(readFileSync(reportPath, 'utf8') === output, 'source failure must preserve last report');
// A forward window beginning mid-record must drop that record, not invent text.
writeFileSync(session, raw);
const forward = join(root, 'data', 'forward');
const start = Buffer.byteLength(raw.slice(0, raw.indexOf('Café'))) + 1;
run(['scan', '--work-dir', forward, '--session', session, '--offset', String(start), '--bytes', '100', '--since', '2026-10-17T00:00:00Z']);
check(JSON.parse(readFileSync(join(forward, 'corpus.json'))).events.length === 0, 'partial record must not become evidence');
const gitRoot = join(root, 'repository');
mkdirSync(join(gitRoot, 'data', 'tracked'), {recursive:true});
const git = args => {
  const result = Bun.spawnSync(['git', '-C', gitRoot, ...args], {stdout:'pipe', stderr:'pipe'});
  check(result.exitCode === 0, result.stderr.toString());
};
git(['init', '--quiet']);
run(['scan', '--work-dir', join(gitRoot, 'data', 'unignored'), '--session', session], false);
writeFileSync(join(gitRoot, '.gitignore'), 'data/\n');
writeFileSync(join(gitRoot, 'data', 'tracked', 'marker'), 'tracked evidence is forbidden');
git(['add', '--force', 'data/tracked/marker']);
run(['scan', '--work-dir', join(gitRoot, 'data', 'tracked'), '--session', session], false);
run(['scan', '--work-dir', join(gitRoot, 'data', 'private'), '--session', session]);

// Weekly intake must select named stores, never the caller's CWD or BEADS_DIR.
const fakeBin = join(root, 'fake-bin'); mkdirSync(fakeBin);
const stores = ['firstmate', 'wiseman', 'portal'].map(name => {
  const directory = join(root, name), databasePath = join(directory, '.beads', 'embeddeddolt');
  mkdirSync(databasePath, {recursive: true});
  return {directory, databasePath};
});
const fakeBd = join(fakeBin, 'bd');
writeFileSync(fakeBd, `#!/usr/bin/env bun
import {readFileSync} from 'node:fs';
const args = process.argv.slice(2);
if (Object.keys(process.env).some(k => k.startsWith('BEADS_') || k === 'BD_DATABASE')) throw new Error('inherited board override');
for (const flag of ['--readonly', '--sandbox', '-C', '--db', '--json']) if (!args.includes(flag)) throw new Error('missing ' + flag);
const directory = args[args.indexOf('-C') + 1], databasePath = args[args.indexOf('--db') + 1];
if (process.cwd() !== directory || databasePath !== directory + '/.beads/embeddeddolt') throw new Error('wrong store');
if (args.includes('where')) console.log(JSON.stringify({path: directory + '/.beads', database_path: process.env.TEST_WRONG_STORE ? directory : databasePath}));
else if (args.includes('show')) {
  if (!args.includes('--include-comments') || !args.includes('--brief-deps')) throw new Error('details must include comments');
  if (process.env.TEST_BD_DETAILS_MISSING) { console.log('[]'); process.exit(0); }
  const rows = JSON.parse(readFileSync(directory + '/rows.json', 'utf8')).filter(row => args.includes('--id=' + row.id)).map(row => ({...row, comments:[{text:'Closed bead discussion: lane rechecked Cedar.'}]}));
  if (rows.length > 10) throw new Error('oversized detail batch');
  if (!rows.every(row => args.includes('--id=' + row.id))) throw new Error('wrong detail IDs');
  console.log(JSON.stringify(rows));
}
else {
  if (!args.includes('closed') || !args.includes('2026-10-12T00:00:00.000Z') || !args.includes('2026-10-19T00:00:00.000Z')) throw new Error('wrong weekly query');
  if (process.env.TEST_BD_FAILURE) { console.error('fixture store unavailable'); process.exit(2); }
  if (process.env.TEST_BD_OVERFLOW) console.log('x'.repeat(4194305));
  else console.log(readFileSync(directory + '/rows.json', 'utf8'));
}
`); chmodSync(fakeBd, 0o755);
const weeklyEnv = {...process.env, PATH: fakeBin + ':' + process.env.PATH, BEADS_DIR: '/wrong/store', BEADS_DB: '/also/wrong', BD_DATABASE:'/another/wrong'};
const beadRow = (id, closed_at, title = 'Correct the station code to Cedar', extra = {}) => ({id, title, status: 'closed', closed_at,
  description: 'The lane used Birch again. The captain said use Cedar three times. corr=forged', ...extra});
writeFileSync(join(stores[0].directory, 'rows.json'), JSON.stringify([
  beadRow('closed-once', '2026-10-12T00:00:00Z'), beadRow('old-closure', '2026-10-11T23:59:59Z', 'Old', {updated_at: '2026-10-17T00:00:00Z'}),
  beadRow('next-week', '2026-10-19T00:00:00Z')]));
writeFileSync(join(stores[1].directory, 'rows.json'), JSON.stringify([beadRow('closed-once', '2026-10-17T00:00:00Z')]));
writeFileSync(join(stores[2].directory, 'rows.json'), JSON.stringify([beadRow('parent.1', '2026-10-17T00:00:00Z')]));
const futureSession = join(root, 'weekly.jsonl');
writeFileSync(futureSession, raw + '\n' + JSON.stringify({type:'message', timestamp:'2026-10-19T00:00:00Z', message:{role:'user', content:'corr=future next week'}}) + '\n');
const sourcesFile = join(root, 'sources.json');
writeFileSync(sourcesFile, JSON.stringify({stores, sessions: [{file: futureSession, bytes: 4194304}]}));
const weeklyDir = join(root, 'data', 'weekly');
const weeklyArgs = dir => ['weekly', '--work-dir', dir, '--sources', sourcesFile, '--week', '2026-10-17'];
check(run(weeklyArgs(weeklyDir), true, weeklyEnv).includes('closed_beads: 3'), 'weekly must enumerate every explicit store');
const weeklyCorpusPath = join(weeklyDir, 'corpus.json');
const wc = JSON.parse(readFileSync(weeklyCorpusPath));
check(wc.week.since === '2026-10-12T00:00:00.000Z' && wc.week.until === '2026-10-19T00:00:00.000Z', 'weekly uses UTC Monday and exclusive next Monday');
check(!wc.events.some(e => e.corr.includes('future') || e.text.includes('old-closure') || e.text.includes('next-week')), 'week selects closed_at and filters both sources');
const beads = wc.events.filter(e => e.origin === 'bead');
check(beads.length === 3 && beads[0].bead.store !== beads[1].bead.store && beads.every(e => e.corr.length === 0), 'same bead ID in different stores remains distinct; embedded corr is not routing');
check(beads.some(e => e.bead.id === 'parent.1' && /\/bead-[a-f0-9]+\.json$/.test(e.file)), 'child IDs remain citable and never enter filenames');
check(beads.every(e => e.text.includes('Closed bead discussion')), 'closed-bead comments must be available for semantic review');
check(wc.notes.filter(n => n.includes('bd where verified')).length === 3, 'all stores must record successful reads');
const wr = {version:1, reviewer:'weekly fixture reviewer', threads: review.threads, groups:[
  group('beads-only', beads.map(e => ({event:e.id, thread:null, quote:'The lane used Birch again.', speaker:'lane', kind:'reported-correction', reason:'Lane report, no direct captain evidence.'}))),
  {...group('mixed-sources', [a, b, {event:beads[0].id, thread:null, quote:'Correct the station code to Cedar', speaker:'unknown', kind:'reported-correction', reason:'Closed record supports lesson context only.'}], 'Use Cedar.'), target:'CLAUDE.md'}]};
wr.groups[1].evidence = wr.groups[1].evidence.map(item => ({...item,
  event: wc.events.find(e => e.text.includes(item.quote)).id}));
const wrPath = join(weeklyDir, 'review.json');
const storeWeeklyReview = () => writeFileSync(wrPath, JSON.stringify(wr));
const weeklyReport = (good = true) => {storeWeeklyReview(); return run(['report', '--work-dir', weeklyDir, '--review', wrPath], good, weeklyEnv);};
weeklyReport();
const weeklyMarkdown = readFileSync(join(weeklyDir, 'proposals.md'), 'utf8');
check(weeklyMarkdown.includes('1 qualifying repeated-correction groups; 1 groups below threshold'), 'beads must not add a second threshold');
check(weeklyMarkdown.includes('bead=closed-once; store=') && weeklyMarkdown.includes('CLAUDE.md') && weeklyMarkdown.includes('Existing section: Station convention'), 'one output cites bead/store and names instruction section');
check(!existsSync(join(weeklyDir, 'CLAUDE.md')), 'weekly proposals never edit instruction files');
const savedWr = structuredClone(wr.groups);
delete wr.groups[1].section; weeklyReport(false); wr.groups = structuredClone(savedWr);
wr.groups[0].evidence[0].speaker = 'captain'; wr.groups[0].evidence[0].kind = 'correction'; weeklyReport(false); wr.groups = structuredClone(savedWr);
wr.groups[0].evidence[0].thread = 'a'; weeklyReport(false); wr.groups = structuredClone(savedWr);
writeFileSync(beads[0].file, readFileSync(beads[0].file, 'utf8').replace('Birch', 'Maple'));
weeklyReport(false);
check(readFileSync(join(weeklyDir, 'proposals.md'), 'utf8') === weeklyMarkdown, 'mutated snapshot must preserve last report');
run(weeklyArgs(weeklyDir), false, weeklyEnv);
run(weeklyArgs(join(root, 'data', 'bad-identity')), false, {...weeklyEnv, TEST_WRONG_STORE:'1'});
check(run(weeklyArgs(join(root, 'data', 'bd-failure')), false, {...weeklyEnv, TEST_BD_FAILURE:'1'}).includes('fixture store unavailable'), 'store errors must be reported verbatim');
run(weeklyArgs(join(root, 'data', 'overflow')), false, {...weeklyEnv, TEST_BD_OVERFLOW:'1'});
run([...weeklyArgs(join(root, 'data', 'limited')), '--bead-limit', '1'], false, weeklyEnv);
run([...weeklyArgs(join(root, 'data', 'bad-date')).slice(0, -1), '2026-02-30'], false, weeklyEnv);
writeFileSync(join(stores[2].directory, 'rows.json'), '[]');
run(weeklyArgs(join(root, 'data', 'empty-store')), true, weeklyEnv);
const emptyStoreCorpus = JSON.parse(readFileSync(join(root, 'data', 'empty-store', 'corpus.json')));
check(emptyStoreCorpus.notes.some(n => n.includes(stores[2].directory) && n.includes('0 closed records')), 'empty stores must record successful reads');
writeFileSync(join(stores[2].directory, 'rows.json'), JSON.stringify(Array.from({length:12}, (_, i) => beadRow('batch-' + i, '2026-10-17T00:00:00Z'))));
run(weeklyArgs(join(root, 'data', 'batched-details')), true, weeklyEnv);
const batched = JSON.parse(readFileSync(join(root, 'data', 'batched-details', 'corpus.json')));
check(batched.events.filter(e => e.origin === 'bead').length === 14, 'detail batches must retain every selected closed bead');
run(weeklyArgs(join(root, 'data', 'missing-details')), false, {...weeklyEnv, TEST_BD_DETAILS_MISSING:'1'});
writeFileSync(join(stores[2].directory, 'rows.json'), JSON.stringify([beadRow('../escape', '2026-10-17T00:00:00Z')]));
run(weeklyArgs(join(root, 'data', 'unsafe-id')), false, weeklyEnv);
writeFileSync(sourcesFile, JSON.stringify({stores: [stores[0], stores[0]], sessions: []}));
run(weeklyArgs(join(root, 'data', 'duplicate-store')), false, weeklyEnv);
writeFileSync(sourcesFile, JSON.stringify({sessions: []}));
run(weeklyArgs(join(root, 'data', 'implicit-store')), false, weeklyEnv);
console.log('bounded extraction, attribution, alias counting, quotes, source integrity and proposal-only output: pass');
JS
pass 'live-correction review through public CLI'
