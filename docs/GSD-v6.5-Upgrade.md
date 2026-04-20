---
type: upgrade-spec
id: gsd-v6.5
title: GSD V6.5 — Hermes Notification Agent + Letta-Inspired Skill Forge
status: Proposed (not executed)
date: 2026-04-20
supersedes: none (additive to V6)
depends_on: [v6-design, agent-system-design, hook-registry]
breaking_change: false
---

# GSD V6.5 Upgrade Spec

## Executive Summary

V6.5 is a **non-breaking, additive** upgrade to V6. It closes two concrete gaps surfaced during a review of the current repo against (a) the missing-Hermes-agent question and (b) Letta Code's memory-first harness.

Two upgrades, shipped together:

1. **HermesAgent** — a dedicated notification/dispatch agent that listens for escalation and critical state-change events from the Orchestrator and routes them to configured human-facing channels (Slack, email, webhook, GitHub Issues). Closes the system-to-human alerting gap.
2. **SkillForge** — an automated skill-extraction subsystem, inspired by Letta Code's `/remember` + skill-learning model. Nominates candidate skills from successful session patterns and promotes them to `.claude/skills/` after human approval. Closes the manual-only `/consolidate` gap.

Both upgrades are additive: existing pipelines run unchanged if Hermes is disabled and SkillForge is dormant.

## Why V6.5, Not V7

- No breaking changes to agent contracts (`PipelineState`, `GateResult`, etc.)
- No changes to the 7-stage pipeline graph or SDLC phase map
- No changes to vault schema, volatility semantics, or contradiction handling
- Hermes subscribes to existing events (`EscalationError`, deploy rollback, gate halt) — does not introduce new ones
- SkillForge reads from existing session logs and vault — does not alter write paths

V7 is reserved for changes that would break existing orchestration.

## Upgrade 1 — HermesAgent

### Problem

`src/harness/orchestrator.ts` throws `EscalationError` and sets `status='paused'` on retry exhaustion. `deploy-agent.ts` triggers rollback on failure. `quality-gate-agent.ts` fails hard on HardGateViolation. All three events write to the vault and console — no human is notified. The pipeline silently waits.

### Solution

