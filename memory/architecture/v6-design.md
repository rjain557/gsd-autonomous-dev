---
type: architecture
id: v6-design
title: GSD V6 Architecture — Hierarchical decomposition, durable state, harness-engineering alignment
status: Active (canonical)
date: 2026-04-19
supersedes: V5.0 (archived)
depends_on: [ADR-006, ADR-007]
---

# GSD V6 Design Document

## Executive Summary

V6 keeps V5's SDLC specialization (Phases A-G, .NET 8 + React 18 + SQL Server constraints, vault memory) and swaps in a stronger execution kernel below the agent layer. The design draws from two external sources:

1. **gsd-build/gsd-2** — a general-purpose autonomous coding kernel with hierarchical decomposition (Milestone → Slice → Task), git worktree isolation, SQLite durable state, execution graph scheduler, and crash recovery.
2. **OpenAI's harness-engineering playbook** — repo-as-record, golden-rules-as-code, filesystem-as-memory, agent-legible environment, self-healing feedback loops.

V5 already satisfies parts of both. V6 fills the gaps in priority order across 5 tiers.

## Why V6 (Not V5.1)

This is a breaking change, not an additive one. Specifically:

- **State model changes** from pure markdown vault to hybrid SQLite + markdown. Existing session/decision files stay; runtime state migrates.
- **Task graph shape changes** from linear 7-stage sequence to three-level hierarchy (Milestone → Slice → Task).
- **Agent session model changes** from long-lived context accumulation to fresh-context-per-task with explicit preamble injection.
- **File system layout changes** to use git worktrees per milestone instead of running everything in the main checkout.

Projects mid-SDLC on V5 should finish on V5. V6 is for new milestones.

## V5 Baseline (what exists today)

Grounding the design in actual code, not aspirations:

| Component | File | Lines | What it does |
|---|---|---|---|
| Orchestrator | `src/harness/orchestrator.ts` | 825 | 7-stage pipeline routing, decision logging, remediation loop, state save/restore |
| BaseAgent | `src/harness/base-agent.ts` | 374 | Agent lifecycle, CLI-first LLM call, API key auto-fallback, extractJSON, rate limiter integration |
| Types | `src/harness/types.ts` | 387 | PipelineState, all agent I/O contracts, error classes |
| Vault adapter | `src/harness/vault-adapter.ts` | ~330 | Obsidian note read/write, wikilinks, OS-level file locking |
| Rate limiter | `src/harness/rate-limiter.ts` | ~150 | Sliding-window RPM, cooldowns, CLI model switch tracking |
| 14 agents | `src/agents/*.ts` | ~1,800 | SDLC A-E + Pipeline F-G |

**V5 already has:**

- Typed agent contracts (PipelineState, ReviewResult, GateResult, DeployRecord, etc.)
- Hard gate enforcement (HardGateViolation prevents deploy without passing quality gate)
- Dual auth (CLI OAuth primary, API key auto-fallback with 5-min cooldown)
- 30-day feature-check cadence (memory/knowledge/feature-check-schedule.md)
- Verification-first process for adopting new features
- 107 Claude Code skills + 97 agent skills installed (Trail of Bits, Caveman, HashiCorp, McGo security audit)
- GitNexus + Graphify + Semgrep + Playwright + Context7 MCP workstation stack
- Decision logging in memory/decisions/
- State save/restore via pipeline-state-latest.json

## Gap Analysis — What V5 Lacks

### From gsd-2

