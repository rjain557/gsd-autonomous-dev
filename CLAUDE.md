# GSD Autonomous Dev — Claude Code Project Configuration

## What this project is

A multi-agent autonomous development system (V5.0 in production; V6 designed) that drives .NET 8 + React 18 + SQL Server projects from requirements extraction through architecture, Figma validation, contract freeze, code review, remediation, quality gates, and alpha deployment. Uses a TypeScript harness with typed agent contracts, Obsidian vault memory, dual-auth LLM routing (CLI OAuth primary at $0, API key backup when limits hit), and a workstation augmentation stack built around Graphify, GitNexus, Context7, Semgrep, Playwright, GitHub MCP, OWASP, and Shannon. V6 (designed in `memory/architecture/v6-design.md`) adds hierarchical decomposition (Milestone → Slice → Task), git worktree isolation, SQLite durable state, and harness-engineering alignment from the OpenAI playbook.

## Agent System Overview

Fourteen typed agents coordinated through a unified CLI and two orchestration layers:

- SDLC agents for Phases A-E: requirements, architecture, Figma validation, reconcile, blueprint freeze, and contract freeze.
- Pipeline agents for Phases F-G: blueprint analysis, review, remediation, quality gates, E2E, deploy, and post-deploy validation.

All system prompts live in `memory/agents/` vault notes, runtime configuration lives in `memory/knowledge/`, architecture/state contracts live in `memory/architecture/`, and decisions are logged to `memory/decisions/`.

## Agent Roster

| Agent | File | Vault Note | Job |
|---|---|---|---|
| RequirementsAgent | `src/agents/requirements-agent.ts` | `memory/agents/requirements-agent.md` | Draft Intake Pack from project description |
| ArchitectureAgent | `src/agents/architecture-agent.ts` | `memory/agents/architecture-agent.md` | Generate diagrams, OpenAPI draft, and threat model |
| FigmaIntegrationAgent | `src/agents/figma-integration-agent.ts` | `memory/agents/figma-integration-agent.md` | Validate 12/12 Figma Make deliverables |
| PhaseReconcileAgent | `src/agents/phase-reconcile-agent.ts` | `memory/agents/phase-reconcile-agent.md` | Reconcile requirements after prototyping |
| BlueprintFreezeAgent | `src/agents/blueprint-freeze-agent.ts` | `memory/agents/blueprint-freeze-agent.md` | Freeze implementation blueprint for Phase F |
| ContractFreezeAgent | `src/agents/contract-freeze-agent.ts` | `memory/agents/contract-freeze-agent.md` | Generate SCG1 contracts and validation report |
| Orchestrator | `src/harness/orchestrator.ts` | `memory/agents/orchestrator.md` | Route work, decide retry/escalate/halt |
| BlueprintAnalysisAgent | `src/agents/blueprint-analysis-agent.ts` | `memory/agents/blueprint-analysis-agent.md` | Read specs, detect drift |
| CodeReviewAgent | `src/agents/code-review-agent.ts` | `memory/agents/code-review-agent.md` | Review code, check quality |
| RemediationAgent | `src/agents/remediation-agent.ts` | `memory/agents/remediation-agent.md` | Fix failed issues |
| QualityGateAgent | `src/agents/quality-gate-agent.ts` | `memory/agents/quality-gate-agent.md` | Run tests + npm audit + dotnet vuln check |
| E2EValidationAgent | `src/agents/e2e-validation-agent.ts` | `memory/agents/e2e-validation-agent.md` | Test API contracts, SPs, mock data, auth |
| DeployAgent | `src/agents/deploy-agent.ts` | `memory/agents/deploy-agent.md` | Deploy with rollback |
| PostDeployValidationAgent | `src/agents/post-deploy-validation-agent.ts` | `memory/agents/post-deploy-validation-agent.md` | Validate live env: SPA cache, DI, no 500s |

## Vault Memory Structure

```
memory/
  agents/           - Agent system prompts and configs (frontmatter + body)
  knowledge/        - Pipeline configs, quality gates, deploy targets, rollback procedures, project paths
  architecture/     - System design docs, state schema, hook registry
  sessions/         - Append-only run logs (auto-created per run)
  decisions/        - Orchestrator decision records with rationale
  evals/            - Test cases and results
```

## How to Start a Pipeline Run

```bash
npx ts-node src/index.ts run requirements --project "MyApp" --description "Multi-tenant SaaS"
```

## How to Resume a Failed Run

```bash
npx ts-node src/index.ts sdlc run --from-phase contracts
npx ts-node src/index.ts pipeline run --from-stage gate
```

## How to Run Evals

```bash
npx ts-node src/evals/runner.ts
```

## How to Run in Dry-Run Mode (No Deploy)

