# GSD V3 Pipeline Guide

## Overview

The GSD V3 Pipeline is a 2-model, API-only convergence engine that autonomously develops, fixes, and verifies code against specifications. It replaces the V2 7-agent CLI+REST system with a streamlined architecture: Claude Sonnet handles all reasoning (research, plan, review, verify) and Codex Mini handles all code generation (execute), with 5 additional models available in the execute rotation pool.

V3 is approximately 85% cheaper and 10x faster than V2, achieved through prompt caching, batch API usage, structured JSON output, and elimination of CLI process spawning overhead.

## Quick Start

### Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| PowerShell | 7+ (pwsh) | Required for V3 scripts |
| .NET SDK | 8.x | For backend build validation |
| Node.js | 18+ | For frontend build validation |
| Git | 2.x+ | Version control and commit tracking |

### API Keys Required

All V3 pipeline operations use direct API calls (no CLI tools). The following environment variables must be set as persistent User-level variables:

| Variable | Provider | Purpose | Required |
|----------|----------|---------|----------|
| ANTHROPIC_API_KEY | Anthropic | Sonnet for reasoning phases | Yes |
| OPENAI_API_KEY | OpenAI | Codex Mini for code generation | Yes |
| DEEPSEEK_API_KEY | DeepSeek | Execute rotation pool | Recommended |
| KIMI_API_KEY | Moonshot AI | Execute rotation pool | Optional |
| MINIMAX_API_KEY | MiniMax | Execute rotation pool | Optional |
| GEMINI_API_KEY | Google | Research and execute rotation | Recommended |
| GLM_API_KEY | Zhipu AI | Execute rotation pool | Optional |

Set keys as User-level environment variables:

```powershell
[System.Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", "sk-ant-...", "User")
[System.Environment]::SetEnvironmentVariable("OPENAI_API_KEY", "sk-...", "User")
[System.Environment]::SetEnvironmentVariable("DEEPSEEK_API_KEY", "sk-...", "User")
# ... repeat for each key
```

### First Run Setup

1. Ensure your project has a `.gsd/` directory with a `requirements/requirements-matrix.json` (created by `gsd-blueprint` or `gsd-assess`).
2. Ensure specification documents are in `docs/` (SDLC Phase A-E) and design deliverables are in `design/{type}/v##/_analysis/`.
3. Run the pipeline using one of the mode-specific entry scripts described below.

## Pipeline Modes

The V3 pipeline supports three operational modes, each tuned for a different use case:

### greenfield -- New Project Build

Build a complete project from specifications. Used for pre-1.0 development where no production code exists.

| Setting | Value |
|---------|-------|
| Command | `gsd-blueprint` |
| Budget cap | $50.00 |
| Max iterations | 25 |
| Batch size | 3-15 requirements per iteration |
| Research | Full (all specs analyzed) |
| Spec gate | Full validation |
| Two-stage execute | Enabled (skeleton then fill) |

### bug_fix -- Post-Launch Fixes

Targeted bug fixes with minimal iteration overhead. Skips research and spec gate phases for speed.

| Setting | Value |
|---------|-------|
| Command | `gsd-fix` |
| Budget cap | $5.00 |
| Max iterations | 5 |
| Batch size | 1-3 requirements per iteration |
| Research | Skipped |
| Spec gate | Skipped |
| Two-stage execute | Disabled (single pass) |

Input modes:

```powershell
# From description
gsd-fix "Login page returns 500 on empty password"

# From file
gsd-fix -File bugs.md

# From directory with artifacts (screenshots, logs)
gsd-fix -BugDir ./bugs/issue-name/

# Scoped to interface
gsd-fix -Interface web "Navigation menu broken"
```

### feature_update -- Add Features to Existing Project

Add new features from updated specifications while preserving all existing satisfied requirements. Includes regression detection.

| Setting | Value |
|---------|-------|
| Command | `gsd-update` |
| Budget cap | $400.00 |
| Max iterations | 50 |
| Batch size | 3-15 requirements per iteration |
| Research | Full, scoped to new specs |
| Spec gate | Incremental (new sections only) |
| Two-stage execute | Enabled |

Preservation rules:
- All previously satisfied requirements are preserved
- Regression detection: alerts if satisfied requirements regress to partial or not_started
- New requirements tagged with spec version for traceability

## Running the Pipeline

### Feature Update (Most Common)

