---
type: knowledge
description: Rules for writing maintenance change specifications (Phase U2) — delta specs, EARS criteria, test plans, risk routing
last_updated: 2026-06-12
---

# Spec-Update Guidelines (Phase U — maintenance flow)

Format informed by OpenSpec (proposal → delta-spec → tasks state machine) and Kiro
(requirements/design/tasks with EARS notation). See `docs/GSD-Maintenance-Flow.md`.

## Principles

1. **Spec before code.** The pipeline implements against a frozen change spec, never against the
   raw issue text. The change spec is the maintenance-scale ContractFreeze.
2. **Deltas only.** Never rewrite a frozen spec document — emit ADDED/MODIFIED/REMOVED deltas per
   section, in the target document's own conventions (OpenAPI fragment for contracts, table rows for
   the screen-state matrix, T-SQL for the DB plan).
3. **Repro gate is hard.** A bug spec without a confirmed reproduction is a defect in the process —
   the agent must throw, not improvise (mirrors Rule 8: DeployAgent requires gate.passed).
4. **EARS criteria** are the contract: `WHEN <trigger> THE SYSTEM SHALL <response>`. One per behavior
   change + one regression guard per blast-radius component. Criterion #1 is always the repro flip.
5. **Small tasks.** Each implementation task ≤1 file where possible, ordered, named by file +
   change — sized for the RemediationAgent loop (max 3 iterations).
6. **Scope ceiling.** If ≥3 frozen specs need rewriting (not delta-ing), the change is not
   maintenance — recommend re-running the SDLC `contracts` milestone instead.

## Change spec layout (persisted to vault `changes/CH-{runId}/change-spec.md`)

```
# CH-{runId}: <title>
## Proposal        — root cause, approach, alternative considered, non-goals
## Delta specs     — per target: section, ADDED/MODIFIED/REMOVED, content
## Acceptance      — EARS criteria (repro flip first)
## Tasks           — ordered checklist for RemediationAgent
## Test plan       — repro test, regression scope, Semgrep ruleset, Playwright paths
## Risk            — level, requiresHumanApproval, security-critical paths touched
```

## Risk routing

| Condition | Action |
|---|---|
| riskLevel low/medium, no contract break | auto-proceed to pipeline F1 |
| riskLevel high OR contract-breaking delta | `requiresHumanApproval` → pipeline pauses; resume `--from-stage blueprint` after signoff |
| security-critical path touched | + SecurityAgent binding review (v6.2) |

## Stack conventions the deltas must honor

.NET 10 default (project may pin via stack-overrides) · Dapper + SPs only (`usp_{Entity}_{Action}`,
NOCOUNT, TRY/CATCH, typed params) · TenantId + IsDeleted filters · Fluent v9 + five-states rule ·
audit columns. SQL Server 2025: native `JSON` type for JSON payloads, `REGEXP_*` for validation.