```bash
npx ts-node src/index.ts run full --dry-run
```

## Memory Rules — ALWAYS Follow These

1. Read the relevant `memory/agents/*.md` note before modifying any agent
2. All agent system prompts live in the vault — edit there, not in code
3. Every session must append a summary to `memory/sessions/`
4. Never hardcode thresholds, configs, or deploy targets in code — they live in `memory/knowledge/`
5. Before adding a new agent: design its vault note first, then build the class
6. The task graph lives in `memory/architecture/agent-system-design.md` — update it there when the pipeline changes
7. The orchestrator must log a Decision for every routing choice it makes
8. DeployAgent MUST NOT execute unless GateResult.passed === true (runtime assertion)
9. Rollback logic must exist before deploy logic — never implement deploy without rollback
10. All vault log writes use append() — never overwrite session/decision files
11. Set ANTHROPIC_API_KEY in environment as backup — costs $0 unless CLI OAuth hits limits, then auto-switches
12. Check `memory/knowledge/feature-check-schedule.md` every 30 days for new Claude/Codex/Gemini features

## Current Pipeline Stage Map

| Step | Agent | Depends On | On Success | On Failure |
|---|---|---|---|---|
| 1 | BlueprintAnalysisAgent | (trigger) | Step 2 | Retry 3x then HALT |
| 2 | CodeReviewAgent | Step 1 | If passed: Step 4; If failed: Step 3 | Retry 3x then HALT |
| 3 | RemediationAgent | Step 2 (failed) | Step 4 | Retry 2x then HALT |
| 4 | QualityGateAgent | Step 2 or 3 | If passed: Step 5; If failed: Step 3 (loop, max 3) | Retry 2x then HALT |
| 5 | E2EValidationAgent | Step 4 | If passed: Step 6; If failed: Step 3 | Retry 2x then HALT |
| 6 | DeployAgent | Step 5 (passed=true ONLY) | Step 7 | Rollback then HALT |
| 7 | PostDeployValidationAgent | Step 6 | COMPLETE | Log failures, recommend rollback |

## Known Failure Modes

| Failure | Agent | Handling |
|---|---|---|
| Quota exhaustion | Any LLM agent | Pipeline pauses, resume with --from-stage |
| Spec conflicts | BlueprintAnalysisAgent | Reports high risk, orchestrator decides |
| Build failures | QualityGateAgent | Fails gate, routes to remediation loop |
| Deploy target unreachable | DeployAgent | Immediate rollback |
| Blocked file writes (D-05) | RemediationAgent | Skip after 1 retry per file |

## Legacy Engine Role

Claude Code also handles 3 phases of the legacy PowerShell convergence loop:
1. **code-review** — Score repo health, update requirement statuses
2. **create-phases** — Extract requirements from specs + Figma (one-time)
3. **plan** — Prioritize next batch, write generation instructions

Legacy write paths: `.gsd/health/`, `.gsd/code-review/`, `.gsd/generation-queue/`, `.gsd/agent-handoff/current-assignment.md`

**Note:** `config/agent-map.json` and `config/global-config.json` are PowerShell-legacy only. The TypeScript harness (v4.2) reads runtime configuration from `memory/knowledge/` and `memory/agents/` vault notes.

---

## Installed Skills

### `/sql-expert` — MS SQL Server Schema & T-SQL
**Activate when:** "design a table/schema", "write a stored procedure", "normalize this",
"write a CTE", "use window functions", "model this relationship", "generate a migration script"

Skill path: `.claude/skills/sql-expert/SKILL.md`

### `/sql-performance-optimizer` — Query Performance & Indexes
**Activate when:** "this query is slow", "analyze execution plan", "what indexes do I need",
"fix N+1", "optimize this SP", "why is CPU/IO high"

Skill path: `.claude/skills/sql-performance-optimizer/SKILL.md`

### `/react-ui-design-patterns` — Async States, Skeletons, Errors, Empty States
**Activate when:** building a screen that fetches data, "add a loading state", "handle errors gracefully",
"show empty state", "optimistic update", "add error boundary", reviewing a component for missing states

Skill path: `.claude/skills/react-ui-design-patterns/SKILL.md`

### `/composition-patterns` — React Component Architecture
**Activate when:** refactoring a component with many boolean props, building reusable component libraries,
designing flexible APIs, working with compound components or context providers

Skill path: `.claude/skills/composition-patterns/SKILL.md`

### `/web-design-guidelines` — UI Accessibility & Design Audit
**Activate when:** "review my UI", "check accessibility", "audit design", "review UX",
"check my site against best practices"

Skill path: `.claude/skills/web-design-guidelines/SKILL.md`

Full skills reference: `docs/GSD-Claude-Code-Skills.md`

