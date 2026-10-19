# SI Control Section 15: shadow AI inventory and incident response

This is the operator inventory and incident runbook required by Section 15 of the SI Control architecture.
It provides a baseline for acceptance scenario #21, unregistered agent, local model, or browser extension detection or denial of resource access.
It does not record that scenario as passed.
The initial read-only baseline was collected on 2026-10-19 UTC, October 18 in America/New_York, with individual timestamps in the evidence.
The [sanitized evidence](evidence/section-15-baseline-2026-10-19.json) contains the enumerated items, collection methods, versions, and explicit limits.
Internal topology detail is deliberately withheld from this public document and its evidence as non-public: host names, addresses, ports, internal endpoints, service, timer and process names, credential paths, probe commands, vault and secret key names, and local model aliases.
Only counts, categories, approval status, and stated gaps are published, and the detailed collection is retained in a restricted private record.

## Scope and authority

Shadow AI means unregistered execution, identities, tools, or data flows, including local inference, personal SaaS accounts, extensions, remote MCP, unattended scripts, and CI jobs.
The live sample covers one development workstation and three Covenant clinic Linux servers, as the operator's login user.
It covers a snapshot of visible processes, sockets, running services, scheduled system timers, a named binary search, and credential-carrier existence.
The workstation additionally has extension and MCP configuration metadata, dispatch configuration, proxy service registrations, and provider quota observations.
No credential values, authentication headers, cookies, application records, patient data, model prompts, process arguments, or environment values were printed or retained in evidence.

Jon, the human Arcs Health operator, owns this register and approval of additions, data routes, exceptions, and removals.
`Registered` below means present in the current Firstmate dispatch configuration, shipped Firstmate extension surface, or named proxy registry.
That is evidence of an operational configuration, not independent proof of human approval, account ownership, enterprise contracting, or technical containment.
`Approval unconfirmed` means no applicable human authorization record was established in this collection.
An installed binary, token, subscription, manifest, or successful quota request never approves itself.
Until Jon reconciles an unconfirmed item, do not grant it new sensitive resource access.
This document grants no new execution or data access authority.

## Inventory

### Harnesses and binaries

| Surface | Registration or approval reference | Observed reality | Scope and disposition |
| --- | --- | --- | --- |
| Claude, Codex, Pi, Cursor agent, Antigravity (`agy`) | Workstation Firstmate crew dispatch configuration | All five commands found on the workstation | Registered development routing candidates, subject to the matching task rule and account binding |
| Pi provider routes | Same dispatch record | Kimi, Alibaba, MiMo, z.ai, and OpenCode Go configured | Registered route names, with individual model pins in evidence, not proof of a usable or approved tenant |
| Grok | Dispatch rule text reserves Grok for the primary coordinator | Workstation command found and quota available | No general worker authorization inferred |
| Kimi CLI, Gemini CLI, Muse, Command Code | Firstmate supports these adapters, but support is not approval | Commands found on the workstation | Approval unconfirmed for standalone use outside an applicable task grant |
| Ollama | No approval record established | Workstation binary found | Binary presence only, no running Ollama server established |
| llama-swap | Dated SI working inventory records this local route | Workstation process, running service, local listener, and model-list HTTP 200 | Existing local inference surface, approval and data classification still require owner reconciliation |
| Local model catalog | Model-list metadata only | Four local model aliases advertised, names withheld | Advertisement does not prove a model is loaded, used, licensed, or approved for sensitive data |
| no-mistakes, quota-axi, `bl`, Docker, chrome-devtools-axi | Release, routing, cloud, container, and browser tooling | Commands found on the workstation | Tool presence gives no extra action authority |
| Covenant binaries | Same named search over the remote login PATH | Docker found on two of the three servers, none of the named candidates found on the third | No named AI harness found in those PATHs, with no claim about other users, images, or arbitrary locations |

Workstation versions observed: Claude Code `2.1.302`, Codex CLI `0.162.0`, Pi `1.3.0`, Cursor agent `2026.10.16-e3cb207`, quota-axi `0.1.64`, and no-mistakes `v1.84.0`.
Evidence records resolved binary file hashes to distinguish the collected installation from later replacements.
These are file hashes, never credential hashes, and do not establish publisher trust or the full dependency tree.

### Extensions, skills, and remote tools