Add a 15th typed agent whose sole job is event-to-channel dispatch. Hermes does **not** route work between agents (that remains the Orchestrator's job, per rule #7). Hermes routes events to humans.

### Scope

**In scope:**
- Subscribe to: `EscalationError`, `HardGateViolation`, deploy rollback, budget-exhausted (CLI+API both throttled), post-deploy 500-storm
- Dispatch to: Slack webhook, email (SMTP or SendGrid), GitHub Issues (via existing GitHub MCP), generic webhook
- Configurable channel routing per event severity in `memory/knowledge/notification-targets.md`
- Dry-run mode that writes planned notifications to `memory/observability/hermes-dispatches/` without sending
- Rate limiting — no more than 1 notification per event-key per 10 minutes (deduplication via SQLite)

**Out of scope:**
- Agent-to-agent routing (Orchestrator already does this)
- Reading from external systems (Hermes is push-only)
- Acknowledgement / bidirectional flow (one-way dispatch only in v6.5)

### Files to Create

| Path | Purpose |
|---|---|
| `memory/agents/hermes-agent.md` | System prompt + config (vault source of truth, per rule #5) |
| `src/agents/hermes-agent.ts` | Implementation, extends `BaseAgent` |
| `memory/knowledge/notification-targets.md` | Channel configs, severity routing, rate limits |
| `src/harness/event-bus.ts` | Lightweight pub/sub shim on top of existing logger |
| `memory/observability/hermes-dispatches/` | JSONL log of all dispatches (append-only) |

### Files to Modify

| Path | Change |
|---|---|
| `src/harness/orchestrator.ts` | Emit `event:escalation` when throwing `EscalationError`; emit `event:paused` on status change |
| `src/harness/types.ts` | Add `HermesEvent`, `NotificationDispatch`, `ChannelConfig` types |
| `src/agents/deploy-agent.ts` | Emit `event:rollback` on rollback path |
| `src/agents/quality-gate-agent.ts` | Emit `event:gate-halt` on HardGateViolation |
| `src/agents/post-deploy-validation-agent.ts` | Emit `event:post-deploy-failure` on 500-storm detection |
| `src/index.ts` | Register Hermes subscribers at startup if enabled in config |
| `CLAUDE.md` | Add HermesAgent row to Agent Roster table |
| `memory/architecture/agent-system-design.md` | Document event bus and Hermes subscription model |

### Agent Contract

```ts
interface HermesEvent {
  eventKey: string;           // dedup key, e.g. "escalation:M001:S003:T007"
  severity: 'info' | 'warn' | 'error' | 'critical';
  source: AgentName;          // which agent emitted
  title: string;
  summary: string;            // ≤ 500 chars
  contextUrl?: string;        // vault path or GitHub URL
  payload: Record<string, unknown>;
  timestamp: string;          // ISO
}

interface NotificationDispatch {
  event: HermesEvent;
  channel: 'slack' | 'email' | 'github-issue' | 'webhook';
  target: string;
  status: 'sent' | 'suppressed-ratelimit' | 'failed';
  attemptedAt: string;
  response?: unknown;
}
```

### Channel Routing Rules (default)

Defined in `memory/knowledge/notification-targets.md`, not hardcoded (rule #4):

| Severity | Default channels |
|---|---|
| `info` | observability log only |
| `warn` | Slack (#gsd-ops) |
| `error` | Slack (#gsd-ops) + GitHub Issue |
| `critical` | Slack (#gsd-ops) + email (on-call) + GitHub Issue |

### Secrets

All channel tokens read from environment — never checked in:
- `HERMES_SLACK_WEBHOOK_URL`
- `HERMES_SMTP_URL` or `HERMES_SENDGRID_API_KEY`
- `GITHUB_PERSONAL_ACCESS_TOKEN` (already present for GitHub MCP)

### Orchestrator Integration

Hermes is **not** part of the 7-stage task graph. It is a sidecar subscriber. The Orchestrator still logs every routing decision (rule #7); Hermes logs every dispatch to `memory/observability/hermes-dispatches/`.

Hard rule: Hermes cannot block the pipeline. Dispatch failures are logged but never propagate up.

---

## Upgrade 2 — SkillForge (Letta-Inspired)

### Problem

Letta Code's agents automatically extract reusable skills from experience and persist them as `.md` in git. GSD's equivalent is `/consolidate`, which requires a human to invoke it. High-value patterns solved during autonomous pipeline runs go undiscovered because no human was in that loop.

### Solution

Add a lightweight post-session analyzer that scans session logs for recurring solution patterns and nominates them as candidate skills. Nominations are human-gated — SkillForge never writes directly to `.claude/skills/`.

### Scope

**In scope:**
- Analyze session logs in `memory/sessions/` on the existing `Stop` hook
- Detect patterns matching: repeated tool sequences, novel remediations, cross-agent fix loops
- Write nominations to `memory/skill-nominations/{session-id}.md` with full rationale
- Surface count of pending nominations in `/vault-status` output
- Human approval via new `/promote-skill <nomination-id>` command → copies to `.claude/skills/` with full attribution

**Out of scope:**
- Direct writes to `.claude/skills/` (approval-gated)
- Modification of existing skills (nominate-only, no in-place updates in v6.5)
- Cross-repo skill sharing

### Files to Create

| Path | Purpose |
|---|---|
| `src/harness/skill-forge/nominator.ts` | Pattern detector, runs on Stop hook |
| `src/harness/skill-forge/promoter.ts` | `/promote-skill` implementation |
| `src/harness/skill-forge/patterns.ts` | Pattern heuristics (initially 3–5, extensible) |
| `memory/skill-nominations/` | Append-only nomination dir |
| `memory/knowledge/skill-forge-config.md` | Pattern thresholds, cooldowns, ignore list |
| `.claude/commands/promote-skill.md` | Slash command definition |

### Files to Modify

| Path | Change |
|---|---|
| `.claude/settings.json` | Register Stop hook to invoke nominator |
| `docs/GSD-Claude-Code-Skills.md` | Document SkillForge workflow |
| `CLAUDE.md` | Add `/promote-skill` to Installed Skills section |

### Pattern Heuristics (initial set)

1. **Repeated-fix pattern** — same `RemediationAgent` fix applied ≥ 3 times in the last 10 sessions → nominate as remediation skill
2. **Novel-solution pattern** — agent produced a fix that has no matching `.claude/skills/` entry and resolved a failing gate → nominate
3. **Cross-agent loop resolved** — a remediation → gate → remediation loop that converged after ≥ 2 iterations → nominate the final pattern
4. **Manual consolidate shadow** — if a human runs `/consolidate` and the consolidated topic references a reproducible procedure → nominate
5. **Query-intensive pattern** — a task that used `gitnexus_query` + `gitnexus_context` chains successfully → nominate the query template

### Nomination Schema

```yaml
---
nomination_id: <short hash>
session_id: <session file name>
pattern: repeated-fix | novel-solution | cross-agent-loop | consolidate-shadow | query-template
confidence: high | medium | low
source_agents: [<agent names>]
sample_invocations: <count>
suggested_skill_name: <kebab-case>
suggested_path: .claude/skills/<name>/SKILL.md
rationale: <≤ 200 words>
raw_log_refs: [<paths>]
status: pending | approved | rejected | superseded
---
```

### Approval Flow

1. Nominator writes to `memory/skill-nominations/` with `status: pending`
2. `/vault-status` shows pending count
3. Human reviews, runs `/promote-skill <id>`
4. Promoter copies to `.claude/skills/<name>/SKILL.md`, updates nomination `status: approved`, logs to `memory/decisions/`
5. If rejected, human sets `status: rejected` with one-line reason

---

## Combined Architecture

```
┌─────────────────┐    events    ┌──────────────┐    dispatches    ┌──────────────┐
│   Orchestrator  │─────────────▶│ HermesAgent  │─────────────────▶│  Channels    │
│   (existing)    │              │   (NEW)      │                  │ Slack/Email  │
└─────────────────┘              └──────────────┘                  └──────────────┘
        │
        │ on Stop hook
        ▼
┌─────────────────┐   nominates   ┌──────────────────┐   /promote   ┌──────────────┐
│ Session logger  │──────────────▶│   SkillForge     │─────────────▶│  .claude/    │
│   (existing)    │               │   Nominator NEW  │  (human)     │   skills/    │
└─────────────────┘               └──────────────────┘              └──────────────┘
```

## Migration Plan

Ship in four commits, each independently testable:

| # | Commit | Exit criteria |
|---|---|---|
| 1 | Event bus + type additions + vault notes | `npm run build` clean; vault notes exist; no runtime behavior change |
| 2 | HermesAgent + orchestrator emit points + dry-run | Fake `EscalationError` in an eval produces a dispatch JSONL file, zero external calls |
| 3 | Channel adapters (Slack, GitHub Issue, email, webhook) | Integration test sends to a staging Slack channel; real channels gated behind env var |
| 4 | SkillForge nominator + `/promote-skill` | End-to-end: a seeded recurring pattern produces a nomination; `/promote-skill` copies the skill file |

## Test Plan

### Hermes
- Unit: event bus dedup, channel router severity mapping, rate-limit window
- Integration: fake `EscalationError` in `src/evals/` produces dispatch in dry-run mode
- Chaos: dispatch failure must not crash pipeline (hard rule)
- Secrets: no channel keys appear in any committed file (Semgrep rule)

### SkillForge
- Unit: each of the 5 pattern heuristics against synthetic session logs
- Integration: run a pipeline that triggers pattern 1 three times → verify nomination file exists
- Safety: `/promote-skill` refuses if target path exists (no silent overwrites)

### Regression
- Full V6 eval suite must pass unchanged with Hermes disabled
- Full V6 eval suite must pass unchanged with Hermes in dry-run mode
- Decision log volume increases by ≤ 10% (Hermes dispatches are separate, not decisions)

## Rollback

- Hermes: set `HERMES_ENABLED=false` — agent unsubscribes at startup, pipeline behavior identical to V6
- SkillForge: remove Stop hook entry from `.claude/settings.json` — nominator stops running, existing nominations remain as inert files
- Full rollback: revert the four commits in reverse order; no schema migrations to undo

## Non-Goals (explicit)

- Replacing the Orchestrator's routing role
- Bidirectional notification (ack/reply flow)
- Automatic skill promotion without human approval
- Cross-repo skill syndication
- Migrating to the Letta harness (evaluated and rejected — see review notes)

## Open Questions

- Slack channel naming convention — single `#gsd-ops` or per-project channels? Defer to first-project deployment
- Email on-call rotation source — static list vs PagerDuty integration? v6.5 ships static list, PagerDuty deferred to v6.6
- SkillForge pattern 5 (query template) may have low precision — ship behind feature flag, measure in first 30 days

## Review Cadence

Per rule #12, re-check LLM vendor features on 2026-05-20 for any native notification or skill-extraction primitives that could simplify this design before execution.

---

**Status: spec-only. No code or vault mutations performed. Execute via the four-commit migration plan when approved.**