1. **Hierarchical decomposition.** V5's task graph is flat (7 stages). gsd-2 uses Milestone → Slice → Task, where each level has its own state, markdown narrative, and execution semantics.
2. **Fresh context per task.** V5 agents accumulate context across a stage. gsd-2 starts each task with a fresh session and explicit preamble.
3. **Git worktree isolation.** V5 runs every agent in the main checkout. gsd-2 creates a worktree per milestone so changes are atomic and reversible.
4. **Turn-level git transactions.** V5 commits at the end; gsd-2 commits after each task and resets on failure.
5. **SQLite durable state.** V5 uses markdown files only; gsd-2 persists typed state in SQLite with markdown as the human-readable view.
6. **Execution graph scheduler.** V5 runs stages linearly; gsd-2 runs independent tasks in parallel based on dependency graph.
7. **Budget-pressure tier shifts.** V5 has a static PHASE_ROUTING table; gsd-2 downgrades models at 50/75/90% budget thresholds.
8. **Capability-aware routing.** V5 uses hardcoded agent-per-phase mapping; gsd-2 scores agents on task metadata (language, domain, token size).
9. **Stuck-loop detection.** V5's remediate↔gate loop has a hard cap of 3 iterations but can't detect oscillation patterns (same PatchSet signature repeating).
10. **Timeout hierarchy.** V5 has one `timeout_seconds` per agent; gsd-2 has soft/idle/hard timeouts with progressive signals.
11. **Crash recovery.** V5 has `--from-stage` resume; gsd-2 has auto-lock files, session forensics, and auto-restart with backoff.
12. **Shell-output compression.** V5 passes raw tool output to agents; gsd-2 compresses via RTK binary.
13. **Headless JSON snapshot.** V5 prints to stdout; gsd-2 has `gsd headless query` for machine-readable state.
14. **Forensics bundle.** V5 has scattered logs; gsd-2 has `/gsd forensics` that packages everything for triage.
15. **Knowledge harvest.** V5 appends decisions but never mines them; gsd-2 has `extract-learnings` for periodic pattern mining.

### From the OpenAI harness-engineering article

1. **Repo-as-system-of-record with progressive disclosure.** V5 has CLAUDE.md (good) but no AGENTS.md or per-skill SKILL.md with lazy-loaded bodies.
2. **Golden rules enforced mechanically.** V5 documents conventions in CLAUDE.md prose (T-SQL naming, Fluent UI patterns, 5-states rule, tenant isolation). These should be custom Semgrep/ESLint rules that QualityGate runs.
3. **Filesystem as memory.** V5 does this well for decisions and sessions. Gap: tool outputs (bash, Semgrep, Playwright) flow verbatim through agent context instead of being summarized.
4. **Agent-legible environment.** V5 has Playwright wired but no structured query surface. Post-deploy agent can't grep E2E logs or deploy traces — only sees the assertion diff.
5. **Self-healing feedback loops.** V5 has remediate↔gate. Gap: no cross-review (reviewer of reviewer), no dry-run rollback simulation, no automated response to PR review comments.
6. **Depth-first decomposition cue.** V5 stages are fixed. An agent can't say "the SP for REQ-042 doesn't exist, I need to halt and build it" — it just returns a gap.
7. **Merge philosophy / fast-follow PRs.** V5 halts on any gate failure; the article prefers short PRs with follow-ups for non-critical drift.

## V6 Design — Five Tiers

### Tier 1 — Execution Kernel (breaking)

**1.1 Hierarchical decomposition**

Introduce three levels above the existing stages:

```
Milestone      (SCG1 release, e.g., "v1.2 chatbot improvements")
  └── Slice    (user-visible feature, e.g., "thread archive")
        └── Task (single agent run, e.g., "blueprint-analysis for thread archive")
              └── Stage (existing V5 stage: blueprint/review/remediate/gate/e2e/deploy/post-deploy)
```

File layout mirrors gsd-2:

```
memory/
  milestones/
    M001-v1.2-chatbot-improvements/
      ROADMAP.md                    # milestone goal + slice list
      state.json                    # typed milestone state
      slices/
        S01-thread-archive/
          PLAN.md                   # slice goal + task list
          state.json
          tasks/
            T01-blueprint-analysis.md
            T02-code-review.md
            ...
```

**1.2 Hybrid state**