### Security and Repo Wiring

- OWASP Security reference skill: `.agents/skills/owasp-security/SKILL.md`
- Shannon reference skill: `.agents/skills/shannon/SKILL.md`
- Some workstations mirror those security skills into `.claude/skills/` through local symlinks, but the repository source of truth is `.agents/skills/`
- Graphify `PreToolUse` guidance and GitHub MCP config live in `.claude/settings.json`

---

## Project Patterns (enforced for all generated projects)

- **Backend**: .NET 8 + Dapper + SQL Server stored procedures only (no EF Core, no inline SQL)
- **Frontend**: React 18 + TypeScript + Fluent UI React v9 + React Query v5
- **Auth**: JWT, role-based, with DB-driven module-level navigation guards (SEC-FE-17–21)
- **Compliance**: HIPAA, SOC 2, PCI, GDPR

---

## MS SQL Server — T-SQL Conventions

### Naming
| Object | Convention | Example |
|---|---|---|
| Tables | PascalCase plural | `dbo.Orders`, `dbo.NavigationModules` |
| Columns | PascalCase | `CreatedAt`, `TenantId`, `IsActive` |
| PKs | `Id` (INT IDENTITY or NVARCHAR GUID) | `Id INT IDENTITY(1,1)` |
| FKs | `{TableName}Id` | `TenantId`, `UserId` |
| Indexes | `IX_{Table}_{Columns}` | `IX_Orders_TenantId_Status` |
| SPs | `usp_{Entity}_{Action}` | `usp_Order_Create`, `usp_Order_ListByTenant` |
| Constraints | `UQ_`, `CK_`, `FK_`, `DF_` prefixes | `UQ_Users_Email` |

### Mandatory Audit Columns (every table)
```sql
CreatedAt   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
CreatedBy   NVARCHAR(100) NOT NULL,
UpdatedAt   DATETIME2 NULL,
UpdatedBy   NVARCHAR(100) NULL,
IsDeleted   BIT NOT NULL DEFAULT 0  -- soft delete
```

### Multi-Tenant Isolation
All data tables include `TenantId NVARCHAR(50) NOT NULL`. Every query filters:
```sql
WHERE TenantId = @TenantId AND IsDeleted = 0
```

### SP Rules
- `SET NOCOUNT ON` at top
- `BEGIN TRY / END TRY BEGIN CATCH THROW END CATCH` always
- All parameters explicitly typed with length (`NVARCHAR(100)` not `NVARCHAR(MAX)`)
- No implicit conversions — parameter type must match column type exactly
- No `SELECT *` — explicit column list only
- `GRANT EXECUTE ON dbo.usp_... TO [AppRole];` after every SP

---

## Fluent UI React v9 — Conventions

### Import Pattern
Always import from the single entry point:
```tsx
import {
  Button, Text, Spinner, Skeleton, SkeletonItem,
  MessageBar, MessageBarBody, MessageBarActions,
  FluentProvider, webLightTheme,
  makeStyles, tokens,
} from '@fluentui/react-components';
```

### Theming via FluentProvider
Wrap the entire app once at the root:
```tsx
<FluentProvider theme={webLightTheme}>
  <App />
</FluentProvider>
```

### Token Usage
```tsx
const useStyles = makeStyles({
  container: {
    backgroundColor: tokens.colorNeutralBackground1,
    color: tokens.colorNeutralForeground1,
    padding: tokens.spacingVerticalM,
    borderRadius: tokens.borderRadiusMedium,
  },
});
```

### No Boolean Prop Proliferation
```tsx
// Bad
<Button primary disabled loading iconLeft={<Spinner />} />

// Good
<Button appearance="primary" disabled icon={<Spinner />}>Save</Button>
```

### WAI-ARIA (mandatory)
- All interactive elements have `aria-label` or visible `<Label>` from Fluent
- Dialog/Drawer: `aria-labelledby` pointing to the title element
- Toast errors: `role="alert"`; informational toasts: `role="status"`
- No `tabIndex > 0`

### Five States Rule (every data-driven component)
1. **Loading** → `<Skeleton>` matching final layout shape
2. **Error** → `<MessageBar intent="error">` with retry button
3. **Empty** → centered empty state with title + description + CTA
4. **Populated** → normal render
5. **Optimistic** → disabled UI + React Query `onMutate` local cache update

---

## GSD Output Discipline

- Keep ALL phase outputs under 5000 tokens
- Use tables and bullets, never prose paragraphs
- Drift reports: max 50 lines
- Review findings: max 100 lines
- Plan output: queue JSON + assignment doc only

## LLM API Quick Reference

