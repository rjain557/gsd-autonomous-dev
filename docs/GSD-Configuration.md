# GSD Configuration Reference

## Global Configuration

### global-config.json

Location: `%USERPROFILE%\.gsd-global\config\global-config.json`

```json
{
  "notifications": {
    "ntfy_topic": "auto",
    "notify_on": ["iteration_complete", "converged", "stalled", "quota_exhausted", "error"]
  },
  "patterns": {
    "backend": ".NET 8 with Dapper",
    "database": "SQL Server stored procedures only",
    "frontend": "React 18",
    "api": "Contract-first, API-first",
    "compliance": ["HIPAA", "SOC 2", "PCI", "GDPR"]
  },
  "phase_order": ["code-review", "create-phases", "research", "plan", "execute"],
  "council": {
    "enabled": true,
    "max_attempts": 2,
    "consensus_threshold": 0.66
  }
}
```

#### notifications

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| ntfy_topic | string | "auto" | Set to "auto" for per-project auto-detection (gsd-{username}-{reponame}), or a specific string to use one topic for all projects |
| notify_on | string[] | (all events) | Events that trigger push notifications |

Notification events: `iteration_complete`, `no_progress`, `execute_failed`, `build_failed`, `regression_reverted`, `converged`, `stalled`, `quota_exhausted`, `error`, `heartbeat`, `agent_timeout`, `progress_response`, `supervisor_active`, `supervisor_diagnosis`, `supervisor_fix`, `supervisor_restart`, `supervisor_recovered`, `supervisor_escalation`, `validation_failed`, `validation_passed`

All notification types that include status information (heartbeat, iteration_complete, converged, stalled, max_iterations, progress_response) also include running token cost data read from `.gsd/costs/cost-summary.json`. Terminal notifications (converged, stalled, max_iterations) and progress responses include a per-agent cost breakdown.

#### patterns

Project technology patterns enforced by all pipelines. These are injected into agent prompts to ensure consistent technology choices.

| Field | Type | Description |
|-------|------|-------------|
| backend | string | Backend framework and ORM |
| database | string | Database access pattern |
| frontend | string | Frontend framework |
| api | string | API design approach |
| compliance | string[] | Regulatory compliance requirements |

#### phase_order

Defines the convergence loop phase sequence. Each phase maps to a specific agent and prompt template.

#### council

LLM Council configuration. The council provides multi-agent cross-validation at 6 stages across both pipelines: convergence (100% health gate), post-research, pre-execute, post-blueprint, stall-diagnosis, and post-spec-fix. Codex and Gemini review; Claude synthesizes only.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | bool | true | Enable/disable all council reviews |
| max_attempts | int | 2 | Max convergence council runs per pipeline (prevents infinite looping) |
| consensus_threshold | float | 0.66 | Fraction of reviewers that must agree to approve (1/2) |

Council types and their behavior:

| Type | Pipeline | Blocking | Reviewers | Synthesizer |
|------|----------|----------|-----------|-------------|
| convergence | Both | Yes (resets health to 99%) | Codex + Gemini | Claude |
| post-research | Convergence | No (feedback only) | Codex + Gemini | Claude |
| pre-execute | Convergence | No (feedback only) | Codex + Gemini | Claude |
| post-blueprint | Blueprint | Yes (regenerates manifest) | Codex + Gemini | Claude |
| stall-diagnosis | Both | N/A (diagnostic) | Codex + Gemini | Claude |
| post-spec-fix | Both | Yes (retries resolution) | Codex + Gemini | Claude |

#### council.chunking

Chunked review configuration for the convergence council. Large projects have requirements auto-chunked into smaller groups for focused, quota-friendly reviews.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | bool | true | Enable/disable chunked reviews |
| max_chunk_size | int | 25 | Max requirements per chunk |
| min_group_size | int | 5 | Groups smaller than this get merged |
| strategy | string | "auto" | Chunking strategy (see below) |
| cooldown_seconds | int | 5 | Pause between chunks |
| min_requirements_to_chunk | int | 30 | Skip chunking below this count |

Chunking strategies:
- **auto** (default): Discovers the best grouping field from the data (tries `pattern`, `sdlc_phase`, `priority`, `source`, `spec_doc`)
- **field:X**: Force group by a specific field (e.g., `"field:sdlc_phase"`)
- **id-range**: Sequential blocks of N requirements (fallback)

#### quality_gates

Controls the three quality gate checks that run during pipeline execution.