Create `memory/state.db` (SQLite) alongside the vault:

| Table | What's in it |
|---|---|
| milestones | id, name, status, started_at, completed_at, budget_usd |
| slices | id, milestone_id, name, status, depends_on_slice_ids |
| tasks | id, slice_id, agent_id, stage, status, cost_usd, tokens_in, tokens_out |
| decisions | id, task_id, action, reason, evidence (FK to memory/decisions/ markdown) |
| rate_limit_windows | cli_id, timestamp, calls_in_window |
| stuck_patterns | id, signature_hash, occurrences, first_seen, last_seen |

Markdown stays for narrative (plans, decisions, session logs). SQLite is the queryable durable state.

**1.3 Git worktree isolation**

Each milestone creates a git worktree in `.gsd-worktrees/M001/`. All agent file writes happen there. On milestone complete, the worktree merges back to main as a single PR (or multiple slice-scoped PRs if the milestone is too large).

**1.4 Execution graph scheduler**

Replace the linear `stageOrder: PipelineStage[]` array with a dependency graph. Initial independent tasks that can run in parallel:

- Blueprint analysis (reads specs)
- Semgrep scan (reads code)
- GitNexus impact analysis (reads code)
- Graphify context build (reads code)

Review depends on all four. Remediation depends on review. Gate depends on remediation. etc.

**1.5 Fresh session per task**

BaseAgent's `execute()` currently reuses `this.state`. V6: each task gets a new agent instance with only the explicit preamble (task description, relevant vault notes, prior task outputs it depends on). No accumulated context from prior stages.

### Tier 2 — Reliability & Supervision

**2.1 Timeout hierarchy**

Replace `timeout_seconds` with:

```typescript
interface TaskTimeouts {
  softTimeoutSec: number;   // inject "wrap up" message
  idleTimeoutSec: number;   // probe for progress
  hardTimeoutSec: number;   // halt + forensic bundle
}
```

Defaults: soft=120, idle=180, hard=300.

**2.2 Stuck-loop detection**

On each remediate→gate cycle, hash the PatchSet (files + diff). If the same hash appears twice, the agent is looping. Escalate instead of retry.

```typescript
interface StuckDetector {
  recordAttempt(taskId: string, outputHash: string): void;
  isStuck(taskId: string, windowSize: number): boolean;
}
```

**2.3 Auto-lock + session forensics**

Create `memory/state.db.lock` during runs. On crash recovery:

1. Detect stale lock (> 10 min old and process not running)
2. Dump forensic bundle: decisions, raw tool outputs, git state, SQLite snapshot
3. Clear lock
4. Optionally auto-restart with exponential backoff

**2.4 Turn-level git transactions**

Each task wraps its filesystem work in a git txn:

- Start: `git stash -u` (or note current HEAD)
- On success: commit with task ID in message
- On failure: reset to pre-task state

Combined with worktrees, gives trivial rollback.

### Tier 3 — Cost, Routing, Verification

**3.1 Budget-pressure model router**

Wrap `pickAgentForPhase()` so it consults current spend vs milestone budget:

```typescript
function pickAgentForPhase(phase: string, budgetPct: number): string {
  if (budgetPct > 90) return 'deepseek'; // emergency
  if (budgetPct > 75) return 'gemini';   // downgrade
  if (budgetPct > 50) return 'gemini' || 'claude';
  return 'claude'; // normal
}
```

**3.2 Capability-aware routing**

Score agents per task:

```typescript
interface AgentCapability {
  agentId: string;
  languages: string[];        // ['csharp', 'typescript', 'sql']
  domains: string[];          // ['auth', 'billing', 'ui']
  maxContextTokens: number;
  qualityScore: number;       // from historical eval results
}
```

Router picks the highest-scoring available agent for the task's metadata.

**3.3 Verification auto-fix band**

Between gate failure and RemediationAgent, run mechanical fixes first (cheap, fast):

