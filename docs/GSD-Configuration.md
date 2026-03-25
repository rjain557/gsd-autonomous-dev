# GSD Configuration Reference

## Global Configuration

### global-config.json

Location: `%USERPROFILE%\.gsd-global\config\global-config.json`

```json
{
  "git": {
    "enabled": true,
    "commit_on_iteration": true,
    "push_on_iteration": false,
    "push_on_terminal": true,
    "tag_on_terminal": true
  },
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
  },
  "agent_models": {
    "claude": "claude-sonnet-4-6",
    "gemini": "gemini-3.0-pro",
    "codex": "gpt-5.4"
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

#### git

Controls commit/push behavior during autonomous runs. The default is local commits during iterations, with remote push reserved for terminal states.

```json
"git": {
  "enabled": true,
  "commit_on_iteration": true,
  "push_on_iteration": false,
  "push_on_terminal": true,
  "tag_on_terminal": true,
  "commit_developer_handoff": true
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Master switch for git automation |
| `commit_on_iteration` | bool | true | Commit generated work during iterations |
| `push_on_iteration` | bool | false | Push after each iteration commit |
| `push_on_terminal` | bool | true | Push on converged/stalled/max-iteration exit |
| `tag_on_terminal` | bool | true | Create terminal tags on successful completion |
| `commit_developer_handoff` | bool | true | Commit the generated developer handoff report |

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

#### agent_models

Controls which exact model version each CLI agent uses. Defaults are set in the hardening module and overridden from this config at startup. Changing these values does not require re-running the installer — the engine reads them on every pipeline start.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| claude | string | `claude-sonnet-4-6` | Model passed to `claude --model`. Use `claude-opus-4-6` for higher quality at higher cost |
| gemini | string | `gemini-3.0-pro` | Model passed to `gemini --model` |
| codex | string | `gpt-5.4` | Model passed to `codex exec --model` |

These values are passed via `--model` flag to every CLI invocation (both production dispatch in `Invoke-WithRetry` and fallback paths). REST agents (Kimi, DeepSeek, GLM-5, MiniMax) use the `model_id` field in `model-registry.json` instead.

To upgrade a model without reinstalling:
```json
"agent_models": {
  "claude": "claude-opus-4-6",
  "gemini": "gemini-3.0-pro",
  "codex": "gpt-5.4"
}
```

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

#### differential_review

Controls differential code review (review only changed files).

```json
"differential_review": {
    "enabled": true,
    "max_diff_pct": 50,
    "cache_ttl_iterations": 10
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Enable differential review |
| `max_diff_pct` | int | 50 | Fall back to full review if >N% files changed |
| `cache_ttl_iterations` | int | 10 | Rebuild cache every N iterations |

#### pre_execute_gate

Controls the pre-execute compile gate (build validation before commit).

```json
"pre_execute_gate": {
    "enabled": true,
    "max_fix_attempts": 2,
    "include_tests": false
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Enable pre-execute gate |
| `max_fix_attempts` | int | 2 | Fix attempts before fallthrough |
| `include_tests` | bool | false | Also run tests pre-commit |

#### acceptance_tests

Controls per-requirement acceptance test execution.

```json
"acceptance_tests": {
    "enabled": true,
    "block_on_failure": false,
    "test_types": ["file_exists", "pattern_match", "build_check", "dotnet_test", "npm_test"],
    "max_test_time_seconds": 60
}
```

#### api_contract_validation

Controls contract-first API validation.

```json
"api_contract_validation": {
    "enabled": true,
    "block_on_missing": true,
    "warn_on_undocumented": true,
    "scan_patterns": ["*Controller*.cs", "*controller*.ts", "*routes*.ts"]
}
```

#### visual_validation

Controls Figma screenshot diff validation.

```json
"visual_validation": {
    "enabled": true,
    "max_diff_pct": 15,
    "screenshot_dir": "design/screenshots",
    "viewport_width": 1280,
    "viewport_height": 720,
    "block_on_high_diff": false,
    "playwright_timeout_ms": 30000
}
```

#### design_token_enforcement

Controls design token compliance scanning.

```json
"design_token_enforcement": {
    "enabled": true,
    "block_on_violation": false,
    "scan_extensions": [".css", ".scss", ".tsx", ".jsx", ".ts"],
    "allowed_raw_colors": ["#000000", "#ffffff", "transparent", "inherit", "currentColor"]
}
```

#### compliance_engine

Controls per-iteration compliance audit, DB migration validation, and PII tracking.

```json
"compliance_engine": {
    "per_iteration_audit": { "enabled": true, "block_on_critical": true },
    "db_migration": { "enabled": true, "check_foreign_keys": true, "check_index_coverage": true, "check_seed_integrity": true },
    "pii_tracking": { "enabled": true, "pii_fields": ["email","ssn","phone","address","credit_card","password"], "check_logging": true, "check_encryption": true, "check_ui_masking": true }
}
```

#### speed_optimizations

Controls speed optimization features.

```json
"speed_optimizations": {
    "conditional_research_skip": { "enabled": true, "skip_when_health_improving": true, "min_health_delta": 1 },
    "smart_batch_sizing": { "enabled": true, "context_limit_tokens": 128000, "utilization_target": 0.7, "min_batch": 2, "max_batch": 12 },
    "incremental_file_map": { "enabled": true },
    "prompt_deduplication": { "enabled": true, "inject_security_standards": true, "inject_coding_conventions": true }
}
```

#### agent_intelligence

Controls agent performance scoring and warm-start features.

```json
"agent_intelligence": {
    "performance_scoring": { "enabled": true, "min_samples": 3, "recalculate_interval": 5 },
    "warm_start": { "enabled": true, "cache_patterns": true, "share_across_projects": true }
}
```

#### loc_tracking

Tracks AI-generated lines of code per iteration and computes cost-per-line metrics.

```json
"loc_tracking": {
    "enabled": true,
    "include_extensions": [".cs", ".ts", ".tsx", ".js", ".jsx", ".css", ".scss", ".html", ".sql", ".json", ".md", ".ps1", ".py", ".yaml", ".yml"],
    "exclude_paths": [".gsd/", "node_modules/", "bin/", "obj/", "dist/", "build/", ".vs/", ".idea/", "*.min.*", "*.bundle.*", "package-lock.json", "yarn.lock"],
    "track_per_file": true,
    "cost_per_line": true
}
```

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | bool | Master toggle for LOC tracking |
| `include_extensions` | array | Source file extensions to count (others excluded) |
| `exclude_paths` | array | Path patterns to exclude from counting |
| `track_per_file` | bool | Include per-file breakdown (top 20) in each iteration |
| `cost_per_line` | bool | Cross-reference cost-summary.json to compute $/line |

Output: `.gsd/costs/loc-metrics.json` — per-iteration and cumulative LOC with cost-per-line.

#### runtime_smoke_test

Controls the runtime smoke test that runs as part of final validation (checks 8-10).

```json
"runtime_smoke_test": {
    "enabled": true,
    "startup_timeout_seconds": 30,
    "max_endpoints": 50,
    "block_on_500": true,
    "block_on_di_error": true,
    "block_on_fk_violation": true,
    "skip_if_no_dotnet": true
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Master toggle for runtime smoke testing |
| `startup_timeout_seconds` | int | 30 | Max seconds to wait for app startup |
| `max_endpoints` | int | 50 | Max API endpoints to test (prevents runaway on large APIs) |
| `block_on_500` | bool | true | Any HTTP 500 response is a hard failure (sets health to 99%) |
| `block_on_di_error` | bool | true | DI container errors are hard failures |
| `block_on_fk_violation` | bool | true | FK constraint violations are hard failures |
| `skip_if_no_dotnet` | bool | true | Skip runtime test if no .NET project detected |

Disable: set `runtime_smoke_test.enabled` to `false`. The engine falls back to original 7-check validation.

#### partitioned_code_review

Controls 3-way parallel code review with agent rotation.

```json
"partitioned_code_review": {
    "enabled": true,
    "rotation_strategy": "round-robin",
    "validate_against_figma": true,
    "validate_against_spec": true,
    "fallback_to_single": true,
    "parallel_timeout_minutes": 15
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Master toggle for partitioned review |
| `rotation_strategy` | string | "round-robin" | Agent rotation strategy. "round-robin" rotates A/B/C across claude/gemini/codex every iteration |
| `validate_against_figma` | bool | true | Include Figma deliverable paths in review prompts |
| `validate_against_spec` | bool | true | Include spec document paths in review prompts |
| `fallback_to_single` | bool | true | Fall back to single-agent Claude review if partitioned review fails |
| `parallel_timeout_minutes` | int | 15 | Max time for parallel review jobs before timeout |

Disable: set `partitioned_code_review.enabled` to `false`. The engine uses single-agent Claude review.

**Gemini prerequisite**: Gemini CLI requires `experimental.plan: true` in its settings for `--approval-mode plan` (used during read-only review partitions). Run `gemini` once interactively and enable this setting, or partitioned reviews assigned to Gemini will fail.

Rotation schedule (repeats every 3 iterations):

| Iteration | Partition A | Partition B | Partition C |
|-----------|-------------|-------------|-------------|
| 1, 4, 7 | Claude | Gemini | Codex |
| 2, 5, 8 | Gemini | Codex | Claude |
| 3, 6, 9 | Codex | Claude | Gemini |

Output files: `.gsd/code-review/rotation-history.jsonl`, `.gsd/code-review/coverage-matrix.json`

#### maintenance_mode

Controls post-launch maintenance features: bug fix mode, incremental updates, and scoped convergence.

```json
"maintenance_mode": {
    "enabled": true,
    "fix_defaults": { "max_iterations": 5, "batch_size": 3, "skip_research": true },
    "scope_filter": { "enabled": true, "review_all_on_scope": true, "scope_plan_and_execute": true },
    "incremental_phases": { "enabled": true, "preserve_satisfied": true, "add_spec_version_tag": true }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `fix_defaults.max_iterations` | int | Default max iterations for `gsd-fix` |
| `fix_defaults.batch_size` | int | Default batch size for `gsd-fix` |
| `fix_defaults.skip_research` | bool | Skip research phase for bug fixes (saves tokens) |
| `scope_filter.review_all_on_scope` | bool | Code-review sees all requirements even when scoped |
| `scope_filter.scope_plan_and_execute` | bool | Plan/execute restricted to scoped items |
| `incremental_phases.preserve_satisfied` | bool | Never modify satisfied requirements during incremental |
| `incremental_phases.add_spec_version_tag` | bool | Tag new requirements with spec_version field |

#### council_requirements

Controls the 3-phase parallel council requirements extraction pipeline (`gsd-verify-requirements` command and convergence Phase 0 integration).

```json
"council_requirements": {
    "enabled": true,
    "agents": ["claude", "codex", "gemini"],
    "min_agents_for_merge": 2,
    "chunk_size": 10,
    "timeout_seconds": 600,
    "cooldown_between_agents": 5,
    "fallback_to_single": true
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Enable council extraction in convergence Phase 0 |
| `agents` | string[] | ["claude","codex","gemini"] | Agents to use (partitioned round-robin) |
| `min_agents_for_merge` | int | 2 | Minimum agents required to produce valid output |
| `chunk_size` | int | 10 | Spec files per LLM call (smaller = less tokens per call) |
| `timeout_seconds` | int | 600 | Timeout per chunk (total timeout = chunks × timeout + 120s) |
| `cooldown_between_agents` | int | 5 | Seconds between sequential chunks within each agent |
| `fallback_to_single` | bool | true | Fall back to single-agent create-phases if council fails |

Prompt templates: `%USERPROFILE%\.gsd-global\prompts\council\requirements-extract-chunk.md`, `requirements-verify.md`, `requirements-synthesize.md`, `requirements-synthesize-partial.md`.

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
| codex | gpt-5.4, gpt-5.4-codex, gpt-5.3-codex, codex-mini-latest | Build, Execute |
| codex_gpt51 | gpt-5.1-codex, gpt-5.1 | (alternative code gen) |
| gemini | gemini-3.0-pro, gemini-3-pro, gemini-3.1-pro-preview, gemini-2.5-pro | Research, Spec-fix |
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

## V3 Configuration Reference

The following sections document configuration options specific to the V3 pipeline, found in `v3/config/global-config.json`.

### execute_model_pool

Controls the multi-model code generation pool used during the execute phases.

```json
{
  "execute_model_pool": {
    "enabled": true,
    "strategy": "round-robin-weighted",
    "models": [
      { "name": "codex-mini", "provider": "openai", "weight": 3 },
      { "name": "deepseek", "provider": "deepseek", "weight": 2 },
      { "name": "kimi", "provider": "kimi", "weight": 1 },
      { "name": "minimax", "provider": "minimax", "weight": 1 },
      { "name": "claude-sonnet", "provider": "anthropic", "weight": 1 },
      { "name": "gemini-flash", "provider": "google", "weight": 1 },
      { "name": "glm5", "provider": "glm", "weight": 1 }
    ]
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | boolean | true | Enable multi-model execute pool. When false, only Codex Mini is used. |
| strategy | string | "round-robin-weighted" | Model selection strategy. Currently only "round-robin-weighted" is supported. |
| models | array | (see above) | List of models in the pool. Each entry has a name, provider, and weight. |
| models[].name | string | -- | Display name for the model, used in logs and cost tracking |
| models[].provider | string | -- | Provider identifier, used to select the correct API client |
| models[].weight | integer | 1 | Selection weight. Higher weight means the model is selected more often. A weight of 3 means 3x more likely than weight 1. |

**Notes**:
- Models without a configured API key (environment variable) are automatically excluded at runtime
- When a model hits a rate limit, it is temporarily removed from the rotation until the limit resets
- Add new models by appending entries to the `models` array with the appropriate provider

### anti_plateau

Controls the graduated escalation system that breaks through health score plateaus.

```json
{
  "anti_plateau": {
    "enabled": true,
    "warn_at_zero_delta": 3,
    "escalate_at_zero_delta": 4,
    "skip_at_zero_delta": 5,
    "max_zero_delta": 5,
    "deferred_recheck_every": 10
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | boolean | true | Enable anti-plateau protection |
| warn_at_zero_delta | integer | 3 | Number of consecutive zero-delta iterations before logging a warning and flagging stuck requirements |
| escalate_at_zero_delta | integer | 4 | Number of consecutive zero-delta iterations before recommending Opus escalation |
| skip_at_zero_delta | integer | 5 | Number of consecutive zero-delta iterations before deferring stuck requirements |
| max_zero_delta | integer | 5 | Hard maximum; pipeline halts if zero-delta exceeds this without resolution |
| deferred_recheck_every | integer | 10 | Re-evaluate deferred requirements every N iterations to check if dependencies resolved |

### spec_alignment

Controls the specification alignment guard that prevents code generation against stale specs.

```json
{
  "spec_alignment": {
    "enabled": true,
    "block_on_critical_drift_pct": 20,
    "warn_on_moderate_drift_pct": 5,
    "check_every_n_iterations": 10
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | boolean | true | Enable spec alignment checking |
| block_on_critical_drift_pct | integer | 20 | Percentage drift that blocks the pipeline. Must fix specs before continuing. |
| warn_on_moderate_drift_pct | integer | 5 | Percentage drift that triggers a warning but allows the pipeline to continue |
| check_every_n_iterations | integer | 10 | How often to re-check alignment during long runs (in addition to pre-pipeline check) |

### decomposition_budget

Controls how large requirements are split into smaller sub-requirements.

```json
{
  "decomposition_budget": {
    "max_new_subreqs_per_iteration": 20,
    "max_depth": 4,
    "defer_excess": true
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| max_new_subreqs_per_iteration | integer | 20 | Maximum number of new sub-requirements that can be created in a single iteration. Prevents runaway decomposition. |
| max_depth | integer | 4 | Maximum nesting depth for decomposed requirements. A depth-4 sub-requirement cannot be further decomposed. |
| defer_excess | boolean | true | When true, excess sub-requirements beyond the per-iteration limit are deferred to the next iteration rather than dropped. |

### phase_model_overrides

Override the default model assignment for specific phases. By default, all reasoning phases use Claude Sonnet. This setting allows you to assign different models to specific phases.

```json
{
  "phase_model_overrides": {
    "research": "sonnet",
    "verify": "sonnet",
    "review": "sonnet",
    "spec-align": "sonnet"
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| research | string | "sonnet" | Model for the research phase. Options: "sonnet", "gemini" |
| verify | string | "sonnet" | Model for the verify phase. Options: "sonnet", "gemini" |
| review | string | "sonnet" | Model for the review phase. Options: "sonnet" |
| spec-align | string | "sonnet" | Model for the spec alignment check. Options: "sonnet" |

**Notes**:
- The plan and execute phases cannot be overridden (plan always uses Sonnet, execute always uses the execute pool)
- Setting a phase to "gemini" requires a valid GEMINI_API_KEY
- The "sonnet" option always resolves to the model specified in the Anthropic API client (currently claude-sonnet-4-6)

### multi_pipeline

Controls multi-frontend parallel pipeline execution.

```json
{
  "multi_pipeline": {
    "enabled": false,
    "strategy": "per-interface",
    "max_parallel": 3,
    "shared_phases": ["cache-warm", "spec-gate", "spec-align"]
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | boolean | false | Enable multi-pipeline mode. When false, all interfaces are processed in a single pipeline. |
| strategy | string | "per-interface" | Pipeline splitting strategy. Currently only "per-interface" is supported. |
| max_parallel | integer | 3 | Maximum number of frontend pipelines running simultaneously. Higher values increase API pressure but reduce wall-clock time. |
| shared_phases | string[] | ["cache-warm", "spec-gate", "spec-align"] | Phases that run once and benefit all pipelines. These are not repeated per-interface. |

**Notes**:
- Multi-pipeline mode requires that the repository has multiple detected interfaces (web, mcp-admin, browser, mobile, etc.)
- Sequential layers (database, backend, shared) always run before parallel frontend pipelines
- Each frontend pipeline gets a proportional share of the total budget based on requirement count
- See the [GSD Multi-Frontend Pipeline Guide](GSD-Multi-Frontend.md) for detailed documentation

### cost_alerts

Controls per-requirement cost alerting thresholds.

```json
{
  "cost_alerts": {
    "per_requirement_warn_usd": 2.00,
    "per_requirement_escalate_usd": 5.00,
    "per_requirement_hard_cap_usd": 10.00,
    "action_at_hard_cap": "defer"
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| per_requirement_warn_usd | float | 2.00 | Cost threshold (in USD) that triggers a warning for a single requirement |
| per_requirement_escalate_usd | float | 5.00 | Cost threshold that triggers an escalation alert |
| per_requirement_hard_cap_usd | float | 10.00 | Maximum cost allowed for a single requirement before automatic action |
| action_at_hard_cap | string | "defer" | Action when a requirement hits the hard cap. Options: "defer" (mark as deferred), "skip" (skip entirely) |

**Notes**:
- These thresholds apply to the cumulative cost of a single requirement across all iterations
- Cost is tracked per-requirement in `.gsd/costs/cost-summary.json`
- A requirement that costs $10+ is typically a sign that it needs decomposition into smaller sub-requirements

### git_commits

Controls automatic git commit behavior during pipeline execution.

```json
{
  "git_commits": {
    "per_iteration": true,
    "include_health_in_message": true,
    "timeout_seconds": 60
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| per_iteration | boolean | true | Commit all changes after each iteration completes |
| include_health_in_message | boolean | true | Include the current health percentage in the commit message |
| timeout_seconds | integer | 60 | Maximum time (in seconds) allowed for git operations. If exceeded, the commit is skipped and the pipeline continues. |

**Notes**:
- Git commits are always local; the pipeline does not push to remote unless configured separately
- Commit messages include the iteration number, health score, and number of requirements processed
- If a git commit fails (e.g., due to lock contention), the pipeline logs a warning and continues without committing

### existing_codebase_mode

Controls behavior when running `gsd-existing.ps1` for existing codebases.

```json
{
  "existing_codebase_mode": {
    "deep_extraction": true,
    "code_inventory_on_start": true,
    "verify_by_reading_code": true,
    "skip_satisfied_in_execute": true,
    "stub_detection_patterns": ["TODO", "FILL", "NotImplementedException", "throw new NotImplementedException"]
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| deep_extraction | boolean | true | Use extended token limits (16K, 32K auto-retry) for large spec sets |
| code_inventory_on_start | boolean | true | Scan entire codebase before satisfaction verification |
| verify_by_reading_code | boolean | true | Read actual code to verify satisfaction (not just file existence) |
| skip_satisfied_in_execute | boolean | true | Skip already-satisfied requirements in execute phase |
| stub_detection_patterns | string[] | ["TODO", "FILL", "NotImplementedException", "throw new NotImplementedException"] | Patterns that indicate incomplete implementation |

### smoke_test

Controls smoke test behavior and tiered cost optimization.

```json
{
  "smoke_test": {
    "max_cycles": 3,
    "fix_model": "claude",
    "cost_optimize": true,
    "budget_cap_usd": 10.0
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| max_cycles | integer | 3 | Maximum fix attempts before stopping |
| fix_model | string | "claude" | Model for generating fixes: "claude" or "codex" |
| cost_optimize | boolean | true | Enable tiered model routing (local/cheap/mid/premium) |
| budget_cap_usd | number | 10.0 | Maximum budget for smoke test runs |

### model_tiers

Defines the 4-tier model routing for smoke testing. Configured in `v3/config/model-tiers.json`.

```json
{
  "tiers": {
    "local": {
      "cost_per_1m_tokens": 0,
      "tasks": ["build_validation", "mock_data_scan", "route_parsing", "rbac_matrix", "placeholder_detection"]
    },
    "cheap": {
      "cost_per_1m_tokens": 0.21,
      "models": ["deepseek", "kimi", "minimax"],
      "fallback": "codex",
      "tasks": ["db_schema_check", "module_completeness", "config_validation"]
    },
    "mid": {
      "cost_per_1m_tokens": 1.50,
      "models": ["codex"],
      "tasks": ["api_wiring_check", "auth_flow_check", "di_registration_check"]
    },
    "premium": {
      "cost_per_1m_tokens": 9.00,
      "models": ["claude"],
      "tasks": ["security_review", "gap_report", "fix_generation", "architecture_analysis"]
    }
  }
}
```

### code_review

Controls 3-model code review behavior.

```json
{
  "code_review": {
    "models": "claude,codex,gemini",
    "fix_model": "claude",
    "max_cycles": 5,
    "min_severity_to_fix": "medium",
    "max_reqs": 50,
    "budget_cap_usd": 20.0
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| models | string | "claude,codex,gemini" | Comma-separated list of review models |
| fix_model | string | "claude" | Model for generating fixes |
| max_cycles | integer | 5 | Maximum review-fix iterations |
| min_severity_to_fix | string | "medium" | Minimum severity level to auto-fix (critical\|high\|medium\|low) |
| max_reqs | integer | 50 | Maximum requirements per review run |
| budget_cap_usd | number | 20.0 | Maximum budget for code review |

### full_pipeline

Controls the full pipeline orchestrator phases.

```json
{
  "full_pipeline": {
    "max_cycles": 3,
    "max_reqs": 50,
    "skip_wireup": false,
    "skip_codereview": false,
    "skip_smoketest": false
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| max_cycles | integer | 3 | Review-fix cycles per phase |
| max_reqs | integer | 50 | Requirements per batch |
| skip_wireup | boolean | false | Skip wire-up phase |
| skip_codereview | boolean | false | Skip code review phase |
| skip_smoketest | boolean | false | Skip smoke test phase |

### validators

Controls local validation behavior.

```json
{
  "validators": {
    "local_validate": {
      "dotnet_build_required": true,
      "npm_build_required": true,
      "test_run_required": false,
      "max_errors_before_escalate": 20
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| dotnet_build_required | boolean | true | Run `dotnet build` during local validation |
| npm_build_required | boolean | true | Run `npm run build` during local validation |
| test_run_required | boolean | false | Run unit tests during local validation |
| max_errors_before_escalate | integer | 20 | Escalate to LLM fixer if more than this many build errors |

### cost_tracking

Controls per-requirement cost alerts and budget enforcement.

```json
{
  "cost_tracking": {
    "enabled": true,
    "per_req_warn_threshold": 2.0,
    "per_req_escalate_threshold": 5.0,
    "per_req_hard_cap": 10.0
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| enabled | boolean | true | Enable cost tracking |
| per_req_warn_threshold | number | 2.0 | Warn when a single requirement exceeds this cost ($) |
| per_req_escalate_threshold | number | 5.0 | Escalate (flag for review) when requirement exceeds this cost ($) |
| per_req_hard_cap | number | 10.0 | Hard cap: defer requirement automatically when this cost is reached ($) |