```json
"quality_gates": {
    "database_completeness": {
        "enabled": true,
        "require_seed_data": true,
        "min_coverage_pct": 90
    },
    "security_compliance": {
        "enabled": true,
        "block_on_critical": true,
        "warn_on_high": true
    },
    "spec_quality": {
        "enabled": true,
        "min_clarity_score": 70,
        "check_cross_artifact": true
    }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `database_completeness.enabled` | bool | true | Enable/disable DB completeness check |
| `database_completeness.require_seed_data` | bool | true | Require seed data for every table |
| `database_completeness.min_coverage_pct` | int | 90 | Minimum coverage % to pass |
| `security_compliance.enabled` | bool | true | Enable/disable security scan |
| `security_compliance.block_on_critical` | bool | true | Critical violations are hard failures |
| `security_compliance.warn_on_high` | bool | true | High severity shown as warnings |
| `spec_quality.enabled` | bool | true | Enable/disable spec quality gate |
| `spec_quality.min_clarity_score` | int | 70 | Minimum spec clarity score (0-100) |
| `spec_quality.check_cross_artifact` | bool | true | Run cross-artifact consistency check |

Disable any gate: set `enabled: false`. Skip spec quality gate: use `-SkipSpecCheck` pipeline parameter.

### Prompt Templates

Quality gate prompt templates are stored in:

| Path | Description |
|------|-------------|
| `prompts/shared/security-standards.md` | 88+ OWASP security rules by layer (.NET, SQL, React, compliance) |
| `prompts/shared/coding-conventions.md` | .NET/React/SQL naming, formatting, SOLID conventions |
| `prompts/shared/database-completeness-review.md` | Database chain verification rules and enhanced tier structure |
| `prompts/claude/spec-clarity-check.md` | Pre-generation spec clarity audit template |
| `prompts/claude/cross-artifact-consistency.md` | Post-Figma-Make cross-reference validation template |

## Model Registry

### model-registry.json

Location: `%USERPROFILE%\.gsd-global\config\model-registry.json`

Central configuration for all AI agents (CLI and REST API). Created by `patch-gsd-multi-model.ps1`. Defines agent metadata, rotation pool, and REST API connection details.

```json
{
  "agents": {
    "claude": { "type": "cli", "role": ["review", "plan", "verify", "blueprint", "council-synthesize"] },
    "codex": { "type": "cli", "role": ["execute", "build", "council-review"] },
    "gemini": { "type": "cli", "role": ["research", "spec-fix", "council-review"] },
    "kimi": {
      "type": "openai-compat",
      "endpoint": "https://api.moonshot.ai/v1/chat/completions",
      "api_key_env": "KIMI_API_KEY",
      "model_id": "kimi-k2.5",
      "max_tokens": 8192,
      "temperature": 0.3,
      "role": ["execute-fallback", "council-review"],
      "supports_tools": false,
      "enabled": true
    },
    "deepseek": {
      "type": "openai-compat",
      "endpoint": "https://api.deepseek.com/v1/chat/completions",
      "api_key_env": "DEEPSEEK_API_KEY",
      "model_id": "deepseek-chat",
      "max_tokens": 8192,
      "temperature": 0.3,
      "role": ["execute-fallback", "council-review"],
      "supports_tools": false,
      "enabled": true
    },
    "glm5": {
      "type": "openai-compat",
      "endpoint": "https://api.z.ai/api/paas/v4/chat/completions",
      "api_key_env": "GLM_API_KEY",
      "model_id": "glm-5",
      "max_tokens": 8192,
      "temperature": 0.3,
      "role": ["execute-fallback", "council-review"],
      "supports_tools": false,
      "enabled": true
    },
    "minimax": {
      "type": "openai-compat",
      "endpoint": "https://api.minimax.io/v1/chat/completions",
      "api_key_env": "MINIMAX_API_KEY",
      "model_id": "MiniMax-M2.5",
      "max_tokens": 8192,
      "temperature": 0.3,
      "role": ["execute-fallback", "council-review"],
      "supports_tools": false,
      "enabled": true
    }
  },
  "rotation_pool_default": ["claude", "codex", "gemini", "kimi", "deepseek", "glm5", "minimax"]
}
```

#### Agent entry fields

| Field | Type | CLI | REST | Description |
|-------|------|-----|------|-------------|
| type | string | "cli" | "openai-compat" | Discriminator for dispatch logic |
| role | string[] | Yes | Yes | Roles this agent can fill |
| endpoint | string | No | Yes | Chat completions API URL |
| api_key_env | string | No | Yes | Environment variable name for API key |
| model_id | string | No | Yes | Model identifier sent in API requests |
| max_tokens | int | No | Yes | Max output tokens per request |
| temperature | number | No | Yes | Sampling temperature (0.0-1.0) |
| supports_tools | bool | No | Yes | Whether the model supports function calling (future use) |
| enabled | bool | No | Yes | Set to false to exclude from rotation |

#### rotation_pool_default

Ordered list of agent names for quota rotation. `Get-NextAvailableAgent` reads this list and validates each agent: CLI agents must have their CLI available, REST agents must have their API key set. Agents failing validation are excluded from the active pool.

To add a new OpenAI-compatible agent, add its entry to the `agents` object with `type: "openai-compat"` and append its name to `rotation_pool_default`. Set the corresponding environment variable and the agent is immediately available.

## Pricing Cache

### pricing-cache.json

Location: `%USERPROFILE%\.gsd-global\pricing-cache.json`

Auto-generated by `gsd-costs` (token cost calculator). Stores cached LLM pricing data fetched from the LiteLLM open-source database.

```json
{
  "models": {
    "codex": {
      "InputPerM": 1.75,
      "Name": "GPT 5.3 Codex",
      "OutputPerM": 14.0,
      "CacheReadPerM": 0.175
    },
    "gemini": {
      "InputPerM": 2.0,
      "Name": "Gemini 3.1 Pro",
      "OutputPerM": 12.0,
      "CacheReadPerM": 0.5
    },
    "claude_opus": {
      "InputPerM": 5.0,
      "Name": "Claude Opus 4.6",
      "OutputPerM": 25.0,
      "CacheReadPerM": 0.5
    },
    "claude_sonnet": {
      "InputPerM": 3.0,
      "Name": "Claude Sonnet 4.6",
      "OutputPerM": 15.0,
      "CacheReadPerM": 0.3
    },
    "claude_haiku": {
      "InputPerM": 1.0,
      "Name": "Claude Haiku 4.5",
      "OutputPerM": 5.0,
      "CacheReadPerM": 0.1
    },
    "codex_gpt51": {
      "InputPerM": 1.25,
      "Name": "GPT Codex 5.1",
      "OutputPerM": 10.0,
      "CacheReadPerM": 0.125
    }
  },
  "lastUpdated": "2026-03-02T19:09:59Z",
  "source": "litellm-github"
}
```

#### Model entry fields

| Field | Type | Description |
|-------|------|-------------|
| Name | string | Display name of the model |
| InputPerM | number | Cost per 1 million input tokens (USD) |
| OutputPerM | number | Cost per 1 million output tokens (USD) |
| CacheReadPerM | number | Cost per 1 million cached/read tokens (USD) |

#### Cache freshness thresholds

| Age | Behavior |
|-----|----------|
| < 14 days | Fresh -- used directly, no fetch attempted |
| 14-60 days | Aging -- auto-refresh attempted silently, falls back to cached on failure |
| > 60 days | Stale -- warning displayed, auto-refresh attempted, falls back to stale on failure |
| No cache | Fetches from web, falls back to hardcoded prices if fetch fails |

#### Supported model keys

| Cache Key | LiteLLM Lookup Keys (priority order) | Default Agent |
|-----------|--------------------------------------|---------------|
| claude_sonnet | claude-sonnet-4-6, claude-sonnet-4-5, claude-sonnet-4-1 | Review, Plan, Verify, Blueprint |
| claude_opus | claude-opus-4-6, claude-opus-4-5, claude-opus-4-1 | (premium alternative to Sonnet) |
| claude_haiku | claude-haiku-4-5, claude-haiku-4-5-20251001 | (economy alternative to Sonnet) |
| codex | gpt-5.3-codex, codex-mini-latest | Build, Execute |
| codex_gpt51 | gpt-5.1-codex, gpt-5.1 | (alternative code gen) |
| gemini | gemini-3.1-pro-preview, gemini-3-pro-preview, gemini-2.5-pro | Research, Spec-fix |
| kimi | kimi-k2.5, moonshot-v1-128k | Rotation fallback, Council review |
| deepseek | deepseek-chat, deepseek-coder | Rotation fallback, Council review |
| glm5 | glm-5, glm-4-plus | Rotation fallback, Council review |
| minimax | MiniMax-M2.5, minimax-pro | Rotation fallback, Council review |

## Per-Project Configuration

### .gsd-checkpoint.json

Location: `.gsd\.gsd-checkpoint.json`

Stores crash recovery state. Auto-managed by the engine. Also read by the background heartbeat job to report current status in ntfy notifications.

```json
{
  "pipeline": "converge",
  "iteration": 5,
  "phase": "execute",
  "health": 72.5,
  "batch_size": 8,
  "status": "in_progress",
  "timestamp": "2026-03-02T10:30:00Z",
  "pid": 12345
}
```

| Field | Type | Description |
|-------|------|-------------|
| pipeline | string | "converge" or "blueprint" |
| iteration | int | Current iteration number |
| phase | string | Current/last completed phase |
| health | number | Health score at checkpoint |
| batch_size | int | Current batch size (may be reduced from retries) |
| status | string | "in_progress" or "completed" |
| timestamp | string | ISO 8601 timestamp |
| pid | int | Process ID of the running pipeline |

### health-current.json

Location: `.gsd\health\health-current.json`

Current project health score and breakdown. Written by Claude during the review/verify phase.

```json
{
  "health_score": 72.5,
  "total_requirements": 40,
  "satisfied": 25,
  "partial": 8,
  "not_started": 7,
  "iteration": 5
}
```

### engine-status.json

Location: `.gsd\health\engine-status.json`

Live engine state file updated at every state transition and on a 60-second heartbeat interval. Used for stall detection by external observers, dashboards, and the supervisor.

```json
{
  "pid": 23340,
  "state": "running",
  "phase": "research",
  "agent": "gemini",
  "iteration": 4,
  "attempt": "1/3",
  "batch_size": 8,
  "health_score": 87.5,
  "last_heartbeat": "2026-03-02T22:27:00Z",
  "started_at": "2026-03-02T22:00:00Z",
  "elapsed_minutes": 27,
  "sleep_until": null,
  "sleep_reason": null,
  "last_error": null,
  "errors_this_iteration": 0,
  "recovered_from_error": false
}
```

| Field | Type | Description |
|-------|------|-------------|
| pid | int | OS process ID of the running pipeline |
| state | string | Engine state: starting, running, sleeping, stalled, completed, converged |
| phase | string | Current pipeline phase |
| agent | string | Active agent ("claude", "codex", "gemini") |
| iteration | int | Current iteration number |
| attempt | string | Retry attempt in "N/M" format |
| batch_size | int | Current batch size |
| health_score | number | Latest health score percentage |
| last_heartbeat | string | ISO 8601 timestamp of last heartbeat update (refreshed every 60s) |
| started_at | string | ISO 8601 timestamp when the pipeline started |
| elapsed_minutes | number | Total minutes since pipeline start |
| sleep_until | string/null | ISO 8601 timestamp when sleep ends (null if not sleeping) |
| sleep_reason | string/null | Reason for sleep (e.g., "quota_backoff", "rate_limit") |
| last_error | string/null | Last error message (truncated to 200 chars) |
| errors_this_iteration | int | Number of errors in the current iteration |
| recovered_from_error | bool | Whether the engine recovered from an error this iteration |

### final-validation.json

Location: `.gsd\health\final-validation.json`

Structured results from the final validation gate. Written when health reaches 100% and `Invoke-FinalValidation` runs.

```json
{
  "passed": true,
  "hard_failures": [],
  "warnings": ["NuGet vulnerabilities: 2 package(s) flagged"],
  "iteration": 12,
  "timestamp": "2026-03-03T14:30:00Z",
  "checks": {
    "dotnet_build": { "passed": true, "warnings": 0 },
    "npm_build": { "passed": true },
    "dotnet_test": { "passed": true, "summary": ["MyApp.Tests.csproj: Passed (42 tests)"] },
    "npm_test": { "passed": true },
    "sql": { "passed": true },
    "dotnet_audit": { "passed": false, "vulnerabilities": ["High: Package.Name 1.2.3"] },
    "npm_audit": { "passed": true }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| passed | bool | Overall result: false if any hard failure, true if only warnings or all clean |
| hard_failures | string[] | List of hard failure descriptions (blocks convergence) |
| warnings | string[] | List of warning descriptions (advisory, included in handoff) |
| iteration | int | Iteration when validation ran |
| timestamp | string | ISO 8601 timestamp |
| checks | object | Per-check results: `dotnet_build`, `npm_build`, `dotnet_test`, `npm_test`, `sql`, `dotnet_audit`, `npm_audit` |

Each check object has `passed` (bool) and optionally `skipped` (bool + `reason`), `errors` (string[]), `warnings` (int), `summary` (string[]), or `vulnerabilities` (string[]).

### developer-handoff.md

Location: Repository root (e.g., `C:\repos\my-app\developer-handoff.md`)

Auto-generated markdown file containing everything a developer needs to pick up the project. Created by `New-DeveloperHandoff` in the pipeline's `finally` block. Committed and pushed to the remote repository automatically.

Sections: Header (project metadata), Quick Start (auto-detected build commands), Database Setup (SQL files + connection strings), Environment Configuration (config files + .env), Project Structure (file tree), Requirements Status (grouped table), Validation Results, Known Issues (remaining gaps + recent errors), Health Progression (ASCII chart), Cost Summary (by agent and phase).

This file is overwritten on each pipeline run.

### health-history.jsonl

Location: `.gsd\health\health-history.jsonl`

One JSON object per line, tracking health progression over iterations. Used by the token cost calculator for historical progression analysis.

### requirements-matrix.json

Location: `.gsd\health\requirements-matrix.json`

Every requirement extracted from specs with current status (pending, in_progress, completed, blocked).

### queue-current.json

Location: `.gsd\generation-queue\queue-current.json`

Prioritized batch of items for the next iteration. Managed by the Plan phase.

### blueprint.json

Location: `.gsd\blueprint\blueprint.json`

Blueprint manifest with every file the project needs. Generated by the Blueprint phase. Each item has:

| Field | Description |
|-------|-------------|
| id | Unique identifier |
| type | Item type (sql-migration, stored-procedure, controller, component, etc.) |
| path | Target file path |
| status | pending, partial, completed |
| description | What the item should contain |
| dependencies | Other item IDs this depends on |

### token-usage.jsonl

Location: `.gsd\costs\token-usage.jsonl`

Append-only log of actual API token costs for every agent call. One JSON object per line. Survives crashes and pipeline restarts. This is the ground truth for cost data -- `cost-summary.json` can always be rebuilt from this file.

```json
{"timestamp":"2026-03-02T14:30:00Z","pipeline":"converge","iteration":5,"phase":"code-review","agent":"claude","batch_size":8,"success":true,"is_fallback":false,"tokens":{"input":45000,"output":3200,"cached":12000},"cost_usd":0.183,"duration_seconds":120,"num_turns":4}
```

| Field | Type | Description |
|-------|------|-------------|
| timestamp | string | ISO 8601 timestamp of the agent call |
| pipeline | string | "converge" or "blueprint" |
| iteration | int | Iteration number |
| phase | string | Pipeline phase (e.g., "code-review", "execute", "build", "verify") |
| agent | string | "claude", "codex", or "gemini" |
| batch_size | int | Number of items in the batch |
| success | bool | Whether the agent call succeeded |
| is_fallback | bool | Whether this was a fallback agent call |
| tokens | object | `{ input, output, cached }` -- token counts |
| cost_usd | number | Cost in USD (from CLI or calculated from token counts × pricing) |
| duration_seconds | number | Wall-clock time for the call |
| num_turns | int | Number of agent turns (Claude only, 0 for others) |

### cost-summary.json

Location: `.gsd\costs\cost-summary.json`

Rolling totals updated after each agent call. Can be rebuilt from `token-usage.jsonl` via `Rebuild-CostSummary` if corrupted.

```json
{
  "project_start": "2026-03-01T10:00:00Z",
  "last_updated": "2026-03-02T14:30:00Z",
  "total_calls": 47,
  "total_cost_usd": 12.45,
  "total_tokens": { "input": 2100000, "output": 156000, "cached": 890000 },
  "by_agent": {
    "claude": { "calls": 28, "cost_usd": 7.20, "tokens": { "input": 1400000, "output": 84000, "cached": 700000 } },
    "codex": { "calls": 12, "cost_usd": 3.90, "tokens": { "input": 500000, "output": 60000, "cached": 150000 } },
    "gemini": { "calls": 7, "cost_usd": 1.35, "tokens": { "input": 200000, "output": 12000, "cached": 40000 } }
  },
  "by_phase": {
    "code-review": { "calls": 10, "cost_usd": 2.10 },
    "research": { "calls": 10, "cost_usd": 1.35 },
    "plan": { "calls": 10, "cost_usd": 1.80 },
    "execute": { "calls": 10, "cost_usd": 3.20 }
  },
  "runs": [
    { "started": "2026-03-01T10:00:00Z", "ended": "2026-03-01T12:30:00Z", "calls": 25, "cost_usd": 6.00 },
    { "started": "2026-03-02T09:00:00Z", "ended": null, "calls": 22, "cost_usd": 6.45 }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| project_start | string | ISO 8601 timestamp of first tracked agent call |
| last_updated | string | ISO 8601 timestamp of last update |
| total_calls | int | Total number of agent calls tracked |
| total_cost_usd | number | Total cost across all agents |
| total_tokens | object | `{ input, output, cached }` -- aggregate token counts |
| by_agent | object | Per-agent breakdown (calls, cost_usd, tokens) |
| by_phase | object | Per-phase breakdown (calls, cost_usd) |
| runs | array | Each pipeline run with start/end times, calls, and cost |

## Token Cost Calculator Configuration

The token cost calculator uses several configurable constants defined in the script:

### Token estimates per item type

| Item Type | Output Tokens | Examples |
|-----------|---------------|---------|
| sql-migration | 1,000 | CREATE TABLE, ALTER TABLE |
| stored-procedure | 2,000 | CRUD procedures |
| controller | 5,000 | API controllers |
| service | 3,500 | Business logic services |
| dto | 1,500 | Data transfer objects |
| component / react-component | 4,000 | React UI components |
| hook | 2,500 | React hooks |
| middleware | 2,000 | API middleware |
| config | 1,500 | Configuration files |
| test | 3,000 | Unit/integration tests |
| compliance | 2,000 | Audit, logging, security |
| routing | 1,500 | Route definitions |
| (default) | 3,500 | Any unrecognized type |

### Context scaling formulas

| Context Type | Formula | Cap |
|--------------|---------|-----|
| Blueprint context | total_items * 200 + 5,000 | 100,000 tokens |
| File map | total_items * 50 | 30,000 tokens |

### Client quote complexity tiers

| Tier | Item Count | Suggested Markup |
|------|-----------|-----------------|
| Standard | <= 100 | 5x |
| Complex | <= 250 | 7x |
| Enterprise | <= 500 | 7-10x |
| Enterprise+ | > 500 | 10x |

### Subscription costs (for comparison)

| Service | Monthly Cost |
|---------|-------------|
| Claude Pro | $20 |
| Claude Max | $100-200 |
| ChatGPT Plus | $20 |
| ChatGPT Pro | $200 |
| Gemini Advanced | $20 |
| Minimum bundle (Pro tiers) | $60/month |

## Supervisor Configuration

### supervisor-state.json

Location: `.gsd\supervisor\supervisor-state.json`

Tracks supervisor recovery attempts across pipeline restarts. Auto-managed.

```json
{
  "pipeline": "converge",
  "attempt": 2,
  "max_attempts": 5,
  "start_time": "2026-03-02T10:00:00Z",
  "strategies_tried": [
    {"category": "build_loop", "fix": "Added namespace constraints to prompt hints", "attempt": 1}
  ],
  "diagnoses": [
    {"attempt": 1, "category": "build_loop", "root_cause": "DTO namespace mismatch"}
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| pipeline | string | "converge" or "blueprint" |
| attempt | int | Current attempt number |
| max_attempts | int | Maximum attempts before escalation |
| start_time | string | ISO 8601 timestamp of first attempt |
| strategies_tried | array | List of category + fix combinations already attempted (prevents repeats) |
| diagnoses | array | Root-cause diagnosis from each attempt |

### last-run-summary.json

Location: `.gsd\supervisor\last-run-summary.json`

Written by the pipeline before exit so the supervisor knows what happened.

```json
{
  "pipeline": "converge",
  "exit_reason": "stalled",
  "health": 65.0,
  "iteration": 8,
  "stall_count": 3,
  "batch_size": 4,
  "timestamp": "2026-03-02T12:30:00Z"
}
```

### agent-map.json

Location: `%USERPROFILE%\.gsd-global\config\agent-map.json`

Controls parallel sub-task execution and council reviewer pools.

```json
{
  "execute_parallel": {
    "enabled": true,
    "max_concurrent": 3,
    "agent_pool": ["codex", "claude", "gemini", "kimi", "deepseek", "glm5", "minimax"],
    "strategy": "round-robin",
    "fallback_to_sequential": true,
    "subtask_timeout_minutes": 30
  },
  "council": {
    "reviewers": ["codex", "gemini", "kimi", "deepseek", "glm5", "minimax"]
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | bool | true | Master switch. `false` = original monolithic behavior |
| max_concurrent | int | 3 | Max parallel agent jobs per wave. Set to 1 for sequential round-robin |
| agent_pool | string[] | ["codex","claude","gemini","kimi","deepseek","glm5","minimax"] | Agents to rotate through. Order = priority. REST agents without API keys are excluded at runtime. |
| strategy | string | "round-robin" | `"round-robin"` rotates agents across sub-tasks; `"all-same"` uses first agent for all |
| fallback_to_sequential | bool | true | If all parallel sub-tasks fail, fall back to monolithic single-agent call |
| subtask_timeout_minutes | int | 30 | Per-subtask watchdog timeout in minutes |

To disable parallel execution entirely, set `enabled` to `false`. The monolithic path is preserved as-is.

#### council.reviewers

Controls which agents participate in council reviews. REST agents in this list are dynamically added to the council reviewer pool using the `openai-compat-review.md` prompt template.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| reviewers | string[] | ["codex","gemini","kimi","deepseek","glm5","minimax"] | Agents available for council reviews. REST agents without API keys are excluded at runtime. |

### agent-override.json

Location: `.gsd\supervisor\agent-override.json`

Allows the supervisor to reassign phases to different agents.

```json
{
  "execute": "claude",
  "build": "gemini"
}
```

Valid agent values: `"claude"`, `"codex"`, `"gemini"`, `"kimi"`, `"deepseek"`, `"glm5"`, `"minimax"`

### pattern-memory.jsonl

Location: `%USERPROFILE%\.gsd-global\supervisor\pattern-memory.jsonl`

Cross-project failure pattern database (append-only JSONL). Each line:

```json
{"pattern": "build_error_missing_namespace", "category": "build_loop", "fix": "Rewrite prompt-hints to specify exact namespace for DTOs", "success": true, "project": "patient-portal", "timestamp": "2026-03-02T15:00:00Z"}
```

| Field | Type | Description |
|-------|------|-------------|
| pattern | string | Short description of the failure pattern |
| category | string | Failure category (stuck_requirements, build_loop, etc.) |
| fix | string | Description of the fix that was applied |
| success | boolean | Whether the fix resolved the issue |
| project | string | Project name where this pattern was learned |
| timestamp | string | ISO 8601 timestamp |

### errors.jsonl

Location: `.gsd\logs\errors.jsonl`

Structured error log (append-only JSONL). Every error captured by the engine is written here for supervisor analysis and debugging.

```json
{"timestamp": "2026-03-02T10:30:00Z", "category": "agent_crash", "phase": "execute", "iteration": 3, "message": "codex exit code 2", "resolution": "Batch reduced to 4"}
```

| Field | Type | Description |
|-------|------|-------------|
| timestamp | string | ISO 8601 timestamp |
| category | string | Error category (see below) |
| phase | string | Pipeline phase where error occurred |
| iteration | int | Iteration number |
| message | string | Error description |
| resolution | string | Action taken to resolve |

Error categories: `quota`, `network`, `disk`, `corrupt_json`, `boundary_violation`, `agent_crash`, `health_regression`, `spec_conflict`, `watchdog_timeout`, `build_fail`, `fallback_success`, `validation_fail`

### error-context.md

Location: `.gsd\supervisor\error-context.md`

Written by the supervisor after each failed pipeline run. Contains structured error information that is automatically injected into all agent prompts via `Local-ResolvePrompt`. This tells agents what went wrong and how to avoid repeating the same mistakes.

Format:

```markdown
## Error Context (Supervisor Attempt N)

### Last Iteration Errors
- [error type]: [description]
- [error type]: [description]

### Root Cause
[AI-generated root cause analysis]

### Instructions
DO NOT [specific instruction to avoid the failure pattern]
ALWAYS [specific instruction to fix the issue]
```

This file persists across pipeline restarts within a supervisor recovery cycle. It is cleared when supervisor state is manually reset (`Remove-Item .gsd\supervisor\error-context.md`).

### prompt-hints.md

Location: `.gsd\supervisor\prompt-hints.md`

Written by `Invoke-SupervisorFix` based on AI diagnosis. Contains persistent constraints and instructions that modify agent behavior. Automatically appended to all agent prompts via `Local-ResolvePrompt`.

Format:

```markdown
## Supervisor Hints

- Always include TRY/CATCH in stored procedures
- Use explicit table aliases in all SQL joins
- Use namespace MyApp.Core.DTOs for all DTO classes (not MyApp.DTOs)
```

Unlike error-context.md which describes what happened, prompt-hints.md describes what agents should do differently going forward. Both files are appended to prompts for all agents (Claude review, Claude plan, Codex execute, Codex build).

### escalation-report.md

Location: `.gsd\supervisor\escalation-report.md`

Generated by `New-EscalationReport` when the supervisor exhausts all recovery attempts (default 5). Contains comprehensive diagnostic data for human intervention.

Sections:

| Section | Content |
|---------|---------|
| Summary | What was tried, how many attempts, time elapsed |
| Diagnoses | Root-cause analysis from each attempt (from diagnosis-{N}.md files) |
| Strategies Tried | Category + fix combinations attempted |
| Error Statistics | Aggregated error counts by type, phase, and agent |
| Health Trajectory | Health score at each attempt |
| Recommended Actions | Specific human intervention steps based on failure pattern |

### diagnosis-{N}.md

Location: `.gsd\supervisor\diagnosis-{N}.md`

Root-cause analysis generated by `Invoke-SupervisorDiagnosis` for attempt N. One file per supervisor attempt. Contains the structured diagnosis from Claude including root cause, category, failing phase, and recommended fix strategy.

### Supervisor Constants

| Constant | Default | Description |
|----------|---------|-------------|
| SUPERVISOR_MAX_ATTEMPTS | 5 | Maximum recovery attempts before escalation |
| SUPERVISOR_TIMEOUT_HOURS | 24 | Wall-clock time limit for supervisor loop |
| AGENT_WATCHDOG_MINUTES | 30 | Watchdog timeout per agent call (kills hung processes) |
| RETRY_MAX | 3 | Maximum retries per agent call |
| MIN_BATCH_SIZE | 2 | Minimum batch size after reduction |
| BATCH_REDUCTION_FACTOR | 0.5 | Batch reduction multiplier on failure |
| RETRY_DELAY_SECONDS | 10 | Delay between retries |

### Default Batch Sizes

| Pipeline | Default | Description |
|----------|---------|-------------|
| Blueprint (-BatchSize) | 15 | Items per build cycle |
| Convergence (-BatchSize) | 8 | Items per execute cycle |

## Environment Variables

### API Key Variables

#### CLI Agent Keys

Set during installation (Step 0 of `install-gsd-global.ps1`) or via `setup-gsd-api-keys.ps1`. Stored as persistent User-level environment variables (Windows registry). API keys bypass interactive rate limits for higher throughput.

| Variable | Used By | Expected Prefix | Key Source |
|----------|---------|----------------|-----------|
| ANTHROPIC_API_KEY | Claude Code CLI | sk-ant- | https://console.anthropic.com/settings/keys |
| OPENAI_API_KEY | Codex CLI | sk- | https://platform.openai.com/api-keys |
| GOOGLE_API_KEY | Gemini CLI | AIza | https://aistudio.google.com/apikey |

Manage CLI agent API keys:

```powershell
# Show current status
.\scripts\setup-gsd-api-keys.ps1 -Show

# Update keys interactively
.\scripts\setup-gsd-api-keys.ps1

# Remove all keys
.\scripts\setup-gsd-api-keys.ps1 -Clear
```

#### REST Agent Keys

Set manually via PowerShell. REST agents without keys are automatically excluded from the rotation pool (no error, just skipped).

| Variable | Used By | Provider | Key Source |
|----------|---------|----------|-----------|
| KIMI_API_KEY | Kimi K2.5 | Moonshot AI | https://platform.moonshot.ai |
| DEEPSEEK_API_KEY | DeepSeek V3 | DeepSeek | https://platform.deepseek.com |
| GLM_API_KEY | GLM-5 | Zhipu AI | https://z.ai |
| MINIMAX_API_KEY | MiniMax M2.5 | MiniMax | https://platform.minimaxi.com |

Set REST agent keys (User-level, persists across sessions):

```powershell
[System.Environment]::SetEnvironmentVariable("KIMI_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("DEEPSEEK_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("GLM_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("MINIMAX_API_KEY", "your-key-here", "User")
```

The engine resolves keys in order: Process → User → Machine. Keys set at User or Machine level are auto-loaded into the current session during preflight, so no terminal restart is needed.

Verify REST agent keys are detected:

```powershell
# Run any pipeline -- preflight shows REST agent status:
#   [OK] KIMI_API_KEY set (REST agent: kimi)
#   [OK] DEEPSEEK_API_KEY set (REST agent: deepseek)
#   [OK] GLM_API_KEY set (REST agent: glm5)
#   [OK] MINIMAX_API_KEY set (REST agent: minimax)
#   4 REST agent(s) available for rotation
```

Remove REST agent keys:

```powershell
[System.Environment]::SetEnvironmentVariable("KIMI_API_KEY", $null, "User")
[System.Environment]::SetEnvironmentVariable("DEEPSEEK_API_KEY", $null, "User")
[System.Environment]::SetEnvironmentVariable("GLM_API_KEY", $null, "User")
[System.Environment]::SetEnvironmentVariable("MINIMAX_API_KEY", $null, "User")
```

### System Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| USERPROFILE | All scripts | Home directory for .gsd-global |
| USERNAME | Notifications | Auto-generates ntfy topic |
| PATH | CLI wrappers | Must include .gsd-global\bin |

## VS Code Integration

### tasks.json

Two tasks are registered during installation:

- **GSD: Convergence Loop** -- runs gsd-converge
- **GSD: Blueprint Pipeline** -- runs gsd-blueprint

### Keyboard Shortcuts

Installed by `install-gsd-keybindings.ps1` (Ctrl+Shift+G chord prefix):

| Shortcut | Action |
|----------|--------|
| Ctrl+Shift+G, C | Run convergence loop |
| Ctrl+Shift+G, B | Run blueprint pipeline |
| Ctrl+Shift+G, S | Show status dashboard |