- `npm run lint -- --fix`
- `dotnet format`
- `prettier --write`
- Re-run gate

If gate still fails after 2 mechanical passes, then escalate to RemediationAgent (LLM).

### Tier 4 — Harness-Engineering Alignment

**4.1 Golden-rules-as-code**

Convert every rule in CLAUDE.md into executable checks:

| CLAUDE.md rule | V6 enforcement |
|---|---|
| T-SQL naming (usp_Entity_Action) | Custom Semgrep rule matching `CREATE PROCEDURE` |
| No SELECT * | Custom Semgrep rule |
| Tenant filter required | Custom rule matching queries without `WHERE TenantId` |
| Fluent UI 5-states rule | Custom ESLint rule on React components |
| All SPs have TRY/CATCH THROW | Custom Semgrep rule on .sql files |

Store rules in `memory/knowledge/rules/*.yml`. QualityGateAgent runs them in parallel with standard Semgrep.

**4.2 AGENTS.md + progressive disclosure**

Top-level `AGENTS.md` (~100 lines): map of agents, when to use each, link to full SKILL.md.

Per-agent `memory/agents/{id}.md` already has frontmatter. V6 adds lazy-loading: orchestrator reads only `description` and `when_to_use` fields until an agent is selected; then loads the full system prompt.

**4.3 Tool-output compaction**

Wrap every bash/Semgrep/Playwright call in a compactor:

```typescript
async function compactedExec(cmd: string): Promise<{ summary: string; rawPath: string }> {
  const raw = await execAsync(cmd);
  const rawPath = `memory/sessions/${runId}/raw/${Date.now()}.txt`;
  await fs.writeFile(rawPath, raw);
  if (raw.length < 2000) return { summary: raw, rawPath };
  const summary = await summarizeWithHaiku(raw);
  return { summary, rawPath };
}
```

Agent sees the summary. If it needs raw, it reads `rawPath` explicitly.

**4.4 Agent-queryable observability**

Expose structured query surface over logs:

```
memory/observability/
  e2e-traces/{runId}.jsonl       # Playwright network + console
  deploy-logs/{runId}.jsonl      # each deploy step + timing
  gate-results/{runId}.jsonl     # each check + evidence
  build-output/{runId}.jsonl     # dotnet + npm output, structured
```

PostDeployValidationAgent can grep or jq these instead of just seeing pass/fail.

**4.5 Cross-review gate**

Add a lightweight `ReviewAuditorAgent` between QualityGate pass and Deploy:

- Runs on Gemini (cheap, 1M context)
- Reads the full ReviewResult, PatchSet, and GateResult
- Looks for: blind spots, contradictions, suspicious passes
- Returns a second opinion before DeployAgent starts

**4.6 Doc-gardening recurring agent**

Scheduled job (daily or weekly):

1. For each agent note in `memory/agents/`, diff the declared `tools` list against actual code
2. For each knowledge note referenced in agent notes, check it still exists
3. For each external tool mentioned in notes, verify it's still installed
4. Open a PR with reconciliation diffs

**4.7 Depth-first capability escalation**

When any agent detects a missing capability, it emits a special result:

```typescript
interface CapabilityGap {
  kind: 'capability-gap';
  missing: string;       // "Semgrep rule for SEC-FE-17"
  blocks: string;        // "code-review for slice S04"
  suggestedFix: string;  // "add rule to memory/knowledge/rules/"
}
```

Orchestrator pauses the current slice and creates a new slice to build the capability. Then resumes.

### Tier 5 — Developer Experience

**5.1 Headless JSON state API**

Add `gsd query` subcommand that returns current state as JSON:

```bash
gsd query milestone M001           # milestone status + slice list
gsd query task T042                # task detail + decisions
gsd query cost --since 7d          # cost rollup
gsd query stuck                    # any stuck loops detected
```

Useful for CI, Prom exporters, dashboards.

**5.2 Forensics command**

