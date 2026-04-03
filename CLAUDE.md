# GSD Autonomous Dev — Claude Code Project Configuration

## Role in the GSD Engine

Claude Code handles 3 phases of the GSD convergence loop (token-efficient, judgment-heavy):
1. **code-review** — Score repo health, update requirement statuses
2. **create-phases** — Extract requirements from specs + Figma (one-time)
3. **plan** — Prioritize next batch, write generation instructions

Read source code but **never modify it**. Write only to:
- `.gsd/health/`, `.gsd/code-review/`, `.gsd/generation-queue/`, `.gsd/agent-handoff/current-assignment.md`

Never write to: `.gsd/research/`, or source code files.

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