| Surface | Enumerated items | Registration and gap |
| --- | --- | --- |
| Shipped Firstmate Pi extensions | `fm-primary-pi-watch.ts`, `fm-branch-supervision.ts`, `fm-primary-turnend-guard.ts`, `fm-calm.ts`, and `lib` directory | Registered repository surface, directory presence is not proof of session loading |
| Shipped Firstmate omp extensions | `fm-primary-omp-watch.ts`, `fm-primary-turnend-guard.ts` | Registered repository surface, not proof omp is installed or running |
| Workstation user Pi extensions | `herdr-agent-state.ts`, `moshi-hooks.ts`, `caveman`, `calm`, `pi-round-timestamp.ts` | Installed entries, individual approval and loaded state unconfirmed |
| Workstation Pi package sources | `pi-herdr-btw`, `pi-caveman`, `pi-cursor-provider`, `pi-zai`, `pi-commandcode-provider`, `pi-alibaba-models`, `pi-web-access`, `pi-agy`, `pi-meta-ai`, `pi-openai-server-compaction` | Configured sources enumerated in evidence, not an integrity or dependency audit |
| Workstation Claude plugins | `code-review`, `pr-review-toolkit`, `compound-engineering`, `frontend-design`, `shadcnblocks`, `ponytail` | Installed registry metadata and versions recorded, approval unconfirmed |
| Workstation Cursor extension | `anysphere.remote-ssh` `1.1.14` | Manifest observed, approval and enabled state unconfirmed |
| Workstation Chrome Default extensions | `ghbmnnjooekpmoecnnnilnnbdlolhkhi` `1.110.1`, `nmmhkkegccagdldgiimedpiccmgmieda` `1.0.0.6` | Manifest IDs and versions observed, localized names unresolved, enabled state and approval unconfirmed |
| Workstation project MCP | `superhuman-mail`, HTTP host `mcp.mail.superhuman.com` | Found in Claude project configuration, authority and session use unconfirmed |
| Workstation Codex MCP configuration | No `mcp_servers` entries observed in the inspected user config | Runtime connector injection, plugins, and other configuration roots remain outside this check |
| VS Code, Covenant desktops, other browsers, Macs, Windows, and remaining skill trees | Not inventoried here | Not observable from this bounded inspection, not an empty or approved set |

The Claude scan examined MCP server metadata in 538 project configuration entries without exporting project paths or their other contents.
Manifest names alone cannot distinguish an AI extension from a general extension that gains AI capabilities later.
Firstmate skills and instructions are mutable intelligence inputs, not protected enforcement.

### Endpoints and credential references

| Endpoint or identity surface | Reference and observation | Boundary |
| --- | --- | --- |
| Agent Vault proxy | Workstation loopback API and proxy listeners, login-user service running | Proxy registration is not an operation grant |
| Exa search service | Registry host `api.exa.ai`, credential key reference present | Registered external search route, no secret value read |
| JEV classification service | Registry host `api.typesafe.ai`, credential key reference present | Registered classification route, never a grantor |
| Slack service | Registry host `slack.com`, credential key reference present | Registered communication route, sending still requires authority |
| Internal probe service | Internal registry endpoint withheld, credential key reference present | Registration observed, purpose, current need, expiry, and approval unconfirmed |
| Other mail, video, and QA proxy wrappers | Named by the agent-vault operational reference | Other vault registrations and live use not inspected, no coverage inferred from wrapper existence |
| Model providers | Provider-specific local carriers and quota metadata in the following table | Actual inference hostname, tenant, recipient account, retention, and contractual scope not proven by quota |
| SSH | Workstation fleet, clinic, and other key carriers exist, remote login succeeds to the three clinic servers | Carrier categories and file modes recorded, key contents and effective grants not inspected |
| Corporate data access | Workstation rclone configuration carrier exists | Credential existence only, remote names, permissions, and stored data not read |
| Service credentials | Vault identity and sealed production-carrier architecture documented by the agent-vault reference | Only the proxy owner credential was consumed inside the registry-read process, none was printed, comprehensive vault and sealed-secret inventories remain a gap |

Workstation Claude, Codex, and Pi auth carriers were present with mode `600`, SSH carriers with mode `600`, and rclone configuration with mode `640`.
One clinic server had a fleet SSH carrier, another had fleet and clinic SSH carriers, and no carrier from the named search was observed on the third.
The probe inspected only explicit paths under the login user's home, not root, all users, browser credentials, or every application secret.
The retired system credential-broker service was `masked` and `inactive` on the workstation, while the current login-user proxy service was running.
A process named `agent-vault` therefore does not establish that the retired broker returned.

### Model accounts, sign-in evidence, and cloud usage