```powershell
# Basic feature update
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project'"

# With scope filter (only process requirements from a specific spec version)
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project' -Scope 'source:v02_spec'"

# Scope to specific requirements by ID
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project' -Scope 'id:REQ-201,REQ-202'"

# Scope to a specific interface
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project' -Scope 'interface:web'"

# Resume from a specific iteration after a crash
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project' -StartIteration 15"

# Compound scope filters (AND logic)
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-update.ps1 -RepoRoot 'C:\repos\my-project' -Scope 'interface:web AND source:v02_spec'"
```

### Greenfield Build

```powershell
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-blueprint.ps1 -RepoRoot 'C:\repos\new-project'"
```

### Bug Fix

```powershell
pwsh -NoExit -Command "& D:\vscode\gsd-autonomous-dev\gsd-autonomous-dev\v3\scripts\gsd-fix.ps1 -RepoRoot 'C:\repos\my-project' -Description 'Login returns 500'"
```

### Pipeline Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| -RepoRoot | (required) | Absolute path to the repository root |
| -Scope | "" (all) | Scope filter: `source:`, `id:`, `interface:`, `spec_version:` |
| -NtfyTopic | "auto" | Notification topic (auto-generates from username + repo name) |
| -StartIteration | 1 | Resume from a specific iteration number |

## Convergence Loop Phases

Each iteration of the pipeline executes the following phases in sequence. Phases may be skipped based on the active pipeline mode.

### Phase 0: Cache Warm

Sends a minimal request to Anthropic with the system prompt, spec documents, and blueprint manifest as cached prefix blocks. Subsequent requests that reuse these blocks receive a 90% input token discount. Cache TTL is 5 minutes.

### Phase 1: Spec Gate

Validates that specification documents are complete, consistent, and sufficient for code generation. In greenfield mode, performs full validation. In feature_update mode, validates only new sections while cross-referencing existing code.

- **Blocks pipeline** if critical issues found (missing specs, contradictions)
- **Warns** on moderate issues (ambiguous requirements, missing edge cases)

### Phase 2: Spec Align

Checks alignment between specifications, requirements matrix, and the current codebase. Detects drift that could cause the pipeline to generate incorrect code.

- Blocks if drift exceeds 20%
- Warns if drift exceeds 5%
- Runs at pipeline start and every 10 iterations thereafter

### Phase 3: Research

Claude Sonnet analyzes the current batch of requirements against the codebase to determine implementation strategy. Outputs:

- Per-requirement findings (existing files, patterns, dependencies)
- Size estimates (token budget for execute phase)
- Decomposition recommendations for oversized requirements

### Phase 4: Plan

Claude Sonnet creates detailed implementation plans for each requirement in the batch. Each plan specifies:

- Files to create or modify
- Exact changes (code snippets, patterns to follow)
- Confidence score (used by confidence-gated review)
- Dependencies between requirements

Plans with confidence >= 0.9 that pass local validation will skip the Review phase entirely.

### Phase 5: Execute-Skeleton (Two-Stage Execute, Pass 1)

Codex Mini (or a model from the execute pool) generates structural code: type definitions, interfaces, class stubs, and function signatures. This pass uses approximately 30% of the output token budget.

The skeleton is validated for structural correctness before proceeding to the fill pass.

### Phase 6: Execute-Fill (Two-Stage Execute, Pass 2)

Codex Mini (or a model from the execute pool) fills in the implementation details: function bodies, business logic, error handling, and data access code. This pass uses approximately 70% of the output token budget.

Models are selected from the execute pool using weighted round-robin distribution.

### Phase 7: Local Validate

Runs local build and type-checking validation without consuming API tokens:

| Validator | Command | Purpose |
|-----------|---------|---------|
| file_exists | (filesystem check) | Verify all planned files were created |
| dotnet_build | `dotnet build --no-restore` | Backend compilation |
| typescript_check | `npx tsc --noEmit` | Frontend type checking |
| sql_syntax | `sqlcmd -i {file} -b` | SQL script validation |
| pattern_match | (regex check) | Verify expected patterns exist in output |

Items that pass all validators skip directly to Verify (no Review needed). Items that fail are sent to Review with error context attached.

### Phase 8: Review

Claude Sonnet reviews code changes using diff-based review (sends only the diff plus error context, not full files). This reduces token consumption by approximately 75% compared to full-file review.

