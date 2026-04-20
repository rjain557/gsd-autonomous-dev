# GSD V6 — Autonomous Development Engine Developer Guide

**Version:** 6.1.0
**Date:** April 2026
**Status:** Canonical
**Classification:** Confidential - Internal Use Only

---

## Document History

| Version | Date | Changes |
|---|---|---|
| 6.0.0 | April 2026 | Canonical V6 architecture: hierarchical decomposition (Milestone → Slice → Task), hybrid SQLite + markdown state, git worktree isolation, execution graph scheduler, 14-agent roster, Claude memory stack (`claude-memory/`), and unified workstation configuration. All prior version docs archived to `docs/legacy/`. |
| 6.1.0 | April 2026 | Per-project backend framework override via `docs/gsd/stack-overrides.md`. Target projects can declare `net8.0` / `net9.0` / `net10.0`, solution file format, data access pattern, and frontend stack. Backward compatible: projects without the override continue to receive .NET 8 defaults. Adds `src/harness/project-stack-context.ts`, `--project-root` CLI flag, `PROJECT STACK CONTEXT` prompt block injection, and §1.4.1 documentation. |

---

# Chapter 1: Introduction

## 1.1 What GSD V6 Is

GSD V6 is an AI-native autonomous development system that covers the full Technijian SDLC lifecycle from project intake through alpha deployment. It combines a TypeScript control plane, hybrid SQLite + vault memory, git worktree isolation, an execution graph scheduler, CLI-first model routing, and deployment automation into a single workflow.

V6 is organized around three levels of hierarchical decomposition above the existing 7-stage pipeline:

```text
Milestone      (SCG1 release, e.g., "v1.2 chatbot improvements")
  └── Slice    (user-visible feature, e.g., "thread archive")
        └── Task (single agent run, e.g., "blueprint-analysis for thread archive")
              └── Stage (Blueprint → Review → Remediate → Gate → E2E → Deploy → Post-deploy)
```

The runtime uses two coordinated layers:

- An **SDLC orchestrator** for Phases A-E: requirements, architecture, Figma validation, reconciliation, blueprint freeze, and contract freeze.
- A **Pipeline orchestrator** for Phases F-G: blueprint drift analysis, code review, remediation, quality gates, E2E validation, deployment, and post-deploy validation.

Each milestone runs in its own git worktree. Each task gets a fresh agent context with explicit preamble injection (no accumulated context from prior stages). Durable runtime state lives in SQLite (`memory/state.db`); human-readable narrative stays in markdown.

## 1.2 What the System Produces

At the end of a successful milestone run, GSD V6 produces:

- A structured **Intake Pack** with outcomes, RACI, NFRs, risks, and acceptance criteria.
- An **Architecture Pack** with Mermaid diagrams, an OpenAPI draft, a threat model, and an observability plan.
- A validated **Figma deliverable checkpoint** against the required 12 analysis files and stub structure.
- A reconciled requirements and architecture baseline after design feedback.
- A **Frozen Blueprint** that becomes the Phase F implementation contract.
- **SCG1 contract artifacts** for UI, API, stored procedure mapping, database planning, testing, and CI gates.
- A full code pipeline result per slice with review findings, patches, gate evidence, E2E evidence, deploy records, and post-deploy checks.
- A milestone-scoped PR (or multiple slice-scoped PRs) merged back from the worktree to main.
- A durable run history in SQLite (queryable via `gsd query`) and in markdown under `memory/sessions/`, `memory/decisions/`, `memory/observability/`.

## 1.3 V6 Capabilities At A Glance

| Capability | V6 Behavior |
|---|---|
| Scope | Full SDLC lifecycle (Phases A-G) |
| Agents | 14 typed agents (6 SDLC + 7 Pipeline + Orchestrator) |
| Task graph | Milestone → Slice → Task → Stage hierarchy |
| State model | Hybrid: SQLite (`memory/state.db`) for queryable state + markdown for narrative |
| Isolation | Git worktree per milestone (`.gsd-worktrees/M001/`) |
| Scheduler | Dependency-graph scheduler (parallel-capable) |
| Agent context | Fresh context per task with explicit preamble |
| Auth | CLI OAuth primary, API key auto-fallback with 5-min cooldown |
| Cost model | $0 marginal under normal load; pay-per-token only during CLI cooldowns |
| Budget routing | Model downgrades at 50/75/90% budget thresholds |
| Feature cadence | 30-day check cycle for Claude/Codex/Gemini capability updates |
| Memory stack | Durable knowledge in `claude-memory/` vault (Obsidian, OneDrive-synced) with retrieval hooks |

## 1.4 Enforced Technology and Delivery Constraints

GSD does not attempt to be framework-neutral. The system encodes a specific delivery model.

| Layer | Standard |
|---|---|
| Backend | .NET Web API (configurable, default .NET 8) + Dapper + SQL Server stored procedures |
| Frontend | React 18 + TypeScript + Fluent UI React v9 |
| Database | SQL Server, stored-procedure-first design |
| Auth | JWT Bearer, role-based, multi-tenant with `TenantId` |
| Compliance | HIPAA, SOC 2, PCI, GDPR |
| LLM routing | Claude Code, Codex CLI, Gemini CLI first; API fallback only when subscriptions are exhausted |

If a target project does not fit that stack, GSD can still be used selectively, but many generated assumptions, checks, and prompts will no longer be authoritative.

## 1.4.1 Per-Project Stack Overrides (v6.1.0+)

Projects that require a different backend framework can declare it in `docs/gsd/stack-overrides.md` of the target project. GSD agents read this file as part of project context and honor the declared framework.

**Supported backend frameworks:**

- `net8.0` — default when no override is declared
- `net9.0` — Technijian Platform standard per `tech-web-shared` ADR-0004
- `net10.0` — when projects upgrade after the .NET 10 LTS release

**How it works:**

1. At the start of every SDLC / Pipeline run, the orchestrator calls [`getProjectStackContext(projectRoot)`](../src/harness/project-stack-context.ts) which reads `<projectRoot>/docs/gsd/stack-overrides.md` from the target project.
2. If the file exists, its fields override defaults. If absent, `.NET 8` defaults are returned (preserving v6.0.0 behavior).
3. The resolved context is attached to every agent via `BaseAgent.setProjectStackContext()` and injected into each agent's system prompt as a `PROJECT STACK CONTEXT` block.
4. Agents honor the declared framework when generating `.csproj` TargetFrameworks, SDK references, architecture prose, and quality-gate commands.

**CLI:**

```bash
gsd run requirements \
    --project "Technijian ITSM" \
    --description "..." \
    --project-root ../tech-web-myitsm
```

The `--project-root` flag defaults to the current working directory. The target project's `docs/gsd/stack-overrides.md` is looked up relative to that root.

**stack-overrides.md format (any subset of these rows — unspecified fields inherit defaults):**

```markdown
| Field                | Value                      |
|----------------------|----------------------------|
| Backend framework    | net9.0                     |
| Backend SDK          | .NET 10 SDK                |
| Solution file format | slnx                       |
| Data access          | Dapper + stored procedures |
| Database             | SQL Server                 |
| Frontend framework   | React 18                   |
| Frontend UI library  | Fluent UI v9               |
| Frontend build tool  | Vite                       |
| Mobile framework     | React Native               |
| Mobile toolchain     | Expo managed workflow      |
| Remote agent language| Go                         |
| Compliance           | SOC 2, HIPAA, PCI, GDPR    |
```

See [`src/harness/project-stack-context.ts`](../src/harness/project-stack-context.ts) for the context reader, parser (`parseStackOverrides`), and renderer (`renderStackContextBlock`).

**Backward compatibility:** Projects without `docs/gsd/stack-overrides.md` continue to receive v6.0.0 defaults (.NET 8). No existing project breaks; no CLI flag is required. Test fixtures under `test-fixtures/stack-overrides/` cover the full, minimal, and empty cases.

### 1.4.2 Stack Leak Validator (v6.1.0+)

Because LLM-generated artifacts can still drift — for example, an agent may emit `net8.0` in a `.csproj` even when the stack context declares `net9.0` — v6.1.0 ships a **stack-leak validator** as defense-in-depth.

**What it does:**
- Walks the target project directory (respecting common ignore dirs: `node_modules`, `dist`, `.git`, `.gsd-worktrees`, `.gitnexus`, `graphify-out`, `_archive`)
- Scans every `.csproj`, `.json`, `.md`, `.yaml`, `.yml`, `.xml`, `.targets`, `.props` file
- Flags any `net{N}.0` token that does not match the declared `backendFramework`
- Heuristic false-positive filter skips lines in migration/upgrade/legacy/changelog/archived contexts so mentioning the old framework in prose is not flagged

**Two ways to run:**

1. **Automatic (post-phase)** — `MilestoneOrchestrator` runs the validator after each SDLC phase completes. Findings are:
   - Logged to observability under the `gate-results` category (`memory/observability/gate-results/{runId}.jsonl`)
   - Persisted as decisions in `state.db` with `action=stack-leak-detected`
   - Warned to the console (`[MILESTONE] Stack leak validator found N finding(s)`)
   - **Non-fatal**: the milestone continues; findings are surfaced for human review. To make findings fatal, use the standalone CLI in your CI pipeline (below).

2. **Standalone (CI hook)** — `gsd validate-stack` for pipeline integration:

   ```bash
   gsd validate-stack --project-root . --fail-on-findings
   ```

   Exit code `0` = no leaks. Exit code `1` = findings detected. Add this as a final step after any GSD-driven code generation run.

**JSON mode for structured CI:**

```bash
gsd validate-stack --project-root . --json | jq '.findings | length'
```

**Implementation:** [`src/harness/v6/stack-leak-validator.ts`](../src/harness/v6/stack-leak-validator.ts). Reports are rendered as markdown by `formatStackLeakReport()` for human review.

### 1.4.3 Inspecting the resolved context (v6.1.0+)

Before running a milestone — especially in CI — verify that GSD sees your override correctly:

```bash
gsd query stack --project-root /path/to/your-project
```

Returns JSON:

```json
{
  "subject": "stack",
  "ok": true,
  "data": {
    "backendFramework": "net9.0",
    "backendSdk": ".NET 10 SDK",
    "solutionFileFormat": "slnx",
    "dataAccessPattern": "Dapper + stored procedures",
    "database": "SQL Server",
    "frontendFramework": "React 18",
    "frontendUiLibrary": "Fluent UI v9",
    "frontendBuildTool": "Vite",
    "mobileFramework": "React Native",
    "mobileToolchain": "Expo managed workflow",
    "agentLanguage": "Go",
    "complianceFrameworks": ["SOC 2", "HIPAA", "PCI", "GDPR"],
    "source": "override",
    "resolvedFromPath": "<abs path>/docs/gsd/stack-overrides.md"
  }
}
```

If `source: 'default'` appears, the override file was not found — check the path is `<projectRoot>/docs/gsd/stack-overrides.md` and that `--project-root` points at the right directory.

### 1.4.4 End-to-end workflow (v6.1.0+)

```bash
# 1. In the TARGET project, declare overrides (copy the template)
cp <gsd-repo>/docs/stack-overrides-template.md <target-project>/docs/gsd/stack-overrides.md
#    Edit the file to your values; unspecified rows inherit defaults.

# 2. Verify GSD sees them
gsd query stack --project-root /path/to/target-project

# 3. Run a milestone against the target project
gsd run requirements \
    --project "MyApp" \
    --description "..." \
    --project-root /path/to/target-project

# 4. After the run, scan for leaks (CI-friendly)
gsd validate-stack --project-root /path/to/target-project --fail-on-findings
```

## 1.5 Getting Started in 5 Minutes

