resolver under test: /home/jon/.no-mistakes/worktrees/2f32188048b1/01M312WDH0S5BXMGTK4T79DHH0/bin/fm-dispatch-resolve.sh

──────────────────────────────────────────────────────────────────
case: model-less agy profile  {"harness":"agy"}
cmd : fm-dispatch-resolve.sh brief.md --project pager  (TYPESAFE_API_KEY set; quota-axi serves the agy snapshot; curl is faked)
out :
dispatch-resolve:
  status: clear
  model: jev-1.13.0   latency_ms: 4   tokens: 100/60
  rule: rule_1 (Agy work.)   confidence: 0.99
  probabilities: rule_1=0.99 default=0.01
  note: rule matched
  candidate: agy:-  provider=agy  scope=gemini  remaining=41%  spendPriority=0.2  runway=through_reset  bounds=all_models:64%/through_reset,gemini:41%/through_reset  -> eligible
  profile: --harness 'agy'
exit: 0

──────────────────────────────────────────────────────────────────
case: pinned agy gemini model  {"harness":"agy","model":"gemini-3.8-flash-low"}
cmd : fm-dispatch-resolve.sh brief.md --project pager  (TYPESAFE_API_KEY set; quota-axi serves the agy snapshot; curl is faked)
out :
dispatch-resolve:
  status: clear
  model: jev-1.13.0   latency_ms: 4   tokens: 100/60
  rule: rule_1 (Agy gemini work.)   confidence: 0.99
  probabilities: rule_1=0.99 default=0.01
  note: rule matched
  candidate: agy:gemini-3.8-flash-low  provider=agy  scope=gemini  remaining=41%  spendPriority=0.2  runway=through_reset  bounds=all_models:64%/through_reset,gemini:41%/through_reset  -> eligible
  profile: --harness 'agy' --model 'gemini-3.8-flash-low'
exit: 0

──────────────────────────────────────────────────────────────────
case: pinned agy claude model  {"harness":"agy","model":"claude-opus-4-6"}
cmd : fm-dispatch-resolve.sh brief.md --project pager  (TYPESAFE_API_KEY set; quota-axi serves the agy snapshot; curl is faked)
out :
dispatch-resolve:
  status: clear
  model: jev-1.13.0   latency_ms: 3   tokens: 100/60
  rule: rule_1 (Agy claude work.)   confidence: 0.99
  probabilities: rule_1=0.99 default=0.01
  note: rule matched
  candidate: agy:claude-opus-4-6  provider=agy  scope=claude_gpt  remaining=55%  spendPriority=0.3  runway=through_reset  bounds=all_models:64%/through_reset,claude_gpt:55%/through_reset  -> eligible
  profile: --harness 'agy' --model 'claude-opus-4-6'
exit: 0