Review output:
- Pass/fail per requirement
- Specific issues found with fix instructions
- Status updates (satisfied, partial, not_started)

### Phase 9: Verify

Claude Sonnet performs a final binary check: does each requirement's output meet its acceptance criteria? Updates the requirements matrix with current statuses.

### Phase 10: Spec Fix

For requirements that repeatedly fail, Sonnet analyzes whether the spec itself is ambiguous or contradictory and suggests spec-level corrections.

## Model Allocation

### Reasoning Phases (Claude Sonnet)

| Phase | Model | Notes |
|-------|-------|-------|
| Cache Warm | claude-sonnet-4-6 | Warms cache prefix |
| Spec Gate | claude-sonnet-4-6 | Spec validation |
| Spec Align | claude-sonnet-4-6 | Drift detection |
| Research | claude-sonnet-4-6 | Configurable via phase_model_overrides |
| Plan | claude-sonnet-4-6 | Implementation planning |
| Review | claude-sonnet-4-6 | Code review |
| Verify | claude-sonnet-4-6 | Configurable via phase_model_overrides |

### Code Generation Phases (Execute Pool)

The execute pool uses 7 models in weighted round-robin distribution:

| Model | Provider | Weight | Selection Frequency |
|-------|----------|--------|-------------------|
| Codex Mini | OpenAI | 3 | ~30% of executions |
| DeepSeek Chat | DeepSeek | 2 | ~20% of executions |
| Kimi | Moonshot AI | 1 | ~10% of executions |
| MiniMax | MiniMax | 1 | ~10% of executions |
| Claude Sonnet | Anthropic | 1 | ~10% of executions |
| Gemini Flash | Google | 1 | ~10% of executions |
| GLM-5 | Zhipu AI | 1 | ~10% of executions |

Models without configured API keys are automatically excluded from the pool. When a model hits a rate limit, the pipeline rotates to the next available model immediately.

## Anti-Plateau Protection

The pipeline detects when health score stops improving and takes graduated action:

| Consecutive Zero-Delta Iterations | Action | Details |
|-----------------------------------|--------|---------|
| 3 | Warning | Flag stuck requirements (failed 3+ times), log warning |
| 4 | Escalate | Recommend Opus escalation for top 3 stuck requirements |
| 5 | Skip | Defer all stuck requirements, remove from active pool, continue with remaining |

Deferred requirements are re-checked every 10 iterations in case dependencies have been resolved.

### Escalation Limits

| Escalation Type | Max Per Project | Purpose |
|-----------------|----------------|---------|
| Opus escalation | 10 | Upgrade plan/review to Claude Opus for persistent failures |
| Codex full escalation | 5 | Upgrade Codex Mini to full Codex when output is truncated |

## Decomposition Budget

Large requirements that cannot be implemented in a single execute pass are automatically decomposed into sub-requirements:

| Setting | Value | Purpose |
|---------|-------|---------|
| Max new sub-reqs per iteration | 20 | Prevents runaway sub-requirement explosion |
| Max depth | 4 | Limits decomposition nesting |
| Defer excess | Enabled | Excess sub-reqs deferred to next iteration |

Decomposition is triggered in three ways:
1. **Research phase**: Sonnet identifies requirements that are too large and recommends splitting
2. **Plan phase**: Plan output includes decomposition directives for oversized requirements
3. **Pre-decompose**: Previously truncated requirements are automatically split before planning

## Cost Management

### Budget Caps by Mode

| Mode | Budget Cap | Notes |
|------|-----------|-------|
| greenfield | $50.00 | Full project build |
| bug_fix | $5.00 | Targeted fixes |
| feature_update | $400.00 | Large-scale feature additions |

### Per-Requirement Cost Alerts

| Threshold | Action |
|-----------|--------|
| $2.00 | Warning logged |
| $5.00 | Escalation: requirement flagged for review |
| $10.00 | Hard cap: requirement deferred automatically |

### Cost Tracking

All costs are tracked per-phase, per-model, per-requirement, and per-interface. Summary files are stored at:

- `.gsd/costs/cost-summary.json` -- aggregate costs
- `.gsd/costs/greenfield-summary.json` -- greenfield mode costs
- `.gsd/costs/bugfix-summary.json` -- bug fix mode costs
- `.gsd/costs/update-summary.json` -- feature update mode costs

### Budget Checks

