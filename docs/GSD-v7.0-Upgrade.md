---
type: upgrade-spec
id: gsd-v7.0
title: GSD V7.0 — Hermes + SkillForge + Evaluator Contracts + Fork-Join DAG + Hard Model-Family Split + Agent Scratch Pads + Extended Model Pool + Fluent UI v9 Mastery + Fluent UI v9 Design Review + React Native Mastery + React Native Design Review
status: Proposed (not executed)
date: 2026-04-23
supersedes: v6
depends_on: [v6-design, agent-system-design, hook-registry]
breaking_change: false
references: [harness-engineering-literature-2026]
---

# GSD V7.0 Upgrade Spec

For a concise feature-by-feature explanation of what V7 adds and why each item improves the pipeline, see `docs/GSD-v7.0-Feature-Benefits.md`.

## Executive Summary

V7.0 is the next numbered release after V6. It ships eleven additive upgrades that close concrete gaps surfaced during a review of the current repo against (a) the missing-Hermes-agent question, (b) Letta Code's memory-first harness, (c) the 2026 harness-design literature (Rajasekaran / Anthropic Engineering, Böckeler / martinfowler.com, Raschka, Generative Programmer's 12 patterns, WaveSpeedAI operational breakdown, Anthropic "How Claude Code works", OpenDev paper arXiv:2603.05344, scaffold taxonomy arXiv:2604.03515, Confucius Code Agent arXiv:2512.10398), and (d) a 2026-04-23 live research sweep surfacing GPT-5.5, DeepSeek V4, Gemini 3.1 Flash-Lite, the Anthropic Agent Skills open standard, and Playwright CLI as recommended harness inputs.

Although V7.0 carries a major version bump to mark a milestone release, its runtime behavior remains backward-compatible: existing V6 pipelines run unchanged if Hermes is disabled, SkillForge is dormant, rubrics default to the prose criteria embedded in existing agent system prompts, pipeline concurrency defaults to 1, model-family split enforcement defaults to off, agent scratch pads are opt-in per agent, extended model pool is feature-gated behind endpoint probes, and the four UI skills (two web, two mobile) only activate on matching work or review requests.

Eleven upgrades, shipped together:

1. **HermesAgent** — a dedicated notification/dispatch agent that listens for escalation and critical state-change events from the Orchestrator and routes them to configured human-facing channels (Slack, email, webhook, GitHub Issues). Closes the system-to-human alerting gap.
2. **SkillForge** — an automated skill-extraction subsystem, inspired by Letta Code's `/remember` + skill-learning model. Nominates candidate skills from successful session patterns and promotes them to `.claude/skills/` after human approval. Closes the manual-only `/consolidate` gap.
3. **Evaluator Contracts + Grading Rubrics** — formalizes the generator/evaluator separation that the V6 pipeline implies but does not enforce. Adds `EvaluationContract` (negotiated before generation), explicit per-phase `GradingRubric` files in `memory/knowledge/rubrics/`, and live-interaction tool access for the ReviewAuditor. Directly addresses Anthropic's finding that "tuning a standalone evaluator to be skeptical turns out to be far more tractable than making a generator critical of its own work" (Rajasekaran 2026).
4. **Fork-Join DAG Pipeline** — promotes the unused `ExecutionGraph` utility to the primary pipeline scheduler. Stages become nodes with declared dependencies; default concurrency of 1 preserves V6 sequential behavior exactly, and opting into higher concurrency lets independent stages (e.g. `audit` + `e2e`) run in parallel. Addresses Scaffold Taxonomy's finding that 11 of 13 surveyed agents compose multiple loop primitives rather than hardcode one (arXiv:2604.03515).
5. **Hard Generator/Evaluator Model-Family Split** — upgrades the `role: 'generator' \| 'evaluator'` hint added in Upgrade 3 from advisory to enforced, gated by a config knob. When enabled, the capability-router refuses to assign the same model family to generator and evaluator within a single milestone run. Single-family deployments opt out via an explicit `escape: 'single-family-ok'` flag. Directly enforces Rajasekaran's primary harness-design finding on external skeptical evaluation.
6. **Agent Scratch Pads + Gather/Act/Verify Phase Framing** — every agent gains an append-only scratch pad at `memory/observability/scratch/{runId}/{agentId}.md` for intermediate findings, hypotheses, and dead-ends, plus a declared `phases:` mix in its vault frontmatter. Addresses Confucius Code Agent's finding that persistent note-taking decouples working memory from exploration depth (arXiv:2512.10398) and aligns agent lifecycle with Claude Code's gather → act → verify loop (Anthropic, "How Claude Code works").
7. **Extended Model Pool** — adds **Gemini 3.1 Flash-Lite** as a third-family cheap-generator lane, **DeepSeek V4** as a pending-release routing slot gated on an endpoint probe, and **GPT-5.5** via OAuth-Codex CLI as the preferred generator when the operator's subscription is in the rollout wave. All three are feature-flagged — a V7.0 deployment with no endpoint access keeps V6 routing exactly. Widens the `familySplit` pool in Upgrade 5 from two to three families.
8. **Fluent UI React v9 Mastery Skill** — a new Claude Code skill at `.claude/skills/fluent-v9-mastery/SKILL.md` that codifies a production-grade design-and-implementation discipline for every frontend the pipeline generates: token system, Griffel styling, the four-states rule, accessibility, anti-patterns, and a pre/post-coding checklist. Activates automatically on any frontend request. Raises the baseline floor from "generated admin panel" to "senior-Microsoft-designer level" across all downstream projects.
9. **Fluent UI React v9 Design Review Skill + `/design-review` slash command** — the enforcement companion to Upgrade 8. Ships `.claude/skills/fluent-v9-design-review/SKILL.md` (auto-activates on "review this", "audit", "design review", or end-of-Phase-D completion) plus `.claude/commands/design-review.md` (explicit `/design-review <scope>` invocation). Runs 15 review categories against the mastery guide and emits a severity-classified report (Blocker / Critical / Major / Minor / Nit) with an 8-dimension quality scorecard. Closes the "code generated to spec, never reviewed against it" loop.
10. **React Native + Expo Mobile Mastery Skill** — the mobile counterpart to Upgrade 8. Ships `.claude/skills/react-native-mastery/SKILL.md` codifying production-grade discipline for iOS + Android from a single React Native + Expo codebase: the unify-vs-diverge rule, design tokens, safe areas, navigation patterns, FlashList performance, the five-states rule (loading / empty / error / success / **offline**), keyboard + autofill, motion + haptics, accessibility (VoiceOver + TalkBack + Dynamic Type), and platform-specific polish. Activates automatically on any mobile request. Same Swagger backend and feature-folder structure as web, so Phase C/D traceability stays symmetrical across platforms.
11. **React Native Design Review Skill + `/mobile-design-review` slash command** — the mobile enforcement companion to Upgrade 10 and the analog of Upgrade 9 for mobile. Ships `.claude/skills/react-native-design-review/SKILL.md` plus `.claude/commands/mobile-design-review.md`. Runs 17 review categories against the mobile mastery guide, emits a severity-classified report **plus a Platform Parity Check table** (iOS vs Android per concern), and produces a 10-dimension quality scorecard out of 100. The Platform Parity table is the secret weapon: it forces the reviewer to mentally check both platforms for every concern, rather than defaulting to whichever platform the dev tested on.

## V7.0 Scope and Deferrals

**In scope (this release):**

- No breaking changes to agent contracts (`PipelineState`, `GateResult`, etc.) — new types (`HermesEvent`, `EvaluationContract`, `GradingRubric`, `RubricScore`, `PipelineGraph`, `AgentScratch`) are strictly additive
- The 7-stage pipeline graph and SDLC phase map are re-expressed as a declarative `PipelineGraph`, but default concurrency=1 preserves V6 sequential behavior byte-for-byte
- No changes to vault schema, volatility semantics, or contradiction handling
- Hermes subscribes to existing events (`EscalationError`, deploy rollback, gate halt) — does not introduce new ones
- SkillForge reads from existing session logs and vault — does not alter write paths
- Rubrics fall back to current prose prompts when a rubric file is absent — zero-day backward compatibility
- Hard model-family split defaults to disabled; operators opt in per deployment
- Scratch pads are opt-in per agent — non-adopting agents keep working unchanged

**Explicitly deferred to a future release:**

- Migrating agent I/O from CLI-spawn to a structured tool-call protocol
- Giving `QualityGateAgent` live-interaction tools (remains build-and-scan only)
- Bidirectional Hermes (ack / reply flow) requiring an inbound listener
- Cross-repo skill syndication (SkillForge remains single-repo)
- Auto skill promotion without human approval (safety policy, not scope)
- Hierarchical working-memory tiers (Confucius §2) inside a single run — our per-run reset is a reasonable substitute until volume justifies tiers
- Parallel remediation loops (remediation stays serialized even at concurrency > 1)
- Cross-milestone parallelism beyond worktree isolation

These deferrals are intentional: V7.0 ships the changes that were review-validated against the 2026 harness literature. The remaining items require larger-blast-radius changes, new security surface, or policy decisions that are better scheduled as their own numbered release once V7.0 is in production.

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
- Acknowledgement / bidirectional flow (one-way dispatch only in v7.0)

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
- Modification of existing skills (nominate-only, no in-place updates in v7.0)
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

Nominations use the **Anthropic Agent Skills open standard** (agentskills.io) so that promoted skills are portable across Claude, OpenAI, and Atlassian/Figma/Canva/Stripe/Notion/Zapier ecosystems that already adopted the schema. A GSD-local wrapper adds the nomination metadata in `x-gsd-*` keys:

```yaml
---
# Standard Agent Skills fields (agentskills.io)
name: <kebab-case>                        # promoted SKILL.md name
description: <≤ 200 words>                # agent-facing summary
version: 1
allowed-tools: [<optional list>]
# GSD-local nomination metadata (x-gsd-* prefix is ignored by standard loaders)
x-gsd-nomination-id: <short hash>
x-gsd-session-id: <session file name>
x-gsd-pattern: repeated-fix | novel-solution | cross-agent-loop | consolidate-shadow | query-template | multi-step-scratch
x-gsd-confidence: high | medium | low
x-gsd-source-agents: [<agent names>]
x-gsd-sample-invocations: <count>
x-gsd-suggested-path: .claude/skills/<name>/SKILL.md
x-gsd-raw-log-refs: [<paths including scratch pads>]
x-gsd-status: pending | approved | rejected | superseded
---

# <Promotable skill body in Anthropic Agent Skills format>
```

