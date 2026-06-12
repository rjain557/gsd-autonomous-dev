# GSD V6 Autonomous Dev — Claude Code Project Configuration

## What this project is

A V6 multi-agent autonomous development system that drives .NET (configurable, **default .NET 10 LTS** as of 2026-06-11 — .NET 8 and 9 both reach end-of-support 2026-11-10) + React 18 + SQL Server projects from requirements extraction through architecture, Figma validation, contract freeze, code review, remediation, quality gates, and alpha deployment. Canonical architecture is documented in `memory/architecture/v6-design.md` and `docs/GSD-Developer-Guide.md`. Projects can still pin `net8.0`/`net9.0` in `docs/gsd/stack-overrides.md` for legacy/compat work (see GSD Developer Guide §1.4.1).

V6 combines a TypeScript harness with typed agent contracts, hierarchical decomposition (Milestone → Slice → Task → Stage), hybrid SQLite + vault memory, git worktree isolation per milestone, an execution graph scheduler, dual-auth LLM routing (CLI OAuth primary at $0, API key backup when limits hit), and a workstation augmentation stack built around Graphify, GitNexus, Context7, Semgrep, Playwright, GitHub MCP, OWASP, and Shannon.

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
| SecurityAgent (v6.2) | `src/agents/security-agent.ts` | `memory/agents/security-agent.md` | Security-engineer-of-record. BINDING signoff on security-critical paths. Semgrep + CodeQL + SCA + license deny-list. Threat-model deltas. |
| ComplianceAgent (v6.2) | `src/agents/compliance-agent.ts` | `memory/agents/compliance-agent.md` | All-16-framework mapping (CMMC/FedRAMP/HIPAA/PCI/SOC2/...). Evidence packs + management assertion drafts + gap analysis. |
| LegalAgent (v6.2) | `src/agents/legal-agent.ts` | `memory/agents/legal-agent.md` | Drafts MSA/BAA/EULA/privacy/consent/breach-notification documents. UPL boundary enforced. Reads `D:/VSCode/tech-legal/`. |
| PMAgent (v6.2) | `src/agents/pm-agent.ts` | `memory/agents/pm-agent.md` | Vendor relationship tracking + renewal calendar + milestone progress + weekly RJain action items. |
| IssueTriageAgent (v6.3) | `src/agents/issue-triage-agent.ts` | `memory/agents/issue-triage-agent.md` | Phase U1: classify client issue → reproduce (hard gate) → localize fault (file→symbol→line) → blast radius. |
| UpdateSpecAgent (v6.3) | `src/agents/update-spec-agent.ts` | `memory/agents/update-spec-agent.md` | Phase U2: TriageResult → frozen change spec (delta specs + EARS criteria + tasks + test plan) → feeds pipeline F1. |

## v6.2 Domain Agents — Hard-5% Coverage

These four agents replace human-hire roles identified in myJian
platform-coverage decision §10.15. AI does the drafting/analysis; RJain
(or named officer) is the human-of-record only where statute or contract
requires a human signatory (compliance attestations, contract execution,
Apple MDM verification calls, breach escalations to client GCs).

See: `memory/agents/{security,compliance,legal,pm}-agent.md` for full
contracts, and `memory/knowledge/{security-policy,security-critical-paths,
threat-model,edge-telemetry-catalog,control-mapping-policy,jurisdiction-matrix,
upl-boundaries,legal-policy,vendor-relationships,renewal-calendar,
milestone-catalog,calendar-time-tracks}.md` for the supporting knowledge files.

## Vault Memory Structure (V6)

