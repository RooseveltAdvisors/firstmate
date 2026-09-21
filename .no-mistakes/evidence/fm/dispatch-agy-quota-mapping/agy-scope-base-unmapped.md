# Pre-PR base resolver (804394e): agy scoped rows are unmapped

Same end-to-end driver, real `bin/fm-dispatch-resolve.sh` from the base commit, fake quota-axi serving an agy snapshot that carries gemini (41%, p=0.2) and claude_gpt (55%, p=0.3) rows next to all_models (64%, p=0.4). Every agy candidate ignores the scoped rows and falls back to `scope=all_models` — the behavior PR #5100 maps:

resolver under test: /tmp/fm-e2e/base/bin/fm-dispatch-resolve.sh

──────────────────────────────────────────────────────────────────
case: model-less agy profile  {"harness":"agy"}
cmd : fm-dispatch-resolve.sh brief.md --project pager  (TYPESAFE_API_KEY set; quota-axi serves the agy snapshot; curl is faked)
out :
dispatch-resolve:
  status: clear
  model: jev-1.13.0   latency_ms: 3   tokens: 100/60
  rule: rule_1 (Agy work.)   confidence: 0.99
  probabilities: rule_1=0.99 default=0.01
  note: rule matched
  candidate: agy:-  provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  -> eligible
  profile: --harness 'agy'
exit: 0

──────────────────────────────────────────────────────────────────
case: pinned agy gemini model  {"harness":"agy","model":"gemini-3.8-flash-low"}
cmd : fm-dispatch-resolve.sh brief.md --project pager  (TYPESAFE_API_KEY set; quota-axi serves the agy snapshot; curl is faked)
out :
dispatch-resolve:
  status: clear
  model: jev-1.13.0   latency_ms: 3   tokens: 100/60
  rule: rule_1 (Agy gemini work.)   confidence: 0.99
  probabilities: rule_1=0.99 default=0.01
  note: rule matched
  candidate: agy:gemini-3.8-flash-low  provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  -> eligible
  profile: --harness 'agy' --model 'gemini-3.8-flash-low'
exit: 0

──────────────────────────────────────────────────────────────────
case: pinned agy claude model  {"harness":"agy","model":"claude-opus-4-6"}
cmd : fm-dispatch-resolve.sh brief.md --project pager  (TYPESAFE_API_KEY set; quota-axi serves the agy snapshot; curl is faked)
out :
dispatch-resolve:
  status: clear
  model: jev-1.13.0   latency_ms: 4   tokens: 100/60
  rule: rule_1 (Agy claude work.)   confidence: 0.99
  probabilities: rule_1=0.99 default=0.01
  note: rule matched
  candidate: agy:claude-opus-4-6  provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  -> eligible
  profile: --harness 'agy' --model 'claude-opus-4-6'
exit: 0