These are local account lanes and provider observations, not an export of identity-provider sign-in history or all tenant accounts.
`quota-axi auth --json` was read-only, and usage collection explicitly passed `--no-credential-refresh`.
Account locators are carrier references, not credential values or proof of a distinct billing identity.

| Provider lane | Credential or account reference observed | Usage result and reconciliation |
| --- | --- | --- |
| Claude | Claude OAuth file carrier, local default lane | Fresh Max quota, 91% session and 79% weekly remaining, dispatch registered |
| Codex | Codex auth file, Pi OpenAI Codex provider, CLI RPC | Fresh `prolite` quota, 79% weekly remaining, lane aliases need owner-to-tenant reconciliation |
| Cursor | User state database and CLI auth file | Fresh Ultra quota, 99% included and 76% API remaining, state-database source also reported sign-in required |
| Grok | Grok auth file, Pi xAI provider | Fresh quota, 87% weekly remaining, primary-only routing restriction |
| Kimi | Pi `kimi-coding` and Kimi CLI carrier references | Both report expired, cached quota stale, live usage not observable in this read |
| z.ai | Pi `zai`, OpenCode auth carrier | Fresh Max quota, 53% weekly remaining, registered last-resort route |
| Antigravity | Loopback auth source, local default lane | Fresh Gemini and Claude/GPT quota windows, provider subaccounts not exported |
| Alibaba | `bl` CLI auth source | Local source available, console usage read failed because its session was not logged in or expired |
| OpenCode Go | OpenCode auth carrier | Carrier available, quota source reports `auth_required` and `provider_auth_rejected` |
| Command Code | Pi provider and Command Code CLI auth file | Fresh usable auth, zero included credits, standalone approval unconfirmed |
| MiMo | Pi `xiaomi-token-plan-sgp` | Usable auth, quota semantics unknown and no usage window returned, dispatch registered |
| Copilot | GitHub CLI host configuration source, native Copilot carriers absent | Fresh individual quota observed through available source, approval unconfirmed, not proof of a native Copilot installation |
| Higgsfield | Higgsfield CLI source | Fresh Ultra account, 6000 credits, 20 sampled jobs completed, not a complete job or billing history, approval unconfirmed |
| Minimax, direct DeepSeek, OpenRouter, ElevenLabs, Devin, Muse | Named auth sources missing in quota-axi | Not set up in this selected local view, not proof no organization account exists |

Fresh quota is partial cloud usage evidence, not per-request attribution, invoice reconciliation, a sign-in audit, or proof data stayed on an approved route.
Direct DeepSeek absence does not contradict the configured DeepSeek model route through Alibaba.
No Entra/Microsoft 365, Google, GitHub organization, provider organization, Cloudflare, cloud IAM, or cloud billing audit export was obtained.
Personal browser accounts, alternate profiles, dormant accounts, unmanaged endpoints, and accounts absent from the local tool remain not observable.
Jon must reconcile tenant/account identifiers, owners, sign-in events, and invoices through independent administrator exports before claiming organization-wide coverage.

### Approved data-route boundaries

| Data class | Existing registration and permitted interpretation | Missing approval evidence |
| --- | --- | --- |
| Public research | Registered search and task-specific model routes may support an authorized public-data task | Service/account binding and the task's scope must still match |
| Coding | Dispatch-registered harnesses and providers are operational development routes | A routing rule does not approve sending private repository contents to every provider |
| Corporate data | Scope resource access to the named business workflow, identity, tenant, and destination | No complete approved corporate model/data-route register or per-route retention, training-use, subprocessor, and jurisdiction review established here |
| Clinical data | No model or browser route is newly authorized by this inventory | Contracted enterprise API, approved data flow, access role, retention, training use, subprocessors, jurisdiction, and BAA coverage require human privacy/security approval before use |

Consumer subscriptions and enterprise APIs are distinct routes even when the model name matches.
Local inference also needs a data route, resource boundary, and owner approval.
No patient data belongs in discovery evidence or the acceptance drill.

## Comparison against reality and coverage gaps