```
memory/
  agents/           - Agent system prompts and configs (frontmatter + body)
  knowledge/        - Pipeline configs, quality gates, deploy targets, rollback procedures, project paths
    rules/          - Golden-rules-as-code (Semgrep/ESLint YAML)
  architecture/     - v6-design.md (canonical), agent-system-design, state schema, hook registry
  milestones/       - V6 hierarchical runtime: M{nnn}/ROADMAP.md, slices/, tasks/
  observability/    - Structured logs: e2e-traces/, deploy-logs/, gate-results/, build-output/
  sessions/         - Append-only run logs (auto-created per run)
  decisions/        - Orchestrator decision records with rationale
  evals/            - Test cases and results
  state.db          - V6 SQLite durable state (milestones, slices, tasks, decisions)
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

**Maintenance flow (v6.3, Phase U — existing apps):** `gsd run maintenance --issue "<client issue>"`
prepends U1 IssueTriageAgent → U2 UpdateSpecAgent before Step 1; both auto-skip on greenfield runs.
Not-actionable triage or high-risk specs PAUSE for human input. See `docs/GSD-Maintenance-Flow.md`.

| Step | Agent | Depends On | On Success | On Failure |
|---|---|---|---|---|
| U1 | IssueTriageAgent (maintenance only) | --issue trigger | U2 | Not actionable → PAUSE + clarifying questions |
| U2 | UpdateSpecAgent (maintenance only) | U1 valid | Step 1 (change spec frozen) | Needs approval → PAUSE; resume --from-stage blueprint |
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

**Note:** `config/agent-map.json` and `config/global-config.json` are PowerShell-legacy only. The V6 TypeScript harness reads runtime configuration from `memory/knowledge/` and `memory/agents/` vault notes.

---

## Installed Skills

### `/fluent-v9-mastery` — Fluent UI React v9 Design & Implementation Discipline
**Activate when:** any frontend work, React components, Fluent UI, UI/UX design, screen implementation,
form building, or any visual polish pass on generated projects. Output must feel like it was built by a
senior product designer + senior frontend engineer at Microsoft — not an AI-generated admin panel.

Skill path: `.claude/skills/fluent-v9-mastery/SKILL.md`

Covers token system, Griffel styling, theming, layout, component selection, forms (React Hook Form + Zod
+ TanStack Query), the four-states rule, accessibility, polish details, code quality standards, forbidden
anti-patterns, and a pre/post-coding checklist. Layers on top of the narrower React skills below rather
than replacing them — activates first on any frontend request.

### `/fluent-v9-design-review` + `/design-review` — Fluent UI React v9 Design Review
**Activate when:** "review this", "audit", "design review", "check the code", end of a Phase D feature
implementation, or explicit `/design-review <scope>` invocation.

Skill path: `.claude/skills/fluent-v9-design-review/SKILL.md`
Slash command: `.claude/commands/design-review.md`

Companion to `/fluent-v9-mastery` — the mastery skill shapes generation, the review skill enforces it.
Runs 15 review categories against the mastery guide and emits a severity-classified report (🔴 Blocker /
🟠 Critical / 🟡 Major / 🔵 Minor / ⚪ Nit) with an 8-dimension quality scorecard (overall score /80).
When the user says "apply fixes", auto-fixes all Blockers + Criticals, re-runs typecheck and lint, and
reports what remains. Cites mastery-guide part numbers for teaching-while-reviewing.

### `/react-native-mastery` — React Native + Expo Mobile Design & Implementation Discipline
**Activate when:** any mobile app work, React Native components, screens, navigation, or any mobile
frontend implementation. Output must feel native on both iOS and Android — not like a web page in a
WebView, not like a cross-platform app that betrays its cross-platform nature.

Skill path: `.claude/skills/react-native-mastery/SKILL.md`

Mobile counterpart to `/fluent-v9-mastery`. Covers the unify-vs-diverge rule, design tokens, safe areas,
React Navigation patterns (Native Stack, Tabs, Drawer), the core 18-component library, FlashList
performance, forms with autofill + return-key chains, the five-states rule (loading / empty / error /
success / **offline**), motion + haptics with Reanimated v3 + expo-haptics, accessibility (VoiceOver,
TalkBack, Dynamic Type), platform-specific polish (iOS large titles, Android edge-to-edge), and the
forbidden anti-patterns list. Same Swagger backend and feature folder structure as web for symmetry.

### `/react-native-design-review` + `/mobile-design-review` — React Native Mobile Design Review
**Activate when:** "review this", "audit", "design review", "check the code", end of a mobile feature
implementation, or explicit `/mobile-design-review <scope>` invocation on mobile code.

Skill path: `.claude/skills/react-native-design-review/SKILL.md`
Slash command: `.claude/commands/mobile-design-review.md`

Companion to `/react-native-mastery` — the mastery skill shapes generation, the review skill enforces it.
Runs 17 review categories against the mobile mastery guide and emits a severity-classified report plus a
unique **Platform Parity Check** table (iOS vs Android per concern) with a 10-dimension quality scorecard
(overall score /100). When the user says "apply fixes", auto-fixes all Blockers + Criticals, re-runs
typecheck and lint, and offers to re-run on the other platform's simulator if platform-specific fixes
were made.

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

- **Backend**: .NET (configurable per project via `docs/gsd/stack-overrides.md`; **default .NET 10 LTS**) + Dapper + SQL Server stored procedures only (no EF Core, no inline SQL). On .NET 9+ use built-in OpenAPI (`Microsoft.AspNetCore.OpenApi`), not Swashbuckle.
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
- All parameters explicitly typed with length (`NVARCHAR(100)` not `NVARCHAR(MAX)`). **SQL Server 2025:** for JSON payloads use the native `JSON` type instead of `NVARCHAR(MAX)`; `REGEXP_*` for in-DB validation; `VECTOR` + `AI_GENERATE_EMBEDDINGS` are GA. See `docs/GSD-Frontend-Stack-2026.md` §3.
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

Model endpoints, pricing, and routing live in two places (this machine = `Administrator`):
- **Credentials**: the key vault — `C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\VSCODE\keys\`
  (`anthropic.md`, `openai.md`, `azure-openai.md`, `deepseek.md`, `gemini.md`, `kimi-moonshot.md`,
  `minimax.md`, `glm-zhipu.md`, `nvidia-build.md`, `litellm*.md`). Never print or commit values.
- **Live model catalog / pricing** (re-verified weekly): the Cortex vault topics `model_catalog`
  and `litellm_gateway` (see Knowledge Sources above) + repo `config/model-registry.json`.

**Routing (full-gateway, 2026-06-11):** every LLM call routes through the LiteLLM gateway
(pay-per-token) so spend is tracked per project. Env: `LITELLM_BASE_URL`
(`http://10.100.254.102:4000`), `LITELLM_VIRTUAL_KEY` (`sk-tj-gsd-autonomouse-dev`, from key vault —
never hardcode), `GSD_LLM_MODE` (`gateway`|`sdk`|`cli`), `GSD_PROJECT`. Per-task model picks +
Fable 5 guidance: `docs/GSD-Model-Cost-Optimization.md`. Drift check: `npm run model-sync`. Canonical
wiring: `memory/knowledge/litellm-gateway.md`.

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

