# GSD Multi-Frontend Pipeline Guide

## When to Use

The multi-frontend pipeline is designed for repositories that contain two or more independent frontend frameworks that can be developed in parallel. Common scenarios:

- **Web + Admin panel**: A customer-facing React web app and an internal MCP-admin dashboard
- **Web + Browser extension + Mobile**: Multiple client interfaces sharing a common backend
- **Multiple SPA clients**: Separate single-page applications for different user roles

Benefits of multi-pipeline mode:

- **Build isolation**: TypeScript errors in one frontend do not block progress on others
- **Parallel development**: Independent frontends are worked on simultaneously
- **Targeted debugging**: Each pipeline has its own log file and health tracking
- **Budget efficiency**: Budget is proportioned by requirement count, preventing any single interface from consuming the entire budget

## Architecture

The multi-frontend pipeline uses an orchestrator pattern that respects dependency ordering:

```
ORCHESTRATOR (Phase Orchestrator)
  |
  +-- Phase 1: DATABASE pipeline (sequential)
  |     Stored procedures, tables, views, seed data
  |
  +-- Phase 2: BACKEND pipeline (sequential, depends on database)
  |     .NET 8 controllers, services, Dapper repositories
  |
  +-- Phase 3: SHARED pipeline (sequential, depends on backend)
  |     TypeScript types, shared hooks, API clients, constants
  |
  +-- Phase 4: FRONTEND pipelines (parallel, depend on shared)
        |
        +-- WEB pipeline (React 18 + Vite)
        +-- MCP-ADMIN pipeline (React 18 + MCP SDK)
        +-- BROWSER pipeline (Chrome Extension, Manifest V3)
        +-- MOBILE pipeline (React Native / .NET MAUI)
        +-- SPA-CLIENT pipeline (any additional frontend)
```

### Dependency Rules

| Layer | Depends On | Can Run In Parallel With |
|-------|-----------|------------------------|
| Database | Nothing | Nothing (must run first) |
| Backend | Database | Nothing (must run second) |
| Shared | Backend | Nothing (must run third) |
| Web | Shared | All other frontends |
| MCP-Admin | Shared | All other frontends |
| Browser Extension | Shared | All other frontends |
| Mobile | Shared | All other frontends |

### Shared Phases

Some phases run once and benefit all pipelines. These are not repeated per-interface:

- **cache-warm**: Warms the Sonnet cache prefix (system prompt, specs, blueprint)
- **spec-gate**: Validates all specifications upfront
- **spec-align**: Checks alignment across all interfaces

## Configuration

Multi-pipeline mode is controlled by the `multi_pipeline` section in `v3/config/global-config.json`:

```json
{
  "multi_pipeline": {
    "enabled": true,
    "strategy": "per-interface",
    "max_parallel": 3,
    "shared_phases": ["cache-warm", "spec-gate", "spec-align"]
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | boolean | false | Enable multi-pipeline mode |
| strategy | string | "per-interface" | Pipeline splitting strategy. Currently only "per-interface" is supported. |
| max_parallel | integer | 3 | Maximum number of frontend pipelines running simultaneously |
| shared_phases | string[] | ["cache-warm", "spec-gate", "spec-align"] | Phases that run once for all interfaces |

### Interface Detection

The pipeline automatically detects interfaces from the repository structure:

```
design/
  web/v01/_analysis/        --> "web" interface detected
  mcp-admin/v01/_analysis/  --> "mcp-admin" interface detected
  browser/v01/_analysis/    --> "browser" interface detected
  mobile/v01/_analysis/     --> "mobile" interface detected
```

Supported interface types: `web`, `mcp-admin`, `browser`, `mobile`, `agent`

Each interface type has its own conventions configured in `global-config.json` under `interface_conventions`, including frontend stack, build commands, test commands, and output directories.

## Running Multi-Pipeline

### Enable and Run

```powershell
# Edit global-config.json to set multi_pipeline.enabled = true, then:
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project'"
```

### Scope to a Specific Interface

If you need to restart or run only one frontend pipeline:

```powershell
# Run only the web interface
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project' -Scope 'interface:web'"