| Signal | Observation and comparison | What cannot be concluded |
| --- | --- | --- |
| Workstation processes | Claude, Codex, Pi, and Antigravity process names, the local inference router, browser and interpreter names visible | Generic `node`, `python`, or browser processes cannot be assigned a model, tool, or approval from `comm` alone |
| Covenant processes | No named candidate AI harness process recognized in the three server snapshots | Short-lived processes, renamed executables, images, VMs, other users' configurations, and clinic endpoints may escape this view |
| Scheduled and CI execution | Workstation local-inference watchdog timer, live runner services, and clinic server timers observed, with per-host counts in evidence | Timer or runner presence is not a workflow-content audit, job history, or proof of grant enforcement |
| Network peers | Established peers on the workstation and clinic servers, counted by loopback, private, and public class in evidence | An established peer may be inbound, and a socket snapshot does not establish initiating identity, destination hostname, tenant, API method, payload, or every connection |
| TLS and shared infrastructure | Exact address observations retained only in the restricted private record, hostnames only attributed where explicitly configured | TLS-hidden destinations and encrypted contents are **not observable**, and complete encrypted-traffic visibility is not claimed |
| Identity | Local carrier/source availability compared with quota responses, including expiry and rejected auth | No sign-in-history comparison possible without independent IdP/provider audit exports |
| Cloud usage | Fresh, stale, unknown, rejected, and missing provider lanes distinguished above | No all-account billing census, complete request log, cloud workload census, or historical usage comparison |
| Prevention controls | Existing action-gate evidence is separately scoped in [T1 evidence](evidence/t1-enforcement.json) | This inventory does not prove endpoint application controls, universal egress mediation, tenant binding, or an EDR/Defender for Cloud Apps deployment or license |

DNS filtering alone cannot detect local inference or reliably distinguish services sharing HTTPS infrastructure.
Restrict sensitive resources even when it is unknown whether a caller uses AI.
Installed or configured items outside the applicable registration are reconciliation candidates, not automatically malicious and not automatically approved.
The probe service, extra plugins/extensions, standalone harnesses, account aliases, expired/rejected credentials, and all missing audit sources remain explicit owner review items.
The collection did not change permissions, services, credentials, firewall rules, or production workloads.

## Inventory maintenance and scenario #21

Jon owns reconciliation before sensitive access expands, after tool/account/extension changes, and during each scenario #21 exercise.
Record the item ID, class, human owner, host, binary/version or extension ID, provider endpoint and tenant, credential reference, data class, permitted actions, approval record, expiry, last observation, and disposition.
Keep `not observable`, `approval unconfirmed`, and stale observations as explicit states instead of dropping them from the register.
Compare new snapshots with the prior approved register and independent process, endpoint, egress, sign-in, and usage records that are actually available.
An unavailable required signal is a coverage gap, never a clean comparison.

Run scenario #21 only in an isolated environment with synthetic data, identities, and protected-resource targets.
Seed an unregistered agent, local model, and browser extension independently and identify the expected detector or resource-denial boundary before each trial.
For each, record the seeded item, runtime/version, host, observation source, UTC timestamps, detected registration mismatch or target denial, false positives, detection delay, and remaining blind spots.
An analyst identifying a mismatch in this document alone does not demonstrate a deployed detector.
A missing signal must produce an unverified result unless an independently observed resource denial satisfies the scenario.
Passing one form of unregistered execution does not establish coverage for the others.
The acceptance lane records the actual scenario result after this deliverable lands.

## Incident owner and independent escalation

**Human incident owner: Jon, Arcs Health operator, `jon@arcs.health`.**
The responder contacts Jon directly from a human-controlled telephone or in person, using an independently verified contact, and can send a minimal notice directly to `jon@arcs.health` from a human-operated mail client.
This path does not call Firstmate, Wiseman, Relay, an agent inbox, a model, or an agent mail/Slack proxy.
If the mailbox or its sessions may be affected, use direct voice or in-person contact and do not trust email acknowledgement alone.
No telephone number, alternate named incident commander, response rota, or delivery/acknowledgement test was established in this collection.
Jon must verify the direct contact path and designate a human alternate before an unattended incident exercise is credited as ready.
Slack paging is supplementary and cannot substitute for human acknowledgement outside the affected agent system.
For suspected clinical exposure, Jon immediately involves the clinic's human privacy/security leadership and applicable legal review through their human contact channels.
Those individual leadership contacts and legal notification obligations were not determined by this inventory.
Agents cannot approve containment, decide disclosure obligations, or close their own incident.

## Incident response runbook

1. **Recognize and notify.**
   Treat an unknown agent, extension, model, account, unexplained usage, unauthorized sensitive-resource request, or missing required discovery signal as an incident candidate.
   Record an incident ID, UTC detection time, reporter, host/resource identifiers, observed facts, unknowns, and immediate business or clinical risk.
   Reach Jon through the independent path above and record human acknowledgement or that contact remains unconfirmed.
