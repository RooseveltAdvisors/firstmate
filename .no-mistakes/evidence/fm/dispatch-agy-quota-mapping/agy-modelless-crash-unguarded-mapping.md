# Model-less agy profile crashes when the mapping ships without the bare() guard

Variant of the target script with the gemini/claude_gpt mapping arms present but the reviewed `def bare(): (($m | split("/") | last) // "")` guard reverted to the old definition. With jq 1.8.2, $("" | split("/") | last) is null, so the model-less agy profile hits 'startswith() requires string inputs' and the whole resolution errors out — the exact regression the shipped guard fixes. The same driver against the shipped script resolves the same case to scope=gemini (see agy-scope-mapping-after-fix.md).