The pipeline checks budget availability before each phase:
- Before each iteration: estimates cost of upcoming iteration (~$0.15 Sonnet + ~$0.05/req Codex)
- Before each phase: estimates phase-specific cost
- At 80% budget consumption: sends notification alert
- At 100% budget: halts pipeline

## Spec Alignment Guard

The spec alignment guard prevents the pipeline from generating code based on outdated or mismatched specifications.

### How It Works

1. **Pre-pipeline check**: Compares specification documents against the requirements matrix and existing codebase
2. **Periodic re-check**: Runs every 10 iterations during long pipeline runs
3. **Drift calculation**: Measures percentage of requirements that no longer match their source specs

### Thresholds

| Drift Level | Threshold | Action |
|-------------|-----------|--------|
| Moderate | >5% | Warning logged, notification sent |
| Critical | >20% | Pipeline blocked until specs are updated |

### Prevention

The spec alignment guard prevents "contamination incidents" where the pipeline generates code matching an old spec version while new specs have been added to the repository.

## Confidence-Gated Review

Not every code change needs a full Sonnet review. The pipeline uses confidence scoring to skip reviews for high-confidence, simple changes:

| Condition | Action |
|-----------|--------|
| Plan confidence >= 0.9 AND local validation passes | Skip Review entirely |
| Plan confidence >= 0.7 | Always send to Review |
| Trivial categories (CRUD, config, DTO, seed data, utility, SQL views) | Eligible for review skip |

This optimization reduces Sonnet API calls by 30-40% on typical projects.

## Speculative Execution

When health is improving (delta > 0), the pipeline can start the next iteration's Research + Plan phases while the current iteration's Review is still in-flight. This provides approximately 40% speed improvement at the cost of 2% wasted computation (if Review produces different results than expected).

Speculative execution is automatically disabled when the pipeline stalls (zero delta).

## Checkpoint and Recovery

The pipeline saves a checkpoint after each phase, enabling crash recovery:

```json
{
  "iteration": 15,
  "phase": "execute-fill",
  "health": 72.5,
  "batch_size": 10,
  "mode": "feature_update",
  "cache_state": { "version": 3, "valid": true }
}
```

To resume from a crash:

```powershell
pwsh -NoExit -Command "& gsd-update.ps1 -RepoRoot 'C:\repos\project' -StartIteration 15"
```

The pipeline automatically clears stale lock files on startup.

## Git Integration

The pipeline commits changes after each iteration with health score information:

| Setting | Default | Description |
|---------|---------|-------------|
| per_iteration | true | Commit after each iteration |
| include_health_in_message | true | Include health % in commit message |
| timeout_seconds | 60 | Maximum time for git operations |

## Logging

Each pipeline run creates a timestamped log file:

- **Per-run log**: `logs/v3-pipeline-{timestamp}.log`
- **Live log**: `v3-pipeline-live.log` (pointer to current run's log)

Tail the live log from another terminal:

```powershell
Get-Content v3-pipeline-live.log -Wait
```

## Troubleshooting

### Pipeline Stalled (No Health Improvement)

1. Check anti-plateau status: look for `[ANTI-PLATEAU]` messages in the log
2. Review stuck requirements: check `.gsd/requirements/fail-tracker.json` for requirements that failed 3+ times
3. Verify specs match requirements: run spec-align manually
4. Consider scope filtering to target specific stuck areas

### Rate Limited

The pipeline automatically rotates to the next available model in the execute pool. If all models are rate-limited:
- Wait for rate limits to expire (typically 1-5 minutes)
- The pipeline will retry automatically with exponential backoff

### Build Errors Persist

1. Check local validation output in the log for specific error messages
2. The validation fixer handles common patterns (missing imports, type mismatches)
3. For persistent build errors, the pre-validate-fix phase uses LLM-assisted fixing
4. If errors persist after 3 attempts, the requirement is deferred

### Spec Drift Detected

1. Review the drift report at `.gsd/requirements/drift-report.md`
2. Update specifications to match current requirements
3. Re-run the pipeline (spec gate will re-validate)

### Budget Exceeded Unexpectedly

1. Check per-requirement costs at `.gsd/costs/cost-summary.json`
2. Look for requirements that consumed disproportionate budget
3. Consider deferring expensive requirements with scope filtering
4. Adjust budget cap in `v3/config/global-config.json` under `pipeline_modes.{mode}.budget_cap_usd`

### Pipeline Crashed Mid-Iteration

1. Check the log file for the error message
2. The checkpoint file at `.gsd/.gsd-checkpoint.json` contains the last saved state
3. Resume with `-StartIteration N` where N is the iteration shown in the checkpoint
4. The pipeline automatically clears stale lock files on restart

## Existing Codebase Mode

### When to Use

Use Existing Codebase Mode when a repository already has significant code and you need to verify it against specifications. This is distinct from greenfield (no code exists) and feature_update (adding new features to a working codebase). Typical scenarios:

- A project was built manually and you need to assess spec compliance
- Code was generated by another tool and needs verification
- You inherited a codebase and need to identify gaps against specs
- You want to verify satisfaction before running a full pipeline

### How It Differs from Other Modes

| Aspect | Greenfield | Feature Update | Existing Codebase |
|--------|-----------|----------------|-------------------|
| Starting point | No code | Working code + new specs | Code exists, unknown compliance |
| Primary goal | Build everything | Add new features | Verify and fill gaps |
| Research scope | Full specs | New specs only | All specs vs existing code |
| Execution | Build all files | Build new features | Targeted gap-filling only |
| Typical cost | $50-400 | $50-400 | $5-10 |
| Typical duration | Hours | Hours | 15-30 minutes |

The key architectural difference is that Existing Codebase Mode front-loads verification work. Instead of assuming nothing exists and building from scratch, it inventories existing code, maps it to requirements, and only executes against verified gaps. This avoids regenerating files that already satisfy their requirements.

### 6-Phase Flow

```
spec-align → deep-extract → code-inventory → satisfaction-verify → targeted-execute → verify
```

1. **Spec Align**: Read ALL specification documents and validate consistency. Blocks if specs are incomplete or contradictory.
2. **Deep Extract**: Extract requirements from specs (not from code). Produces a deduplicated requirements matrix. Uses higher token limits (16K, 32K auto-retry) to handle large spec sets.
3. **Code Inventory**: Scan the entire codebase and build a file-to-capability map. Records what each file implements without making satisfaction judgments.
4. **Satisfaction Verify**: For each requirement, check whether the code inventory provides evidence of implementation. Reads actual code to verify — file existence alone is not proof of satisfaction.
5. **Targeted Execute**: Generate code only for requirements verified as not_started or partial. Uses the standard execute pool (7 models) but with a much smaller batch.
6. **Verify**: Final binary check that all requirements are now satisfied. Updates the requirements matrix.

### Command

```powershell
pwsh -File gsd-existing.ps1 -RepoRoot "C:\repos\project" -DeepVerify
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| -RepoRoot | (required) | Absolute path to the repository root |
| -DeepVerify | false | Enable deep code reading for satisfaction checks (slower but more accurate) |

### Expected Cost

| Cost Component | Estimate |
|----------------|----------|
| Spec align + deep extract | $1-2 |
| Code inventory | $1-2 |
| Satisfaction verify | $1-3 |
| Targeted execute (gaps only) | $2-5 |
| **Total** | **$5-10** |

This is 10-80x cheaper than running a full greenfield or feature_update pipeline ($50-400), because most code already exists and only gaps need execution.

### When to Use Direct Fixes Alongside

Direct fixes via Claude Code are 10-100x more efficient than pipeline execution for small, well-understood gaps. The recommended strategy:

1. Run Existing Codebase Mode for discovery and verification
2. Review the gap list (requirements still at not_started or partial)
3. For simple gaps (missing imports, config values, small functions): fix directly via Claude Code
4. For complex gaps (new controllers, multi-file features): let the pipeline handle them
5. Re-run verification to confirm all gaps are closed

This hybrid approach typically costs $5-10 for verification plus $0 for direct fixes, compared to $50-400 for a full pipeline run.

---

## Full Pipeline Orchestrator

### Overview

The Full Pipeline Orchestrator (`gsd-full-pipeline.ps1`) takes converged code through 5 sequential quality phases to produce production-ready output. Run this after the convergence pipeline reaches 100% health.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| -RepoRoot | (required) | Absolute path to the repository root |
| -ConnectionString | "" | SQL Server connection for DB validation |
| -AzureAdConfig | "" | JSON: {tenantId, clientId, audience, instance, scopes} |
| -TestUsers | "" | JSON array: [{username, password, roles}] |
| -StartFrom | "wireup" | Resume point: wireup\|codereview\|smoketest\|finalreview\|handoff |
| -MaxCycles | 3 | Review-fix cycles per phase |
| -MaxReqs | 50 | Requirements per batch |
| -SkipWireUp | false | Skip wire-up phase |
| -SkipCodeReview | false | Skip code review phase |
| -SkipSmokeTest | false | Skip smoke test phase |

### Phase Flow

```
Phase 1: WIRE-UP ─────────→ Mock data scan + route-role matrix + integration checks
Phase 2: CODE REVIEW ─────→ 3-model consensus (Claude+Codex+Gemini) + auto-fix cycles
Phase 3: SMOKE TEST ──────→ 9-phase integration validation (tiered cost optimization)
Phase 4: FINAL REVIEW ────→ Post-smoke-test re-review at lower severity threshold
Phase 5: HANDOFF ─────────→ PIPELINE-HANDOFF.md with all results + output file paths
```

### Running the Full Pipeline

```powershell
# Basic run
pwsh -NoExit -File gsd-full-pipeline.ps1 -RepoRoot "C:\repos\my-project"

# With database and auth validation
pwsh -NoExit -File gsd-full-pipeline.ps1 -RepoRoot "C:\repos\my-project" `
    -ConnectionString "Server=.;Database=MyDb;Trusted_Connection=true" `
    -AzureAdConfig '{"tenantId":"...","clientId":"...","audience":"..."}' `
    -TestUsers '[{"username":"admin@test.com","password":"...","roles":["Admin"]}]'

# Resume from smoke test (skip wire-up and code review)
pwsh -NoExit -File gsd-full-pipeline.ps1 -RepoRoot "C:\repos\my-project" -StartFrom smoketest
```

### Output Files

| File | Content |
|------|---------|
| `PIPELINE-HANDOFF.md` | Phase summary table + all output paths |
| `.gsd/code-review/review-report.json` | Structured review issues |
| `.gsd/code-review/review-summary.md` | Human-readable review |
| `.gsd/smoke-test/smoke-test-report.json` | Per-phase validation results |
| `.gsd/smoke-test/mock-data-scan.json` | Mock data patterns found |
| `.gsd/smoke-test/route-role-matrix.json` | RBAC gaps |
| `.gsd/smoke-test/gap-report.md` | Integration issues |

---

## Smoke Testing

### Overview

The smoke test (`gsd-smoketest.ps1`) performs 9-phase integration validation to verify runtime functionality. Uses tiered LLM cost optimization to reduce costs by ~85%.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| -RepoRoot | (required) | Repository path |
| -ConnectionString | "" | SQL Server connection |
| -MaxCycles | 3 | Fix attempts before stopping |
| -FixModel | "claude" | claude or codex |
| -TestUsers | "" | JSON array of test users |
| -AzureAdConfig | "" | Azure AD config JSON |
| -SkipBuild | false | Skip build validation |
| -SkipDbValidation | false | Skip DB validation |
| -CostOptimize | true | Use tiered models |

### Nine Validation Phases

| # | Phase | Tier | Cost | What It Checks |
|---|-------|------|------|----------------|
| 1 | Build Validation | LOCAL | $0 | `dotnet build` + `npm run build` |
| 2 | Database Validation | CHEAP | ~$0.05 | Tables, SPs, FKs, migrations |
| 3 | API Smoke Test | MID | ~$0.10 | Controllers, middleware, DI, CORS |
| 4 | Frontend Route Validation | LOCAL | $0 | Route-component mapping |
| 5 | Auth Flow Validation | MID | ~$0.10 | JWT/Azure AD, guards, tokens |
| 6 | Module Completeness | CHEAP | ~$0.05 | API + frontend + DB per module |
| 7 | Mock Data Detection | LOCAL | $0 | Hardcoded data, TODOs |
| 8 | RBAC Matrix | LOCAL | $0 | Route → role → guard |
| 9 | Integration Gap Report | PREMIUM | ~$0.50 | Aggregated analysis |

### Tiered Cost Optimization

| Tier | Models | Cost/1M Tokens | Tasks |
|------|--------|---------------|-------|
| LOCAL | None (regex/file) | $0 | Build, routes, RBAC, mock scan |
| CHEAP | DeepSeek, Kimi, MiniMax | $0.14-0.21 | DB schema, module completeness |
| MID | Codex Mini | $1.50 | API wiring, auth flow, DI check |
| PREMIUM | Claude Sonnet | $9.00 | Security review, gap report, fixes |

Fallback: CHEAP → Kimi → MiniMax → Codex Mini (mid-tier fallback).

### Running Smoke Tests

```powershell
# Basic smoke test
pwsh -NoExit -File gsd-smoketest.ps1 -RepoRoot "C:\repos\my-project"

# With database validation
pwsh -NoExit -File gsd-smoketest.ps1 -RepoRoot "C:\repos\my-project" `
    -ConnectionString "Server=.;Database=MyDb;Trusted_Connection=true"

# Skip build, use codex for fixes
pwsh -NoExit -File gsd-smoketest.ps1 -RepoRoot "C:\repos\my-project" -SkipBuild -FixModel codex
```

---

## 3-Model Code Review

### Overview

The code review (`gsd-codereview.ps1`) uses Claude + Codex + Gemini for consensus-based review with automated fix cycles.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| -RepoRoot | (required) | Repository path |
| -Models | "claude,codex,gemini" | Comma-separated model list |
| -FixModel | "claude" | Model for generating fixes |
| -MaxReqs | 50 | Requirements per run |
| -MaxCycles | 5 | Review-fix cycles |
| -MinSeverityToFix | "medium" | Minimum severity to fix |
| -ReviewOnly | false | Skip auto-fix |
| -Severity | "all" | Filter: critical\|high\|medium\|low\|all |
| -OutputFormat | "json" | json or markdown |
| -RunSmokeTest | false | Chain to smoke test after review |

### Running Code Review

```powershell
# Full review with auto-fix
pwsh -NoExit -File gsd-codereview.ps1 -RepoRoot "C:\repos\my-project"

# Review only (no fixes)
pwsh -NoExit -File gsd-codereview.ps1 -RepoRoot "C:\repos\my-project" -ReviewOnly

# Chain to smoke test after review
pwsh -NoExit -File gsd-codereview.ps1 -RepoRoot "C:\repos\my-project" -RunSmokeTest `
    -ConnectionString "Server=.;Database=MyDb;Trusted_Connection=true"
```

---

## LLM Pre-Validate Fix Phase

### Overview

The validation fixer (`gsd-validation-fixer.ps1`) runs before local build to proactively fix common code generation errors.

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| -RepoRoot | (required) | Repository path |
| -RequirementIds | (required) | Requirement IDs to fix |
| -MaxAttempts | 10 | Max fix attempts |
| -PreValidate | false | Run in proactive mode |

### Fix Strategy

1. **Quick namespace fixes** (zero LLM cost): 60+ regex patterns for known namespace remapping
2. **Sonnet review**: Batches of 5 related files sent to LLM for cross-file fix analysis
3. **Multi-file grouping**: Related errors grouped by directory and shared imports
4. **Validation loop**: dotnet build → tsc --noEmit → test build → unit tests

---

## Centralized Logging

### Log Structure

```
~/.gsd-global/logs/{repo-name}/
├── run-{timestamp}.log              # Pipeline run log
├── smoketest-{timestamp}.log        # Smoke test log
├── codereview-{timestamp}.log       # Code review log
├── full-pipeline-{timestamp}.log    # Full pipeline log
├── latest.log                       # Pointer to latest run
├── iteration-counter.json           # Persistent iteration counter
└── iterations/
    └── iter-NNNN.json               # Per-iteration metrics
```

### Iteration Counter

Persistent across pipeline restarts:

```json
{ "next_iteration": 5, "repo": "my-project", "repo_root": "C:\\repos\\my-project" }
```

### Per-Iteration Metrics

```json
{
  "iteration_number": 1,
  "global_iteration_number": 47,
  "health": { "start": 19.4, "end": 22.5, "delta": 3.1 },
  "cost": { "total": 5.32, "by_model": { "claude": 4.50, "codex": 0.82 } },
  "duration_minutes": 12.5,
  "batch_info": { "size": 10, "satisfied": 3, "partial": 5, "not_started": 2 }
}
```

---

## Verify Phase Checklist

The verify phase (Phase 9) runs a binary check on each requirement. In addition to the requirement-level checks, the following project-wide gates must pass before a handoff is accepted.

### Mandatory Pre-Handoff Gates

| Gate | Command | Pass Condition |
|------|---------|----------------|
| CSS responsive utilities | `grep -c "md:flex" src/Client/technijian-spa/src/index.css` | Count > 0 |
| DB migration completeness | `grep -r "CREATE TABLE {TableName}" Database/Migrations/` | Result found for every table in every stored proc |
| E2E navigation tests | `npx playwright test e2e/navigation.spec.ts` | 0 failures |
| E2E screen render tests | `npx playwright test e2e/screens.spec.ts` | 0 failures |
| TypeScript compilation | `npx tsc --noEmit` | 0 errors |
| .NET build | `dotnet build` | 0 errors |

### When a Gate Fails

**CSS gate fails** → Rebuild with `@tailwindcss/cli@4.1.3`:
```bash
echo '@import "tailwindcss";' > src/tailwind-input.css
npx @tailwindcss/cli@4.1.3 -i src/tailwind-input.css -o src/index.css
```

**DB migration gate fails** → Write the missing migration before proceeding. Do not mark the requirement satisfied until `grep CREATE TABLE` returns a result for every table the stored proc references. A requirement that references a non-existent table is `BLOCKED`, not `PARTIAL`.

**E2E tests fail** → Treat as P1. Do not ship. Debug with:
```bash
npx playwright test --headed --debug e2e/navigation.spec.ts
```
Common causes: Playwright route ordering wrong (see Architecture doc), auth bypass not applied, mock data not matching DB seed.

---

## E2E Test Infrastructure

### Running Tests

```bash
cd src/Client/technijian-spa

# Kill any process holding port 3001 first
Get-NetTCPConnection -LocalPort 3001 | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }

# Run all E2E tests
npx playwright test --config=playwright.e2e.config.ts

# Run specific suites
npx playwright test --config=playwright.e2e.config.ts e2e/navigation.spec.ts
npx playwright test --config=playwright.e2e.config.ts e2e/screens.spec.ts

# Debug a failing test (headed browser)
npx playwright test --config=playwright.e2e.config.ts --headed --debug e2e/navigation.spec.ts
```

### How the Auth Bypass Works

Tests cannot use real Azure AD (MSAL). The bypass:

1. `.env.test` sets `VITE_E2E_BYPASS_AUTH=true`
2. `main.tsx` detects the flag and skips `MsalProvider` + `initializeMsal()`
3. `AuthContext.tsx` detects the flag and reads the role from `sessionStorage.getItem('e2e_test_role')`
4. `helpers.ts` sets `sessionStorage` via `context.addInitScript()` before page load
5. All API calls are intercepted by Playwright route mocks — no real backend needed

The auth bypass flag is **never** true in production or development mode — only in Vite's `test` mode.

### Critical: Route Registration Order

Playwright route matching uses **LIFO** (Last In, First Out). The last-registered route has the highest priority.

**Always** register catch-all routes first and specific routes last:
```typescript
// CORRECT — specific routes win
context.route(`${origin}/api/**`, catchAll);                   // lowest priority
context.route(`${origin}/api/navigation/my-modules`, specific); // highest priority

// WRONG — catch-all intercepts everything, specific route never fires
context.route(`${origin}/api/navigation/my-modules`, specific); // registered first
context.route(`${origin}/api/**`, catchAll);                   // registered last = wins
```

Getting this wrong causes the navigation query to return `[]` (empty array), which makes `isModuleUrlAllowed()` return false for all routes, showing "Access Forbidden" on every module-guarded screen despite correct mock data being provided.

### Adding New Tests

When a new `ProtectedRoute` with `requiredModule` is added in the router, add a corresponding test in `screens.spec.ts`:
```typescript
test('Admin NewFeature renders', async ({ page }) => {
  await page.goto('/admin/new-feature');
  await waitForAppReady(page);
  const body = await page.locator('body').textContent() ?? '';
  expect(body).not.toContain('Access Forbidden');
  expect(page.url()).not.toContain('/login');
});
```

And a forbidden test for roles that should not have access:
```typescript
test('client_user cannot access NewFeature', async ({ page }) => {
  await page.goto('/admin/new-feature');
  await waitForAppReady(page);
  const hasForbidden = await page.locator('text=Access Forbidden').count();
  const redirected = !page.url().includes('/admin/new-feature');
  expect(hasForbidden > 0 || redirected).toBe(true);
});
```