2. **Preserve evidence.**
   Preserve the pre-incident inventory, process/executable metadata, extension manifests, tool/skill and policy diffs, runtime versions, grant decisions, target-side audit records, network metadata, sign-in exports, and cloud usage records available to a human administrator.
   Save restricted evidence outside the affected agent's write/delete authority with access controls, hashes, collector identity, UTC collection times, and a custody log.
   Keep protected content separate from general logs, redact secret values and patient data from shared reports, and preserve originals only through the authorized restricted incident process.
   Do not collect raw command arguments, environment dumps, browser profiles, or application contents merely to fill an inventory gap.
   This Git baseline is agent-produced evidence, not an independently protected incident archive.
3. **Suspend affected authority.**
   Jon or an independently authorized human administrator pauses the affected workload and suspends its target roles, executor grants, account sessions, credentials, or network access at the independent enforcement boundary.
   Reconcile queued, delegated, already-started, and completed effects through target records.
   Apply the human brake where available, but do not assume a harness instruction stops direct APIs, browsers, local inference, CI jobs, or other sessions.
   Preserve unaffected clinical availability, witness paging, logs, and backups while containing the identified scope.
   Record the human authorization, exact scope, time, observed denial, exceptions, and rollback plan before a disruptive action.
4. **Determine impact.**
   Establish the first possible activity, detection and containment times, affected parties, hosts, accounts/tenants, resources, recipients, data classes, and confirmed changes or disclosures.
   Correlate target audit, identity sign-ins, usage, network metadata, and executable/extension history with the approved register.
   Separate confirmed facts, hypotheses, and not-observable intervals, especially TLS contents, unavailable sign-ins, and missing usage records.
   Privacy/security leadership and legal reviewers assess a clinical incident and any required notifications.
5. **Revoke or rotate and remediate.**
   A human credential administrator revokes compromised sessions, keys, tokens, and outstanding grants, and rotates affected credentials through their sanctioned store.
   Test revocation at the target, including another active session, and restore or replace affected binaries, extensions, skills, and configuration from reviewed versions.
   Removal of unlanded work, production changes, and credential actions require their own explicit authority.
   Avoid restoring revoked authority from a backup or broadening access as a recovery shortcut.
6. **Test recovery and close.**
   In isolation, replay the triggering case using synthetic fixtures, verify denial of the compromised route and stale authority, and verify an approved workflow still works with replacement authority.
   Test evidence delivery, independent human notification, queued-effect reconciliation, and the relevant unregistered-agent/model/extension cases.
   Jon authorizes the bounded return to service after reviewing the result, residual gaps, monitoring window, and rollback criteria.
   Record the owner, corrective-action deadlines, approvals, closure time, and the updated register, and retain the restricted incident evidence under the applicable retention policy.

## Disclosure record

The incident owner prepares the following record for human review, even when the conclusion is that no disclosure is required.
Notification timing and recipients are decided by the responsible humans and applicable legal review, not invented by an agent or this runbook.

| Required content | Record |
| --- | --- |
| Affected parties | People or organizations affected, account/tenant and resource scope, data classes, confirmed recipients, and uncertainty, with identifying clinical details restricted |
| Timing | First possible activity, first confirmed activity, discovery, human acknowledgement, containment, revocation, recovery, and notices, all stored in UTC |
| Failed controls | Intended boundary, actual bypass or failure, evidence, detection gaps, and why existing controls did not prevent or reveal the activity |
| Runtime versions | Host/runtime, harness and model/provider version where available, binary hashes, browser/extension versions, gateway/executor release, and unknown version fields |
| Tool and skill changes | Added, removed, or modified tools, skills, plugins, MCP endpoints, workflows, policy, configuration, account routes, and their approval/provenance records |
| Corrective action | Suspended authority, revocations/rotations without values, repairs, recovery tests, action owners, deadlines, residual risks, and human return-to-service approval |

Clinical disclosures require human privacy/security leadership and applicable legal review.
Public lessons omit credentials, patient data, and exploitable operational detail, including internal access topology or bypass instructions.
Keep the restricted forensic record separate from any public summary.
Publication is a separate human decision.

## Source and evidence boundary

The requirement source is the private SI Control architecture of 2026-10-10, Sections 14 and 15, inspected during this collection.
The earlier dated SI inventory beside it supplies dated context only, never a replacement for the current observations.
Firstmate dispatch configuration, repository extension surfaces, the agent-vault operational reference, and the sanitized evidence identify the narrower source for each inventory claim.
The architecture and private configuration are not copied into this repository.
An independent reviewer must refresh the baseline and test the claimed boundary before acceptance closure or promotion to a broader scope.
