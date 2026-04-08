# GSD Autonomous Dev — Claude Code Project Configuration

## What this project is

A multi-agent autonomous development pipeline that drives .NET 8 + React 18 + SQL Server projects from requirements extraction through code review, remediation, quality gates, and alpha deployment — without human intervention at each step. It wraps an existing PowerShell convergence engine (7 LLM agents) in a TypeScript harness with typed agent contracts, Obsidian vault memory, and coordinated orchestration.

## Agent System Overview

Eight agents coordinated by an Orchestrator that routes work through a 7-stage dependency graph: BlueprintAnalysisAgent detects drift, CodeReviewAgent validates, RemediationAgent fixes, QualityGateAgent gates, E2EValidationAgent tests against Figma storyboards, DeployAgent deploys with rollback, PostDeployValidationAgent validates the live environment. All system prompts live in `memory/agents/` vault notes, all configs in `memory/knowledge/`, all decisions logged to `memory/decisions/`.

## Agent Roster

| Agent | File | Vault Note | Job |
|---|---|---|---|
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
  knowledge/        - Pipeline configs, quality gates, deploy targets, rollback procedures
  architecture/     - System design docs, state schema, hook registry
  sessions/         - Append-only run logs (auto-created per run)
  decisions/        - Orchestrator decision records with rationale
  evals/            - Test cases and results
```

## How to Start a Pipeline Run

```bash
npx ts-node src/index.ts pipeline run --trigger manual
```

## How to Resume a Failed Run

```bash
npx ts-node src/index.ts pipeline run --from-stage gate
```

## How to Run Evals

```bash
npx ts-node src/evals/runner.ts
```

## How to Run in Dry-Run Mode (No Deploy)

```bash
npx ts-node src/index.ts pipeline run --trigger manual --dry-run
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
