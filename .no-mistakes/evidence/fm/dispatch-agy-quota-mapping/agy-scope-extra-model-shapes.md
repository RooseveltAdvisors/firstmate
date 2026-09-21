# Additional agy model shapes against the shipped mapping

Real `bin/fm-dispatch-resolve.sh` (target commit 031ffc2) against the same agy snapshot. Confirms the reviewed decision's required shapes and the pinned-model non-regressions:

== default-model
  status: clear
  candidate: agy:default  provider=agy  scope=gemini  remaining=41%  spendPriority=0.2  runway=through_reset  bounds=all_models:64%/through_reset,gemini:41%/through_reset  -> eligible
== gpt-prefixed
  status: clear
  candidate: agy:gpt-5.6  provider=agy  scope=claude_gpt  remaining=55%  spendPriority=0.3  runway=through_reset  bounds=all_models:64%/through_reset,claude_gpt:55%/through_reset  -> eligible
== unrelated-model
  status: clear
  candidate: agy:veo-3  provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset  -> eligible

Reading: model:"default" and empty (model-less) rank on the gemini scope; gpt-* ranks on claude_gpt; an unrelated model (veo-3) is NOT mis-mapped and still uses all_models.