Adopting the open standard means that when a nomination is promoted, the SKILL.md is directly compatible with `agentskills.io`-aware tooling (including Anthropic Skills, OpenAI's adoption of the format, and the published Atlassian/Figma/Canva/Stripe skill catalog). No custom transformation step is required.

### Approval Flow

1. Nominator writes to `memory/skill-nominations/` with `x-gsd-status: pending`
2. `/vault-status` shows pending count
3. Human reviews, runs `/promote-skill <id>`
4. Promoter copies to `.claude/skills/<name>/SKILL.md` (strips `x-gsd-*` keys from the promoted file — they stay in the nomination file for audit), updates nomination `x-gsd-status: approved`, logs to `memory/decisions/`
5. If rejected, human sets `x-gsd-status: rejected` with one-line reason

---

## Upgrade 3 — Evaluator Contracts + Grading Rubrics

### Problem

The V6 pipeline embodies a generator/evaluator pattern but does not enforce it:

- `CodeReviewAgent`, `QualityGateAgent`, and `ReviewAuditorAgent` are nominally evaluators, but their criteria live in prose inside `memory/agents/*.md` system prompts — not in gradable, testable form.
- Evaluator and generator frequently share the same LLM family, which the Anthropic harness-design write-up identifies as a leniency hazard: "models exhibit systematic leniency when judging their own outputs, confidently praising mediocre work" (Rajasekaran 2026).
- There is no "sprint contract" — no negotiated, per-slice definition of "what done looks like" the evaluator later verifies. The orchestrator skips evaluators on green paths (`orchestrator.ts:276–286`), which is correct, but when the evaluator does run it grades against implicit criteria.
- `ReviewAuditorAgent` reads code and logs but cannot click through a running UI or hit live endpoints. Only `E2EValidationAgent` has Playwright access, and it runs after deploy-adjacent stages, not during code review.

### Solution

Three additions, each small and independently useful:

1. **`EvaluationContract`** — a structured object written at the end of `BlueprintFreezeAgent` / `ContractFreezeAgent` that states the acceptance criteria evaluators later grade against. Analogous to Rajasekaran's "sprint contract" between generator and evaluator.
2. **`GradingRubric`** — per-phase rubric files in `memory/knowledge/rubrics/` with explicit dimensions (correctness, security, coverage, architecture-fitness, UX-craft, observability). Each dimension has a 1–5 scale with anchor examples, not a boolean pass/fail.
3. **Evaluator tool-access upgrade** — `ReviewAuditorAgent` gains read-only Playwright access via the same adapter `E2EValidationAgent` uses, so UI changes can be clicked through before deploy.

The evaluator/generator model-family separation is *encouraged but not required* in V7.0: `capability-router.ts` gets a new hint (`role: 'generator' | 'evaluator'`) that prefers a different family when both are available within budget. Hard enforcement is deferred to a future release because it would change routing semantics.

### Scope

**In scope:**
- `EvaluationContract` written by `BlueprintFreezeAgent` and `ContractFreezeAgent`; read by `CodeReviewAgent`, `QualityGateAgent`, `ReviewAuditorAgent`
- Rubric files for: `code-review`, `quality-gate`, `review-auditor`, `e2e-validation`, `post-deploy-validation`
- Rubric loader that falls back to existing prose prompts if the rubric file is absent (backward compatibility)
- Playwright read-only adapter for `ReviewAuditorAgent` (reuse existing `E2EValidationAgent` Playwright wiring)
- Capability-router hint for generator/evaluator family split
- Rubric-scored `GateResult` (evaluators emit dimension scores in addition to current `passed` boolean)

**Out of scope:**
- Hard enforcement of different model families per role (deferred to a future release — would require budget-router rework)
- Rewriting existing agent system prompts (they remain the fallback)
- UI-level grading for non-UI phases (`BlueprintAnalysisAgent` stays text-only)
- Live-interaction access for `QualityGateAgent` (remains build-and-scan only)

### Files to Create

| Path | Purpose |
|---|---|
| `src/harness/evaluation-contract.ts` | `EvaluationContract`, `AcceptanceCriterion`, negotiation helpers |
| `src/harness/rubric-loader.ts` | Reads `memory/knowledge/rubrics/*.md`, validates schema, falls back to prose prompts |
| `src/harness/evaluator-tools.ts` | Read-only Playwright adapter shared by ReviewAuditor + E2EValidation |
| `memory/knowledge/rubrics/code-review.md` | Dimensions, anchors, pass thresholds |
| `memory/knowledge/rubrics/quality-gate.md` | Coverage, security, build-health dimensions |
| `memory/knowledge/rubrics/review-auditor.md` | Cross-review dimensions (architectural coherence, test adequacy, spec alignment) |
| `memory/knowledge/rubrics/e2e-validation.md` | API contract, auth, SP coverage, mock-data guards |
| `memory/knowledge/rubrics/post-deploy-validation.md` | SPA cache, DI health, 500-rate |
| `memory/architecture/evaluator-contracts.md` | Vault note documenting the pattern |

### Files to Modify

| Path | Change |
|---|---|
| `src/harness/types.ts` | Add `EvaluationContract`, `AcceptanceCriterion`, `GradingRubric`, `RubricScore`, `DimensionScore` |
| `src/agents/blueprint-freeze-agent.ts` | Emit `EvaluationContract` at freeze time |
| `src/agents/contract-freeze-agent.ts` | Emit `EvaluationContract` at SCG1 time |
| `src/agents/code-review-agent.ts` | Read contract + rubric; emit dimension scores |
| `src/agents/quality-gate-agent.ts` | Read rubric; emit dimension scores alongside `passed` |
| `src/agents/review-auditor-agent.ts` | Read rubric; gain Playwright read-only access |
| `src/agents/e2e-validation-agent.ts` | Emit dimension scores conformant to rubric |
| `src/agents/post-deploy-validation-agent.ts` | Emit dimension scores conformant to rubric |
| `src/harness/capability-router.ts` | Honor `role: 'generator' \| 'evaluator'` hint when selecting model |
| `src/harness/orchestrator.ts` | Thread `EvaluationContract` through `PipelineState`; log rubric scores to decisions |
| `memory/agents/*.md` (evaluators) | Reference rubric file; remove duplicated criteria prose (keep as fallback via rubric loader) |
| `CLAUDE.md` | Document rubric location in Memory Rules section |

### Agent Contract

```ts
interface AcceptanceCriterion {
  id: string;                       // "AC-001"
  dimension: RubricDimension;       // "correctness" | "security" | "coverage" | ...
  description: string;              // ≤ 200 chars, testable
  verificationMethod: 'automated' | 'evaluator-inference' | 'live-interaction';
  blocker: boolean;                 // if true, failing this vetoes deploy
}

interface EvaluationContract {
  milestoneId: string;
  sliceId: string;
  frozenAt: string;                 // ISO
  frozenBy: AgentName;              // BlueprintFreezeAgent | ContractFreezeAgent
  criteria: AcceptanceCriterion[];
  rubricRefs: string[];             // paths to rubric files in memory/knowledge/rubrics/
}

type RubricDimension =
  | 'correctness'
  | 'security'
  | 'coverage'
  | 'architecture-fitness'
  | 'ux-craft'
  | 'observability'
  | 'performance';

interface DimensionScore {
  dimension: RubricDimension;
  score: 1 | 2 | 3 | 4 | 5;         // anchored; 1 = critical gap, 5 = exemplary
  evidence: string[];               // file paths, test ids, screenshots
  rationale: string;                // ≤ 300 chars
}

interface RubricScore {
  agentId: AgentName;
  contractRef: string;              // path to EvaluationContract
  dimensions: DimensionScore[];
  aggregate: number;                // mean of blocker dimensions
  passed: boolean;                  // true iff no blocker dimension scored ≤ 2
  evaluatedAt: string;
}
```

### Rubric File Schema

Each rubric file is a vault note with YAML frontmatter + dimension table:

```yaml
---
type: rubric
phase: code-review
applies_to: [CodeReviewAgent]
version: 1
last_updated: 2026-04-22
---

# Code Review Rubric

| Dimension | 1 (critical gap) | 3 (acceptable) | 5 (exemplary) | Blocker? |
|---|---|---|---|---|
| correctness | logic error in happy path | edge cases handled | all branches + invariants tested | yes |
| security | OWASP top-10 violation | no known CVE patterns | defense-in-depth + auth review | yes |
| coverage | < 40% on changed lines | ≥ 80% on changed lines | ≥ 95% + mutation-tested | yes |
| architecture-fitness | violates layer boundaries | respects boundaries | enforces via tests | no |
| observability | no logging | structured logs on errors | correlation ids + traces | no |
```

### Evaluator Tool Access

Add `evaluator-tools.ts` as a narrow, read-only adapter:

```ts
interface EvaluatorTools {
  readRepo(path: string): Promise<string>;        // read-only
  runTests(glob: string): Promise<TestReport>;    // no write side-effects
  openPreview(url: string): Promise<PreviewSession>; // Playwright CLI, read-only page
  screenshot(selector?: string): Promise<string>; // stored in observability/
  // No file writes. No shell exec. No git mutations.
}
```

Tool access is gated by a write-path allowlist that matches the existing GitTxn wrapping in the orchestrator: evaluators may only write under `memory/observability/`, never to source code.

**Transport choice — Playwright CLI, not MCP.** Microsoft's own guidance for agentic coding now recommends the Playwright CLI (`@playwright/cli`) over the Playwright MCP server: the CLI produces roughly **4x fewer tokens per session** because it returns concise test-report JSON instead of the MCP server's verbose DOM snapshots + page-state payloads. V7.0 standardizes on the CLI for both `ReviewAuditor` (Upgrade 3) and the existing `E2EValidationAgent`. The MCP server remains a supported fallback when a specific agent needs interactive DOM traversal, but it is no longer the default.

**Benchmark reference for rubric calibration.** Rubric anchors that reference "industry-standard coverage of similar tasks" should point to **SWE-Bench Pro**, not SWE-Bench Verified. OpenAI retired Verified as an internal benchmark after frontier models memorized the gold patches; Pro is the current authoritative leaderboard (`labs.scale.com/leaderboard/swe_bench_pro_public`). Rubric files may cite Pro scores when calibrating the 1–5 anchors.

### Orchestrator Integration

- `PipelineState` gains `evaluationContract: EvaluationContract` (optional — absent for pre-V7.0 resumed runs)
- Each evaluator stage in `orchestrator.ts:executeStage()` loads the contract from state and the rubric from `memory/knowledge/rubrics/{phase}.md`
- Failed blocker dimensions route to `RemediationAgent` (unchanged control flow; only the failure reason is more structured)
- `DecisionRecord` entries now include `rubricScore?: RubricScore` alongside the existing rationale — rule #7 unchanged, decisions are just richer
- Hard rule preserved: `DeployAgent` still refuses to run unless `GateResult.passed === true`; V7.0 adds "*and no blocker dimension scored ≤ 2*" to the assertion

### Why This Doesn't Need a Breaking Change

- If no `EvaluationContract` is present, evaluators behave exactly as in V6 (fall back to prose prompts)
- If a rubric file is missing, evaluators emit a single synthetic dimension (`legacy-prose`) and continue
- `RubricScore` is optional on `GateResult` — consumers can ignore it
- Capability-router role hint is advisory in Upgrade 3; Upgrade 5 promotes it to enforced behind a config knob

---

## Upgrade 4 — Fork-Join DAG Pipeline

### Problem

V6 carries a complete DAG scheduler at [src/harness/execution-graph.ts:106](src/harness/execution-graph.ts#L106) — `ExecutionGraph.runGraph()` already supports dependency-aware concurrent execution, cycle detection, ready/blocked set computation — but the pipeline orchestrator ignores it and runs a hardcoded linear for-loop ([src/harness/orchestrator.ts:262–349](src/harness/orchestrator.ts#L262)). Independent stages (`audit` and `e2e` both read-only, no shared writes) execute one after the other for no architectural reason.

The Scaffold Taxonomy paper (arXiv:2604.03515) finds that 11 of 13 surveyed coding agents *compose* multiple loop primitives (ReAct + generate-test-repair + plan-execute + multi-attempt retry). V6 uses ReAct + multi-attempt retry only, despite having the infrastructure for a fourth primitive.

### Solution

Rewire `orchestrator.run()` to build a declarative `PipelineGraph` and delegate execution to `ExecutionGraph.runGraph(tasks, { concurrency })`. Sequential behavior is preserved exactly when `concurrency: 1` (the default). Operators opt into parallel execution by bumping the knob in `memory/knowledge/pipeline-config.md`.

### Scope

**In scope:**

- Declarative `PipelineGraph` in `src/harness/pipeline-graph.ts` — stages are nodes, dependencies are edges
- Default concurrency=1 preserves V6 order byte-for-byte; parallel execution opt-in
- `audit` and `e2e` marked as runnable in parallel when both are green-pathed and concurrency > 1
- `PipelineState` gains `graphVersion: string` so resume across graph-version changes is a controlled event
- Decision log records the ready/blocked set at each tick for auditability (rule #7 unchanged)

**Out of scope:**

- Parallel remediation loops — remediation stays serialized within a milestone to preserve the existing stuck-detection semantics ([orchestrator.ts:693–702](src/harness/orchestrator.ts#L693))
- Cross-milestone parallelism — worktree isolation already provides this at the next layer up
- Dynamic re-planning — the graph is static per run; conditional skips already handle branch-on-result
- Parallel SDLC phase execution — SDLC phases A–E have hard dependencies and stay sequential

### Files to Create

| Path | Purpose |
|---|---|
| `src/harness/pipeline-graph.ts` | `PipelineGraph`, `StageNode`, default V7.0 graph factory |
| `memory/knowledge/pipeline-config.md` | `concurrency`, `stopOnFailure`, per-stage timeout overrides |
| `memory/architecture/pipeline-graph.md` | Vault note documenting node/edge structure + parallel pairs |

### Files to Modify

| Path | Change |
|---|---|
| `src/harness/orchestrator.ts` | Replace `run()` for-loop with `ExecutionGraph.runGraph()` invocation; keep existing handlers as node executors |
| `src/harness/execution-graph.ts` | Harden for pipeline use — ensure `stopOnFailure` truly halts siblings mid-wave, not just on next tick |
| `src/harness/types.ts` | Add `PipelineGraph`, `StageNode`, extend `PipelineState` with `graphVersion` |
| `src/index.ts` | `--concurrency N` CLI override for ad-hoc runs |
| `memory/architecture/agent-system-design.md` | Update task graph to match the new PipelineGraph shape |
| `CLAUDE.md` | Update the "Current Pipeline Stage Map" table with dependency columns |

### Agent Contract

```ts
interface StageNode {
  id: PipelineStage;              // 'blueprint' | 'review' | ... | 'post-deploy'
  dependsOn: PipelineStage[];     // hard prerequisites
  parallelizableWith?: PipelineStage[]; // advisory — ExecutionGraph scheduler uses this
  execute: (state: PipelineState) => Promise<StageResult>;
  retryBudget: number;
  timeoutMs: number;
}

interface PipelineGraph {
  version: string;                // bump on structural changes
  nodes: StageNode[];
  concurrency: number;            // default 1
  stopOnFailure: boolean;         // default true
}
```

### Default V7.0 Graph

```
blueprint ──▶ review ──▶ remediate (conditional) ──▶ gate ──┬─▶ audit ───┐
                                                            └─▶ e2e   ───┴─▶ deploy ──▶ post-deploy
```

`audit` and `e2e` both depend on `gate` but have no dependency on each other. At `concurrency: 2` they run simultaneously, saving wall-clock on every pipeline run.

### Backward Compatibility

- Default `concurrency: 1` → behavior identical to V6 (same order, same timing within noise)
- `--from-stage X` continues to work — resume picks up from node with id X
- State files from V6 lack `graphVersion`; loader assigns `v6-linear` and maps to the default V7.0 graph
- Resume across incompatible `graphVersion` requires `--force-restart` (explicit, not silent)

### Why This Doesn't Need Structural Change to the SDLC Layer

SDLC phases A–E have hard dependencies (Figma needs requirements; contracts need blueprint). The SDLC orchestrator stays sequential. Only the pipeline (phases F–G) gets the DAG treatment because only there do we have provable independent stages.

---

## Upgrade 5 — Hard Generator/Evaluator Model-Family Split

### Problem

Upgrade 3 adds a `role: 'generator' | 'evaluator'` hint to the capability router but leaves it advisory. If budget pressure pushes the router to select the same family for both roles (e.g. Sonnet 4.6 for both `RemediationAgent` and `CodeReviewAgent`), Rajasekaran's core finding — "models exhibit systematic leniency when judging their own outputs" — applies unmitigated. The evaluator has every incentive to rationalize the generator's output because they were trained on the same distribution.

### Solution

Promote the role hint to a hard constraint, gated by an opt-in config knob. When `familySplit.enforce: true`, the capability-router refuses to assign the same model family to generator and evaluator within a single milestone run. The evaluator family is pinned at milestone start and the generator family is chosen from the remaining pool. Single-family deployments have an explicit escape hatch.

### Scope

**In scope:**

- New config section in `memory/knowledge/model-strategy.md`:
  ```yaml
  familySplit:
    enforce: false              # default off; operators opt in
    escape: 'fail-closed'       # or 'single-family-ok' for single-family deployments
    evaluatorPreference: [anthropic, openai, google]  # tie-break order
  ```
- Router pins evaluator family at milestone start; logs the decision to `memory/decisions/`
- Per-agent family assignments flow through `PipelineState` for resume parity
- When `enforce: true` and only one family is configured, router throws `FamilyConfigError` unless `escape: 'single-family-ok'`

**Out of scope:**

- Forcing split across tiers within the same family (Sonnet vs Haiku — not what Rajasekaran's finding is about)
- Forcing split for non-generator/non-evaluator agents (Hermes, DeployAgent) — they route normally
- Dynamic family re-selection mid-milestone

### Files to Modify

| Path | Change |
|---|---|
| `src/harness/capability-router.ts` | Honor `familySplit` config; pin evaluator family at milestone start |
| `src/harness/types.ts` | Add `FamilyAssignment`, `FamilyConfigError` |
| `memory/knowledge/model-strategy.md` | Add `familySplit` config section |
| `memory/architecture/evaluator-contracts.md` | Document the hard-split invariant |
| `CLAUDE.md` | Add rule: "when familySplit.enforce is true, evaluator and generator families diverge within a milestone" |

### Contract

```ts
interface FamilyAssignment {
  milestoneId: string;
  evaluatorFamily: ModelFamily;       // pinned for the run
  generatorFamily: ModelFamily;       // pinned for the run
  decidedAt: string;                  // ISO
  rationale: string;                  // which rule fired, which budget tiers were available
}

class FamilyConfigError extends Error {
  constructor(reason: 'only-one-family-available' | 'escape-unset' | 'preference-exhausted');
}
```

### Backward Compatibility

- Default `familySplit.enforce: false` → Upgrade 3's advisory hint behavior is preserved exactly
- Operators opt in by flipping the knob and restarting the pipeline
- Single-family deployments set `escape: 'single-family-ok'` and continue unaffected

### Why This Belongs in V7.0, Not Later

Upgrade 3 already adds the role hint and the generator/evaluator roles in the agent registry. Upgrade 5 is the *one-line behavior flip* that turns a documented contract into an enforced one. Shipping them in the same release removes the risk of the hint remaining advisory forever.

---

## Upgrade 6 — Agent Scratch Pads + Gather/Act/Verify Phase Framing

### Problem

V6 agents produce a structured output plus log lines. Intermediate reasoning, rejected hypotheses, partial evidence, and dead-end explorations are lost at the end of each task. Two independent sources name this as a harness-design gap:

- **Confucius Code Agent** (arXiv:2512.10398): persistent note-taking decouples working memory from exploration depth — "agents maintain structured external notes capturing intermediate findings, hypotheses tested, and dead-ends explored." V6 has no equivalent.
- **Anthropic "How Claude Code works"**: frames the agentic loop as three explicit phases — *gather context → take action → verify results*. V6 agents don't label their phase mix; everything is conflated inside one `execute()` call.

The practical cost: debugging a failed RemediationAgent or E2EValidationAgent run requires re-executing with verbose logging because the "why did it pick this approach" trace is ephemeral. SkillForge (Upgrade 2) has to reconstruct intent from outputs alone, which degrades pattern-detection precision.

### Solution

Two tightly-linked changes:

1. **Scratch pads.** Every `BaseAgent.execute()` gains a `this.scratch` helper that writes append-only, timestamped markdown to `memory/observability/scratch/{runId}/{agentId}.md`. Notes are categorized by phase (`gather | act | verify`) and kept across resume. Purely opt-in — agents that never call `this.scratch.*` write nothing.
2. **Phase labels.** Each agent declares its phase mix in `memory/agents/{agentId}.md` frontmatter (e.g. `phases: [gather, verify]` for CodeReviewAgent, `phases: [gather, act, verify]` for RemediationAgent). `BaseAgent` wraps each declared phase with a structured log line — no behavior change, just observability.

### Scope

**In scope:**

- `src/harness/agent-scratch.ts` — small append-only helper; ~50 lines
- `memory/observability/scratch/` — new directory, created lazily per run
- `BaseAgent` gains `this.scratch.gather(note)`, `.act(note)`, `.verify(note)` methods
- `phases:` key added to every `memory/agents/*.md` frontmatter (one-word list)
- SkillForge gains pattern 6: "scratch trace shows consistent multi-step reasoning across ≥ 3 sessions"
- Scratch pads are included in SkillForge nomination `raw_log_refs`

**Out of scope:**

- Forcing agents to use scratch — existing agents work unchanged; adoption is incremental
- Real-time streaming of scratch to external systems — disk-only in V7.0
- Scratch-based replay / re-execution — scratch is for debugging and nomination, not rehydration
- Hierarchical memory tiers (Confucius §2) — out of scope, queued for V8

### Files to Create

| Path | Purpose |
|---|---|
| `src/harness/agent-scratch.ts` | Append-only scratch helper with phase API |
| `memory/observability/scratch/` | Scratch directory (per-run subdirs) |
| `memory/architecture/agent-phases.md` | Vault note documenting the gather/act/verify contract |

### Files to Modify

| Path | Change |
|---|---|
| `src/harness/base-agent.ts` | Instantiate `this.scratch` per task; wrap phases with log lines |
| `src/harness/types.ts` | Add `AgentScratch`, `AgentPhase`, `ScratchNote` |
| `memory/agents/*.md` (all 14 + Hermes) | Add `phases:` frontmatter key |
| `src/harness/skill-forge/patterns.ts` | Add pattern 6 — "multi-step scratch consistency" |
| `src/harness/skill-forge/nominator.ts` | Read scratch pads as signal |
| `CLAUDE.md` | Document scratch location and phase labels in Memory Rules |

### Three-Audience View (Confucius AX/UX/DX)

The Confucius Code Agent paper (arXiv:2512.10398) argues the same working memory must be served to three distinct audiences with different needs: **Agent Experience (AX)** wants compressed, structured state; **User Experience (UX)** wants rich, skimmable traces; **Developer Experience (DX)** wants both with full raw evidence. V7.0 adopts this split at the scratch-pad layer so one write produces three derived views:

| View | File / field | Audience | Contents |
|---|---|---|---|
| `ax` (default) | `scratch/{runId}/{agentId}.ax.md` | Later agents in the pipeline — e.g., RemediationAgent reading CodeReviewAgent's scratch | Compressed bullet list per phase. Skips evidence bodies. `ax: false` notes are excluded. Capped at ~2 KB per agent per run. |
| `ux` | `scratch/{runId}/{agentId}.ux.md` | Humans reviewing a failed run | Readable narrative with phase headers, tag callouts, and inline evidence links |
| `dx` | `scratch/{runId}/{agentId}.dx.jsonl` | SkillForge, evaluator tools, debuggers | Full append-only JSONL — one `ScratchNote` per line, nothing dropped |

Authors call `this.scratch.{gather\|act\|verify}(body, { ax, ux, tags })` once; the helper writes to all three derived views based on the opt-out flags.

### Contract

```ts
type AgentPhase = 'gather' | 'act' | 'verify';
type AudienceFlag = { ax?: boolean; ux?: boolean };  // both default true; dx is always captured

interface ScratchNote {
  phase: AgentPhase;
  at: string;                    // ISO timestamp
  agentId: AgentName;
  runId: string;
  body: string;                  // ≤ 2000 chars per note
  audience: Required<AudienceFlag>;
  tags?: string[];               // hypothesis | dead-end | finding | evidence | secret (auto-redacted from ux/ax)
}

interface AgentScratch {
  gather(body: string, opts?: AudienceFlag & { tags?: string[] }): void;
  act(body: string, opts?: AudienceFlag & { tags?: string[] }): void;
  verify(body: string, opts?: AudienceFlag & { tags?: string[] }): void;
  dump(view?: 'ax' | 'ux' | 'dx'): ScratchNote[] | string;  // for tests / SkillForge
}

interface AgentFrontmatter {
  // ... existing fields
  phases: AgentPhase[];          // declared phase mix; informs wrapper logging
}
```

### Backward Compatibility

- Agents that never call `this.scratch.*` produce no files (zero disk impact)
- Missing `phases:` frontmatter defaults to `[gather, act, verify]` — no breakage
- Pattern 6 in SkillForge activates only when ≥ 3 agents have adopted scratch — lazy ramp-up
- Deleting `memory/observability/scratch/` at any time is safe — next run recreates it

### Why V7.0 Needs This Even Though It's "Just Logging"

Three reasons:

1. **Debuggability scales with run length.** V7.0 pipelines run longer (DAG parallelism, evaluator contracts, richer remediation). Without scratch pads, post-mortems require rerunning pipelines with verbose flags — expensive and irreproducible if upstream state has drifted.
2. **SkillForge precision.** Patterns derived from output alone miss the why. Patterns derived from scratch get the full reasoning trace and produce higher-quality nominations.
3. **Phase framing is free alignment.** Labeling `phases:` in frontmatter costs one line per agent, but once it exists, hooks and observability dashboards can differentiate "time spent gathering" vs "time spent verifying" — critical for future cost analysis.

---

## Upgrade 7 — Extended Model Pool (Gemini Flash-Lite + DeepSeek V4 + GPT-5.5)

### Problem

V6's `memory/knowledge/model-strategy.md` routes across three families: Anthropic (Claude Max), OpenAI (ChatGPT Max / Codex), and Google (Gemini Ultra). The 2026-04-23 research sweep surfaced three routing opportunities that are small in effort but meaningful in practice:

1. **Gemini 3.1 Flash-Lite** — a new cheap generator lane from Google that slots cleanly between Sonnet/Codex-mini and bulk DeepSeek usage
2. **DeepSeek V4** (1T MoE, ~81% SWE-bench, projected ~$0.30/MTok) — announced but not yet shipped; "coming in next few weeks" per Reuters 2026-04-06
3. **GPT-5.5** — announced 2026-04-23, already rolling out to Codex CLI ahead of the public API; likely accessible at $0 marginal cost via the existing `codex` OAuth flow if the operator's subscription tier is in the wave

Upgrade 5 (hard generator/evaluator family split) is materially stronger with three families in the pool than with two. A two-family deployment forces generator + evaluator to use the only two available choices; a three-family deployment gives the router tie-break room and lets cost pressure steer the generator lane without collapsing the split.

### Solution

Add all three as **feature-flagged routing slots** in `memory/knowledge/model-strategy.md`. Each slot activates only when its gating condition is satisfied — a V7.0 deployment with no new endpoint access keeps V6 routing byte-for-byte.

Gating conditions:

| Slot | Feature flag | Gating condition |
|---|---|---|
| Gemini 3.1 Flash-Lite | `models.gemini.flashLite.enabled: true` | `GOOGLE_API_KEY` set or `gemini` CLI reports `flash-lite` in `models list` |
| DeepSeek V4 | `models.deepseek.v4.enabled: 'probe'` | Router probes `POST /v1/chat/completions` with `"model":"deepseek-v4"` at startup; activates if 200, otherwise falls back to `deepseek-chat` (V3.2) |
| GPT-5.5 (API) | `models.openai.gpt55.enabled: 'probe'` | Router probes Responses API; activates if 200; until then, generator stays on Opus 4.7 / Codex-mini |
| GPT-5.5 (OAuth-Codex) | `models.openai.gpt55.codexCli: true` | Router invokes `codex models list` at startup; activates if `gpt-5.5` (or equivalent id) is present AND the operator's subscription tier is in the rollout wave |

### Scope

**In scope:**

- Three new slots in `memory/knowledge/model-strategy.md` (`models.gemini.flashLite`, `models.deepseek.v4`, `models.openai.gpt55`) with `enabled: false | 'probe' | true` knob
- Startup probe logic in capability-router that checks endpoint availability once per pipeline run and caches the result in `PipelineState.modelProbes`
- OAuth-Codex probe invokes `codex models list` and scans for a GPT-5.5-shaped id without hard-coding the exact string (accepts `gpt-5.5`, `gpt-5.5-codex`, etc.)
- When a probe fails, router falls back to the V6 default for that slot and logs the decision to `memory/decisions/`
- `familySplit.evaluatorPreference` in Upgrade 5 gains Google as a valid third entry so the tie-break picks Flash-Lite when the budget requires it

**Out of scope:**

- Automatic cost re-estimation when a new slot activates (the existing cost accumulator already measures per-call; no proactive recalc)
- Hard-coding any model id strings — all three slots resolve ids at startup via the respective CLI or API
- Per-project override of the global model pool (defer to a future release)

### Files to Modify

| Path | Change |
|---|---|
| `memory/knowledge/model-strategy.md` | Add `models.gemini.flashLite`, `models.deepseek.v4`, `models.openai.gpt55` sections with feature flags and gating |
| `src/harness/capability-router.ts` | Add startup probe helper; honor new slots; cache probe results in `PipelineState.modelProbes` |
| `src/harness/types.ts` | Add `ModelProbeResult`, `ExtendedModelPoolConfig` |
| `memory/knowledge/feature-check-schedule.md` | Confirm 2026-04-23 entry already captures GPT-5.5 / DeepSeek V4 / Gemini Flash-Lite routing guidance (done) |
| `CLAUDE.md` | Add note: "Three feature-flagged model slots may activate at startup — check `memory/decisions/` for the probe outcome" |

### Contract

```ts
interface ModelProbeResult {
  slot: 'gemini-flash-lite' | 'deepseek-v4' | 'gpt-5.5-api' | 'gpt-5.5-codex-oauth';
  probedAt: string;
  available: boolean;
  resolvedModelId?: string;       // actual id returned by the endpoint / CLI
  fallbackUsed?: string;          // which V6 default was used when probe failed
  reason?: string;                // why the probe failed
}

interface ExtendedModelPoolConfig {
  gemini: { flashLite: { enabled: boolean | 'probe' } };
  deepseek: { v4: { enabled: boolean | 'probe' } };
  openai: { gpt55: { enabled: boolean | 'probe'; codexCli: boolean } };
}
```

### Backward Compatibility

- Default config for all three slots is `enabled: false` — V7.0 with no operator action routes identically to V6
- Operators opt in per slot; probes run at pipeline start and cache in state so the decision is stable across a run
- When a slot's endpoint disappears mid-run (e.g., API SKU changes), router falls back on next restart — no runtime guessing

### Why V7.0 Needs All Three Together

Each slot is individually small. Bundling them means:

- The `familySplit` pool grows by one family in one commit (Gemini is the third)
- Operators who install the spec once get GPT-5.5 routing the moment OpenAI flips the API SKU live, without a V7.1
- DeepSeek V4 is already in the config if it ships on the pre-announced timeline — no scramble

---

## Upgrade 8 — Fluent UI React v9 Mastery Skill

### Problem

V6 ships a handful of Claude Code skills at `.claude/skills/` — `react-ui-design-patterns`, `composition-patterns`, `web-design-guidelines`, `sql-expert`, `sql-performance-optimizer`. They cover targeted situations (async state patterns, component composition, accessibility audits) but none of them codifies the *full* design-and-implementation discipline required for a production-grade Fluent UI React v9 frontend. In practice this means every generated UI regresses to "plausible but generic admin panel" — hex colors creep in, `@fluentui/react` v8 imports appear, the four-states rule (loading / empty / error / content) is half-implemented, and form components skip `Field`, `Zod`, or `useQuery`.

The **Microsoft-level baseline** is what separates a usable output from a shippable one. Without a skill that captures it, we re-derive the discipline on every project.

### Solution

Ship a new skill at `.claude/skills/fluent-v9-mastery/SKILL.md` that codifies the full Fluent UI React v9 discipline as a single mandatory reference for all frontend code generation. The skill activates automatically whenever the user requests frontend work, React components, Fluent UI, UI/UX design, screen implementation, form building, or any visual polish pass.

The skill covers 15 parts spanning design philosophy, the token system, Griffel styling, theming, layout, component selection, forms with React Hook Form + Zod + TanStack Query, the four-states rule, accessibility, polish details, TypeScript code quality, forbidden anti-patterns, a pre/post-coding checklist, unknown-pattern fallback, and a definition of done.

### Scope

**In scope:**

- Full `SKILL.md` at `.claude/skills/fluent-v9-mastery/SKILL.md` with trigger description, parts 1–15, and related-skill cross-references
- Trigger description tuned so the skill auto-activates on any frontend-coding request in this repo
- Related skills `/react-ui-design-patterns`, `/composition-patterns`, `/web-design-guidelines` kept in place — fluent-v9-mastery layers on top, it does not replace them
- `CLAUDE.md` gains a row in the Installed Skills section pointing at the new skill
- `docs/GSD-Claude-Code-Skills.md` gains a section explaining when fluent-v9-mastery activates vs the narrower React skills

**Out of scope:**

- Codifying backend or SQL discipline — covered by `sql-expert` and `sql-performance-optimizer`
- Automated enforcement (lint rules that reject hex colors, v8 imports, etc.) — V7.0 ships the skill as feedforward guidance; automated sensors are a V8 candidate
- A matching dark-mode or brand-customization skill — future release

### Files to Create

| Path | Purpose |
|---|---|
| `.claude/skills/fluent-v9-mastery/SKILL.md` | The full 15-part skill (frontmatter + body) |

### Files to Modify

| Path | Change |
|---|---|
| `CLAUDE.md` | Add `/fluent-v9-mastery` row to Installed Skills section with activation criteria |
| `docs/GSD-Claude-Code-Skills.md` | Add section describing the skill, when it activates, and how it layers with the narrower React skills |
| `memory/knowledge/rubrics/code-review.md` (when Upgrade 3 ships) | Reference fluent-v9-mastery anti-patterns in the `ux-craft` dimension anchors |

### Skill Frontmatter

```yaml
---
name: fluent-v9-mastery
description: >
  Production-grade Fluent UI React v9 design and implementation discipline.
  Activates whenever the user requests frontend work, React components, Fluent
  UI, UI/UX design, screen implementation, form building, or any visual polish
  pass on generated projects.
metadata:
  stack: "@fluentui/react-components v9, Griffel, React 18, TypeScript strict, React Hook Form, Zod, TanStack Query v5"
  related-skills: [react-ui-design-patterns, composition-patterns, web-design-guidelines]
  version: '1.0.0'
  applies-to: frontend-code-generation, ui-review, visual-polish
---
```

### How It Layers With Existing Skills

| Situation | Skill that owns it |
|---|---|
| Any non-trivial frontend screen, form, or component | `/fluent-v9-mastery` (primary; activates first) |
| Async state machinery, skeletons, optimistic updates | `/react-ui-design-patterns` (detail; called into from within fluent-v9-mastery Part 8) |
| Compound components, render props, context providers | `/composition-patterns` (detail; called into from fluent-v9-mastery Part 6) |
| Accessibility audit / UX review of existing UI | `/web-design-guidelines` (review pass; may cite fluent-v9-mastery Part 9) |

### Backward Compatibility

- Skill is entirely additive — no existing skill or agent behavior changes
- If the skill file is deleted, the pipeline continues with the narrower React skills as in V6
- No change to any code path; skill activation is handled by Claude Code's built-in skill system

### Why This Belongs in V7.0

Three reasons:

1. **Frontend baseline parity with backend.** SQL and security have deep skills (`/sql-expert`, `/owasp-security`, `/shannon`). Frontend was the weakest leg of the discipline stack
2. **It multiplies Upgrade 3 (rubrics).** The ReviewAuditor's `ux-craft` dimension has explicit anchors to point at once this skill exists; without it, anchors are vague
3. **The skill is a one-file write with zero runtime cost.** No agent changes, no router changes, no pipeline changes. Shipping it in V7.0 means every generated project from day one of V7.0 benefits

---

## Upgrade 9 — Fluent UI React v9 Design Review Skill + `/design-review` Slash Command

### Problem

Upgrade 8 codifies *how* to build Fluent UI v9 — the feedforward guidance that shapes generation. But Böckeler's framing makes clear that **feedforward alone is not enough**: a harness also needs feedback sensors that observe output and flag violations after the fact. V6 and V7.0-through-Upgrade-8 have no systematic review pass for generated frontend code. CodeReviewAgent (V6) is general-purpose; it catches gross bugs but not Fluent-specific violations like `padding: '16px'` instead of `shorthands.padding(tokens.spacingVerticalL, ...)`, `Dropdown` used where `Combobox` fits, or missing empty states.

Every project to date has shipped with some Fluent violations that a rigorous review would have caught. Without a companion to the mastery skill, those violations accumulate and drift the codebase away from the standard.

### Solution

Two tightly-linked artifacts:

1. **`.claude/skills/fluent-v9-design-review/SKILL.md`** — a skill that auto-activates on "review this", "audit", "design review", "check the code", or end-of-Phase-D feature completion. Runs 15 review categories against the mastery guide (framework imports, theming, tokens, Griffel, typography, layout, primitives, four states, forms, server state, a11y, motion, responsive, code quality, polish) and emits a Review Report in a fixed format with severity-classified findings and an 8-dimension quality scorecard (Overall design quality score: X/80).
2. **`.claude/commands/design-review.md`** — an explicit `/design-review <scope>` slash command that invokes the same skill against a named scope (file, feature, or recent diff).

The pair forms a **feedforward (Upgrade 8) + feedback (Upgrade 9) sensor loop** per Böckeler. Mastery is the source of truth; Review is the enforcer.

### Scope

**In scope:**

- Full `SKILL.md` at `.claude/skills/fluent-v9-design-review/SKILL.md` with all 15 review categories, severity levels, fix-application workflow, and report format
- `/design-review` slash command at `.claude/commands/design-review.md` for explicit invocation with a scope argument
- Auto-trigger phrases in the skill description so it activates on "review", "audit", "design review", "check the code", feature completion
- Companion-skill cross-reference: review findings cite the mastery guide's specific part numbers (e.g., "Violates Part 3: Griffel requires `shorthands.padding()`")
- Fix-application mode: when the user responds "apply fixes", the skill auto-fixes all Blockers + Criticals, proposes Majors for approval, and lists Minors for later
- Report format includes an 8-dimension metrics scorecard so quality trends can be tracked across features over time

**Out of scope:**

- Automated CI-level gating (V7.0 ships as interactive reviews; CI integration is a V8 candidate)
- Cross-feature trend dashboards (scorecard is produced per-review; aggregation is manual)
- Lint/Semgrep sensors that reject violations at commit time (queued for V8 per Appendix B)
- Backend or SQL review — covered by other skills

### Files to Create

| Path | Purpose |
|---|---|
| `.claude/skills/fluent-v9-design-review/SKILL.md` | Full 15-category review skill with report format and fix workflow |
| `.claude/commands/design-review.md` | `/design-review <scope>` slash command that invokes the skill |

### Files to Modify

| Path | Change |
|---|---|
| `CLAUDE.md` | Add `/fluent-v9-design-review` skill row and `/design-review` command note to Installed Skills section |
| `docs/GSD-Claude-Code-Skills.md` | Add section on the mastery + review skill pairing |
| `memory/agents/code-review-agent.md` | Note that on frontend slices, CodeReviewAgent should invoke `/design-review` as its visual-quality pass (preserves the rubric-scored generic review but adds Fluent-specific depth) |
| `memory/knowledge/rubrics/code-review.md` (when Upgrade 3 ships) | Reference Upgrade 9's review categories as the `ux-craft` dimension anchors — anchors become concrete instead of vague |

### Severity Levels

| Level | Meaning | Merge block? |
|---|---|---|
| 🔴 Blocker | Ships broken, inaccessible, or violates a hard rule (v8 imports, hex colors, no error state) | Yes |
| 🟠 Critical | Noticeably unprofessional or degrades UX (missing loading state, hand-rolled table) | Yes |
| 🟡 Major | Visibly off-brand or wrong pattern (wrong typography token, missing hover state, raw pixel spacing) | Fix this sprint |
| 🔵 Minor | Polish issue (copy could be tighter, icon could be Filled when selected) | Fix when touching the file |
| ⚪ Nit | Subjective preference | Note but don't require |

### Review Report Format (enforced by the skill)

```text
# Design Review: <scope>

Reviewed: <N> files, <M> lines
Date: <date>
Overall verdict: ✅ Ship it | ⚠️ Ship after fixes | ❌ Not ready

## Summary
<2–3 sentences. Lead with what's good, then headline issues>

## Findings by Severity
  🔴 Blockers (<count>)
  🟠 Critical (<count>)
  🟡 Major (<count>)
  🔵 Minor (<count>)
  ⚪ Nits (<count>)

## Strengths
<3–5 bullets on what was done well>

## Recommended Fix Order
1. Blockers
2. Criticals
3. Majors (follow-up PR)

## Metrics (scored /10 each; overall /80)
  Token discipline
  Component primitive fit
  State coverage (loading / empty / error / success)
  Accessibility
  Forms & validation
  Responsive
  Code quality
  Polish & copy

## Next Steps
<One paragraph. Offer to apply Blocker + Critical fixes automatically>
```

### Integration with CodeReviewAgent (V7.0 Upgrade 3)

When Upgrade 3 ships rubrics, the `code-review` rubric's `ux-craft` dimension gains concrete 1–5 anchors derived directly from Upgrade 9's severity levels:

| Rubric score | Equivalent review verdict |
|---|---|
| 1 (critical gap) | ≥ 1 Blocker finding |
| 2 (inadequate) | 0 Blockers but ≥ 2 Critical findings |
| 3 (acceptable) | ≤ 1 Critical finding; Majors ≤ 5 |
| 4 (strong) | 0 Critical findings; Majors ≤ 2 |
| 5 (exemplary) | 0 Blocker/Critical/Major findings; only Minor/Nit |

This makes the `ux-craft` dimension gradable by running the review skill, not by subjective judgment.

### Three Ways to Invoke

| Mode | Trigger | When to use |
|---|---|---|
| Slash command | `/design-review src/features/orders` | Explicit, ad-hoc review of a named scope |
| Auto-activation | User says "review this", "audit", "design review" | Natural-language review request |
| Phase D auto-trigger | End of feature implementation in the autonomous pipeline | Pre-merge gate — catches regressions before they ship |

### Backward Compatibility

- Skill and command are entirely additive — no existing skill or agent behavior changes
- If either file is deleted, the pipeline continues with V6 CodeReviewAgent as before
- No code path changes; activation handled by Claude Code's built-in skill + command system
- When run against non-frontend code, the skill reports `Nothing substantive to review in <scope>. Code is minimal and follows conventions. Approved.` rather than padding with false findings

### Why V7.0 Needs This Paired With Upgrade 8

Feedforward without feedback lets violations accumulate silently. Every project that ships with Fluent violations is a data point the mastery skill failed to prevent alone. Shipping the pair together means:

1. **Every frontend PR can be reviewed with `/design-review` before merge** — catches the 5% of violations that slip past the mastery guide
2. **CodeReviewAgent's `ux-craft` rubric dimension (Upgrade 3) becomes gradable**, not hand-wavy
3. **Quality trends become measurable** via the 8-dimension scorecard over time
4. **Token discipline scores usually improve fastest**; accessibility and polish scores are the long tail — the metrics make where to focus obvious

---

## Upgrade 10 — React Native + Expo Mobile Mastery Skill

### Problem

The pipeline has no codified discipline for mobile work. Phase C / D can already prototype and implement web frontends well thanks to Upgrades 8 and 9, but as soon as a project asks for an iOS + Android app the same gaps reopen: cross-platform divergence guesswork, unsafe area handling, `ScrollView`-with-`.map()` performance traps, missing offline state, no haptic feedback, native gestures broken, accessibility ignored. The Fluent v9 skill does not transfer — mobile is not responsive web. The patterns are different, the failure modes are different, and the bar for "feels native" is much higher.

A second, structural problem: when a customer asks for "the same thing on mobile", we currently regenerate primitives, navigation patterns, and state strategies from scratch. Without a mobile mastery skill we cannot achieve symmetry with the web frontend (same Swagger contract, same feature folder structure, same TanStack Query + RHF + Zod patterns), which is what makes a multi-surface product actually maintainable.

### Solution

Ship a new skill at `.claude/skills/react-native-mastery/SKILL.md` that codifies production-grade React Native + Expo discipline as a single mandatory reference for all mobile code generation. Auto-activates on any mobile request, screen, navigation, or React Native component. Backend remains the same .NET 8/9 + SQL Server + Swagger API used by web — symmetry is deliberate.

The skill spans 19 parts:

1. The unify-vs-diverge rule (the hardest mobile decision)
2. Stack & tooling (Expo SDK 50+, React Navigation v6+, TanStack Query, RHF + Zod, Reanimated v3, FlashList, expo-image, expo-haptics, expo-secure-store)
3. Design tokens (single `src/theme/tokens.ts` source of truth with platform-specific shadows)
4. Typography rules (system fonts, Dynamic Type, line height, accessibility-first)
5. Layout & safe areas (notches, home indicators, keyboard, one-handed reach)
6. Navigation (Native Stack vs Tabs vs Drawer; iOS large titles; Android predictive back)
7. Component patterns (the core 18-component library every screen composes from)
8. Lists (where mobile performance dies — FlashList rules, never nested scrollers)
9. Forms (RHF + Zod, keyboard types, autofill, return-key chains)
10. The five states (loading, empty, error, success, **offline**)
11. Motion & haptics (Reanimated worklets, spring physics, expo-haptics intent map)
12. Images & media (expo-image, dimensions, blurhash placeholders)
13. Accessibility (VoiceOver, TalkBack, Dynamic Type up to 200%, focus management)
14. Platform-specific polish (iOS Live Activities, Android edge-to-edge, etc.)
15. Data, offline & sync (cache persistence, NetInfo, optimistic updates, secure storage)
16. Anti-patterns (the forbidden list — bare `Image`, `TouchableOpacity`, `Animated`, hex colors, ScrollView+.map, etc.)
17. Project structure (mirror of the web feature folder for symmetry)
18. Workflow before writing code (11-step pre-coding checklist)
19. Definition of done (13-point ship checklist)

### Scope

**In scope:**

- Full `SKILL.md` at `.claude/skills/react-native-mastery/SKILL.md` with frontmatter trigger description and parts 1–19
- Trigger description tuned so the skill auto-activates on any mobile-coding request (React Native, Expo, iOS, Android, mobile screen, navigation, etc.)
- Cross-references to `/react-native-design-review` (Upgrade 11), `/fluent-v9-mastery` (sister web skill, same backend), `/react-ui-design-patterns` (shared async-state patterns)
- `CLAUDE.md` gains a row in the Installed Skills section pointing at the new skill
- `docs/GSD-Claude-Code-Skills.md` gains a section explaining when react-native-mastery activates and how it relates to the web pair

**Out of scope:**

- Codifying native iOS Swift/SwiftUI or native Android Kotlin/Compose — the skill is React Native + Expo only; bare native development is outside the pipeline's current target stack
- Backend (covered by `sql-expert`, `sql-performance-optimizer`)
- Wear OS / watchOS / Apple TV / tvOS — single-mobile-target only in V7.0
- Automated lint enforcement (queued for V8)

### Files to Create

| Path | Purpose |
|---|---|
| `.claude/skills/react-native-mastery/SKILL.md` | The full 19-part skill (frontmatter + body) |

### Files to Modify

| Path | Change |
|---|---|
| `CLAUDE.md` | Add `/react-native-mastery` row to Installed Skills section with activation criteria |
| `docs/GSD-Claude-Code-Skills.md` | Add section documenting the mobile mastery + review pair and how they mirror the web pair |
| `memory/knowledge/feature-check-schedule.md` | Note that Phase C (Figma Make prototyping) should ask "web, mobile, or both?" so Phase D picks up the right mastery skills |
| `memory/knowledge/rubrics/code-review.md` (when Upgrade 3 ships) | Reference react-native-mastery anti-patterns in the `ux-craft` dimension anchors when reviewing mobile slices |

### Symmetry With Web

The skill's project structure is intentionally identical to the web frontend so developers moving between codebases feel at home:

```text
src/
  api/generated/       # Same Swagger client, both surfaces
  components/          # Mobile-specific primitives (Button, Input, Card, etc.)
  features/<feature>/
    screens/           # Mobile = screens; web = pages
    components/
    hooks/
    api/               # Same TanStack Query wrappers as web
    types/
  navigation/          # Mobile-only — replaces web routing
  theme/tokens.ts      # Same token system, platform-specific shadow values
```

### Backward Compatibility

- Skill is entirely additive — no existing skill or agent behavior changes
- If the skill file is deleted, the pipeline simply lacks mobile-specific guidance (mobile work falls back to generic React patterns)
- No code path changes; activation handled by Claude Code's skill system
- Web pipelines completely unaffected

### Why V7.0 Needs This

Three reasons:

1. **Mobile demand is now**: V7.0 is the first release that bundles all the upstream pipeline upgrades that make multi-surface generation possible (rubrics, evaluator contracts, scratch pads). Shipping mobile mastery in the same release means the next project can target both web and mobile from day one rather than forcing a V7.1
2. **Symmetry compounds**: same Swagger contract, same feature folder, same form/state libraries. The mastery skill enforces that symmetry — without it, mobile drifts and the maintenance cost doubles
3. **One file, no runtime cost**: same shape as Upgrade 8 — a SKILL.md and a CLAUDE.md row. The risk is zero; the value scales with every cross-platform project

---

## Upgrade 11 — React Native Design Review Skill + `/mobile-design-review` Slash Command

### Problem

The Upgrade 8/9 pair gave web a feedforward (mastery) + feedback (review) sensor loop per Böckeler. Without a mobile review skill, Upgrade 10 ships half the pair: generation discipline without enforcement. Mobile has *more* surface area than web — safe areas, haptics, offline, platform divergence, FlashList performance, keyboard behavior, Dynamic Type, predictive back gesture — none of which the generic CodeReviewAgent catches. Every project that ships with mobile violations is a data point the mastery skill failed to prevent alone, and on mobile those violations are more user-visible: a missed safe area is a button hidden behind the home indicator, a missed `expo-image` swap is a flash of unstyled content on every list scroll, a missed `Pressable` accessibility role is an entire app TalkBack can't navigate.

### Solution

Two tightly-linked artifacts, mirroring the web pair:

1. **`.claude/skills/react-native-design-review/SKILL.md`** — auto-activates on "review this", "audit", "design review", "check the code", or end-of-mobile-feature implementation. Runs **17** review categories against the mobile mastery guide (vs 15 on web — mobile has more surface area).
2. **`.claude/commands/mobile-design-review.md`** — explicit `/mobile-design-review <scope>` slash command.

The 17 categories are: platform handling, stack compliance, design tokens, typography, safe areas & layout, navigation, component primitive selection, lists & performance, forms & validation, the five states, data/offline/sync, motion & haptics, accessibility, images & media, code quality & architecture, platform-specific polish, polish & copy.

The review report includes a unique **Platform Parity Check** table (iOS vs Android per concern) that web does not have. This is the secret weapon: every concern (native feel, navigation patterns, haptic feedback, typography, touch targets, safe areas, keyboard handling) gets a ✅ / ⚠️ / ❌ rating per platform, forcing the reviewer to mentally check both rather than defaulting to whichever platform they tested on.

### Scope

**In scope:**

- Full `SKILL.md` at `.claude/skills/react-native-design-review/SKILL.md` with all 17 review categories, severity levels, fix-application workflow, and report format
- `/mobile-design-review` slash command at `.claude/commands/mobile-design-review.md` for explicit invocation with a scope argument
- Auto-trigger phrases in the skill description so it activates on natural-language review requests
- Companion-skill cross-reference: review findings cite mobile mastery part numbers (e.g., "Violates Part 8: FlashList requires `estimatedItemSize` for virtualization to work")
- Fix-application mode: when the user responds "apply fixes", the skill auto-fixes all Blockers + Criticals, proposes Majors for approval, and lists Minors for later
- Report format includes the **Platform Parity Check** table and the 10-dimension metrics scorecard out of 100
- Offer to also run on the other platform's simulator if platform-specific fixes were made

**Out of scope:**

- Automated CI-level gating (V7.0 ships as interactive reviews; mobile CI integration is V8)
- Cross-feature trend dashboards (per-review scorecard only)
- Native iOS / Android lint integrations (SwiftLint, ktlint) — RN-only review

### Files to Create

| Path | Purpose |
|---|---|
| `.claude/skills/react-native-design-review/SKILL.md` | Full 17-category mobile review skill with report format and fix workflow |
| `.claude/commands/mobile-design-review.md` | `/mobile-design-review <scope>` slash command that invokes the skill |

### Files to Modify

| Path | Change |
|---|---|
| `CLAUDE.md` | Add `/react-native-design-review` skill row and `/mobile-design-review` command note to Installed Skills section |
| `docs/GSD-Claude-Code-Skills.md` | Section on the mobile mastery + review pair, and how it mirrors the web pair |
| `memory/agents/code-review-agent.md` | Note that on mobile slices, CodeReviewAgent should invoke `/mobile-design-review` as its mobile-quality pass (preserves the rubric-scored generic review but adds RN-specific depth) |
| `memory/knowledge/rubrics/code-review.md` (when Upgrade 3 ships) | `ux-craft` dimension's mobile anchors map directly to mobile review severity counts |

### Severity Levels (mobile-tuned)

Same five-level scale as web (Blocker / Critical / Major / Minor / Nit), but several blockers are mobile-only:

- 🔴 **Blocker** — Crashes on one platform; broken safe areas; bare `Image` / deprecated `SafeAreaView` / `TouchableOpacity` / `Animated`; auth tokens in `AsyncStorage`; `ScrollView` + `.map()` over dynamic lists; touch target < 44 without `hitSlop`
- 🟠 **Critical** — Missing platform divergence where convention demands; `KeyboardAvoidingView` using same `behavior` on both platforms; missing `textContentType` / `autoComplete` on autofill fields; no offline detection
- 🟡 **Major** — Inconsistent spacing rhythm; FlatList where FlashList belongs; haptics missing on primary actions; landscape breaks layout
- 🔵 **Minor** — No haptic on tab change; missing swipe actions on list items; loading message variation
- ⚪ **Nit** — Subjective (e.g., would prefer Filled icon for selected tab)

### Review Report Format (Platform Parity table is mandatory)

```text
# Mobile Design Review: <scope>

Reviewed: <N> files, <M> lines
Platforms: iOS <version> / Android <version>
Date: <date>
Overall verdict: ✅ Ship it | ⚠️ Ship after fixes | ❌ Not ready

## Summary
<2–3 sentences>

## Findings by Severity
  🔴 Blockers (count) — each with file:line, evidence, platform impact, fix
  🟠 Critical (count) — same format
  🟡 Major (count)
  🔵 Minor (count)
  ⚪ Nits (count)

## Platform Parity Check
| Concern              | iOS         | Android     | Notes |
|----------------------|-------------|-------------|-------|
| Native feel          | ✅ / ⚠️ / ❌ | ✅ / ⚠️ / ❌ |       |
| Navigation patterns  |             |             |       |
| Haptic feedback      |             |             |       |
| Typography           |             |             |       |
| Touch targets        |             |             |       |
| Safe areas           |             |             |       |
| Keyboard handling    |             |             |       |

## Strengths
<3–5 specific bullets>

## Recommended Fix Order

## Metrics (scored /10 each; overall /100)
  Platform handling
  Token discipline
  Component primitive fit
  State coverage (5 states)
  Lists & performance
  Forms & validation
  Accessibility
  Motion & haptics
  Offline & data
  Polish & copy

## Next Steps
```

### Three Ways to Invoke

| Mode | Trigger | When to use |
|---|---|---|
| Slash command | `/mobile-design-review src/features/orders` | Explicit, ad-hoc review of a named scope |
| Auto-activation | "review this", "audit", "design review" on a mobile feature | Natural-language review request |
| End-of-feature auto-trigger | End of mobile feature implementation in the autonomous pipeline | Pre-merge gate for mobile slices |

### Backward Compatibility

- Skill and command are entirely additive — no existing skill or agent behavior changes
- If either file is deleted, mobile reviews fall back to V6 CodeReviewAgent
- No code path changes; activation handled by Claude Code's built-in skill + command system
- When run against non-mobile code, the skill reports `Nothing substantive to review in <scope>. Code is minimal and follows conventions. Approved.` rather than padding with false findings

### Why V7.0 Needs This Paired With Upgrade 10

Same logic as the web pair, plus three mobile-specific reasons:

1. **Mobile has more surface area** — 17 review categories vs 15 on web. The cost of *not* shipping the review skill is meaningfully higher than on web because each missed category becomes a regression class
2. **Platform Parity check is irreplaceable** — no other mechanism (not human review, not CodeReviewAgent, not the rubrics from Upgrade 3) systematically forces a per-concern iOS vs Android comparison. This single table is what catches "works on my simulator" bugs
3. **Symmetry with the web pair** — operators learn one mental model: mastery shapes generation, review enforces it, on every surface

---

## Combined Architecture

```
                    ┌──────────────────────┐
                    │ EvaluationContract   │  (frozen by
                    │ + GradingRubric      │   BlueprintFreeze /
                    │      (NEW)           │   ContractFreeze)
                    └──────────┬───────────┘
                               │  reads
                               ▼
┌─────────────────┐      ┌───────────────────────┐      events     ┌──────────────┐   dispatches   ┌──────────────┐
│  PipelineGraph  │─────▶│   Orchestrator        │────────────────▶│ HermesAgent  │───────────────▶│  Channels    │
│  (NEW — DAG)    │      │  runs via             │                 │    (NEW)     │                │ Slack/Email  │
│  concurrency≥1  │      │  ExecutionGraph       │                 └──────────────┘                └──────────────┘
└─────────────────┘      │                       │
                         │  routes via           │      role hint     ┌───────────────────────┐
                         │  CapabilityRouter ───────────────────────▶│ Family-split enforcer │
                         │                       │                    │   (NEW — hard split)  │
                         └──────────┬────────────┘                    └───────────────────────┘
                                    │ runs (parallel-capable)
                                    ▼
          ┌──────────────────────────────────────────────────┐       ┌──────────────────────────┐
          │  Stage nodes: blueprint / review / remediate /   │       │ Evaluator Tools (NEW)    │
          │  gate / audit ∥ e2e / deploy / post-deploy       │◀─────▶│ read-only Playwright,    │
          │  Evaluators emit RubricScore                     │       │ test runner, repo read   │
          └──────────────────────┬───────────────────────────┘       └──────────────────────────┘
                                 │  every agent writes to
                                 ▼
                    ┌──────────────────────────────┐
                    │ memory/observability/scratch │  (NEW — append-only,
                    │ /{runId}/{agentId}.md        │   phase-tagged notes)
                    └──────────────┬───────────────┘
                                   │ on Stop hook
                                   ▼
          ┌─────────────────┐  nominates  ┌──────────────────┐  /promote  ┌──────────────┐
          │ Session + scratch│──────────▶ │   SkillForge     │──────────▶│  .claude/    │
          │    logger        │            │ Nominator (NEW)  │  (human)  │   skills/    │
          └─────────────────┘             └──────────────────┘           └──────────────┘
```

## Migration Plan

Ship in fifteen commits, each independently testable. Upgrades are mostly orthogonal:

- Commits 1–3 = Hermes (no dependencies)
- Commits 4–5 = Evaluator Contracts + Rubrics (no dependencies)
- Commit 6 = SkillForge (depends on nothing; benefits from commit 10 when scratch lands; uses Agent Skills open-standard schema)
- Commits 7–8 = Fork-Join DAG (no dependencies, but should land before concurrency > 1 is ever set)
- Commit 9 = Hard family-split enforcement (depends on commit 4 for the role hint type; widens at commit 11 when Gemini Flash-Lite lands)
- Commit 10 = Scratch pads + phase framing (depends on nothing; feeds commit 6)
- Commit 11 = Extended model pool slots (depends on nothing; strengthens commit 9 once Flash-Lite is available)
- Commit 12 = Fluent UI v9 Mastery skill (depends on nothing; zero runtime cost)
- Commit 13 = Fluent UI v9 Design Review skill + `/design-review` command (depends on commit 12 as source of truth; sharpens commit 5 `ux-craft` rubric anchors)
- Commit 14 = React Native Mastery skill (depends on nothing; zero runtime cost)
- Commit 15 = React Native Design Review skill + `/mobile-design-review` command (depends on commit 14 as source of truth; sharpens commit 5 mobile `ux-craft` rubric anchors)

| # | Commit | Exit criteria |
|---|---|---|
| 1 | Event bus + type additions + vault notes | `npm run build` clean; vault notes exist; no runtime behavior change |
| 2 | HermesAgent + orchestrator emit points + dry-run | Fake `EscalationError` in an eval produces a dispatch JSONL file, zero external calls |
| 3 | Channel adapters (Slack, GitHub Issue, email, webhook) | Integration test sends to a staging Slack channel; real channels gated behind env var |
| 4 | Rubric loader + rubric files + `EvaluationContract` type | Rubric loader returns parsed rubric for each phase; missing-file fallback to prose prompt path verified |
| 5 | Evaluator agents emit `RubricScore`; `ReviewAuditor` gains Playwright CLI read-only | Existing V6 eval suite passes; new dimension scores appear in `GateResult`; ReviewAuditor produces screenshots under `observability/` |
| 6 | SkillForge nominator + `/promote-skill` using Agent Skills open-standard schema | End-to-end: a seeded recurring pattern produces a nomination with `x-gsd-*` metadata; `/promote-skill` copies the skill file in agentskills.io format |
| 7 | `PipelineGraph` type + `pipeline-config.md` + graph loader | Graph loads; default concurrency=1; `npm test` shows identical stage order to V6 |
| 8 | Orchestrator rewired to `ExecutionGraph.runGraph()` | V6 eval suite passes at concurrency=1; at concurrency=2, `audit` and `e2e` overlap in wall-clock logs |
| 9 | Capability-router honors `familySplit.enforce` | With `enforce: true` and two families configured, evaluator and generator provably use different families across a full eval run; `FamilyConfigError` thrown when escape is unset and only one family is available |
| 10 | Scratch pads + phase labels + pattern 6 | Every adopting agent writes to `scratch/{runId}/{agentId}.ax.md`, `.ux.md`, and `.dx.jsonl`; SkillForge pattern 6 fires on synthetic multi-step trace |
| 11 | Extended model pool — Gemini Flash-Lite / DeepSeek V4 / GPT-5.5 slots + startup probes | With all three slots set to `enabled: 'probe'`, probe results appear in `PipelineState.modelProbes` and `memory/decisions/`; unavailable slots fall back to V6 defaults without error; `familySplit` pool has ≥ 3 families when Flash-Lite probe succeeds |
| 12 | Fluent UI v9 Mastery skill | `.claude/skills/fluent-v9-mastery/SKILL.md` ships; activates on frontend requests in an eval; `CLAUDE.md` Installed Skills section updated; zero-impact on non-frontend pipelines verified |
| 13 | Fluent UI v9 Design Review skill + `/design-review` command | `.claude/skills/fluent-v9-design-review/SKILL.md` + `.claude/commands/design-review.md` ship; `/design-review` against a seeded-violation fixture produces the 8-dimension scorecard and correctly severity-classifies each seeded violation; `apply fixes` mode auto-fixes Blockers + Criticals and reports the residual |
| 14 | React Native Mastery skill | `.claude/skills/react-native-mastery/SKILL.md` ships; activates on mobile requests in an eval; `CLAUDE.md` Installed Skills section updated; zero-impact on web-only and backend-only pipelines verified |
| 15 | React Native Design Review skill + `/mobile-design-review` command | `.claude/skills/react-native-design-review/SKILL.md` + `.claude/commands/mobile-design-review.md` ship; `/mobile-design-review` against a seeded-mobile-violation fixture produces the 10-dimension scorecard plus the **Platform Parity Check** table with each concern correctly rated per platform; `apply fixes` mode auto-fixes Blockers + Criticals and offers to re-run on the other platform |

## Test Plan

### Hermes

- Unit: event bus dedup, channel router severity mapping, rate-limit window
- Integration: fake `EscalationError` in `src/evals/` produces dispatch in dry-run mode
- Chaos: dispatch failure must not crash pipeline (hard rule)
- Secrets: no channel keys appear in any committed file (Semgrep rule)

### SkillForge

- Unit: each of the 5 pattern heuristics against synthetic session logs; pattern 6 against synthetic scratch pads
- Integration: run a pipeline that triggers pattern 1 three times → verify nomination file exists
- Safety: `/promote-skill` refuses if target path exists (no silent overwrites)

### Evaluator Contracts

- Unit: rubric parser rejects malformed frontmatter; loader falls back to prose prompt when file absent
- Unit: `RubricScore.passed` is false iff any blocker dimension scored ≤ 2
- Integration: seed a contract where an evaluator should fail on `coverage` dimension → verify `DeployAgent` refuses to run even when `GateResult.passed` was true under the old boolean path
- Live-interaction: run `ReviewAuditor` on a branch with a UI regression → verify screenshot evidence appears in `observability/review-auditor/`
- Regression: identical pipeline runs with and without rubric files produce semantically equivalent decisions (pass/fail parity)

### Fork-Join DAG

- Unit: `PipelineGraph` loader rejects cycles via `ExecutionGraph.detectCycles()`
- Unit: at concurrency=1, stage order is lexicographically identical to V6 linear loop
- Integration: at concurrency=2, `audit` and `e2e` overlap in wall-clock (start-time delta < max(stage duration) / 4)
- Resume: `--from-stage gate` correctly picks up with the DAG scheduler; state files from V6 load with `graphVersion: v6-linear` auto-assigned
- Safety: `stopOnFailure: true` halts sibling stages mid-wave; no orphan work proceeds after a blocker

### Hard Family Split

- Unit: router with two families configured and `enforce: true` assigns different families to generator vs evaluator roles
- Unit: router with one family + `escape: 'fail-closed'` throws `FamilyConfigError`; with `escape: 'single-family-ok'` proceeds
- Integration: full pipeline run with `enforce: true` shows `FamilyAssignment` record in `memory/decisions/` and distinct `model` fields across agent logs
- Regression: with `enforce: false` (default), router behavior is identical to Upgrade 3's advisory state

### Agent Scratch Pads

- Unit: `AgentScratch` helper writes one file per (run, agent), append-only
- Unit: missing `phases:` frontmatter defaults to `[gather, act, verify]`
- Integration: a full pipeline with all 15 agents adopting scratch produces ≤ 200 MB of scratch per run
- SkillForge: pattern 6 (multi-step scratch consistency) fires when ≥ 3 agents produce structurally similar trace across ≥ 3 sessions

### Extended Model Pool

- Unit: router startup probe with all three slots set to `enabled: 'probe'` produces a `ModelProbeResult` for each slot and caches it in `PipelineState.modelProbes`
- Unit: when a probe returns non-200, router falls back to the V6 default for that slot and logs to `memory/decisions/` without throwing
- Integration: with `deepseek.v4.enabled: 'probe'` and a mock endpoint returning 404 for `deepseek-v4`, bulk-generation work continues on `deepseek-chat` (V3.2)
- Integration: with `openai.gpt55.codexCli: true` and a `codex models list` fixture exposing `gpt-5.5`, generator work routes through Codex OAuth; fixture without `gpt-5.5` keeps generator on Codex-mini
- Regression: all three slots set to `enabled: false` (default) produces a run with routing behavior identical to V6

### Fluent UI v9 Mastery Skill

- Unit: skill file parses — frontmatter valid, 15 parts present
- Integration: a synthetic frontend request in `src/evals/` shows the skill activating (verified via `/context` output)
- Integration: a backend-only pipeline request does NOT activate the skill
- Content check: skill's Part 12 (anti-patterns) lists all 14 forbidden patterns from the original spec

### Fluent UI v9 Design Review Skill + `/design-review` Command

- Unit: skill file parses — frontmatter valid, 15 review categories present, report format block intact
- Unit: slash command file parses; `/design-review` appears in the command list
- Integration: `/design-review` against a seeded fixture containing each severity level produces a report with correct counts (e.g., 3 Blockers, 5 Critical, 8 Major, 4 Minor, 2 Nit)
- Integration: review findings cite mastery-guide part numbers (verify text like `Violates Part 3` appears for Griffel violations)
- Integration: auto-activation fires on "review this", "audit", "design review" natural-language triggers
- Integration: run against a backend-only diff produces the "Nothing substantive to review" response without padding
- Fix-mode: when user says "apply fixes", auto-fixes all Blockers + Criticals, re-runs `npm run typecheck` / `npm run lint`, reports residual Major/Minor/Nit items
- Metrics: 8-dimension scorecard sums to a total out of 80

### React Native Mastery Skill

- Unit: skill file parses — frontmatter valid, 19 parts present
- Integration: a synthetic mobile request in `src/evals/` shows the skill activating (verified via `/context` output)
- Integration: a web-only or backend-only pipeline request does NOT activate the skill
- Content check: skill's Part 16 (anti-patterns) lists the full forbidden set including bare `Image`, `TouchableOpacity`, `Animated`, hex colors, ScrollView+.map, `AsyncStorage` for credentials

### React Native Design Review Skill + `/mobile-design-review` Command

- Unit: skill file parses — frontmatter valid, 17 review categories present, Platform Parity Check table block intact, report format block intact
- Unit: slash command file parses; `/mobile-design-review` appears in the command list
- Integration: `/mobile-design-review` against a seeded mobile fixture containing each severity level produces a report with correct severity counts and a fully-populated Platform Parity Check table (every row has both iOS and Android cells filled)
- Integration: review findings cite mobile mastery part numbers (verify text like `Violates Part 8: FlashList requires estimatedItemSize` appears for FlashList violations)
- Integration: auto-activation fires on "review this", "audit", "mobile design review" natural-language triggers
- Integration: run against a web-only diff produces the "Nothing substantive to review" response without padding
- Fix-mode: when user says "apply fixes", auto-fixes all Blockers + Criticals, re-runs typecheck / lint, offers to re-run on the other platform's simulator
- Metrics: 10-dimension scorecard sums to a total out of 100

### Regression

- Full V6 eval suite must pass unchanged with all six upgrades disabled / dormant / defaulted off
- Full V6 eval suite must pass unchanged at concurrency=1 with rubrics absent and `familySplit.enforce: false`
- Decision log volume increases by ≤ 25% (Hermes dispatches separate; rubric scores + family assignments + DAG ready-set ticks each add ≤ 8 fields per decision record)

## Rollback

- **Hermes**: set `HERMES_ENABLED=false` — agent unsubscribes at startup, pipeline behavior identical to V6
- **SkillForge**: remove Stop hook entry from `.claude/settings.json` — nominator stops running, existing nominations remain as inert files
- **Evaluator Contracts**: delete or rename any file in `memory/knowledge/rubrics/` — loader falls back to prose prompts; `EvaluationContract` fields in `PipelineState` are optional and ignored when absent
- **Fork-Join DAG**: set `concurrency: 1` in `memory/knowledge/pipeline-config.md` — behavior identical to V6 sequential loop; at `concurrency: 0` the orchestrator can fall back to the pre-DAG for-loop via feature flag `USE_LEGACY_LINEAR_LOOP=1`
- **Hard Family Split**: set `familySplit.enforce: false` — router reverts to Upgrade 3 advisory behavior
- **Scratch pads**: delete `memory/observability/scratch/` at any time; next run recreates as needed. Agents continue to work whether or not they call `this.scratch.*`
- **Extended model pool**: set all three feature flags back to `enabled: false` — router reverts to V6 three-family routing; probed slots are ignored; cached probe results in `PipelineState.modelProbes` go stale but are harmless
- **Fluent UI v9 Mastery skill**: delete `.claude/skills/fluent-v9-mastery/` — skill stops activating; narrower React skills continue to apply; no code or agent changes needed
- **Fluent UI v9 Design Review skill + `/design-review` command**: delete `.claude/skills/fluent-v9-design-review/` and `.claude/commands/design-review.md` — review invocations fall back to the generic CodeReviewAgent; mastery skill continues to guide generation; no other changes needed
- **React Native Mastery skill**: delete `.claude/skills/react-native-mastery/` — mobile generation falls back to generic React patterns; no code or agent changes needed
- **React Native Design Review skill + `/mobile-design-review` command**: delete `.claude/skills/react-native-design-review/` and `.claude/commands/mobile-design-review.md` — mobile review invocations fall back to the generic CodeReviewAgent; mobile mastery skill continues to guide generation; no other changes needed
- **Full rollback**: revert the fifteen commits in reverse order; no schema migrations to undo

## Non-Goals (explicit)

- Replacing the Orchestrator's routing role
- Bidirectional notification (ack/reply flow) — stays one-way dispatch
- Automatic skill promotion without human approval
- Cross-repo skill syndication
- Migrating to the Letta harness (evaluated and rejected — see review notes)
- Giving `QualityGateAgent` live-interaction tools (remains build-and-scan only)
- Migrating agent I/O from CLI-spawn to a structured tool-call protocol
- Hierarchical working-memory tiers (Confucius §2) inside a single run
- Parallel remediation loops — remediation stays serialized
- Cross-milestone parallelism beyond the existing worktree isolation
- Dynamic DAG re-planning mid-run

## Open Questions

- Slack channel naming convention — single `#gsd-ops` or per-project channels? Defer to first-project deployment
- Email on-call rotation source — static list vs PagerDuty integration? v7.0 ships static list, PagerDuty deferred to a future release
- SkillForge pattern 5 (query template) may have low precision — ship behind feature flag, measure in first 30 days
- Rubric dimension weights — should `correctness` and `security` weight higher than `ux-craft` in the aggregate? v7.0 ships equal weights; weighting deferred until we see real score distributions
- Playwright preview bootstrapping for `ReviewAuditor` on backend-only slices — skip the preview step entirely or spin up a minimal harness?
- Default concurrency for a hosted deployment — 1 is safe but leaves wall-clock on the table; 2 captures the `audit ∥ e2e` win; higher is speculative until we measure multi-slice contention
- Evaluator family preference order — start with `[anthropic, openai, google]` and revisit after the next LLM feature check on 2026-05-23
- Scratch pad retention — keep forever, or GC runs older than N days? v7.0 keeps forever, revisit when disk pressure appears
- GPT-5.5 routing priority — once API SKU is confirmed, should we prefer Responses API over OAuth-Codex for audit trail cleanliness, or prefer OAuth-Codex for $0 marginal cost? Ship both paths, measure once real traffic flows
- Fluent v9 skill enforcement mechanism — V7.0 ships as feedforward guidance (skill content). Should V8 add feedback sensors (lint rules, Semgrep patterns) that actively reject hex colors, v8 imports, and raw pixel values? Defer until we see how often the skill gets violated in generated code
- Phase C prompt update — should Phase C (Figma Make prototyping) ask "web, mobile, or both?" at intake so Phase D picks up the right mastery + review skill pair? Recommended yes for next pipeline-prompt revision; not blocking V7.0 ship
- Mobile project bootstrapping — V7.0 ships skills only; no Expo project template. Should we add an Expo SDK 50+ template scaffolder as a Phase D step, or leave that to per-project decision? Defer until first cross-platform project ships

## Review Cadence

Per rule #12, re-check LLM vendor features on 2026-05-20 for any native notification, skill-extraction, or structured-grading primitives (e.g., Anthropic "skills" API, OpenAI function-call rubric scoring) that could simplify this design before execution.

---

## Appendix A — Harness Design References

V7.0 is informed by the 2026 harness-design literature. This appendix maps our architecture to the published patterns and cites each source by way of justification.

### Literature Consulted

| Source | Author / Org | Role in V7.0 design |
|---|---|---|
| *Harness design for long-running application development* | Rajasekaran / Anthropic Engineering | Primary source for Upgrade 3 and Upgrade 5 — context resets, generator/evaluator separation, explicit grading criteria, sprint contracts, live-interaction for evaluators |
| *How Claude Code works* (code.claude.com) | Anthropic Engineering | Source for gather/act/verify phase framing in Upgrade 6; agentic harness = model + tools + context management |
| *Harness engineering for coding agent users* (martinfowler.com) | Böckeler / Thoughtworks | Source for the "inner vs outer harness" framing below and the feedforward-guides / feedback-sensors vocabulary |
| *Components of a Coding Agent* | Raschka | Six-component reference model — confirms our live-repo-context, structured memory, and bounded subagent design |
| *12 Agentic Harness Patterns from Claude Code* | Generative Programmer | Pattern checklist mapped below |
| *Claude Code Agent Harness: Architecture Breakdown* (wavespeed.ai) | WaveSpeedAI | Operational benchmarks — 98% auto-compaction threshold, 25K MCP tool-output cap, 5–6 MCP server cap, permission-tier model |
| *Inside the Scaffold: A Source-Code Taxonomy of Coding Agent Architectures* | Rombaut (arXiv 2604.03515) | Motivates Upgrade 4 — 11 of 13 surveyed agents compose multiple loop primitives (ReAct + generate-test-repair + plan-execute + multi-attempt retry + tree search); V7.0 adds plan-execute fork-join to our composition |
| *Building Effective AI Coding Agents for the Terminal* (OpenDev) | Bui (arXiv 2603.05344) | Motivates scaffolding-vs-harness distinction, lazy tool discovery (deferred), event-driven reminders (informational) |
| *Confucius Code Agent: Scalable Agent Scaffolding* | arXiv 2512.10398 | Motivates Upgrade 6 — persistent note-taking decouples working memory from exploration depth; AX/UX/DX three-audience split adopted in scratch-pad schema |
| *Anthropic Agent Skills open standard* (agentskills.io, github.com/anthropics/skills) | Anthropic + ecosystem | SkillForge (Upgrade 2) emits nominations in this schema — interoperable with Atlassian, Figma, Canva, Stripe, Notion, Zapier, and OpenAI skill catalogs |
| *SWE-Bench Pro public leaderboard* (labs.scale.com) | Scale AI | Canonical rubric calibration benchmark; retires SWE-Bench Verified for V7.0 rubric references |
| *Playwright MCP* (github.com/microsoft/playwright-mcp) | Microsoft | Motivates Playwright-CLI-over-MCP choice in Upgrade 3 — ~4x fewer tokens per session for evaluator usage |

### Inner vs Outer Harness (Böckeler)

V7.0 makes this distinction explicit because it clarifies what we own versus what we inherit:

- **Inner harness** (inherited): Claude Code itself — tool dispatch, context compaction, permission gating, MCP, hooks, subagents
- **Outer harness** (V6 / V7.0 scope): the GSD pipeline around projects — agent orchestration, SDLC phase map, vault memory, rubrics, git worktree isolation, durable state, capability router, Hermes, SkillForge

All three V7.0 upgrades live in the outer harness. None modify Claude Code behavior.

### Pattern Coverage (Generative Programmer's 12)

| # | Pattern | V6 status | V7.0 change |
|---|---|---|---|
| 1 | Persistent Instruction File | ✓ `CLAUDE.md` + `memory/agents/*.md` | — |
| 2 | Scoped Context Assembly | ✓ per-agent system prompts | — |
| 3 | Tiered Memory | ✓ `MEMORY.md` index + topics + sessions | Upgrade 6 adds per-agent scratch layer (AX/UX/DX) |
| 4 | Dream Consolidation | partial — manual `/consolidate`, `/review` | SkillForge automates nomination side (Upgrade 2) |
| 5 | Progressive Context Compaction | N/A — we reset per task (Rajasekaran-preferred) | — |
| 6 | Explore-Plan-Act Loop | partial — SDLC A–E is plan-heavy | Upgrade 6 labels phases (`phases:` frontmatter) |
| 7 | Context-Isolated Subagents | ✓ `SubagentRegistry` + per-agent vault notes | Evaluator tools (Upgrade 3) formalizes the read-only scope |
| 8 | Fork-Join Parallelism | limited — `ExecutionGraph` exists but pipeline is sequential | **Upgrade 4 promotes ExecutionGraph to primary scheduler** |
| 9 | Progressive Tool Expansion | N/A — CLI-spawn model | — (deferred: structured tool protocol) |
| 10 | Command Risk Classification | partial — GitTxn wraps destructive agents | — (deferred) |
| 11 | Single-Purpose Tool Design | partial — `evaluator-tools.ts` narrows to read-only | Upgrade 3 adds one; Upgrade 6 scratch helper is another |
| 12 | Deterministic Lifecycle Hooks | ✓ `default-hooks.ts` + `.claude/settings.json` | Hermes adds event subscribers on existing lifecycle |

### Rajasekaran's Practices — Explicit Adoption

| Practice | V7.0 adoption |
|---|---|
| Prefer context resets over compaction | already adopted in V6 (`base-agent.ts:104`) |
| Separate generator from evaluator agents | Upgrade 3 formalizes — `EvaluationContract`, rubric, role hint in router |
| Encode subjective preferences into concrete, measurable criteria | Upgrade 3 — rubric files with 1–5 anchors per dimension |
| Negotiate "what done looks like" before coding | Upgrade 3 — `EvaluationContract` emitted by BlueprintFreeze / ContractFreeze |
| Equip evaluators with live interaction capabilities | Upgrade 3 — Playwright CLI read-only for ReviewAuditor |
| **Enforce the generator/evaluator split, don't leave it advisory** | Upgrade 5 — `familySplit.enforce: true` pins distinct families per milestone |
| Challenge assumptions in harness complexity as models improve | Reaffirmed via rule #12 cadence; captured as an Open Question on rubric weighting |
| Maintain feature-rich specifications despite long execution | already covered by BlueprintFreeze + ContractFreeze in V6 |

### Scaffold Taxonomy (arXiv 2604.03515) — Loop Primitive Composition

V6 composed **ReAct + multi-attempt retry**. V7.0 composes four primitives:

| Primitive | Where it lives in V7.0 |
|---|---|
| ReAct | Per-agent execution loop inside `BaseAgent.execute()` |
| Plan-Execute | SDLC phases A–E (sequential, contract-gated) |
| Generate-Test-Repair | Remediation → Gate loop (orchestrator.ts:305–328) |
| **Multi-attempt retry with fork-join** | **Upgrade 4** — DAG scheduler parallelizes independent stages within a retry wave |

Tree-search remains unused; we have no search space that benefits from MCTS given the deterministic pipeline graph.

### Confucius AX/UX/DX Alignment (arXiv 2512.10398)

| Audience | V7.0 artifact | Backing file |
|---|---|---|
| Agent Experience | Compressed scratch for downstream agents | `scratch/{runId}/{agentId}.ax.md` |
| User Experience | Readable trace for post-mortem | `scratch/{runId}/{agentId}.ux.md` |
| Developer Experience | Full JSONL for tools + SkillForge | `scratch/{runId}/{agentId}.dx.jsonl` |

### Iterative Simplification Reminder

Rajasekaran's closing note — *"every component in a harness encodes an assumption about what the model can't do on its own"* — applies directly to the evaluator contract. As frontier-model evaluation skills improve, we expect to be able to relax the generator/evaluator model-family split and possibly the explicit rubric altogether. The rubric loader's prose-prompt fallback is the deliberate escape hatch for that simplification.

---

## Appendix B — Live Research Sweep (2026-04-23)

A concurrent research sub-agent scanned late-2025 and April 2026 sources for items not covered by the harness-design literature above. Findings are classified below. Items marked *pulled in* are already folded into Upgrades 2, 3, 6, 7, or 8. Items marked *queued for V8* are captured here so they don't get lost.

### Pulled into V7.0

| Finding | Source | Folded into |
|---|---|---|
| **Anthropic Agent Skills open standard** (schema adoption across Atlassian, Figma, Canva, Stripe, Notion, Zapier, OpenAI) | agentskills.io + github.com/anthropics/skills | Upgrade 2 — SkillForge nominations use the open schema with `x-gsd-*` prefix for local metadata |
| **Playwright CLI over MCP** — 4x fewer tokens per evaluator session | github.com/microsoft/playwright-mcp | Upgrade 3 — Evaluator Tools standardize on CLI transport; MCP is fallback only |
| **SWE-Bench Pro replaces Verified** — Verified retired after frontier memorization | labs.scale.com/leaderboard/swe_bench_pro_public | Upgrade 3 — rubric calibration references Pro, not Verified |
| **Confucius AX/UX/DX split** — three audiences from one write | arXiv:2512.10398 | Upgrade 6 — scratch pad helper emits three derived views |
| **Gemini 3.1 Flash-Lite cheap-generator lane** (widens `familySplit` pool to 3 families) | Google DeepMind release notes | Upgrade 7 — new routing slot with `enabled: 'probe'` gate |
| **DeepSeek V4 (1T MoE, projected ~$0.30/MTok)** routing slot, probe-gated on endpoint availability | nxcode.io/resources/news/deepseek-v4-release-specs-benchmarks-2026 | Upgrade 7 — feature-flagged slot; falls back to `deepseek-chat` (V3.2) when endpoint is unavailable |
| **GPT-5.5 via OAuth-Codex CLI** — $0 marginal cost access before the Responses API SKU goes live | OpenAI release 2026-04-23 | Upgrade 7 — router probes `codex models list` for `gpt-5.5`-shaped id and activates when operator's subscription is in the rollout wave |
| **Fluent UI React v9 Mastery discipline** — production-grade frontend baseline raising generated UI from "plausible admin panel" to "senior-Microsoft-designer level" | User-provided prompt, 2026-04-23 | Upgrade 8 — shipped as `.claude/skills/fluent-v9-mastery/SKILL.md` |
| **Fluent UI React v9 Design Review discipline** — feedback-sensor counterpart to the mastery skill; 15 review categories, 5-level severity, 8-dimension scorecard, auto-fix mode | User-provided prompt, 2026-04-23 | Upgrade 9 — shipped as `.claude/skills/fluent-v9-design-review/SKILL.md` + `.claude/commands/design-review.md` |
| **React Native + Expo Mobile Mastery discipline** — mobile counterpart to Fluent v9 mastery; 19 parts including unify-vs-diverge, safe areas, FlashList performance, the five-states rule (incl. offline), haptics, Dynamic Type accessibility | User-provided prompt, 2026-04-23 | Upgrade 10 — shipped as `.claude/skills/react-native-mastery/SKILL.md` |
| **React Native Design Review discipline** — mobile feedback sensor; 17 review categories, the unique **Platform Parity Check** table forcing iOS vs Android comparison per concern, 10-dimension scorecard /100 | User-provided prompt, 2026-04-23 | Upgrade 11 — shipped as `.claude/skills/react-native-design-review/SKILL.md` + `.claude/commands/mobile-design-review.md` |

### Queued for V8 (captured so they don't get lost)

| Candidate | Source | Effort | Reason deferred |
|---|---|---|---|
| **VMAO-style Replan node** — add a Replan phase that re-plans a slice after novel E2E / PostDeploy failure classes (distinct from tactical Remediation) | EMNLP Findings 2025, aclanthology.org/2025.findings-emnlp.757.pdf | medium | Designing the trigger heuristic requires real V7.0 production traces — shipping it blind risks encoding a wrong assumption |
| **Harvey auto-toolkit generation** — given I/O examples + rubric, generate a skill toolkit | artificiallawyer.com/2026/04/07/harvey-drives-legal-agent-learning-via-harness-engineering/ | medium-large | Strict superset of SkillForge Upgrade 2; requires generating skill *bodies* (not just metadata) with its own evaluator + rubric pipeline |
| **Claude Agent SDK subagent transcript helpers** (`list_subagents`, `get_subagent_messages`) | github.com/anthropics/claude-agent-sdk-typescript | small-to-medium | TypeScript SDK function surface could not be verified during the sweep (GitHub page didn't expose signatures; npmjs.com returned 403). Will probe again at next feature check on 2026-05-23 |
| **Hierarchical working memory tiers inside a run** (Confucius §2) | arXiv:2512.10398 | medium-large | V7.0's per-task reset + AX/UX/DX scratch split is a reasonable substitute until long-run volume makes tiers necessary |
| **VMAO Replan + Harvey auto-toolkit combined** = "self-extending pipeline" | cross-paper synthesis | large | Genuinely new architecture — belongs in V8 planning, not V7.0 |
| **CI-gated `/design-review` enforcement** (block PRs when Blockers/Criticals present) | Extending Upgrade 9 to pre-merge gate | small-to-medium | V7.0 ships interactive review; CI integration adds GitHub Actions workflow + scorecard aggregation — fits V8 better |
| **Sensor-level enforcement of Fluent v9 anti-patterns** (lint/Semgrep rules that reject hex colors, v8 imports, raw pixel values) | Böckeler feedback-sensor framing | medium | V7.0 ships feedforward (Upgrade 8) + interactive feedback (Upgrade 9); automated feedback sensors belong after we see real violation rates across multiple projects |
| **Cross-feature quality-trend dashboard** (aggregate `/design-review` scorecards over time) | Upgrade 9 8-dimension scorecard | medium | Scoring exists per-review; aggregation requires a data layer — worth it once we have ≥ 20 reviews to trend |

### GPT-5.5 Routing (informational, API not yet live)

OpenAI announced GPT-5.5 on 2026-04-23 (today). Rolled out to ChatGPT Plus/Pro/Business/Enterprise and Codex first; **API rollout described as "coming very soon" — not live at the time of this spec**. Benchmarks that matter for GSD:

| Benchmark | GPT-5.5 | Claude Opus 4.7 | GPT-5.4 |
|---|---|---|---|
| Terminal-Bench 2.0 | 82.7% | 69.4% | 75.1% |
| SWE-Bench Pro | 58.6% | 64.3% | — |
| OpenAI MRCR v2 (8-needle, 512K–1M ctx) | 74.0% | 32.2% | — |

Suggested routing once API is confirmed:

- **Generator (long-horizon, whole-repo, terminal-use):** GPT-5.5 via the Responses API when available
- **Evaluator (code review, contract grading):** Claude Opus 4.7 (wins SWE-Bench Pro + evaluator-appropriate "skeptical" behavior per Rajasekaran)
- **Bulk code gen:** `gpt-5.1-codex` or Codex-mini (unchanged)
- **Cost-sensitive long-context retrieval:** Gemini 3.1 Pro (unchanged)

**Hard rule until API is confirmed:** do not hard-code `gpt-5.5` as a model id in `CLAUDE.md` or `memory/knowledge/model-strategy.md`. See `memory/knowledge/feature-check-schedule.md` for the confirmation cadence. **OAuth Codex login may expose GPT-5.5 before the API endpoint is live** — see below.

### OAuth-Codex Access Path (preliminary)

OpenAI's release notes describe GPT-5.5 rolling out "to ChatGPT Plus/Pro/Business/Enterprise and Codex first." The `codex` CLI authenticates via OAuth against the operator's ChatGPT subscription. If GPT-5.5 is exposed as a selectable model inside Codex CLI (likely, but not yet confirmed on the public docs page), a GSD operator with a qualifying subscription could route generator work to GPT-5.5 at **$0 marginal cost** (already bundled in the subscription) **before** the Responses API SKU goes live.

Two things must still be verified before we flip the router:

1. That Codex CLI exposes `gpt-5.5` (or an equivalent id) for `codex` subcommand use
2. That the subscription tier the operator holds is included in the rollout wave

Until both are confirmed, leave the capability-router defaulting to Opus 4.7 / Codex-mini for generator work.

---

**Status: spec-only for Upgrades 1–7. Upgrades 8, 9, 10, and 11 are shipped in this session — `.claude/skills/fluent-v9-mastery/SKILL.md`, `.claude/skills/fluent-v9-design-review/SKILL.md`, `.claude/skills/react-native-mastery/SKILL.md`, `.claude/skills/react-native-design-review/SKILL.md`, `.claude/commands/design-review.md`, and `.claude/commands/mobile-design-review.md` are written and registered. No other code or vault mutations performed. Execute the remaining upgrades via the fifteen-commit migration plan when approved.**

## Appendix C — Managed External Source Agents (2026-04-27)

The 2026-04-27 external-link review is captured in `docs/GSD-v7.0-Managed-Agents-Addendum.md` and `memory/managed-agents/`. These managed agents are source-specific sidecars, not runtime `AgentId` classes. They preserve watched links, classify what belongs in V7 versus V8, and give DocGardener / SkillForge / model probes a durable source contract.

Net changes recommended by the addendum:

- Add a Simplicity/Surgicality rubric dimension from the Karpathy-inspired guidance.
- Promote DeepSeek V4 direct API probing and track the 2026-07-24 retirement of `deepseek-chat` / `deepseek-reasoner`.
- Add optional self-verification mode to high-risk evaluator contracts.
- Track Goose recipes, ACP, subagents, and adversary-reviewer patterns as V8 candidates.
- Add Gemini Deep Research / Deep Research Max as explicit research-tier routing candidates.
- Treat EvoMap Evolver's Gene/Capsule model as a V8 SkillForge evolution experiment, not a V7 runtime dependency.
- Keep NVIDIA NIM DeepSeek V4 Pro as a separate hosting lane from direct DeepSeek API.
- Add GPT-5.5 stuck-task escalation and tool-call efficiency tracking from Lovable / Analytics Vidhya field reports, gated by official OpenAI/Codex probes.
- Track OpenMythos recurrent-depth/adaptive-computation controls as a V8 routing research item.
- Use AgentSPEX as validation for V7 `PipelineGraph` and queue typed YAML workflow specs as a V8 candidate.
- Add a LangChain-inspired production-runtime readiness checklist for durable execution, memory, HITL, observability, sandboxes, integrations, and cron.
- Route models by correctness risk using the Kilo Claude Opus 4.7 vs Kimi K2.6 benchmark: cheap open-weight models for scaffolds, frontier/evaluator passes plus targeted reproductions for hard state-machine paths.
