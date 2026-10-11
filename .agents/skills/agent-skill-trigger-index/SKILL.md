---
name: agent-skill-trigger-index
description: Load only when auditing or maintaining the complete agent-only skill trigger index.
user-invocable: false
metadata:
  internal: true
---

# Agent-only reference skills

These skills are not captain-invocable and must load only at their precise triggers.
Each skill's always-loaded frontmatter `description` owns its trigger phrases under the one-owner rule, and this index serves as the navigation map across skills.

- `operational-home-layout` - load when its own `description` trigger matches for Firstmate home, config, data, state, project, or generated runtime paths.
  That always-loaded description is the owner of path layout triggers.
- `session-start-recovery` - load when its own `description` trigger matches for unfinished checks, actionable diagnostics, recovery inputs, or output requiring interpretation.
  That always-loaded description is the owner of session-start recovery triggers.
- `bootstrap-diagnostics` - load when its own `description` trigger matches for actionable bootstrap or network-checks diagnostic lines.
  That always-loaded description is the owner of the complete diagnostic line list and silence rule.
- `diagnostic-reasoning` - load when its own `description` trigger matches before scoping a reported bug or acting on a diagnostic report.
  That always-loaded description is the owner of bug diagnosis triggers.
- `ask-user-authority` - load when its own `description` trigger matches before deciding any ask-user finding.
  That always-loaded description is the owner of ask-user decision triggers.
- `validation-supervision` - load when its own `description` trigger matches for active no-mistakes validation runs or mid-run requirement changes.
  That always-loaded description is the owner of validation supervision triggers.
- `ship-landing` - load when its own `description` trigger matches for PR reporting, landing decisions, or task cleanup.
  That always-loaded description is the owner of landing triggers.
- `scout-completion` - load when its own `description` trigger matches for scout reports, visual iteration artifacts, or implementation promotion.
  That always-loaded description is the owner of scout completion triggers.
- `quota-array-dispatch` - load when its own `description` trigger matches when resolving among candidate crew-dispatch profile arrays from quota-axi.
  That always-loaded description is the owner of multi-profile dispatch triggers.
- `harness-adapters` - load when its own `description` trigger matches before spawning, recovering, interrupting, or adapting an agent.
  That always-loaded description is the owner of harness operation triggers.
- `firstmate-orca` - load when its own `description` trigger matches for switching to Orca, supervising Orca work, smoke testing, or debugging Orca state.
  That always-loaded description is the owner of Orca runtime triggers.
- `project-management` - load when its own `description` trigger matches before adding, creating, removing, or initializing a project.
  That always-loaded description is the owner of project lifecycle triggers.
- `stuck-crewmate-recovery` - load when its own `description` trigger matches for dead endpoints, missing windows, stale wakes, or confused crewmates.
  That always-loaded description is the owner of direct report recovery triggers.
- `secondmate-provisioning` - load when its own `description` trigger matches before creating, seeding, validating, launching, recovering, or retiring a secondmate home.
  That always-loaded description is the owner of secondmate provisioning triggers.
- `captain-hold-lifecycle` - load when its own `description` trigger matches before completing investigations or visual reviews, recording captain answers, or handling record divergences.
  That always-loaded description is the owner of captain hold triggers.
- `away-quiet-supervision` - load when its own `description` trigger matches whenever /afk or /quiet is active or an away-supervisor message arrives.
  That always-loaded description is the owner of away and quiet supervision triggers.
- `process-event-sources` - load when its own `description` trigger matches before arming a long-polling source, registering a watch, or handling process-event wakes.
  That always-loaded description is the owner of process-event triggers.
- `fmx-respond` - load when its own `description` trigger matches for Relay mentions, configuration blockers, milestones, or public follow-ups.
  That always-loaded description is the owner of Relay response triggers.
- `firstmate-codexapp` - load when its own `description` trigger matches before coordinating, steering, or debugging visible Codex Desktop threads.
  That always-loaded description is the owner of Codex Desktop coordination triggers.
- `firstmate-coding-guidelines` - load when its own `description` trigger matches before changing Firstmate's shared, tracked material.
  That always-loaded description is the owner of Firstmate development guideline triggers.
