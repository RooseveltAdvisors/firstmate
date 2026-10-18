#!/usr/bin/env bash
# Public CLI regression: independent native artifacts, conservative gaps,
# byte-bounded transcripts, private append-only rows, idempotence and locking.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if ! command -v bun >/dev/null 2>&1; then
  printf 'skip: rule conformance requires Bun\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-rule-conformance)
export TMP_ROOT ROOT
bun - <<'TS'
import { strict as assert } from 'node:assert';
import { mkdirSync, readFileSync, writeFileSync, appendFileSync, symlinkSync, linkSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root = process.env.ROOT!, tmp = process.env.TMP_ROOT!;
const script = join(root, 'bin/fm-rule-conformance.sh');
function exec(cmd: string[], cwd?: string, env = process.env) {
  // Fixture commits intentionally contain synthetic agent trailers. Override
  // only their hooksPath: fleet commit hooks must remain active for real work.
  if (cmd[0] === 'git' && cmd[1] === 'commit') cmd.splice(1, 0, '-c', 'core.hooksPath=/dev/null');
  const r = spawnSync(cmd[0], cmd.slice(1), {cwd, env, encoding:'utf8'});
  assert.equal(r.status, 0, `${cmd[0]}: ${r.stdout}\n${r.stderr}`); return r.stdout;
}
const registry = join(tmp, 'registry.md');
const ids = ['search-before-ask','ui-done-gate','watchdog','auto-bead','explained-twice','timestamped-heads','disclose-not-rewrite','strip-at-merge','no-waiver-merges','green-claims','current-head-recount','two-attempt-cap','refusal-verbatim','no-hand-edit-enforcement','fail-before-pass-after','stop-at-safety-boundary','no-phi-in-receipts','one-worktree','first-step-first','report-standards','never-bypass-a-refusal'];
writeFileSync(registry, ids.map(id => `| \`${id}\` | fixture signature |`).join('\n'));
const repo = join(tmp,'repo'); mkdirSync(repo);
exec(['git','init','-q'],repo); exec(['git','config','user.name','Fixture'],repo); exec(['git','config','user.email','fixture@example.invalid'],repo);
writeFileSync(join(repo,'control'),'base'); exec(['git','add','.'],repo); exec(['git','commit','-qm','Clean merge'],repo);
const clean = exec(['git','rev-parse','HEAD'],repo).trim();
writeFileSync(join(repo,'control'),'agent'); exec(['git','add','.'],repo);
exec(['git','commit','-qm','Merge\n\nCo-Authored-By: Claude <noreply@anthropic.com>'],repo);
const agent = exec(['git','rev-parse','HEAD'],repo).trim();
exec(['git','commit','--allow-empty','-qm','Human merge\n\nCo-Authored-By: Human <human@openai.com>'],repo);
const human = exec(['git','rev-parse','HEAD'],repo).trim();
writeFileSync(join(repo,'control'),'dirty');
const meta = join(tmp,'task.meta'); writeFileSync(meta,`worktree=${repo}\n`);
const payload = 'PATIENT_SENTINEL_7729 Provider Sensitive';
const session = join(tmp,'session.jsonl');
const record = (role: string, text: string) => JSON.stringify({type:'message',timestamp:'2026-10-18T10:00:00Z',message:{role,content:[{type:'text',text}]}})+'\n';
writeFileSync(session, record('user', 'captain green '+clean) + record('assistant', 'green '+clean+' '+payload) + record('toolResult','gate refusal '+payload) + 'x'.repeat(500000));
const gate = join(tmp,'gate.jsonl'); writeFileSync(gate,JSON.stringify({timestamp:'2026-10-18T10:00:00Z',decision:'ALLOW',action_class:'merge',target:payload})+'\n');
const checks = join(tmp,'checks.json'); writeFileSync(checks,JSON.stringify({total_count:1,check_runs:[{id:123,head_sha:clean,status:'completed',conclusion:'success',output:{text:payload}}]}));
const run = join(tmp,'run.json'); writeFileSync(run,JSON.stringify({id:33,head_sha:clean,run_attempt:4}));
const local = join(tmp,'timing.json'); writeFileSync(local,JSON.stringify({finished_at:'2026-10-18T09:00:00Z',scripts:[{path:'tests/a.test.sh',exit:1}]}));
const beads = join(tmp,'beads.json'); writeFileSync(beads,JSON.stringify([{id:'bead-1',description:payload}]));
const before = join(tmp,'before.log'), after = join(tmp,'after.log');
writeFileSync(before,'FM_TEST_END 2026-10-18T09:00:00Z tests/a.test.sh exit=1 duration_ms=3 gate_skip=false\n');
writeFileSync(after,'FM_TEST_END 2026-10-18T09:01:00Z tests/a.test.sh exit=0 duration_ms=3 gate_skip=false\n');
const manifest = join(tmp,'manifest.json'), output = join(tmp,'data','collected');
const spec = {transcripts:[{file:session,offset:0,bytes:2048}],gateEvents:[gate],git:[{repo,commits:[clean,agent,human],meta,enforcementPaths:['control']}],runData:[{checks,run}],localLogs:[{file:local,beads,before,after}]};
writeFileSync(manifest,JSON.stringify(spec));
const shape = /^[a-z-]+ \| \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ \| (follow|violate|miss|out-of-scope|no-signature) \| [^|\r\n]+$/;
// Synthetic fixture rows are parser inputs, never observations about the fleet.
// Exercise all five verdicts without requiring any verdict in a live dataset.
mkdirSync(output,{recursive:true});
const synthetic = ['follow','violate','miss','out-of-scope','no-signature'].map((v,i) => `strip-at-merge | 2026-10-18T10:00:00Z | ${v} | fixture:synthetic-${i}\n`).join('');
writeFileSync(join(output,'conformance.log'),synthetic);
for (const line of synthetic.trim().split('\n')) assert.match(line,shape);
// Optional read-only live-data validation asserts only the rows actually present.
// It never demands a violation, success, or any other verdict from reality.
if (process.env.FM_CONFORMANCE_LIVE_LOG) for (const line of readFileSync(process.env.FM_CONFORMANCE_LIVE_LOG,'utf8').split('\n').filter(l=>l.trim()&&!l.startsWith('#'))) {
  assert.match(line.split('|').map(s=>s.trim()).join(' | '),shape);
}
function collect(out = output, m = manifest, env = process.env) { return spawnSync('bash',[script,'--manifest',m,'--output',out,'--registry',registry],{encoding:'utf8',env}); }
let result = collect(); assert.equal(result.status,0,result.stderr);
const log = join(output,'conformance.log'), notes = join(output,'conformance-notes.md');
const text = readFileSync(log,'utf8');
const lines = text.trim().split('\n');
assert(lines.length > 21);
for (const line of lines) assert.match(line,shape);
const has = (rule: string, v: string) => lines.some(l => l.startsWith(rule+' |') && l.includes(' | '+v+' | '));
assert(has('strip-at-merge','follow')); assert(has('strip-at-merge','violate'));
assert(has('two-attempt-cap','violate')); assert(has('no-hand-edit-enforcement','violate'));
assert(has('fail-before-pass-after','follow')); assert(has('ui-done-gate','out-of-scope'));
assert(has('auto-bead','no-signature')); assert(has('no-phi-in-receipts','no-signature'));
for (const id of ids) assert(lines.some(l => l.startsWith(id+' |')),id);
assert(!text.includes(payload)); assert(!text.includes('bead-1')); assert(!readFileSync(notes,'utf8').includes(payload));
assert(text.startsWith(synthetic));
assert(lines.some(l => l.startsWith('strip-at-merge') && l.includes(' | violate | ') && l.endsWith(agent)));
assert(lines.some(l => l.startsWith('strip-at-merge') && l.includes(' | follow | ') && l.endsWith(human)));
assert.match(readFileSync(notes,'utf8'),/bytes=2048/);
const firstNotes = readFileSync(notes,'utf8');
result = collect(); assert.equal(result.status,0,result.stderr); assert.equal(readFileSync(log,'utf8'),text); assert.equal(readFileSync(notes,'utf8'),firstNotes);
// Add a new independent commit. Prior history must remain byte-identical.
exec(['git','add','.'],repo); exec(['git','commit','-qm','Next merge'],repo);
const next = exec(['git','rev-parse','HEAD'],repo).trim();
spec.git[0].commits.push(next); writeFileSync(manifest,JSON.stringify(spec));
result = collect(); assert.equal(result.status,0,result.stderr); assert(readFileSync(log,'utf8').startsWith(text));
// Existing padded seed row shares the same identity and must not be duplicated.
const seedOut = join(tmp,'data','seed'); mkdirSync(seedOut,{recursive:true});
const seed = lines.find(l => l.startsWith('strip-at-merge') && l.endsWith(clean))!;
writeFileSync(join(seedOut,'conformance.log'),seed.replace('strip-at-merge |','strip-at-merge    |')+'\n');
assert.equal(collect(seedOut).status,0);
assert.equal(readFileSync(join(seedOut,'conformance.log'),'utf8').split('\n').filter(l=>l.startsWith('strip-at-merge')&&l.endsWith(clean)).length,1);
// Unterminated history, locks, symlinks and hardlinks are refusals, no repair.
const broken = join(tmp,'data','broken'); mkdirSync(broken,{recursive:true}); writeFileSync(join(broken,'conformance.log'),'seed');
assert.notEqual(collect(broken).status,0); assert.equal(readFileSync(join(broken,'conformance.log'),'utf8'),'seed');
mkdirSync(join(output,'.collector.lock')); assert.notEqual(collect().status,0); assert(readFileSync(log,'utf8').startsWith(text));
const linked = join(tmp,'data','linked'); symlinkSync(seedOut,linked); assert.notEqual(collect(linked).status,0);
const hard = join(tmp,'data','hard'); mkdirSync(hard,{recursive:true}); linkSync(join(seedOut,'conformance.log'),join(hard,'conformance.log')); assert.notEqual(collect(hard).status,0);
assert.notEqual(collect(join(tmp,'unsafe')).status,0);
// Incomplete edges, tool output and thinking are not assistant claim records.
const edge = join(tmp,'edge.jsonl'); writeFileSync(edge,record('toolResult','green '+clean)+JSON.stringify({type:'message',message:{role:'assistant',content:[{type:'thinking',thinking:'green '+clean}]}})+'\n'+record('assistant','green '+clean));
const eManifest = join(tmp,'edge.json'); writeFileSync(eManifest,JSON.stringify({transcripts:[{file:edge,offset:3,bytes:100}]}));
const eOut = join(tmp,'data','edge'); assert.equal(collect(eOut,eManifest).status,0);
assert(!readFileSync(join(eOut,'conformance.log'),'utf8').includes('record='));
writeFileSync(eManifest,JSON.stringify({transcripts:[{file:edge,bytes:262145}]})); assert.notEqual(collect(eOut,eManifest).status,0);
// Unknown registry IDs and opinion/verdict input must fail closed.
writeFileSync(eManifest,JSON.stringify({verdict:'follow'})); assert.notEqual(collect(eOut,eManifest).status,0);
// GitHub adapter: exact envelope, all check runs requested, GET-only source reads.
const fake = join(tmp,'fake'); mkdirSync(fake); const called = join(tmp,'called');
const envelope = 'api_response:\n  body: '+JSON.stringify('FM_JSON:'+JSON.stringify({id:33,head_sha:clean,run_attempt:4}))+'\n  truncated: false\n';
writeFileSync(join(fake,'gh-axi'),`#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> '${called}'\ncat <<'RESPONSE'\n${envelope}RESPONSE\n`); chmodSync(join(fake,'gh-axi'),0o755);
writeFileSync(eManifest,JSON.stringify({github:[{repo:'owner/repo',head:clean,run:33}]}));
const ghOut = join(tmp,'data','github'); result = collect(ghOut,eManifest,{...process.env,PATH:fake+':'+process.env.PATH}); assert.equal(result.status,0,result.stderr);
const calls=readFileSync(called,'utf8'); assert(calls.includes('filter=all')); assert(!/POST|PATCH|PUT|DELETE/.test(calls));
assert(readFileSync(join(ghOut,'conformance.log'),'utf8').includes('two-attempt-cap'));
// Private data INSIDE a Git checkout must satisfy BOTH ignored paths. Prior
// fixtures outside Git masked the invalid multi-path `check-ignore -q` call.
// Fixture rows remain parser inputs; no live observation is written or changed.
const privateOut = join(repo,'data','private');
writeFileSync(eManifest,JSON.stringify({}));
writeFileSync(join(repo,'.gitignore'),'data/\n');
const badQuiet = spawnSync('git',['check-ignore','-q','--',join(privateOut,'conformance.log'),join(privateOut,'conformance-notes.md')],{cwd:repo,encoding:'utf8'});
assert.equal(badQuiet.status,128,'Git quiet mode rejects multiple paths before checking ignore rules');
for (const name of ['conformance.log','conformance-notes.md']) {
  assert.equal(spawnSync('git',['check-ignore','-q','--',join(privateOut,name)],{cwd:repo}).status,0);
}
result = collect(privateOut,eManifest); assert.equal(result.status,0,result.stderr);
const privateLog = readFileSync(join(privateOut,'conformance.log'),'utf8');
result = collect(privateOut,eManifest); assert.equal(result.status,0,result.stderr);
assert.equal(readFileSync(join(privateOut,'conformance.log'),'utf8'),privateLog);
for (const onlyIgnored of ['conformance.log','conformance-notes.md']) {
  writeFileSync(join(repo,'.gitignore'),`data/*/${onlyIgnored}\n`);
  const partial = collect(join(repo,'data',onlyIgnored.replaceAll('.','-')),eManifest);
  assert.notEqual(partial.status,0,'one ignored file does not authorize the other');
  assert(partial.stderr.includes('output must be ignored and untracked'));
}
writeFileSync(join(repo,'.gitignore'),'');
assert.notEqual(collect(join(repo,'data','nonignored'),eManifest).status,0);
writeFileSync(join(repo,'.gitignore'),'data/\n');
exec(['git','add','-f',join(privateOut,'conformance.log')],repo);
assert.notEqual(collect(privateOut,eManifest).status,0,'tracked output remains refused');
console.log('pass: five artifact parsers, conservative gaps, row shape, bounded reads, append-only idempotence, privacy, locks and GitHub adapter');
TS