# Run only the admin panel
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project' -Scope 'interface:mcp-admin'"
```

## Budget Allocation

In multi-pipeline mode, the total budget is split proportionally based on the number of requirements per interface.

### Example Budget Distribution

For a project with 1,300 requirements and a $400 budget:

| Interface | Requirements | Percentage | Budget Allocation |
|-----------|-------------|------------|-------------------|
| backend | 500 | 38% | $152.00 |
| web | 400 | 31% | $124.00 |
| mcp-admin | 200 | 15% | $60.00 |
| browser | 100 | 8% | $32.00 |
| shared | 100 | 8% | $32.00 |

Each pipeline tracks its own cost independently. If one pipeline exhausts its budget, it halts without affecting the others.

### Budget Overrides

You can adjust budget allocation by modifying the mode's `budget_cap_usd` and running with a scope filter:

```powershell
# Give the web frontend extra budget by running it separately with a higher cap
pwsh -NoExit -Command "& gsd-update.ps1 -RepoRoot '...' -Scope 'interface:web'"
```

## Monitoring Multiple Pipelines

### Per-Pipeline Logs

Each pipeline generates its own log file:

```
logs/
  v3-pipeline-2026-03-15_103243.log       # Main orchestrator log
  v3-pipeline-web-2026-03-15_103243.log   # Web frontend pipeline
  v3-pipeline-admin-2026-03-15_103243.log # Admin panel pipeline
```

### Health Aggregation

The orchestrator aggregates health across all pipelines:

```
Overall health = weighted average of interface health scores
```

Where weights are proportional to requirement counts. The ntfy notification for each iteration includes per-pipeline status:

```
GSD V3: Iteration 12
Health: 78.5% (overall)
  backend: 92% | web: 71% | admin: 65% | browser: 80%
Cost: $45.23 | Elapsed: 32m
```

### Monitoring Commands

The `progress` command sent via ntfy returns aggregated status across all pipelines:

```
[GSD-STATUS] Progress Report
my-project | V3 multi-pipeline
Health: 78.5% (overall)
  backend: 450/500 (90%) -- COMPLETE
  web: 284/400 (71%) -- iteration 8
  admin: 130/200 (65%) -- iteration 6
  browser: 80/100 (80%) -- iteration 5
Cost: $45.23 | Budget: $400.00 (11%)
```

## Interface Dependencies and Cross-Interface Checks

### Cross-Interface Validation

The pipeline validates consistency across interfaces for shared resources:

| Check | Description | Blocking |
|-------|-------------|----------|
| shared_api_contracts | All frontends use the same API contract definitions | Yes |
| shared_data_types | TypeScript types in `src/shared/types/` are consistent | Yes |
| shared_design_tokens | Design tokens (colors, spacing, typography) match Figma | No (warning) |
| auth_consistency | Authentication flow is identical across all interfaces | Yes |

### Shared Code Rules

Code in `src/shared/` must be pure TypeScript with no platform-specific imports:

- No `react-native` imports
- No `chrome.*` imports
- No `expo-*` imports
- No Node.js-specific imports
- Use `fetch` for HTTP (available in all runtimes)
- Types directory (`src/shared/types/`) is the single source of truth for all TypeScript interfaces

## Handling Failures

### Backend Pipeline Fails

If the backend pipeline fails, all frontend pipelines are paused because frontends depend on backend APIs. Resolution:

1. Fix the backend issue (check `.gsd/requirements/fail-tracker.json`)
2. Restart the backend pipeline with scope filter: `-Scope 'interface:backend'`
3. Once backend health improves, frontend pipelines resume automatically

### One Frontend Fails

If one frontend pipeline fails, all other frontends continue independently. The failed pipeline can be restarted without affecting the others:

```powershell
# Restart just the failed web pipeline
pwsh -NoExit -Command "& gsd-update.ps1 -RepoRoot '...' -Scope 'interface:web'"
```

### Shared Types Change

If the shared pipeline modifies types that are already in use by frontend pipelines, the orchestrator triggers a revalidation of all active frontend pipelines to catch type errors early.

### Budget Exhaustion

If one pipeline exhausts its budget allocation:
- That pipeline halts
- Other pipelines continue with their remaining budgets
- The orchestrator logs which pipeline stopped and why
- You can allocate additional budget and resume the specific pipeline

## Best Practices

1. **Run backend first**: Even in non-multi-pipeline mode, ensure backend requirements are satisfied before starting frontend work. This prevents cascading type errors.

2. **Use shared types**: Define all API response types, request types, and shared constants in `src/shared/types/`. The pipeline enforces this through cross-interface validation.

3. **Monitor per-interface health**: Do not rely solely on the aggregate health score. A 75% overall health might hide the fact that one frontend is at 40% while others are at 90%.

4. **Stagger frontend starts**: If rate limits are a concern, set `max_parallel` to 2 instead of 3 to reduce API pressure.

5. **Scope filter for debugging**: When one frontend is stuck, use `-Scope 'interface:web'` to focus the pipeline's attention (and budget) on that specific interface.