This project is indexed by GitNexus as **gsd-autonomous-dev** (2820 symbols, 5266 relationships, 221 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/gsd-autonomous-dev/context` | Codebase overview, check index freshness |
| `gitnexus://repo/gsd-autonomous-dev/clusters` | All functional areas |
| `gitnexus://repo/gsd-autonomous-dev/processes` | All execution flows |
| `gitnexus://repo/gsd-autonomous-dev/process/{name}` | Step-by-step execution trace |

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


---

## Knowledge Sources & Vault Locations — READ THIS EVERY SESSION

> **Active workstation: `Administrator` (TE-AI fleet host).** Paths below are absolute for
> this machine. The repo's git author is `Ravi Jain`; older `C:\Users\rjain\...` paths that
> appear elsewhere in this file are stale carry-overs from a laptop — on this machine use the
> `Administrator` paths registered here. Full machine-readable registry:
> `memory/knowledge/knowledge-sources.md` (canonical — edit there, not in code).

Three external knowledge stores back this project. Consult them in this order of authority for
their respective domains; never hardcode their contents into code.

### 1. GSD project vault (Obsidian) — durable engineering knowledge
`C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\obsidian\gsd-autonomous-dev\gsd-autonomous-dev\`
(note the doubled folder name; `claude-memory/` lives one level deeper)

- **Purpose**: knowledge-accumulation layer for the GSD pipeline — diseases, solutions,
  patterns, ADRs, per-project health, session logs, standing feedback rules.
- **Read when**: a pipeline failure looks familiar; before architecture/agent changes; to recall
  why a decision was made. Start at `00-Home/GSD-Index.md`, `03-Patterns/index.md`,
  `05-Architecture/index.md`, `07-Feedback/index.md`, and `claude-memory/topics/`.
- **Standing rules live in** `07-Feedback/index.md` (e.g. *No Pipeline Auto-Start*, *Requirements
  from specs only*, *Proactive not reactive*) — treat these as binding.

### 2. Key vault (OneDrive) — secrets & credentials  ⚠️ HANDLE WITH CARE
`C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\VSCODE\keys\`

- **Purpose**: API keys, certs, and connection secrets (186 files). LLM creds:
  `anthropic.md`, `azure-openai.md`, `openai.md`, `deepseek.md`, `gemini.md`,
  `kimi-moonshot.md`, `minimax.md`, `glm-zhipu.md`, `nvidia-build.md`, `amazon-bedrock.md`,
  `litellm.md` / `litellm-master.md` / `litellm-virtual-keys.md` (central LiteLLM gateway),
  plus M365 cert-auth, `Technijian-Agent-Harness.pfx`, and per-tenant `*-eop-*` files.
- **Rules**: read a specific file ONLY when a task needs that credential. **Never print, echo,
  log, or commit secret values.** **Never paste a key into source — load from env or the gateway.**
  Reference creds by filename, not contents. This directory is OUTSIDE the repo and must stay so.

### 3. Cortex knowledge brain (Obsidian "rjain557-knowledge") — research feed
`C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\obsidian\rjain557-knowledge\rjain557-knowledge\`

- **⚡ RESEARCH-FIRST RULE: search Cortex BEFORE doing fresh web research.** The owner pre-loads
  verified deep-research here precisely so sessions don't repeat full online searches. Grep/Glob
  these folders by keyword first; only go to the web for what Cortex doesn't cover or to verify
  volatile facts (prices, versions) older than the note's date.
- **`Topics/` (310+ notes — the main knowledge store):** verified deep-research reports
  (frontmatter: `generated_by: deep_research`, ~30 sources cited each, `verified: passed`,
  `domain:` tags). Coverage: agent orchestration/harnesses, Claude Code workflows & memory, MCP
  servers, coding-agent benchmarks, models, SEO, infra. `_refresh-*.md` notes are recurring
  re-research (e.g. coding-agent benchmarks) — prefer the newest.
- **`claude-memory/topics/`** (18 + `models/` 36): durable curated facts — `model_catalog` +
  per-model cards (re-verified weekly), `litellm_gateway`, `llm_cost_tracking`,
  `ai_fleet_infrastructure`, `deep_research_pipeline`. Check before any model-routing change.
- **`Inbox/` (468+):** raw clippings awaiting synthesis — fallback when Topics has no hit.
- **`Meta/`:** daily lint reports + `Proposals/pending/` (reviewer-loop output — owner decisions,
  don't act on them unprompted).
- **Read when**: designing/upgrading agents, harnesses, skills, workflows; any "what's the latest
  X" question; before model-routing changes.

---

## Memory + Code Intelligence Stack

### Layer Boundaries

| Layer | Location | Purpose |
|-------|----------|---------|
| **Vault (Obsidian)** | `claude-memory/` in Obsidian vault | Durable human knowledge — topic pages only |
| **Auto-memory (CC built-in)** | `C:\Users\Administrator\.claude\projects\d--VSCode-gsd-autonomous-dev-gsd-autonomous-dev\memory\` | Claude's working notes, managed automatically |
| **GitNexus** | `.gitnexus/` + MCP server | Code structure, impact analysis, symbol graph |

### Vault Path
`C:\Users\Administrator\OneDrive - Technijian, Inc\Documents\obsidian\gsd-autonomous-dev\gsd-autonomous-dev\claude-memory\`

### Retrieval Rules
- Vault topics are loaded automatically on `UserPromptSubmit` when topic keywords appear in the prompt
- `preferences.md` is ALWAYS loaded on every retrieval (no keyword gate)
- Topic matches are logged to `.retrieval-log.jsonl` with timestamp and query snippet
- Manually run `/vault-status` to see retrieval quality metrics

### Write Rules
- Topic pages live in `claude-memory/topics/` — write there, never outside this directory
- Never write transcript-style pages — only structured topic format with YAML frontmatter
- Every vault mutation appends to `CHANGELOG.md` with the appropriate prefix
- Run `/consolidate` after a substantive session to save durable knowledge

### Topic Page Schema
```yaml
---
topic: <short name>
aliases: [<alternate names>]
volatility: stable|evolving|ephemeral
last_updated: <ISO date>
confidence: high|medium|low
sources: [<session dates, commit hashes>]
access_count: 0
last_accessed: <ISO date>
---
```

### Volatility Semantics
- **stable**: architectural decisions, domain invariants. Review cadence: yearly. Conservative consolidation.
- **evolving**: active development state (default). Review cadence: quarterly. Normal consolidation.
- **ephemeral**: workarounds, "current state of X" snapshots. Review cadence: aggressive. Auto-archive after 60 days with no access or update.

### Contradiction Handling
Before updating any topic, compare new info against existing `## Key facts`:
- **Compatible** → extend, proceed normally
- **Clarifying** → update in-place, note refinement in CHANGELOG
- **Contradicting** → append to `## Open questions` as `CONTRADICTION detected on [date]`, lower confidence, do NOT overwrite
- **Replacing** (explicit "this was wrong") → overwrite, record in CHANGELOG with `[replaced]` prefix

### Hooks Installed
| Hook | Trigger | Purpose |
|------|---------|---------|
| `retrieve.sh` | UserPromptSubmit | Load matching vault topics + preferences.md |
| `impact-check.sh` | PreToolUse (Edit/Write) | Warn on HIGH/CRITICAL agent/harness edits |
| `reindex.sh` | PostToolUse (Bash) | Run `gitnexus analyze` after git commit/merge |
| `consolidate.sh` | Stop | Remind to consolidate if vault was accessed |
| `health-check.sh` | Stop | Recompute HEALTH.md metrics |
| `preference-extract.sh` | Stop | Signal to check for preference-shaped statements |

### Slash Commands
| Command | Purpose |
|---------|---------|
| `/vault-status` | Health dashboard — topic count, retrieval quality, freshness |
| `/consolidate` | Save durable session knowledge to vault topics |
| `/review` | Weekly vault review — quality, contradictions, volatility calibration |
| `/contradictions` | List and resolve unresolved contradictions |
| `/volatility <topic> <level>` | Manually set topic volatility |
| `/graduate` | Recommend stay vs. migrate to LightRAG |

### Weekly Review Mandate
Run `/review` every week. Target: 5–10 minutes. If days-since-review > 14, the health-check hook prints a warning at session end. If > 30 days, `/graduate` will refuse to give a recommendation.

### Vault Version Control
The Obsidian vault is NOT currently a git repo. To initialize (strongly recommended):
```bash
git init "C:/Users/rjain/OneDrive - Technijian, Inc/Documents/obsidian/gsd-autonomous-dev/gsd-autonomous-dev"
```
Run this once to enable rollback for all vault mutations.

### Key Files
- `claude-memory/index.md` — topic registry
- `claude-memory/HEALTH.md` — live health metrics
- `claude-memory/CHANGELOG.md` — audit trail of all vault mutations
- `claude-memory/.retrieval-log.jsonl` — retrieval event log (used for health metrics)
