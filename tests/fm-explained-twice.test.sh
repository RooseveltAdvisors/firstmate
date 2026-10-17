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
import {mkdirSync, writeFileSync, readFileSync, existsSync, symlinkSync, linkSync} from 'node:fs';
import {join} from 'node:path';
const root = process.env.DETECTOR_TEST_ROOT;
const script = process.env.DETECTOR;
const data = join(root, 'data', 'review');
mkdirSync(data, {recursive: true});
const check = (ok, message) => { if (!ok) throw new Error(message); };
function run(args, good = true) {
  const r = Bun.spawnSync(['bash', script, ...args], {stdout: 'pipe', stderr: 'pipe'});
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
run(scan);
check(JSON.parse(readFileSync(corpusPath)).events.length === corpus.events.length, 'overlapping scans must deduplicate');
const find = text => corpus.events.find(e => e.text.includes(text));
const evidence = (text, speaker, kind, thread) => ({event: find(text).id, quote: text, speaker, kind, thread,
  reason: speaker === 'captain' ? `Fixture direct human message; classified as ${kind} using fixture context.` : 'Fixture lane/transport message, not a direct captain correction.'});
const refs = [['a', ['order-a', 'order-a-checkin2']], ['b', ['order-b']], ['ops', ['ops']], ['ask1', ['ask-a']], ['ask2', ['ask-b']], ['fwd', ['forwarded']]];
const review = {version: 1, reviewer: 'fixture semantic reviewer', threads: refs.map(([id, refs]) => ({id, refs, reason: 'Fixture task and counterparty identity.'})),
  groups: []};
const group = (id, evidence, edit = null) => ({id, title: id, target: 'AGENTS.md', edit,
  whyOwner: 'Fixture session-wide station invariant.', whyNotNeighbour: 'Not a merge procedure.', evidence});
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
console.log('bounded extraction, attribution, alias counting, quotes, source integrity and proposal-only output: pass');
JS
pass 'live-correction review through public CLI'
