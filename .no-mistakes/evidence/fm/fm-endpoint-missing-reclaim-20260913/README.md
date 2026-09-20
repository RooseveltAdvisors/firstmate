# Evidence index

Current for **base `90cd351a` -> target `8b2d6692`**:

| file | what it shows |
|---|---|
| `before-base-90cd351a-deadlock.txt` | The deadlock reproduced on the base commit: `exit` and `relaunch` each name the other as its prerequisite. |
| `after-target-8b2d6692-reclaim.txt` | The same three operator commands on the fix: `exit` reports `endpoint-gone`, `relaunch` re-creates the endpoint in the recorded session, the task survives whole. |
| `reclaim-deadlock-demo.sh` | The driver behind both transcripts. Takes a firstmate code root, so the same scenario replays on either tree. |
| `reclaim-guardrails.txt` | The other half of the contract: a pane that outlived a stopped server is adopted (not duplicated), a returning agent refuses, and a tmux `missing` refuses both verbs with its reason. |
| `guardrails-demo.sh` | The driver behind `reclaim-guardrails.txt`. |
| `regression-fail-before-pass-after.txt` | Each reclaim test added by this change, run individually against both trees. |

Superseded (produced in an earlier round, against pre-rebase commits `b182d0f` / `57757fd`
that are no longer in this branch's history) - kept for the record, do not read the
commit ids as current:

- `reclaim-before-after.txt`
- `reclaim-demo.sh`