```bash
gsd forensics --run <runId> --out forensics.zip
```

Bundles:

- `memory/decisions/*-run-{runId}.md`
- `memory/sessions/{runId}/`
- `memory/observability/*/{runId}.jsonl`
- `git diff` from start of run
- SQLite snapshot filtered to this run

**5.3 Knowledge harvest job**

Weekly cron reads `memory/decisions/` and distills patterns:

- Recurring remediation types → `memory/knowledge/patterns.md`
- Recurring stuck-loop signatures → `memory/knowledge/anti-patterns.md`
- Gate failure categories → feed back into golden rules

**5.4 Subagent delegation**

Two subagents that other agents can delegate to:

- **Scout** — reads specs and vault notes, returns summarized context (used by Blueprint, Review, Remediation)
- **Researcher** — runs Context7 / GitNexus / Graphify queries, returns synthesized findings (used by Remediation, E2E)

Keeps main agents focused on judgment instead of information gathering.

## V6 Roadmap (Proposed)

| Version | Tier | Scope |
|---|---|---|
| v6.0 (breaking) | Tier 1 | Hierarchical decomp + SQLite + worktrees + execution graph. Migrate state model. |
| v6.1 | Tier 2 | Timeout hierarchy + stuck detection + crash recovery + turn-level git txns |
| v6.2 | Tier 3 | Budget router + capability routing + mechanical fix band |
| v6.3 | Tier 4 | Golden rules + progressive disclosure + compaction + observability + cross-review + doc-gardening + capability escalation |
| v6.4 | Tier 5 | Headless query + forensics + knowledge harvest + subagents |

Target: v6.0 MVP within 2 weeks after this design freezes. Each subsequent tier in 1-2 week increments.

## Migration Strategy

**V5 → V6.0 breaking change:**

1. Projects mid-SDLC on V5 complete on V5 (use `--from-stage`).
2. New milestones start on V6.0.
3. Vault memory stays in the same location. V6 adds `memory/milestones/`, `memory/state.db`, `memory/observability/`.
4. Existing agent notes, knowledge notes, decision logs all preserved.
5. The 14 agents from V5 are kept; only the orchestrator and state model change.
6. `gsd run <milestone>` command stays; implementation under the hood migrates.

## Risks

| Risk | Mitigation |
|---|---|
| SQLite adds dependency, contention on concurrent writes | better-sqlite3 is synchronous; wrap in vault-adapter-like lock |
| Git worktrees are unfamiliar to some devs | Document clearly in developer guide; add `gsd worktree status` command |
| Hierarchical decomp may add overhead for tiny changes | Skip Milestone/Slice for single-task runs; fall through to current V5 stage flow |
| Tool-output compaction loses information agents need | Always persist raw; allow agents to request raw by path |
| Cross-review gate adds latency + cost | Run on Gemini (15 RPM, $0 marginal, 1M context); only for deploy-bound changes |
| Golden-rules-as-code blocks legitimate edge cases | Each rule has a `severity` field; warnings don't block |

## What V6 Does NOT Do

- Does not adopt Claude Code agent teams (still experimental; 30-day check defers adoption)
- Does not replace the TypeScript harness with pure Claude Code native agents (multi-LLM routing is the core value)
- Does not introduce a new LLM provider (keeping the 5-model stack: Claude/Codex/Gemini/DeepSeek/MiniMax)
- Does not rewrite the 14 agents (only the orchestrator and state layer change)

## References

- V5 baseline: `docs/GSD-V4-Implementation-Status.md`, `memory/architecture/agent-system-design.md`
- ADR-006 (V4 harness decision)
- ADR-007 (V5 hybrid architecture + dual auth)
- gsd-build/gsd-2: https://github.com/gsd-build/gsd-2
- OpenAI harness engineering: https://openai.com/index/harness-engineering/
- Feature check schedule: `memory/knowledge/feature-check-schedule.md`
