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