This section is the "I just cloned the repo — what do I do?" path. For full workstation setup including AI CLIs, see [Chapter 4](#chapter-4-workstation-setup).

### Step 1: Verify the harness is healthy (30 sec)

Nothing in this step requires an AI subscription or API key.

```bash
git clone https://github.com/rjain557/gsd-autonomous-dev.git
cd gsd-autonomous-dev/gsd-autonomous-dev
npm install
npm run typecheck
npm run test:v6
```

Expected: `0 errors` from typecheck, `31 passed, 0 failed` from tests.

If either fails, something broke during clone/install. Do not proceed — open an issue with the error output.

### Step 2: Explore the CLI without running anything expensive (30 sec)

```bash
npx ts-node src/index.ts help
npx ts-node src/index.ts query stack          # resolved stack context for this cwd (default .NET 8)
npx ts-node src/index.ts status               # "no state.db yet" until your first run
```

These three commands do not call any LLM and do not cost anything. They confirm the CLI is wired correctly.

### Step 3: Install the agent stack (before your first run)

This is [§4.3](#43-install-the-external-tools-gsd-expects) condensed. Run it once per workstation:

```bash
npx playwright install chromium
pip install graphifyy semgrep
npm install -g gitnexus @modelcontextprotocol/server-github
npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli
claude auth
codex auth
gemini auth
graphify claude install && graphify install
gitnexus analyze && gitnexus setup
claude mcp add context7 -- npx -y @upstash/context7-mcp@latest
```

### Step 4: Set environment variables (see `.env.example`)

Minimum: `ANTHROPIC_API_KEY` (backup auth when CLI hits rate limit) and `GITHUB_PERSONAL_ACCESS_TOKEN` (for the GitHub MCP server). Set as persistent Windows user env vars:

```powershell
[System.Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', 'sk-ant-...', 'User')
[System.Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', 'ghp_...', 'User')
```

Restart your terminal after setting these. See [`.env.example`](../.env.example) for the full list.

### Step 5: (If applicable) Declare a per-project stack override

If your target project is **not** .NET 8, create `docs/gsd/stack-overrides.md` in the **target project** (not this repo). Copy [`docs/stack-overrides-template.md`](stack-overrides-template.md), edit the rows you need (usually just `Backend framework | net9.0`).

Verify:

```bash
gsd query stack --project-root /path/to/target-project
# Expected: "source": "override"  and your declared framework
```

### Step 6: Run your first milestone

```bash
gsd run requirements \
    --project "MyApp" \
    --description "Multi-tenant SaaS" \
    --project-root /path/to/target-project

gsd status                                        # see progress
gsd query milestones                              # list all milestones
gsd query milestone <id>                          # drill into one
```

### Step 7: (After the run) Validate no stack leaks

```bash
gsd validate-stack --project-root /path/to/target-project --fail-on-findings
```

Exit code 0 = no leaks. Exit code 1 = LLM emitted a framework that contradicts your declared stack (see [§1.4.2](#142-stack-leak-validator-v610)).

### Day-2 operations

Once you've run a first milestone:

- **Check status frequently**: `gsd status`
- **Triage a failure**: `gsd forensics --run <runId> --milestone <milestoneId>`
- **Mine patterns weekly**: `gsd harvest --since-days 7`
- **Audit vault health**: `gsd doc-garden`
- **Free a stuck worktree**: `gsd worktree status` → `gsd worktree teardown <milestoneId> --force`

Full command reference: [Appendix A](#appendix-a-quick-command-reference).

# Chapter 2: System Architecture

## 2.1 High-Level Control Flow

The V6 runtime is a two-orchestrator system layered under the Milestone → Slice → Task hierarchy.

```text
Developer
  |
  +--> gsd run <milestone>
          |
          +--> Preflight validation (vault, CLIs, env vars, worktree setup)
          |
          +--> Create git worktree: .gsd-worktrees/M{nnn}/
          |
          +--> Record milestone in memory/state.db
          |
          +--> For each Slice in the Milestone:
          |      +--> Execute dependency graph of Tasks (parallel where possible)
          |      |
          |      +--> SDLC Orchestrator (Phases A-E) per slice
          |      |      +--> RequirementsAgent
          |      |      +--> ArchitectureAgent
          |      |      +--> FigmaIntegrationAgent
          |      |      +--> PhaseReconcileAgent
          |      |      +--> BlueprintFreezeAgent
          |      |      +--> ContractFreezeAgent
          |      |
          |      +--> Pipeline Orchestrator (Phases F-G) per slice
          |             +--> BlueprintAnalysisAgent
          |             +--> CodeReviewAgent
          |             +--> RemediationAgent
          |             +--> QualityGateAgent
          |             +--> E2EValidationAgent
          |             +--> DeployAgent
          |             +--> PostDeployValidationAgent
          |
          +--> Merge worktree → main (single milestone PR or slice-scoped PRs)
```

The unified command model lives in [`src/index.ts`](../src/index.ts). The SDLC and pipeline control loops live in [`src/harness/sdlc-orchestrator.ts`](../src/harness/sdlc-orchestrator.ts) and [`src/harness/orchestrator.ts`](../src/harness/orchestrator.ts). V6-specific additions (milestone/slice scheduler, SQLite state adapter, worktree manager) are under [`src/harness/`](../src/harness/).

## 2.2 Phase Map (A-G)

| Phase | Owner | Purpose | Main Output | Persisted Location |
|---|---|---|---|---|
| A | RequirementsAgent | Convert project description into an Intake Pack | Intake Pack | `docs/sdlc/phase-a-intake-pack.json` |
| B | ArchitectureAgent | Produce diagrams, OpenAPI, threat model, and data model inventory | Architecture Pack | `docs/sdlc/phase-b-architecture-pack.json`, `docs/sdlc/openapi-draft.yaml` |
| C | FigmaIntegrationAgent | Validate exported Figma Make analysis/stub deliverables | Figma deliverable state | Saved in SDLC state (`memory/sessions/sdlc-state-*.json`) |
| A/B Reconcile | PhaseReconcileAgent | Merge what the prototype revealed back into requirements and architecture | Reconciliation Report | `docs/sdlc/phase-ab-reconciliation-report.json` |
| D | BlueprintFreezeAgent | Freeze the UI/UX spec for implementation | Frozen Blueprint | `docs/sdlc/phase-d-frozen-blueprint.json` |
| E | ContractFreezeAgent | Produce SCG1 contract artifacts and gap analysis | Contract Artifacts + validation report | `docs/sdlc/phase-e-contract-artifacts.json`, `docs/spec/validation-report.md` |
| F | Pipeline Orchestrator | Review, remediate, gate, and validate the codebase | Pipeline state + evidence | `memory/sessions/pipeline-state-*.json` |
| G | Deploy + PostDeploy | Deploy with rollback and then validate the live environment | Deploy record + post-deploy evidence | `memory/sessions/` |

## 2.3 Agent Roster

### Control Agents

| Agent | Responsibility |
|---|---|
| Orchestrator | Routes pipeline stages, enforces retries and hard gates, logs decisions to the vault |

### SDLC Agents

| Agent | Phase | Responsibility |
|---|---|---|
| RequirementsAgent | A | Build Intake Pack from project name and description |
| ArchitectureAgent | B | Produce architecture diagrams, draft OpenAPI, data model inventory, threat model, observability plan |
| FigmaIntegrationAgent | C | Validate 12/12 Figma analysis files, DTO naming, and optional build health |
| PhaseReconcileAgent | A/B | Merge design discoveries back into requirements and architecture |
| BlueprintFreezeAgent | D | Create immutable UI/UX blueprint |
| ContractFreezeAgent | E | Build SCG1 contract artifact set and compute gap report |

### Pipeline Agents

| Agent | Stage | Responsibility |
|---|---|---|
| BlueprintAnalysisAgent | Blueprint | Detect aligned, drifted, and missing implementation against the blueprint/specs |
| CodeReviewAgent | Review | Run standard review plus adversarial design review |
| RemediationAgent | Remediate | Apply targeted patches, validate, and report patch results |
| QualityGateAgent | Gate | Enforce build, test, coverage, and security thresholds |
| E2EValidationAgent | E2E | Validate routes, contracts, stored procedures, auth, browser rendering, and error states |
| DeployAgent | Deploy | Perform deploy sequence with mandatory rollback on any failure |
| PostDeployValidationAgent | Post-deploy | Verify live environment health, SPA freshness, auth flow, and bundle accessibility |

## 2.4 Runtime Services Behind the Agents

The agents are not standalone scripts. They sit on top of reusable runtime services.

| Runtime Component | Purpose |
|---|---|
| `VaultAdapter` | Reads and writes Obsidian-compatible notes and state files |
| `StateDB` | SQLite-backed durable state for milestones, slices, tasks, decisions, rate-limit windows, stuck patterns |
| `WorktreeManager` | Creates, tracks, and tears down git worktrees per milestone |
| `ExecutionGraph` | Dependency-aware task scheduler; runs independent tasks in parallel |
| `BaseAgent` | Loads the vault note, resolves model/tool settings, runs the LLM call, and normalizes structured output |
| `RateLimiter` | Enforces CLI RPM safety windows and model cooldowns |
| `BudgetRouter` | Downgrades model selection at 50/75/90% budget thresholds |
| `StuckDetector` | Hashes PatchSet signatures; escalates when the same hash recurs |
| `TimeoutHierarchy` | Soft (wrap up), idle (probe), hard (halt + forensics) timeouts per task |
| `CompactedExec` | Wraps bash/Semgrep/Playwright output; agent sees summary, raw persisted at path |
| `ProjectStackContext` (v6.1.0) | Reads `docs/gsd/stack-overrides.md` from the target project; resolves backend framework, SDK, solution format, frontend, mobile, compliance. Defaults to .NET 8 when no override. Injected into every agent's system prompt as a `PROJECT STACK CONTEXT` block via `BaseAgent.setProjectStackContext()` |
| `StackLeakValidator` (v6.1.0) | Post-SDLC defense-in-depth check. Scans generated `.csproj` / `.json` / `.md` / `.yaml` / `.xml` artifacts for framework values that contradict the declared stack context. Heuristic false-positive filter skips migration/changelog/archived contexts. Findings logged to `gate-results` observability + recorded as decisions in `state.db` |
| `ObservabilityLogger` | Structured JSONL output per category (`e2e-traces`, `deploy-logs`, `gate-results`, `build-output`, `router-decisions`) — agent-queryable |
| `HookSystem` | Provides lifecycle hooks such as run logging and result validation |
| `default-hooks` | Registers built-in hooks for costs, validation, and vault logging |
| `types.ts` + `sdlc-types.ts` | Define the strongly typed I/O contracts for all agents |
| `preflight()` | Verifies vault structure, CLI availability, `GSD_LLM_MODE`, SQLite access, and optional security tool availability before a run starts |

## 2.5 Repository Layout

```text
gsd-autonomous-dev/
  src/
    agents/                 SDLC and pipeline agents (14 total)
    harness/                Orchestrators, types, vault adapter, hooks, rate limiter, V6 scheduler
    evals/                  Evaluation runner and judges
    index.ts                Unified CLI entry point
  memory/
    agents/                 Vault notes for every agent
    knowledge/              Quality gates, tools reference, model strategy, deploy config, rollback
    architecture/           V6 design, agent system design, state schema, hook registry
    milestones/             V6 hierarchical runtime: M{nnn}/ROADMAP.md, slices/, tasks/
    observability/          Structured logs: e2e-traces/, deploy-logs/, gate-results/, build-output/
    sessions/               Run state snapshots and append-only evidence
    decisions/              Orchestrator decision trail
    state.db                SQLite durable state (milestones, slices, tasks, decisions)
  claude-memory/            Claude's durable knowledge vault (Obsidian, OneDrive-synced)
    topics/                 Topic pages with YAML frontmatter
    index.md, HEALTH.md, CHANGELOG.md, .retrieval-log.jsonl
  .claude/
    hooks/                  retrieve.sh, consolidate.sh, health-check.sh, impact-check.sh, reindex.sh, preference-extract.sh
    commands/               vault-status.md, review.md, consolidate.md, contradictions.md, volatility.md, graduate.md
    settings.json           Hooks + MCP registrations
  .gsd-worktrees/           Per-milestone git worktrees (ignored)
  docs/
    GSD-Developer-Guide.md  Canonical V6 guide (this document)
    GSD-Workstation-Setup.md  Base toolchain setup
    workstation.md          Per-workstation Claude memory + hooks config
    GSD-Configuration.md    Runtime configuration reference
    GSD-Claude-Code-Skills.md  Installed skills reference
    GSD-Figma-Make-Integration.md
    GSD-Troubleshooting.md
    legacy/                 Archived pre-V6 documentation (do not use)
  graphify-out/             Graphify-generated knowledge graph output
  .gitnexus/                GitNexus graph/index data
  test-fixtures/            Eval fixtures and regression examples
```

# Chapter 3: Vault Memory and State

## 3.1 Why the Vault Exists

The vault is the single source of truth for runtime behavior. The TypeScript code supplies the engine, but the vault supplies the operational configuration: agent prompts, quality thresholds, deploy targets, rollback procedures, project paths, and architecture notes.

This layout is intentionally Obsidian-friendly so that a developer can browse or edit the system in a normal markdown workspace without building custom tooling.

## 3.2 Vault Structure

```text
memory/
  MEMORY.md                         Long-term project context
  active-tasks.md                   Session handoff notes
  session-state.md                  Crash recovery snapshot
  state.db                          V6 SQLite durable state (milestones, slices, tasks, decisions)
  agents/
    requirements-agent.md
    architecture-agent.md
    figma-integration-agent.md
    phase-reconcile-agent.md
    blueprint-freeze-agent.md
    contract-freeze-agent.md
    orchestrator.md
    blueprint-analysis-agent.md
    code-review-agent.md
    remediation-agent.md
    quality-gate-agent.md
    e2e-validation-agent.md
    deploy-agent.md
    post-deploy-validation-agent.md
  knowledge/
    quality-gates.md
    model-strategy.md
    deploy-config.md
    project-paths.md
    rollback-procedures.md
    tools-reference.md
    rules/                          V6 golden-rules-as-code (Semgrep/ESLint YAML)
  architecture/
    v6-design.md                   Canonical V6 architecture reference
    agent-system-design.md
    state-schema.md
    hook-registry.md
  milestones/                       V6 hierarchical runtime tree
    M001-{slug}/
      ROADMAP.md                    Milestone goal + slice list
      state.json                    Typed milestone state (mirror of state.db row)
      slices/
        S01-{slug}/
          PLAN.md                   Slice goal + task list
          state.json
          tasks/
            T01-blueprint-analysis.md
            T02-code-review.md
  observability/                    V6 structured query surface
    e2e-traces/{runId}.jsonl
    deploy-logs/{runId}.jsonl
    gate-results/{runId}.jsonl
    build-output/{runId}.jsonl
  evals/
    test-cases.md
  sessions/
  decisions/
```

## 3.3 Agent Notes and Frontmatter

Every agent note in `memory/agents/` uses frontmatter to define the runtime contract.

| Field | Meaning |
|---|---|
| `agent_id` | Stable agent identity used by the orchestrator |
| `model` | Preferred primary model identifier |
| `tools` | Allowed tool classes |
| `forbidden_tools` | Explicitly blocked tools |
| `reads` | Vault notes the agent depends on |
| `writes` | Vault directories or notes the agent is allowed to write |
| `max_retries` | Retry budget before escalation |
| `timeout_seconds` | Max time for a single attempt |
| `escalate_after_retries` | Whether exhaustion becomes a paused pipeline/error |

The body of the note then defines:

- The agent role.
- The system prompt.
- The input and output schema.
- Known failure modes and how the orchestrator should interpret them.

Changing agent behavior is usually a vault edit, not a code edit.

## 3.4 State Model and Resume Behavior

V6 uses a **hybrid state model**: SQLite (`memory/state.db`) for queryable durable state, markdown for human-readable narrative.

### 3.4.1 SQLite Schema

| Table | Columns |
|---|---|
| `milestones` | id, name, status, started_at, completed_at, budget_usd, worktree_path |
| `slices` | id, milestone_id, name, status, depends_on_slice_ids |
| `tasks` | id, slice_id, agent_id, stage, status, cost_usd, tokens_in, tokens_out, output_hash |
| `decisions` | id, task_id, action, reason, evidence (FK to `memory/decisions/` markdown) |
| `rate_limit_windows` | cli_id, timestamp, calls_in_window |
| `stuck_patterns` | id, signature_hash, occurrences, first_seen, last_seen |

### 3.4.2 Markdown Narrative Files

| File | Producer | Purpose |
|---|---|---|
| `memory/milestones/M{nnn}/ROADMAP.md` | Orchestrator | Milestone goal + slice list |
| `memory/milestones/M{nnn}/slices/S{nn}/PLAN.md` | Orchestrator | Slice goal + task list |
| `memory/milestones/M{nnn}/slices/S{nn}/tasks/T{nn}-{stage}.md` | Agent | Per-task narrative + output |
| `memory/sessions/{date}-run-{runId}.md` | Pipeline orchestrator | Human-readable run summary |
| `memory/decisions/*` | Orchestrators | Decision trail with action, rationale, and evidence |
| `memory/observability/{type}/{runId}.jsonl` | Agents + gate | Structured logs for agent-legible queries |

### 3.4.3 Resume Semantics

- `gsd run <milestone>` — resumes from the last completed task if the milestone exists in `state.db`; otherwise creates a new milestone.
- `sdlc run --from-phase <phase>` — explicit phase-level resume within the active slice.
- `pipeline run --from-stage <stage>` — explicit stage-level resume within the active slice.
- `gsd query task <taskId>` — inspects task state without resuming.
- Auto-lock file `memory/state.db.lock` detects stale locks after crashes; `gsd forensics` packages the forensic bundle for triage.

## 3.5 Using the Vault in Obsidian

The vault is already markdown and folder-based, so the easiest Obsidian setup is to open the repository root or the `memory/` folder directly as a vault.

Recommended developer workflow:

1. Open `memory/MEMORY.md`, `memory/active-tasks.md`, and `memory/session-state.md` at the start of a new session.
2. Review the relevant agent note before changing prompts or runtime rules.
3. Edit `memory/knowledge/*.md` to change thresholds or deploy behavior.
4. Treat `memory/sessions/` and `memory/decisions/` as append-only operational history.

## 3.6 Claude Memory Stack (`claude-memory/`)

In addition to the runtime `memory/` directory, the workstation has a separate **Claude Memory Stack** that persists Claude's durable knowledge across sessions. This is distinct from the TypeScript harness memory — it captures the developer's conversational context with Claude, not the agents' runtime config.

| Layer | Location | Managed By | Purpose |
|-------|----------|------------|---------|
| Runtime Vault | `memory/` (in repo) | TypeScript harness | Agent prompts, thresholds, decisions, session logs |
| **Claude Memory Vault** | `claude-memory/` (in Obsidian) | Claude Code hooks + slash commands | Durable knowledge from conversations with Claude |
| Auto-memory | `C:\Users\<user>\.claude\projects\...\memory\` | Claude Code built-in | Claude's private working notes |
| GitNexus Index | `.gitnexus/` (gitignored) | GitNexus MCP | Symbol graph for impact analysis |

### 3.6.1 Claude Memory Vault Structure

```text
claude-memory/
  index.md                 Topic registry, rebuilt automatically
  CHANGELOG.md             Audit trail of all vault mutations
  HEALTH.md                Live health metrics (status, retrieval quality, freshness)
  preferences.md           User preferences (always loaded on every prompt)
  .retrieval-log.jsonl     Retrieval event log (used for health metrics)
  topics/
    gsd-pipeline-architecture.md
    agent-orchestration.md
    sdlc-phases.md
    llm-routing-strategy.md
    quality-gates.md
  _archive/                Retired or superseded topics
```

Each topic page follows a typed schema:

```yaml
---
topic: <short name>
aliases: [<alternate names for keyword matching>]
volatility: stable|evolving|ephemeral
last_updated: <ISO date>
confidence: high|medium|low
sources: [<session dates, commit hashes>]
access_count: 0
last_accessed: <ISO date>
---

# <Topic>
## Summary
## Key Facts
## Decisions & Rationale
## Open Questions
## Related Code
## Related Topics
```

### 3.6.2 Volatility Semantics

| Level | Review cadence | Consolidation behavior |
|-------|----------------|------------------------|
| `stable` | Yearly | Conservative — strong preference for preserving existing content |
| `evolving` (default) | Quarterly | Normal consolidation with contradiction detection |
| `ephemeral` | Aggressive | Auto-archive after 60 days with no access or update |

### 3.6.3 Contradiction Handling

When `consolidate.sh` encounters new information during a session, it compares against existing `## Key facts`:

- **Compatible** — extends existing, proceed normally
- **Clarifying** — refines existing, update in-place with CHANGELOG entry
- **Contradicting** — genuine conflict; append to `## Open questions` as `CONTRADICTION detected on [date]`, lower confidence by one step, do NOT overwrite
- **Replacing** — only after the user explicitly says "the old info is wrong"; overwrite with `[replaced]` CHANGELOG entry

### 3.6.4 Hooks (registered in `.claude/settings.json`)

| Hook | Trigger | Purpose |
|------|---------|---------|
| `retrieve.sh` | UserPromptSubmit | Loads matching vault topics + preferences.md into context |
| `impact-check.sh` | PreToolUse (Edit/Write) | Warns on HIGH/CRITICAL agent, orchestrator, or harness edits |
| `reindex.sh` | PostToolUse (Bash) | Runs `gitnexus analyze` after `git commit` or `git merge` |
| `consolidate.sh` | Stop | Reminds to run `/consolidate` if vault was accessed |
| `health-check.sh` | Stop | Rewrites `HEALTH.md` with live metrics |
| `preference-extract.sh` | Stop | Signals to check for preference-shaped statements |

All hooks resolve the vault path from `$GSD_VAULT_MEMORY` (env var) with a fallback to the default rjain/Technijian path. On a workstation with a different username or org, set `GSD_VAULT_MEMORY` in the Windows user environment — see [Chapter 4.7](#47-claude-memory-stack-bootstrap).

### 3.6.5 Slash Commands

| Command | Purpose |
|---------|---------|
| `/vault-status` | Health dashboard — topic count, retrieval quality, freshness |
| `/consolidate` | Save durable session knowledge to vault topics |
| `/review` | Weekly vault review — quality, contradictions, volatility calibration |
| `/contradictions` | List and resolve unresolved fact conflicts |
| `/volatility <topic> <stable\|evolving\|ephemeral>` | Set topic volatility manually |
| `/graduate` | Recommend stay vs. migrate to LightRAG |

### 3.6.6 Weekly Review Mandate

Run `/review` every week. Target: 5–10 minutes. Escalation:
- **7–14 days** since last review: gentle reminder at session end
- **14–21 days**: warning at session end
- **>21 days**: "vault health cannot be trusted" notice
- **>30 days**: `/graduate` refuses to give a recommendation

### 3.6.7 Health Classification

`HEALTH.md` is recomputed at every session stop. The status follows a graduated ladder:

| Status | Criteria |
|--------|----------|
| **GREEN** | Topic count < 150, hit rate > 70%, miss rate < 15%, stale-180 < 10% |
| **YELLOW** | Topic count 150–400, hit rate 50–70%, miss rate 15–30%, stale-180 10–25% |
| **RED** | Topic count > 400, hit rate < 50%, miss rate > 30%, stale-180 > 25% |
| **PENDING** | Insufficient retrieval data (< 30 days of `.retrieval-log.jsonl`) |

# Chapter 4: Workstation Setup

## 4.1 Minimum Requirements

| Requirement | Minimum | Notes |
|---|---|---|
| Windows | 10/11, build 19041+ | Primary supported workstation target |
| Git | 2.40+ | Required for repo management and deploy tagging |
| Node.js | 18+ | Required for TypeScript harness and Playwright |
| npm | 9+ | Comes with Node.js |
| Python | 3.10+ | Required for Graphify and Semgrep install path |
| pip | 23+ | Required for Python tool installs |
| Docker Desktop | 4.0+ | Optional, required only for Shannon penetration testing |

## 4.2 Install the Repository and Node Dependencies

From a fresh workstation:

```bash
cd C:\vscode
git clone https://github.com/rjain557/gsd-autonomous-dev.git
cd gsd-autonomous-dev\gsd-autonomous-dev
npm install
npx tsc --noEmit
```

A clean typecheck should produce no output.

## 4.3 Install the External Tools GSD Expects

### Browser and security tooling

```bash
npx playwright install chromium
pip install graphifyy semgrep
npm install -g gitnexus @modelcontextprotocol/server-github
```

This installs the non-LLM augmentation layer that sits beside the vault:

- `Playwright` for real Chromium validation.
- `graphify` for codebase community detection and graph artifacts in `graphify-out/`.
- `semgrep` for SAST scanning in the quality gate.
- `gitnexus` for blast radius analysis and safe symbol-aware refactors.
- `@modelcontextprotocol/server-github` for GitHub MCP automation.

### AI CLIs

```bash
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex
npm install -g @google/gemini-cli
```

Authenticate each installed CLI after installation.

### Claude Code integrations

```bash
graphify claude install
graphify install
gitnexus analyze
gitnexus setup
claude mcp add context7 -- npx -y @upstash/context7-mcp@latest
npx -y skills add agamm/claude-code-owasp -y
npx -y skills add unicodeveloper/shannon -y
```

These integrations map to distinct 4.2 capabilities:

- `graphify claude install` wires Graphify into Claude Code.
- `gitnexus analyze` builds the local repo index in `.gitnexus/`.
- `gitnexus setup` registers the repo and CLI helpers.
- `context7` is a workstation MCP server for live library documentation.
- `OWASP` and `Shannon` are security skills available from the local skill host; the repository also carries reference copies under `.agents/skills/`.

Repository-bundled skill content also exists outside the host-installed copies:

- `.claude/skills/` contains the local project skills for SQL, React, component composition, and design review.
- `.agents/skills/owasp-security/` contains the OWASP security reference skill.
- `.agents/skills/shannon/` contains the Shannon pentest skill and helper scripts.

## 4.4 Environment Variables and Secrets

The runtime checks only a few variables directly, but the full workstation typically needs more.

| Variable | When Needed | Purpose |
|---|---|---|
| `GSD_LLM_MODE` | Optional | `cli` (default) or `sdk` |
| `ANTHROPIC_API_KEY` | Required only when `GSD_LLM_MODE=sdk` | Anthropic SDK structured output mode |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | Required when using GitHub MCP | GitHub automation |
| Provider-specific CLI auth | Required when the corresponding CLI is installed | Claude, Codex, Gemini login state |

Implementation note:

- `claude` is the only CLI treated as mandatory by `preflight()`.
- `codex` and `gemini` are optional accelerators and fallbacks.
- Missing Semgrep only produces a warning because the gate falls back to regex scanning.

## 4.5 Verify the Workstation

Run these checks from the repository root.

```bash
npx tsc --noEmit
semgrep --version
node -e "require('playwright').chromium.launch({headless:true}).then(b => { console.log('OK: Chromium'); b.close(); })"
graphify --help
gitnexus --version
npx ts-node src/index.ts status
```

Expected outcomes:

- TypeScript emits no errors.
- Semgrep reports a version.
- Playwright launches Chromium successfully.
- Graphify and GitNexus are callable.
- Claude, Codex, and Gemini CLIs authenticate successfully if installed.
- `status` either shows the latest SDLC run or prints that no SDLC state exists yet.

## 4.6 Canonical Setup References

The standalone setup and integration references are:

- [`docs/GSD-Workstation-Setup.md`](GSD-Workstation-Setup.md) — Base toolchain (Node, Python, AI CLIs)
- [`docs/workstation.md`](workstation.md) — Claude memory stack + hooks + per-machine config
- [`docs/GSD-Figma-Make-Integration.md`](GSD-Figma-Make-Integration.md)
- [`docs/GSD-Installation-Graphify.md`](GSD-Installation-Graphify.md)

## 4.7 Claude Memory Stack Bootstrap

After the base workstation setup (Sections 4.1–4.5) is complete, bootstrap the Claude Memory Stack described in [Chapter 3.6](#36-claude-memory-stack-claude-memory).

### 4.7.1 Verify Obsidian Vault Access

The `claude-memory/` vault lives in the Obsidian folder and syncs via OneDrive:

```bash
ls "/c/Users/$USERNAME/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev/claude-memory/"
```

Expected output: `CHANGELOG.md  HEALTH.md  _archive  index.md  topics`

If missing, wait for OneDrive sync or copy the vault from another machine.

### 4.7.2 Set `GSD_VAULT_MEMORY` (only if your path differs)

The hooks default to the `rjain` path. Set this env var only if your Windows username or OneDrive org folder name differs:

```powershell
$vaultPath = "C:\Users\YOUR_USERNAME\OneDrive - YOUR_ORG\Documents\obsidian\gsd-autonomous-dev\gsd-autonomous-dev\claude-memory"
[System.Environment]::SetEnvironmentVariable('GSD_VAULT_MEMORY', $vaultPath, 'User')
```

Restart your terminal, then verify with `echo $GSD_VAULT_MEMORY`.

### 4.7.3 Verify Hooks and Commands Are Wired

```bash
cd C:\vscode\gsd-autonomous-dev\gsd-autonomous-dev

# Hook scripts present
ls .claude/hooks/
# Expected: consolidate.sh  health-check.sh  impact-check.sh  preference-extract.sh  reindex.sh  retrieve.sh

# Slash commands present
ls .claude/commands/
# Expected: consolidate.md  contradictions.md  graduate.md  review.md  vault-status.md  volatility.md

# Hooks registered in settings.json
cat .claude/settings.json | python3 -c "import sys,json; s=json.load(sys.stdin); print(list(s['hooks'].keys()))"
# Expected: ['PreToolUse', 'UserPromptSubmit', 'PostToolUse', 'Stop']
```

### 4.7.4 Initialize Vault Git Repo (recommended)

Initializing the vault as a git repo lets you roll back any vault mutation. Run once per workstation (one-time setup):

```bash
VAULT_ROOT="/c/Users/$USERNAME/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev"

git -C "$VAULT_ROOT" init
cat > "$VAULT_ROOT/.gitignore" << 'EOF'
.obsidian/workspace*
.obsidian/cache
.obsidian/graph.json
.trash/
*.tmp
EOF
git -C "$VAULT_ROOT" add .
git -C "$VAULT_ROOT" commit -m "baseline: vault before Claude memory setup"
```

### 4.7.5 First Run

After bootstrap, run `/vault-status` to see the initial health dashboard, then `/review` to mark the first weekly review as complete.

This developer guide is the full narrative source. Those documents are focused operational runbooks.

# Chapter 5: Unified CLI and Daily Workflow

## 5.1 Command Forms

There are two common invocation styles.

### Repository-local form (always works)

```bash
npx ts-node src/index.ts run requirements --project "ClientPortal" --description "Multi-tenant SaaS portal"
```

### Shorthand form (if you have a local alias or wrapper)

```bash
gsd run requirements --project "ClientPortal" --description "Multi-tenant SaaS portal"
```

The repository-local form is the canonical one because it does not depend on any extra shell wrapping.

## 5.2 Milestones and What They Actually Do

| Milestone | Canonical Command | Implementation Behavior |
|---|---|---|
| `requirements` | `npx ts-node src/index.ts run requirements --project "X" --description "Y"` | Runs Phase A then Phase B and writes the Intake Pack and Architecture Pack |
| `figma-prompts` | `npx ts-node src/index.ts run figma-prompts` | Uses the Phase B checkpoint in the unified flow; the actual Figma Make prompt remains the authored file in `scripts/Figma_Complete_Generation_Prompt.md` |
| `figma-uploaded` | `npx ts-node src/index.ts run figma-uploaded --design-path design/web/v1/src/` | Runs Phase C then Phase A/B Reconcile |
| `contracts` | `npx ts-node src/index.ts run contracts` | Runs Phase D then Phase E |
| `blueprint` | `npx ts-node src/index.ts run blueprint` | Starts the Phase F pipeline at the blueprint stage |
| `deploy` | `npx ts-node src/index.ts run deploy` | Starts the pipeline at deploy/post-deploy |
| `full` | `npx ts-node src/index.ts run full --project "X" --description "Y"` | Runs the full lifecycle from Phase A through deploy |

Current implementation note:

- The `figma-prompts` milestone is a workflow checkpoint, not a dynamic prompt authoring engine.
- The Figma Make prompt you paste into Figma today is still the maintained file at `scripts/Figma_Complete_Generation_Prompt.md`.

## 5.3 Prerequisite Validation

Before a milestone runs, the CLI validates prerequisites.

| Milestone | Prerequisite Checked |
|---|---|
| `figma-prompts` | `docs/sdlc/phase-b-architecture-pack.json` must exist |
| `figma-uploaded` | No file prerequisite; the design path is validated by the Phase C agent |
| `contracts` | `docs/sdlc/phase-ab-reconciliation-report.json` must exist |
| `blueprint` | `docs/sdlc/phase-e-contract-artifacts.json` must exist |
| `deploy` | No file prerequisite in the front-end CLI; deploy readiness is enforced inside the pipeline via gate state |

If a prerequisite is missing, the CLI tells you what file it expected and which milestone to run first.

## 5.4 Advanced Subcommands

The unified `run` command is the everyday surface. The lower-level subcommands are the debugging and explicit resume surfaces.

### SDLC-only execution

```bash
npx ts-node src/index.ts sdlc run --project "ClientPortal" --description "Multi-tenant SaaS" \
  --from-phase phase-c --design-path design/web/v2/src/
```

### Pipeline-only execution

```bash
npx ts-node src/index.ts pipeline run --trigger manual --from-stage gate --dry-run
```

### Status

```bash
npx ts-node src/index.ts status
```

## 5.5 Common Flags

| Flag | Used By | Purpose |
|---|---|---|
| `--project <name>` | `run`, `sdlc run` | Project name for Intake Pack generation |
| `--description <text>` | `run`, `sdlc run` | Project description for Intake Pack generation |
| `--design-path <path>` | `run figma-uploaded`, `sdlc run` | Path to exported Figma Make deliverables |
| `--vault-path <path>` | all run surfaces, `query`, `forensics` | Override the vault directory (default: `./memory`) |
| `--project-root <path>` (v6.1.0) | `run`, `sdlc run`, `pipeline run`, `query stack`, `validate-stack` | Target project root for `docs/gsd/stack-overrides.md` resolution (default: `process.cwd()`). Lets GSD honor per-project backend framework (net8/net9/net10). |
| `--review` | `run`, `sdlc run` | Pause after each SDLC phase for human review |
| `--dry-run` | `run`, `pipeline run` | Skip deployment |
| `--worktree` (V6) | `run` | Run in an isolated git worktree per milestone |
| `--base-branch <branch>` (V6) | `run` | Base branch for worktree (default: `main`) |
| `--budget <usd>` (V6) | `run` | Milestone budget for cost routing (default: `10`) |
| `--from-phase <phase>` | `sdlc run` | Resume from a specific SDLC phase |
| `--from-stage <stage>` | `pipeline run` | Resume from a specific pipeline stage |
| `--json` (v6.1.0) | `validate-stack` | Emit JSON report instead of markdown |
| `--fail-on-findings` (v6.1.0) | `validate-stack` | Exit 1 if any findings detected (CI hook) |
| `--since-days <N>` | `harvest` | Window for pattern mining (default: 7) |
| `--dry-run` | `migrate` | Preview V5 → V6 migration without writing to state.db |

## 5.6 Recommended Day-to-Day Workflow

For a new project:

1. Run `requirements` to produce the Intake Pack and Architecture Pack.
2. Use the architecture output together with `scripts/Figma_Complete_Generation_Prompt.md` in Figma Make.
3. Export the Figma deliverables into `design/web/v##/src/`.
4. Run `figma-uploaded` to validate the export and reconcile it with the requirements.
5. Run `contracts` to freeze the blueprint and generate SCG1 artifacts.
6. Run `blueprint` to execute the code pipeline.
7. Run `deploy` to push to alpha once the gate has passed.

For a review-gated workflow, add `--review` and stop between phases for human signoff.

# Chapter 6: Phases A and B - Requirements and Architecture

## 6.1 Phase A - RequirementsAgent

The RequirementsAgent converts a project name and free-form description into a structured Intake Pack. The runtime contract for this agent is documented in [`memory/agents/requirements-agent.md`](../memory/agents/requirements-agent.md).

The generated Intake Pack includes:

- Problem statement.
- Outcomes and measurable success metrics.
- Stakeholders and RACI mapping.
- Data classification and regulatory scope.
- Domain operations and RBAC sketch.
- Non-functional requirements with measurable targets.
- Risk register.
- Testable acceptance criteria.
- Dependencies.

The artifact is written to `docs/sdlc/phase-a-intake-pack.json`.

## 6.2 Phase B - ArchitectureAgent

The ArchitectureAgent transforms the Intake Pack into an Architecture Pack.

Expected output areas:

- System context diagram.
- Component diagrams.
- Sequence diagrams for major flows.
- Data flow diagram.
- Draft OpenAPI 3.0 YAML.
- Data model inventory.
- Threat model.
- Observability plan.
- Promotion model.

Artifacts written by the SDLC orchestrator:

- `docs/sdlc/phase-b-architecture-pack.json`
- `docs/sdlc/openapi-draft.yaml`

## 6.3 Review Expectations for A and B

Even in autonomous mode, Phase A and Phase B are where a human team can get the most leverage from early review.

Recommended checks:

- Are the primary business outcomes measurable?
- Does the RACI model match the real stakeholders?
- Are the regulatory obligations correct for the product?
- Does the draft OpenAPI cover the core user journeys?
- Does the threat model reflect the real trust boundaries?

## 6.4 Using `--review` in Early Phases

When `--review` is supplied, the SDLC orchestrator pauses after each completed SDLC phase, saves state, and tells you to resume with the next milestone.

This is the safest way to operate when:

- The project description is ambiguous.
- The product owner wants to approve the architecture before any design work starts.
- You want the Frozen Blueprint and SCG1 contract to become explicit signoff checkpoints.

## 6.5 Files to Hand to the Design Team

The minimum handoff to a design/prototyping pass is:

- `docs/sdlc/phase-a-intake-pack.json`
- `docs/sdlc/phase-b-architecture-pack.json`
- `docs/sdlc/openapi-draft.yaml`
- `scripts/Figma_Complete_Generation_Prompt.md`

That set gives the design/prototype pass a grounded product and architecture baseline.

# Chapter 7: Phase C, Reconciliation, and Blueprint Freeze

## 7.1 Expected Figma Make Export Structure

The Phase C validator expects the design export under a versioned directory such as `design/web/v1/src/`.

```text
design/web/v1/src/
  _analysis/
    01-screen-inventory.md
    02-component-inventory.md
    03-design-system.md
    04-navigation-routing.md
    05-data-types.md
    06-api-contracts.md
    07-hooks-state.md
    08-mock-data-catalog.md
    09-storyboards.md
    10-screen-state-matrix.md
    11-api-to-sp-map.md
    12-implementation-guide.md
  _stubs/
    backend/
      Controllers/*.cs
      Models/*.cs
    database/
      01-tables.sql
      02-stored-procedures.sql
      03-seed-data.sql
```

That structure is described in the runtime prompt and in [`docs/GSD-Figma-Make-Integration.md`](../docs/GSD-Figma-Make-Integration.md).

## 7.2 Phase C - FigmaIntegrationAgent

Phase C performs validation only. It does not rewrite the design export.

The agent checks:

- Presence of all 12 required analysis files.
- DTO naming patterns in the generated backend stubs.
- Optional build verification (`dotnet build` and `npm build`) when those surfaces exist.

Important implementation detail:

- Phase C state is saved into the SDLC state file, but there is currently no dedicated `docs/sdlc/phase-c-*.json` artifact written by the orchestrator.

## 7.3 Phase A/B Reconcile

The PhaseReconcileAgent compares the original requirements and architecture against what the Figma prototype revealed.

Outputs include:

- `gapsFound`
- `newRequirements`
- `updatedEndpoints`
- `updatedDataModels`
- `alignmentScore`
- `updatedIntakePack`
- `updatedArchitecturePack`

Artifacts written:

- `docs/sdlc/phase-ab-reconciliation-report.json`
- Updated `docs/sdlc/phase-a-intake-pack.json`
- Updated `docs/sdlc/phase-b-architecture-pack.json`

## 7.4 Phase D - BlueprintFreezeAgent

Phase D transforms the reconciled SDLC material plus the Figma analysis into a Frozen Blueprint.

The Frozen Blueprint includes:

- Full screen inventory with routes, layouts, roles, and states.
- Component inventory with categories, reuse surface, and variants.
- Design token counts.
- Navigation architecture summary.
- RBAC matrix.
- Accessibility requirements.
- Copy deck items.
- Approval status flags.
- `frozenAt` timestamp.

Artifact written:

- `docs/sdlc/phase-d-frozen-blueprint.json`

## 7.5 What “Blueprint Freeze” Means Operationally

After Phase D, the implementation target is supposed to stabilize.

That means:

- Route naming should stop changing casually.
- RBAC expectations should be known.
- UI state coverage should be explicit.
- Contract generation in Phase E should not have to infer missing UI intent.

If the Frozen Blueprint is obviously incomplete, stop there and fix the source artifacts before moving forward.

# Chapter 8: Phase E - Contract Freeze and SCG1

## 8.1 What Contract Freeze Produces

The ContractFreezeAgent is the last SDLC step before the code pipeline. It generates the contract set that Phase F is expected to honor.

The artifact model includes these paths:

- `docs/spec/ui-contract.csv`
- `docs/spec/openapi.yaml`
- `docs/spec/apitospmap.csv`
- `docs/spec/db-plan.md`
- `docs/spec/test-plan.md`
- `docs/spec/ci-gates.md`
- `docs/spec/validation-report.md`

The orchestrator also writes the structured summary to:

- `docs/sdlc/phase-e-contract-artifacts.json`

## 8.2 SCG1 Gate Semantics

SCG1 is represented by `scg1Passed` in the contract artifact output.

The ContractFreezeAgent computes:

- Route count.
- Endpoint count.
- Stored procedure count.
- Contract gaps.
- A binary SCG1 verdict.

Typical gap categories include:

- DTO to stored procedure parameter mismatches.
- Endpoint vs controller or handler gaps.
- Data types introduced in the design export but missing from the planned model.

## 8.3 What Blocks Phase F

If `scg1Passed` is false, the system still writes the artifacts, but you should not treat the project as implementation-ready.

The readable human handoff is:

- `docs/spec/validation-report.md`

The structured machine-readable version is:

- `docs/sdlc/phase-e-contract-artifacts.json`

## 8.4 Relationship to the Code Pipeline

The `blueprint` milestone is blocked until `docs/sdlc/phase-e-contract-artifacts.json` exists.

Operationally, that file is the proof that:

- The SDLC phases have already produced a coherent implementation target.
- The code pipeline can start with a frozen contract instead of ambiguous design input.

# Chapter 9: Pipeline Execution (Phases F and G)

## 9.1 Stage Order

The pipeline orchestrator executes the following stage order:

| Order | Stage | Primary Goal |
|---|---|---|
| 1 | `blueprint` | Compare implementation to blueprint/spec and detect drift |
| 2 | `review` | Run standard and adversarial review |
| 3 | `remediate` | Apply targeted patches when review fails |
| 4 | `gate` | Enforce build, test, coverage, and security thresholds |
| 5 | `e2e` | Validate contracts, routes, auth, browser rendering, and runtime behavior |
| 6 | `deploy` | Deploy to alpha with rollback |
| 7 | `post-deploy` | Validate the live environment |

The explicit stage types are defined in [`src/harness/types.ts`](../src/harness/types.ts).

## 9.2 Blueprint Analysis and Review

### BlueprintAnalysisAgent

Inputs:

- Blueprint path or requirements matrix.
- Spec document paths.
- Repository root.

Output:

- `aligned`
- `drifted`
- `missing`
- `riskLevel`

### CodeReviewAgent

The review stage performs two passes in one call:

1. Standard review against correctness, security, coverage, style, and convergence.
2. Adversarial design review that challenges complexity, maintainability, and scaling assumptions.

Design issues are informational and do not automatically fail the pipeline. Critical and high correctness/security/convergence failures do.

## 9.3 Remediation Loop

The remediation loop is owned by the orchestrator, not the RemediationAgent itself.

Loop rules:

- If review passes, remediation is skipped.
- If review fails, the RemediationAgent applies targeted fixes.
- The QualityGateAgent then reruns the binary gate.
- The orchestrator allows up to three remediation iterations.
- If the gate still fails after that budget, the pipeline ends in failure/paused state.

This prevents silent endless patch churn.

## 9.4 Quality Gate

The QualityGateAgent is the hard stop before deploy.

Checks run in this order:

1. `dotnet build --no-restore` and `npm run build`.
2. `dotnet test --no-build --verbosity normal`.
3. Coverage threshold validation.
4. Security scanning with Semgrep, regex fallback, `npm audit`, and `dotnet list package --vulnerable`.
5. Optional frontend test execution when configured.

The gate throws a `QualityGateFailure` when it fails. That is deliberate because the deploy path must never be reachable after a failed gate.

## 9.5 E2E Validation

The E2EValidationAgent runs eight categories in parallel via `Promise.allSettled`.

| Category | Purpose |
|---|---|
| API Contract Validation | Verify documented endpoints are reachable and not returning 404/500 |
| Stored Procedure Existence | Confirm every mapped stored procedure exists in SQL artifacts |
| Mock Data Detection | Detect TODO/FIXME, mock data, lorem ipsum, hardcoded IDs, and dev-only conditionals |
| Page Render Validation | Verify frontend routes return success |
| Auth Flow Validation | Check expected auth/health behavior |
| CRUD Operations | Verify controller and test coverage exists for write routes |
| Error States | Confirm error boundaries and absence of 500s in obvious failure paths |
| Browser Render | Launch Playwright/Chromium and capture console or render failures |

## 9.6 Deploy and Rollback

The DeployAgent reads the target environment from `memory/knowledge/deploy-config.md` and the rollback runbook from `memory/knowledge/rollback-procedures.md`.

Hard rules enforced by the implementation:

- Deploy only runs if `GateResult.passed === true`.
- Rollback instructions must exist before any deploy step begins.
- Any deploy step failure triggers immediate rollback.
- Rollback stops on its own first failure and escalates to a human.

The default documented environment is `alpha`.

## 9.7 Post-Deploy Validation

The PostDeployValidationAgent validates the live environment using checks such as:

- SPA hash freshness.
- `/api/health` returns 200.
- `/api/auth/me` returns the expected auth behavior.
- No discovered API endpoints return 500.
- Frontend root is reachable.
- Referenced SPA bundle assets are accessible.

## 9.8 Dry Runs and Explicit Resume Commands

Dry run:

```bash
npx ts-node src/index.ts pipeline run --dry-run
```

Explicit stage resume:

```bash
npx ts-node src/index.ts pipeline run --from-stage gate
```

Explicit phase resume:

```bash
npx ts-node src/index.ts sdlc run --from-phase phase-d --project "ClientPortal"
```

The milestone-driven `run` command is best for normal operation. The `sdlc` and `pipeline` subcommands are best when you need deterministic resume control.

# Chapter 10: Tooling and Model Strategy

## 10.1 Primary Model Routing

The control plane is intentionally CLI-first.

| Model | CLI | RPM | Primary Use |
|---|---|---|---|
| Claude | `claude` | 10 | Requirements, architecture, review, remediation, deploy judgment |
| Codex | `codex` | 10 | Code generation, structured contract generation, fallback execution |
| Gemini | `gemini` | 15 | Research, large-context synthesis, fallback review |

The orchestrators use stage/phase-specific routing tables and the `RateLimiter` to pick the first available model.

## 10.2 Emergency API Fallbacks

If all subscription CLIs are unavailable at the same time, the pipeline can fall back to API providers registered with the rate limiter.

| Provider | When Used |
|---|---|
| DeepSeek | First emergency fallback when all three subscription CLIs are busy |
| MiniMax | Second emergency fallback if DeepSeek is also unavailable |

The target operating mode is still `$0` marginal per run. API fallback is resilience, not the default path.

## 10.3 Integrated Tooling Stack

Obsidian is only the operator view on top of the vault. The V6 workstation adds an augmentation layer of code intelligence, live documentation, browser validation, security skills, and MCP automation.

| Tool | Category | Role in V6 | Main Location |
|---|---|---|---|
| Graphify | Code intelligence | Community detection, god-node discovery, graph report, optional wiki | `graphify-out/` |
| GitNexus | Code intelligence | Blast radius, execution flows, symbol context, safe rename | `.gitnexus/` |
| Context7 | Live docs MCP | Version-aware library documentation lookup | Claude workstation MCP registry |
| Semgrep | Security scanner | Primary SAST engine in the quality gate | CLI on workstation |
| Playwright | Browser testing | Real Chromium render and console validation | Local npm dependency |
| GitHub MCP | MCP automation | PR creation, issue tracking, review comment automation | `.claude/settings.json` |
| OWASP Security Skill | Security reasoning | Preventive review guidance, ASVS and OWASP patterns | `.agents/skills/owasp-security/` plus host skill install |
| Shannon Lite | Pentesting | White-box exploit-driven release readiness testing | `.agents/skills/shannon/` plus Docker runtime |
| Claude Max | Primary reasoning model | Requirements, architecture, review, remediation, deploy judgment | CLI subscription |
| ChatGPT Max (Codex) | Primary execution model | Code generation, contract generation, fallback implementation | CLI subscription |
| Gemini Ultra | Research model | Large-context synthesis and fallback review | CLI subscription |

The fixed monthly subscriptions power the model layer. The toolchain above powers the augmentation layer around those models.

## 10.4 Repo-Bundled Skills and Commands

The repository includes local skills beyond the vault itself. These are separate from the agent markdown prompts in `memory/agents/`.

### Claude/project skills in `.claude/skills/`

| Skill | Command | Primary use |
|---|---|---|
| SQL Expert | `/sql-expert` | SQL Server schema design, stored procedures, migrations, tenant-safe data modeling |
| SQL Performance Optimizer | `/sql-performance-optimizer` | Query tuning, execution-plan analysis, index design, SP performance fixes |
| React UI Design Patterns | `/react-ui-design-patterns` | Loading/error/empty/optimistic states, skeletons, retries, error boundaries |
| Composition Patterns | `/composition-patterns` | Compound components, context contracts, reusable React APIs, avoiding boolean-prop sprawl |
| Web Design Guidelines | `/web-design-guidelines` | Accessibility review, ARIA checks, UX audit, Fluent UI v9 compliance |

### Security skills bundled in `.agents/skills/`

| Skill | Trigger Surface | Purpose |
|---|---|---|
| OWASP Security | Reasoning-time security reference | OWASP Top 10:2025, ASVS 5.0, agentic AI security, C#/TypeScript secure patterns |
| Shannon | `/shannon` | Docker-based white-box pentest workflow with real exploit verification |

For the long-form skill guide, see [`docs/GSD-Claude-Code-Skills.md`](../docs/GSD-Claude-Code-Skills.md).

## 10.5 MCP Servers and Hook Wiring

Two kinds of augmentation are active in 4.2: MCP servers and repository/workstation hooks.

### MCP servers

| MCP | Config Source | What It Adds |
|---|---|---|
| GitHub MCP | `.claude/settings.json` | PR creation, issue workflows, review comment access |
| Context7 MCP | Claude workstation install via `claude mcp add context7 ...` | Version-specific documentation lookup for frameworks and libraries |

The GitHub MCP configuration is committed in the repo and expects `GITHUB_PERSONAL_ACCESS_TOKEN` to be supplied through the environment.

### Hooks

| Hook Surface | Current 4.2 Behavior |
|---|---|
| `.claude/settings.json` `PreToolUse` | On `Glob` or `Grep`, injects a reminder to read `graphify-out/GRAPH_REPORT.md` before searching raw files if a graph exists |
| Graphify workflow | Encourages graph-first exploration and optional wiki navigation before brute-force scanning |
| GitNexus workflow | Supports post-change re-indexing after commits and merges in Claude Code environments |
| TypeScript harness hooks | Runtime hooks under `HookSystem` and `default-hooks` log costs, validate outputs, and append vault records |

## 10.6 Graphify Operating Model

Graphify is not just an optional report generator. In 4.2 it is the first-pass architecture lens for the code-review side of the system.

Operational rules:

- Read `graphify-out/GRAPH_REPORT.md` before broad file searches when the graph exists.
- If `graphify-out/wiki/index.md` has been generated, prefer the wiki structure before scanning raw files.
- Treat communities and god nodes as scope boundaries for blueprint analysis, review, and remediation.
- Rebuild Graphify after meaningful code changes so the graph does not drift from the repository.

Common rebuild patterns:

```bash
graphify .
graphify . --update
python3 -c "from graphify.watch import _rebuild_code; from pathlib import Path; _rebuild_code(Path('.'))"
```

Used by:

- BlueprintAnalysisAgent
- CodeReviewAgent
- RemediationAgent

## 10.7 GitNexus Operating Model

GitNexus is the symbol-aware side of the code intelligence stack. Where Graphify explains communities, GitNexus explains execution flows and change impact.

Operational rules carried in the repo memory and skill docs:

- Run `gitnexus_impact({target: "symbolName", direction: "upstream"})` before editing a function, method, or class.
- Warn before proceeding if the impact result is high-risk or critical.
- Use `gitnexus_context({name: "symbolName"})` to see callers, callees, and process participation.
- Use `gitnexus_query({query: "concept"})` to find relevant flows before grepping unfamiliar code.
- Run `gitnexus_detect_changes({scope: "staged"})` before commit to confirm the blast radius stayed inside expectations.
- Use `gitnexus_rename(..., dry_run: true)` for renames instead of text search and replace.

If the index is stale, rebuild it:

```bash
npx gitnexus analyze
```

If embeddings were previously enabled, preserve them during rebuild:

```bash
npx gitnexus analyze --embeddings
```

Used by:

- BlueprintAnalysisAgent
- CodeReviewAgent
- RemediationAgent
- E2EValidationAgent

## 10.8 Security, Browser, and Validation Tooling

| Tool | Real 4.2 behavior |
|---|---|
| Semgrep | Runs `semgrep --config auto --json .` in the quality gate, falls back to `python -m semgrep`, and ultimately to built-in regex patterns if the binary is unavailable |
| Playwright | Launches Chromium for page rendering, console error capture, login accessibility checks, and browser-level smoke validation; falls back to HTTP checks if not installed |
| OWASP Security Skill | Supplies preventive reasoning guidance during review and remediation, including OWASP Top 10:2025, ASVS 5.0, and agentic AI security controls |
| Shannon Lite | Reserved for explicit white-box pentesting. Requires Docker, target authorization, non-production scope, and human review of exploit-backed findings |

The quality gate therefore has three layers of security posture:

1. Preventive reasoning patterns from OWASP.
2. Automated static scanning from Semgrep and dependency audits.
3. Optional exploit-driven validation from Shannon for high-confidence release readiness.

## 10.9 Internal Agent Tool Contracts

The augmentation layer above sits on top of a smaller internal tool schema defined in [`memory/knowledge/tool-schemas.md`](../memory/knowledge/tool-schemas.md).

| Internal Tool | Purpose | Notable restrictions |
|---|---|---|
| `read_file` | Read file contents | Available broadly |
| `write_file` | Persist file changes | Used by implementation-capable agents |
| `list_directory` | Enumerate workspace structure | Supports pattern and recursive listing |
| `search_files` | Regex-based content search | Used when graph-first navigation is insufficient |
| `bash` | Execute shell commands | Restricted by agent role: review is read-only, quality gate only scans/tests, remediation test-runs only, deploy deploys only |
| `spawn_agent` | Fan out sub-agent work | Orchestrator only |

These internal contracts matter because the external tooling is not invoked arbitrarily. It is gated by the agent role, hook system, and structured output contracts.

## 10.10 Tool-to-Agent Mapping

| Agent | Main External Tooling |
|---|---|
| BlueprintAnalysisAgent | Graphify, GitNexus |
| CodeReviewAgent | Graphify, GitNexus, OWASP reasoning patterns |
| RemediationAgent | Graphify, GitNexus, Context7, OWASP reasoning patterns |
| QualityGateAgent | Semgrep, npm audit, dotnet vulnerability checks, OWASP patterns, optional Shannon escalation |
| E2EValidationAgent | Playwright, GitNexus |
| Orchestrator | GitHub MCP, hook-driven vault logging |
| ArchitectureAgent | Context7-compatible live docs workflow |
| ContractFreezeAgent | Context7-compatible live docs workflow |

## 10.11 LLM Features in Use (Updated Every 30 Days)

This section documents every LLM provider feature the pipeline actively uses, why we chose it, and what we gain. It grows every 30 days as providers release new capabilities. See `memory/knowledge/feature-check-schedule.md` for the full review checklist.

**Last verified:** 2026-04-10 | **Next review:** 2026-05-10

### Verification Results (2026-04-10)

Every feature below was tested by running the actual CLI command or checking the actual npm package. Nothing is assumed.

| Item | Command Run | Result | Status |
|---|---|---|---|
| Claude CLI | `claude --version` | v2.1.96 | VERIFIED |
| Codex CLI | `codex --version` | v0.110.0 | VERIFIED |
| Gemini CLI | `gemini --version` | v0.28.2 | VERIFIED |
| Claude `--agent` flag | `claude --help` | `--agent`, `--agents`, `agents` subcommand present | VERIFIED |
| Claude hooks | `.claude/settings.json` | Graphify PreToolUse hook configured and working | VERIFIED |
| Claude MCP servers | `claude mcp list` | context7 connected, playwright connected, github needs token | VERIFIED |
| Codex `--ask-for-approval` | `codex --help` | `-a` flag with approval policy options | VERIFIED |
| Codex `--sandbox` | `codex --help` | `-s` flag for sandbox policy | VERIFIED |
| Gemini `--approval-mode` | `gemini --help` | `default`, `auto_edit`, `yolo`, `plan` modes | VERIFIED |
| Gemini `--yolo` | `gemini --help` | Auto-approve all actions flag | VERIFIED |
| Gemini skills system | `gemini --help` | `gemini skills` subcommand present | VERIFIED |
| Anthropic SDK | `require('@anthropic-ai/sdk')` | Loaded, messages.create available | VERIFIED |
| proper-lockfile | `require('proper-lockfile')` | Loaded | VERIFIED |
| TypeScript compilation | `npx tsc --noEmit` | 0 errors | VERIFIED |
| Semgrep SAST v1.159.0 | `semgrep --version` | Installed via pip | VERIFIED |
| Playwright (npm) | `require('playwright')` | Installed via npm | VERIFIED |
| Playwright (MCP) | `claude mcp list` | MCP plugin connected (separate from npm) | VERIFIED |
| Graphify v0.4.1 | `graphify install --platform claude` | Skill installed to Claude Code | VERIFIED |
| GitNexus v1.5.3 | `gitnexus analyze` | 1,045 nodes, 2,090 edges, 46 clusters, 64 flows | VERIFIED |
| ANTHROPIC_API_KEY | user env var set | Dual auth fallback enabled (new terminal sessions) | VERIFIED |
| GitHub PAT | `SetEnvironmentVariable` | Set as user env var (new terminal sessions) | VERIFIED |

**Action items remaining after verification:**
1. ~~Install semgrep~~ DONE (v1.159.0)
2. ~~Install playwright~~ DONE (npm package loaded)
3. ~~Install graphify~~ DONE (v0.4.1, skill installed to Claude Code)
4. ~~Install gitnexus~~ DONE (v1.5.3, indexed: 1,045 nodes, 2,090 edges, 46 clusters, 64 flows)
5. ~~Set ANTHROPIC_API_KEY~~ DONE (user env var, enables dual auth fallback)
6. ~~Set GITHUB_PERSONAL_ACCESS_TOKEN~~ DONE (user env var set)
7. Run `/graphify .` in a Claude Code session to generate the knowledge graph (interactive step)

All API keys set as persistent user environment variables (DEEPSEEK_API_KEY and MINIMAX_API_KEY also configured for emergency fallback).

### Dual Auth Architecture

The pipeline uses two auth modes for Claude, switching automatically:

| Mode | Auth Method | Cost | When Active |
|---|---|---|---|
| CLI (default) | OAuth via `claude auth login` | $0 (Max subscription) | Normal operation |
| SDK (auto-fallback) | `ANTHROPIC_API_KEY` env var | Pay-per-token | When CLI hits rate limit (auto-switches back after 5 min) |

Set `ANTHROPIC_API_KEY` in your environment as insurance. It costs nothing unless the CLI fails.

### Claude (Anthropic) — Features in Use

All features below verified by running `claude --version` (v2.1.96), `claude --help`, and `require('@anthropic-ai/sdk')` on 2026-04-10.

| Feature | Where Used | Why | Verified How | Since |
|---|---|---|---|---|
| Claude CLI v2.1.96 | All Claude calls | OAuth subscription, $0 marginal | `claude --version` | V6 |
| `--agent` flag | Agent routing | Load custom agent definitions at session start | `claude --help` shows `--agent`, `--agents` flags | V6 |
| `--agents` JSON flag | Inline agent definitions | Define agents without files for testing | `claude --help` shows flag | V6 |
| `agents` subcommand | List configured agents | Verify agent discovery | `claude --help` shows subcommand | V6 |
| Hooks (PreToolUse) | Graphify guidance | Inject knowledge graph context before file searches | `.claude/settings.json` has working hook | V6 |
| MCP: Context7 | Live library docs | .NET, React, Dapper docs during architecture and remediation | `claude mcp list` shows connected | V6 |
| MCP: Playwright | Browser testing | Headless Chromium via MCP protocol | `claude mcp list` shows connected | V6 |
| Anthropic SDK (tool_use) | Structured output fallback | JSON schema compliance via tool_use when GSD_LLM_MODE=sdk | `require('@anthropic-ai/sdk')` loads | V6 |
| Sonnet model for agents | All pipeline agents | Best speed/quality balance for execution | Vault agent notes specify model | V6 |

**Verified but not yet adopted (with specific reason):**

| Feature | Verified How | Why Not Adopted Yet | What Would Change |
|---|---|---|---|
| `--agent` custom agents | `claude --help` shows flag | Locks out Codex and Gemini — pipeline needs all 3 CLIs | Could replace TypeScript agent .ts files with .md definitions. But only Claude runs them. |
| `--bare` mode | `claude --help` shows flag | Skips hooks, LSP, plugins — loses Graphify/MCP integration | Useful for reproducible CI runs where hooks aren't needed. |

**Not yet verified (check at 2026-05-10):**

- Agent teams (does `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` work in v2.1.96?)
- Cloud scheduled tasks (need to test `claude.ai/code/scheduled`)
- Prompt caching for CLI OAuth mode (does CLI cache system prompts automatically?)
- Extended thinking via CLI (does `--model claude-opus-4-6` enable it?)
- Batch API (only available via SDK, not CLI — need API key to test)
- Opus 5 / Sonnet 5 model availability

### Codex / OpenAI — Features in Use

All features below verified by running `codex --version` (v0.110.0) and `codex --help` on 2026-04-10.

| Feature | Where Used | Why | Verified How | Since |
|---|---|---|---|---|
| Codex CLI v0.110.0 | All Codex calls | ChatGPT Max subscription, $0 marginal | `codex --version` | V6 |
| `-a` approval policy | Execute phase | Controls when human approval is needed | `codex --help` shows `--ask-for-approval` | V6 |
| `-s` sandbox mode | Execute phase | Controls shell command sandboxing | `codex --help` shows `--sandbox` | V6 |
| `-m` model selection | Model routing | Switch between GPT-4o, o1, o3 | `codex --help` shows `--model` | V6 |
| `apply` subcommand | Diff application | Apply generated diffs to working tree | `codex --help` shows `apply` | V6 |

**Verified but not yet adopted:**

| Feature | Verified How | Why Not Adopted Yet | What Would Change |
|---|---|---|---|
| o1/o3 via `-m o3` | `codex --help` shows model flag accepts any model string | Higher latency, uses more rolling window quota | Would improve complex refactoring. Need to benchmark latency. |
| Local LM Studio/Ollama | `codex --help` shows `model_provider=oss` flag | We use cloud subscription, not local models | Could enable offline code generation. |

**Not yet verified (check at 2026-05-10):**

- Codex sub-agent or multi-session capabilities (no flags found in --help)
- Codex structured JSON output mode (no flags found in --help)
- Codex hook or extension system (no flags found in --help)
- Rate limit changes for ChatGPT Max plan

### Gemini / Google — Features in Use

All features below verified by running `gemini --version` (v0.28.2) and `gemini --help` on 2026-04-10.

| Feature | Where Used | Why | Verified How | Since |
|---|---|---|---|---|
| Gemini CLI v0.28.2 | All Gemini calls | Ultra subscription, $0 marginal, cheapest of the three | `gemini --version` | V6 |
| `--approval-mode plan` | Research phase | Read-only mode prevents accidental writes | `gemini --help` shows 4 modes: default, auto_edit, yolo, plan | V6 |
| `--yolo` mode | Spec-fix phase | Auto-approve all actions for autonomous operation | `gemini --help` shows flag | V6 |
| `-p` headless mode | Pipeline calls | Non-interactive mode for scripted execution | `gemini --help` shows `--prompt` flag | V6 |
| `skills` subcommand | Extensibility | Manage agent skills within Gemini | `gemini --help` shows `gemini skills` | V6 |
| 1M context window | Research, large codebase analysis | Process entire repos without chunking | Gemini 2.5 Pro spec | V6 |

**Verified but not yet adopted:**

| Feature | Verified How | Why Not Adopted Yet | What Would Change |
|---|---|---|---|
| `--experimental-acp` | `gemini --help` shows flag | Experimental ACP mode — unknown behavior, undocumented | May enable agent-to-agent communication protocol. Need to test. |
| `--approval-mode auto_edit` | `gemini --help` shows mode | We use `plan` (read-only) for safety in research | Would auto-approve file edits, enabling Gemini to fix code directly. |
| `-i` interactive-with-prompt | `gemini --help` shows flag | We use `-p` (headless) for pipeline | Would allow hybrid: run a prompt then continue interactively for debugging. |

**Not yet verified (check at 2026-05-10):**

- Gemini grounding or web search capability (no flags found in --help)
- Gemini multimodal/vision via CLI (no flags found in --help)
- Gemini structured JSON output mode (no flags found in --help)
- Context window changes beyond 1M
- Rate limit changes for Ultra plan

### Emergency API Fallbacks — Features in Use

| Model | Feature | Why | Cost |
|---|---|---|---|
| DeepSeek | 60 RPM, $0.28/$0.42 per M tokens | Cheapest API fallback; highest RPM | Pay-per-token |
| MiniMax | 30 RPM, $0.29/$1.20 per M tokens | Backup to DeepSeek; good value | Pay-per-token |

### Feature Adoption Process (Verification-First)

NEVER adopt a feature based on assumptions, training data, or blog posts. Every feature must pass this 5-step gate before implementation. Full process is documented in `memory/knowledge/feature-check-schedule.md`.

1. **Discover** — Read the provider's official changelog. Search for the feature in official docs.
2. **Verify** — Run it locally on a throwaway project. Confirm it works on your OS, with your subscription tier. Document exact command and exact output.
3. **Evaluate** — Measure the actual benefit:
   - Does it replace custom code? How many lines saved?
   - Does it reduce cost? Run both paths, compare real costs.
   - Does it improve speed? Time both paths with same input.
   - Is it Claude-only? If yes, keep TypeScript harness for multi-LLM.
   - Is it stable? If experimental, add to "not yet confirmed" and revisit next cycle.
4. **Implement** — Branch, implement, test full pipeline, update Section 10.11 tables and change log.
5. **Monitor** — Check vault logs after 1 week and 30 days. Revert if benefit didn't materialize.

Features that haven't passed Step 2 go in the "Not yet confirmed" list. Features that passed Step 2 but not Step 3 go in "Confirmed but not adopted." Only features that passed all 5 steps appear in the "Features in Use" table.

### Installed Community Skills (107 Claude Code + 97 Agent Skills)

Installed 2026-04-11 via `npx skills add`. These extend agent capabilities beyond the core TypeScript harness.

**Token optimization:**

| Skill | Source | What it does | Install |
|---|---|---|---|
| caveman | JuliusBrussee/caveman | Cuts 65-75% output tokens via terse responses | `npx skills add JuliusBrussee/caveman` |
| caveman-commit | JuliusBrussee/caveman | Terse git commit messages | Included with caveman |
| caveman-review | JuliusBrussee/caveman | One-line code reviews | Included with caveman |

**Security (Trail of Bits + McGo + OWASP + Shannon):**

| Skill | What it does | GSD Agent |
|---|---|---|
| security-audit | Automated codebase security audit with OWASP/CWE classification | QualityGateAgent |
| semgrep | Semgrep SAST rule creation and variant analysis | QualityGateAgent |
| semgrep-rule-creator | Create custom Semgrep rules for project-specific patterns | QualityGateAgent |
| codeql | CodeQL query writing for deep static analysis | QualityGateAgent |
| owasp-security | OWASP Top 10:2025 + ASVS 5.0 patterns | CodeReviewAgent |
| shannon | White-box penetration testing (~96% exploit rate) | QualityGateAgent (pre-deploy) |
| supply-chain-risk-auditor | Dependency supply chain risk assessment | QualityGateAgent |
| zeroize-audit | Memory zeroization audit for secrets handling | QualityGateAgent |

**Infrastructure (HashiCorp):**

| Skill | What it does |
|---|---|
| new-terraform-provider | Terraform provider scaffolding |
| terraform-style-guide | Terraform code standards |
| terraform-test | Terraform test generation |
| terraform-stacks | Terraform stack management |

**Code quality:**

| Skill | What it does |
|---|---|
| differential-review | Review only changed code (reduces review scope) |
| spec-to-code-compliance | Verify code matches specifications |
| coverage-analysis | Test coverage analysis and gap identification |
| mutation-testing | Mutation testing to verify test quality |
| property-based-testing | Property-based test generation |
| refactor-module | Safe module refactoring with dependency tracking |

### 90-Day Platform Scan Results (2026-01 through 2026-04)

**Claude Code (Anthropic):**
- v2.0 terminal interface + VS Code native extension (shipped)
- Checkpoints with /rewind (shipped)
- Subagents, hooks, background tasks (shipped)
- Managed Agents API (public beta, April 2026) — hosted agent harness with sandboxing
- Advanced tool use beta: Tool Search, Programmatic Tool Calling
- Agent session duration: 99.9th percentile nearly doubled (25min to 45min) Oct 2025 to Jan 2026

**Codex CLI (OpenAI):**
- v0.110.0 with plugin system (March 2026) — skills + MCP in Codex now possible
- Desktop app for macOS (February 2026) — parallel agent threads
- TUI improvements: Ctrl+O copy, /resume by ID, async rate limit fetch
- Remote/cloud workflows: egress websocket, remote --cd, sandbox-aware filesystem

**Gemini CLI (Google):**
- v0.28.2 with skills system, hooks, /rewind (shipped)
- Gemini 3 Flash model available (better performance, lower cost than 2.5 Pro)
- Browser agent (experimental)
- Traffic prioritization by license tier (March 2026) — Pro models require paid subscription
- Code customization support in agent mode

### 30-Day Review: Skills Marketplace Scan

The 30-day review should now also scan these skill sources:

| Source | URL | What to check |
|---|---|---|
| Vercel Labs Skills | github.com/vercel-labs/skills | Official skill tool updates, new skills |
| Agent Skill Exchange | github.com/agentskillexchange/skills | 1,100+ security-scanned skills catalog |
| Trail of Bits | github.com/trailofbits/skills | Security research skills (already installed) |
| SecOpsAgentKit | github.com/AgentSecOps/SecOpsAgentKit | 25+ security operations skills |
| Anthropic official | github.com/anthropics/skills | Official Anthropic-published skills |
| Awesome Claude Skills | github.com/travisvn/awesome-claude-skills | Community curated list |

### Change Log

**2026-04-11 (V6 scan):** Installed 107 Claude Code skills + 97 agent skills from Trail of Bits, HashiCorp, McGo security audit, caveman token reduction. Completed 90-day platform scan covering Claude Code, Codex CLI, and Gemini CLI changelogs. Added skills marketplace to 30-day review checklist.

**2026-04-10 (V6):** Initial section. Documented all features in active use across 3 subscription CLIs + 2 API fallbacks. Created "watching" tables for features not yet adopted. Established 30-day review cadence.

# Chapter 11: Configuration, Operations, and Troubleshooting

## 11.1 Quality Gate Configuration

The binary thresholds live in [`memory/knowledge/quality-gates.md`](../memory/knowledge/quality-gates.md).

Key defaults:

- Line coverage: `>= 80%`
- Critical vulnerabilities: `0`
- High vulnerabilities: `0`
- E2E pass rate: `>= 95%`
- API contract compliance: `100%`

Changing thresholds is a vault edit. The guide should not be edited to tune a live project.

## 11.2 Deploy and Path Configuration

Deployment behavior is controlled by:

- [`memory/knowledge/deploy-config.md`](../memory/knowledge/deploy-config.md)
- [`memory/knowledge/rollback-procedures.md`](../memory/knowledge/rollback-procedures.md)

Design-document lookup for E2E and post-deploy validation is controlled by:

- [`memory/knowledge/project-paths.md`](../memory/knowledge/project-paths.md)

## 11.3 Preflight Failures You Will See First

| Failure | Meaning | Fix |
|---|---|---|
| Vault path missing | `memory/` or `memory/agents/` not found | Run from the repo root or supply `--vault-path` |
| `GSD_LLM_MODE` invalid | Value is not `cli` or `sdk` | Fix or unset the variable |
| SDK mode without API key | `GSD_LLM_MODE=sdk` but `ANTHROPIC_API_KEY` missing | Set the key or return to CLI mode |
| `claude` not found | Required primary CLI unavailable | Install/auth Claude Code |
| `codex` or `gemini` not found | Optional accelerators missing | Install them or continue with reduced routing flexibility |
| Semgrep warning | SAST engine unavailable | Install Semgrep or accept regex fallback |

## 11.4 Common SDLC and Pipeline Failures

| Symptom | Likely Cause | First Place to Look |
|---|---|---|
| `figma-uploaded` reports 0/12 | Design export missing or wrong path | `--design-path`, `_analysis/` directory |
| SCG1 fails | Contract gaps exist | `docs/spec/validation-report.md` |
| Pipeline stops at gate | Build, test, coverage, or security failure | Gate evidence in session state and `memory/sessions/` |
| E2E fails broadly | Backend/frontend not running or contracts wrong | Design paths, backend URL, frontend URL, contract files |
| Deploy rolls back | Health check or artifact copy failed | `memory/knowledge/deploy-config.md`, deploy record in `memory/sessions/` |
| Post-deploy auth fails | Broken live configuration or stale deployment | Post-deploy evidence plus live env logs |

## 11.5 Where to Look for Evidence

| Evidence Type | Location |
|---|---|
| Latest SDLC state | `memory/sessions/sdlc-state-latest.json` |
| Latest pipeline state | `memory/sessions/pipeline-state-latest.json` |
| Decision trail | `memory/decisions/` |
| Human-readable run summary | `memory/sessions/{date}-run-{runId}.md` |
| SCG1 readable gap report | `docs/spec/validation-report.md` |
| Generated SDLC artifacts | `docs/sdlc/` |
| Legacy implementation status context | `docs/GSD-V4-Implementation-Status.md` |

## 11.6 Word Export Workflow

The markdown file [`docs/GSD-Developer-Guide.md`](../docs/GSD-Developer-Guide.md) is the canonical source for the Word guide.

Generate the `.docx` with:

```bash
python docs/generate-docx.py
```

Output:

- `docs/GSD-Developer-Guide.docx`

When opening the generated document in Word:

1. Right-click the table of contents.
2. Choose **Update Field**.
3. Update the entire table.

## 11.7 Supplemental Runbooks

Use these documents when you need narrower operational detail than this guide includes:

- [`docs/GSD-Workstation-Setup.md`](../docs/GSD-Workstation-Setup.md)
- [`docs/GSD-Figma-Make-Integration.md`](../docs/GSD-Figma-Make-Integration.md)
- [`docs/GSD-V4-Implementation-Status.md`](../docs/GSD-V4-Implementation-Status.md)
- [`docs/GSD-Troubleshooting.md`](../docs/GSD-Troubleshooting.md)
- [`docs/GSD-Architecture.md`](../docs/GSD-Architecture.md)

# Chapter 12: Legacy Compatibility and Reference Positioning

## 12.1 What Still Exists from Earlier Generations

The repository still contains earlier PowerShell generations under `v2/`, `v3/`, `scripts/`, and several older documentation files. Those assets remain useful for:

- Historical context.
- Prompt lineage.
- Reference implementations of older convergence behaviors.
- Troubleshooting legacy projects that still run the PowerShell pipeline.

## 12.2 Canonical V6 Documentation Set

For the current V6 lifecycle system, the canonical references are:

- [`docs/GSD-Developer-Guide.md`](GSD-Developer-Guide.md) — Full narrative developer guide (this document).
- [`docs/GSD-Workstation-Setup.md`](GSD-Workstation-Setup.md) — Base toolchain setup.
- [`docs/workstation.md`](workstation.md) — Per-workstation Claude memory + hooks config.
- [`docs/GSD-Configuration.md`](GSD-Configuration.md) — Runtime configuration reference.
- [`docs/GSD-Claude-Code-Skills.md`](GSD-Claude-Code-Skills.md) — Installed skills reference.
- [`docs/GSD-Figma-Make-Integration.md`](GSD-Figma-Make-Integration.md) — Figma export workflow.
- [`memory/architecture/v6-design.md`](../memory/architecture/v6-design.md) — Canonical V6 architecture.
- [`memory/`](../memory/) — Live runtime configuration, SQLite state, session history, decisions.
- [`claude-memory/`](../claude-memory/) — Claude's durable knowledge vault (Obsidian, OneDrive-synced).

Pre-V6 documentation has been archived to [`docs/legacy/`](legacy/). Those files should not be used as references for the current system.

## 12.3 Practical Guidance for Future Updates

When updating the system:

1. Update `package.json` version first.
2. Update [`memory/architecture/v6-design.md`](../memory/architecture/v6-design.md) for architectural changes.
3. Update this guide next so the narrative source stays authoritative.
4. Update the narrower runbooks only after the main guide is accurate.
5. Regenerate `docs/GSD-Developer-Guide.docx` from markdown.
6. Prefer documenting implementation truth, even when a roadmap label is more ambitious than the current code.

That last rule matters most in V6 because the unified lifecycle surface is broad and inaccurate documentation becomes an operational risk.

---

# Chapter 13: V6 Implementation Tiers

V6 is the canonical architecture. The full design lives in [`memory/architecture/v6-design.md`](../memory/architecture/v6-design.md). This chapter summarizes the five tiers and their implementation order so contributors can locate where new work slots in.

## 13.1 Why V6

V6 was synthesized by comparing the prior pipeline against two external sources:

1. **gsd-build/gsd-2** — a general-purpose autonomous coding kernel with hierarchical decomposition, git worktree isolation, SQLite durable state, and execution graph scheduling
2. **OpenAI harness-engineering playbook** — repo-as-record, golden rules enforced mechanically, filesystem-as-memory, agent-legible environment, self-healing feedback loops

V6 adopts the strongest ideas from both while keeping the 14-agent SDLC Phase A-G roster intact.

## 13.2 Architectural Pillars

| Pillar | V6 Behavior |
|---|---|
| Task graph | Milestone → Slice → Task → Stage |
| Context model | Fresh session per task with explicit preamble |
| Filesystem | Git worktree per milestone (`.gsd-worktrees/M001/`) |
| State | Hybrid: SQLite (`memory/state.db`) + markdown narrative |
| Scheduler | Execution graph with parallel independent tasks |
| Commits | Turn-level git transaction per task |
| Memory | `claude-memory/` vault (Obsidian-backed) with retrieval hooks |

## 13.3 Five Implementation Tiers

V6 ships in five tiers. Each tier is independently deployable.

**Tier 1 — Execution Kernel**

- Hierarchical decomposition with `memory/milestones/M###-NAME/slices/S##-NAME/tasks/T##-*.md`
- Hybrid state model: SQLite durable store + markdown narrative
- Git worktree isolation per milestone
- Execution graph scheduler (blueprint, Semgrep, GitNexus run in parallel)
- Fresh agent session per task

**Tier 2 — Reliability and Supervision**

- Timeout hierarchy: soft (wrap up), idle (probe), hard (halt + forensic bundle)
- Stuck-loop detection via PatchSet hash comparison
- Auto-lock + session forensics on crash
- Turn-level git transactions with auto-rollback on failure

**Tier 3 — Cost, Routing, Verification**

- Budget-pressure model router (50/75/90% thresholds trigger progressive downgrade)
- Capability-aware routing (score agents per task metadata)
- Mechanical fix band between gate failure and RemediationAgent (lint, format, re-run)

**Tier 4 — Harness-Engineering Alignment**

- Golden rules as code (Semgrep and ESLint rules generated from CLAUDE.md conventions)
- AGENTS.md top-level map with progressive disclosure
- Tool-output compaction layer (raw persisted to disk, summary injected into context)
- Agent-queryable observability (Playwright/deploy/build logs as JSONL)
- Cross-review gate (second-pass reviewer on Gemini before deploy)
- Doc-gardening recurring agent
- Depth-first capability escalation (agents can halt and request new skills)

**Tier 5 — Developer Experience**

- Headless JSON state API (`gsd query`)
- Forensics bundle command (`gsd forensics --run <id>`)
- Knowledge harvest job (weekly pattern mining from decisions)
- Scout and Researcher subagents for context gathering

## 13.4 V6 Agent Roster (14 agents, unchanged across tiers)

- Orchestrator
- 6 SDLC agents (Requirements, Architecture, Figma, Reconcile, BlueprintFreeze, ContractFreeze)
- 7 Pipeline agents (BlueprintAnalysis, CodeReview, Remediation, QualityGate, E2E, Deploy, PostDeploy)

The agents themselves are not rewritten between tiers. Only the orchestrator and runtime services evolve.

## 13.5 What V6 Does NOT Do

- Does not adopt Claude Code agent teams (still experimental; deferred to next 30-day check)
- Does not replace the TypeScript harness with pure Claude Code native agents (multi-LLM routing is core value)
- Does not introduce a new LLM provider
- Does not alter the SDLC Phase A-G structure

## 13.6 Risks and Mitigations

| Risk | Mitigation |
|---|---|
| SQLite contention on concurrent writes | Use `better-sqlite3` (synchronous) with vault-adapter-style lock |
| Git worktrees unfamiliar to some devs | Document in developer guide; add `gsd worktree status` |
| Hierarchical decomp overhead for tiny changes | Skip Milestone/Slice for single-task runs; fall through to a single default slice |
| Compaction loses information agents need | Always persist raw to disk; agents can request by path |
| Cross-review gate adds latency | Runs on Gemini Ultra (15 RPM, $0 marginal, 1M context); deploy-bound changes only |
| Golden rules block edge cases | Each rule has `severity`; warnings don't block |

## 13.7 Canonical References

- Full design: [`memory/architecture/v6-design.md`](../memory/architecture/v6-design.md)
- Agent system design: [`memory/architecture/agent-system-design.md`](../memory/architecture/agent-system-design.md)
- State schema: [`memory/architecture/state-schema.md`](../memory/architecture/state-schema.md)
- gsd-build/gsd-2: <https://github.com/gsd-build/gsd-2>
- OpenAI harness engineering: <https://openai.com/index/harness-engineering/>

---

# Appendix A: Quick Command Reference

## Milestone Runs

| Task | Command |
|---|---|
| Start a new project | `gsd run requirements --project "X" --description "Y"` |
| Validate uploaded Figma deliverables | `gsd run figma-uploaded --design-path design/web/v1/src/` |
| Freeze contracts | `gsd run contracts` |
| Run the code pipeline | `gsd run blueprint` |
| Deploy to alpha | `gsd run deploy` |
| Run the full lifecycle | `gsd run full --project "X" --description "Y"` |
| Run against a different project root | `gsd run full --project-root /path/to/target-project` |
| Run in an isolated worktree with budget | `gsd run full --worktree --budget 25 --base-branch main` |
| Explicit SDLC resume | `gsd sdlc run --from-phase phase-d --project "X"` |
| Explicit pipeline resume | `gsd pipeline run --from-stage gate` |

## V6 State Inspection

| Task | Command |
|---|---|
| Status (milestones + legacy SDLC) | `gsd status` |
| List all milestones | `gsd query milestones` |
| Milestone detail | `gsd query milestone <milestoneId>` |
| Slice detail | `gsd query slice <sliceId>` |
| Task detail | `gsd query task <taskId>` |
| Cost rollup | `gsd query cost --since 2026-04-01` |
| Stuck-loop patterns | `gsd query stuck --min 2` |
| Decisions for a milestone | `gsd query decisions <milestoneId>` |
| Resolved project stack context (v6.1.0) | `gsd query stack --project-root /path` |

## V6 Maintenance

| Task | Command |
|---|---|
| Milestone worktree status | `gsd worktree status` |
| Prune stale worktree metadata | `gsd worktree prune` |
| Tear down milestone worktree | `gsd worktree teardown <milestoneId>` |
| Forensics bundle for a run | `gsd forensics --run <runId> --milestone <milestoneId> --out ./forensics` |
| Scan vault notes for drift | `gsd doc-garden --vault-path ./memory` |
| Mine decisions for patterns (weekly) | `gsd harvest --since-days 7` |
| V5 → V6 state migration (one-time) | `gsd migrate [--dry-run]` |
| **Stack-leak validator (v6.1.0)** | `gsd validate-stack --project-root /path [--json] [--fail-on-findings]` |

## Utilities

| Task | Command |
|---|---|
| Typecheck | `npm run typecheck` |
| Run V6 unit tests | `npm run test:v6` |
| Generate the Word guide | `python docs/generate-docx.py` |

# Appendix B: Artifact Inventory

## SDLC Phase Artifacts (generated per run in the target project)

| Artifact | Produced By | Why It Matters |
|---|---|---|
| `docs/sdlc/phase-a-intake-pack.json` | RequirementsAgent | Product and delivery baseline |
| `docs/sdlc/phase-b-architecture-pack.json` | ArchitectureAgent | Technical implementation baseline |
| `docs/sdlc/openapi-draft.yaml` | ArchitectureAgent | Early contract scaffold |
| `docs/sdlc/phase-ab-reconciliation-report.json` | PhaseReconcileAgent | Records what design feedback changed |
| `docs/sdlc/phase-d-frozen-blueprint.json` | BlueprintFreezeAgent | Immutable UI/UX implementation target |
| `docs/sdlc/phase-e-contract-artifacts.json` | ContractFreezeAgent | Structured SCG1 contract summary |
| `docs/spec/validation-report.md` | ContractFreezeAgent | Human-readable gap report |

## V6 Runtime State

| Artifact | Produced By | Why It Matters |
|---|---|---|
| `memory/state.db` | MilestoneOrchestrator (SQLite) | Durable milestone/slice/task state, rate-limit windows, stuck patterns — source of truth for `gsd query` |
| `memory/state.db.lock` | AutoLock | Crash-recovery lock file; stale-lock detection on next run |
| `memory/milestones/M{id}/ROADMAP.md` | MilestoneOrchestrator | Human-readable milestone narrative + slice list |
| `memory/milestones/M{id}/slices/S{nn}/PLAN.md` | Orchestrator | Slice narrative + task list |
| `memory/milestones/M{id}/slices/S{nn}/tasks/T{nn}-{stage}.md` | Agents | Per-task narrative + output |
| `.gsd-worktrees/M{id}/` | WorktreeManager | Per-milestone git worktree (gitignored) |

## V6 Observability (JSONL per category, per run)

| Artifact | Produced By | Why It Matters |
|---|---|---|
| `memory/observability/e2e-traces/{runId}.jsonl` | E2EValidationAgent | Flow-by-flow traces for post-mortem |
| `memory/observability/deploy-logs/{runId}.jsonl` | DeployAgent | Step-by-step deploy record |
| `memory/observability/gate-results/{runId}.jsonl` | QualityGateAgent, ReviewAuditor, stack-leak validator | Gate evidence + audit findings |
| `memory/observability/build-output/{runId}.jsonl` | BaseAgent (via CompactedExec) | Compacted bash/Semgrep/Playwright output |
| `memory/observability/router-decisions/{runId}.jsonl` | Orchestrator, BaseAgent, MilestoneOrchestrator | Budget/capability routing decisions |

## Legacy Session State

| Artifact | Produced By | Why It Matters |
|---|---|---|
| `memory/sessions/sdlc-state-latest.json` | SDLC orchestrator | Current SDLC resume state |
| `memory/sessions/pipeline-state-latest.json` | Pipeline orchestrator | Current pipeline resume state |
| `memory/sessions/{date}-run-{runId}.md` | Pipeline orchestrator | Human-readable run summary |
| `memory/decisions/*` | Orchestrators | Why the system routed and halted the way it did |

## Claude Memory Stack (Obsidian-backed, v6.0.0+)

| Artifact | Produced By | Why It Matters |
|---|---|---|
| `claude-memory/index.md` | Manual + hooks | Topic registry for the vault |
| `claude-memory/HEALTH.md` | health-check.sh hook | Live retrieval-quality metrics |
| `claude-memory/CHANGELOG.md` | Every vault mutation | Audit trail |
| `claude-memory/.retrieval-log.jsonl` | retrieve.sh hook | Topic-match retrieval events |
| `claude-memory/topics/*.md` | `/consolidate` command + manual | Durable human knowledge |
| `claude-memory/preferences.md` | preference-extract.sh hook | Always-loaded user preferences |

## Target-Project Inputs (v6.1.0+)

| Artifact | Provided By | Why It Matters |
|---|---|---|
| `<projectRoot>/docs/gsd/stack-overrides.md` | The target project (optional) | Declares per-project backend framework, SDK, solution format, frontend, mobile, compliance. Read by `getProjectStackContext()` at the start of every SDLC/Pipeline run. See [`docs/stack-overrides-template.md`](stack-overrides-template.md) for the template. |

*End of GSD V6 Developer Guide*