See `C:\Users\rjain\.claude\CLAUDE.md` for full model endpoint reference (Anthropic, OpenAI, DeepSeek, Kimi, MiniMax, GLM5).

## Quality, Security, and Automation Tools

- **Semgrep** (`pip install semgrep`): SAST scanner with 2000+ rules. QualityGateAgent runs it automatically. Preflight warns if missing.
- **Playwright** (`npm install playwright`): Headless Chromium browser testing. E2EValidationAgent uses it for real page rendering, JS console error detection. Falls back to HTTP if not installed.
- **Context7** (`claude mcp add context7 -- npx -y @upstash/context7-mcp@latest`): Live library documentation MCP used during architecture, contract freeze, and remediation.
- **GitHub MCP** (`@modelcontextprotocol/server-github`): Configured in `.claude/settings.json`. Provides PR creation, issue tracking, review comments. Supply `GITHUB_PERSONAL_ACCESS_TOKEN` through the environment rather than editing the committed file.
- **OWASP Security Skill** (`npx -y skills add agamm/claude-code-owasp -y`): Security review guidance rooted in OWASP Top 10:2025, ASVS 5.0, and agentic AI controls. Repository reference path: `.agents/skills/owasp-security/SKILL.md`.
- **Shannon Lite** (`npx -y skills add unicodeveloper/shannon -y`): Docker-based white-box pentesting for explicit release-readiness or audit work. Repository reference path: `.agents/skills/shannon/SKILL.md`.

## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `python3 -c "from graphify.watch import _rebuild_code; from pathlib import Path; _rebuild_code(Path('.'))"` to keep the graph current

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **gsd-autonomous-dev** (1084 symbols, 2133 relationships, 68 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## When Debugging

1. `gitnexus_query({query: "<error or symptom>"})` — find execution flows related to the issue
2. `gitnexus_context({name: "<suspect function>"})` — see all callers, callees, and process participation
3. `READ gitnexus://repo/gsd-autonomous-dev/process/{processName}` — trace the full execution flow step by step
4. For regressions: `gitnexus_detect_changes({scope: "compare", base_ref: "main"})` — see what your branch changed

## When Refactoring

- **Renaming**: MUST use `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` first. Review the preview — graph edits are safe, text_search edits need manual review. Then run with `dry_run: false`.
- **Extracting/Splitting**: MUST run `gitnexus_context({name: "target"})` to see all incoming/outgoing refs, then `gitnexus_impact({target: "target", direction: "upstream"})` to find all external callers before moving code.
- After any refactor: run `gitnexus_detect_changes({scope: "all"})` to verify only expected files changed.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Tools Quick Reference

| Tool | When to use | Command |
|------|-------------|---------|
| `query` | Find code by concept | `gitnexus_query({query: "auth validation"})` |
| `context` | 360-degree view of one symbol | `gitnexus_context({name: "validateUser"})` |
| `impact` | Blast radius before editing | `gitnexus_impact({target: "X", direction: "upstream"})` |
| `detect_changes` | Pre-commit scope check | `gitnexus_detect_changes({scope: "staged"})` |
| `rename` | Safe multi-file rename | `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` |
| `cypher` | Custom graph queries | `gitnexus_cypher({query: "MATCH ..."})` |

## Impact Risk Levels

| Depth | Meaning | Action |
|-------|---------|--------|
| d=1 | WILL BREAK — direct callers/importers | MUST update these |
| d=2 | LIKELY AFFECTED — indirect deps | Should test |
| d=3 | MAY NEED TESTING — transitive | Test if critical path |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/gsd-autonomous-dev/context` | Codebase overview, check index freshness |
| `gitnexus://repo/gsd-autonomous-dev/clusters` | All functional areas |
| `gitnexus://repo/gsd-autonomous-dev/processes` | All execution flows |
| `gitnexus://repo/gsd-autonomous-dev/process/{name}` | Step-by-step execution trace |

## Self-Check Before Finishing

Before completing any code modification task, verify:
1. `gitnexus_impact` was run for all modified symbols
2. No HIGH/CRITICAL risk warnings were ignored
3. `gitnexus_detect_changes()` confirms changes match expected scope
4. All d=1 (WILL BREAK) dependents were updated

## Keeping the Index Fresh

After committing code changes, the GitNexus index becomes stale. Re-run analyze to update it:

```bash
npx gitnexus analyze
```

If the index previously included embeddings, preserve them by adding `--embeddings`:

```bash
npx gitnexus analyze --embeddings
```

To check whether embeddings exist, inspect `.gitnexus/meta.json` — the `stats.embeddings` field shows the count (0 means no embeddings). **Running analyze without `--embeddings` will delete any previously generated embeddings.**

> Claude Code users: A PostToolUse hook handles this automatically after `git commit` and `git merge`.

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
