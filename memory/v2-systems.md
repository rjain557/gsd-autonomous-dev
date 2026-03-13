# V2 Systems & Modules

## Token Cost Calculator (scripts/token-cost-calculator.ps1)
- ~1048 lines, estimates API costs for completing projects to 100%
- Dynamic pricing from LiteLLM GitHub database, cached locally (14-day refresh, 60-day stale warning)
- Supports 10 models: Claude Sonnet/Opus/Haiku, GPT 5.3 Codex, GPT-5.1 Codex, Gemini 3.1 Pro, Kimi K2.5, DeepSeek V3, GLM-5, MiniMax M2.5
- Key params: -ProjectPath, -TotalItems, -Pipeline (blueprint/convergence), -ClaudeModel, -ShowComparison, -Detailed
- Client quoting: -ClientQuote -Markup (5-10x) -ClientName with 3-tier pricing and margin analysis
- Functions: Get-ProviderPricing, Get-LlmPricing, Save-PricingCache, Get-ModelPrice, Get-PipelineCost

## Supervisor System (scripts/patch-gsd-supervisor.ps1)
- Self-healing recovery: reads logs, root-causes via Claude, modifies prompts/specs/queue/matrix, restarts in new terminal
- Three layers: L1 pattern match (free), L2 AI diagnosis (1 Claude call), L3 AI fix (1 Claude call)
- Error context injection: .gsd/supervisor/error-context.md + prompt-hints.md appended to all agent prompts
- Agent override: .gsd/supervisor/agent-override.json reassigns phases to different agents
- Pattern memory: ~/.gsd-global/supervisor/pattern-memory.jsonl (cross-project learning)
- Pipeline writes last-run-summary.json before exit; supervisor reads it to know what happened
- Max 5 attempts, then escalation-report.md + urgent notification
- Params: -SupervisorAttempts (default 5), -NoSupervisor (bypass)

## Supervisor Enhancements (2026-03-08)
- 15s polling, change log, lock removal on startup, kimi type fix (cli->openai-compat)
- Spec gate summary in last-run-summary.json, auto-SkipSpecCheck on retry
- Health stagnation detection (flat 3+ attempts), cooldown clear fix type
- Failed pattern memory, pipeline timeout reduced, CLI-only phase filter
- WhatsApp bridge: `~/.gsd-global/whatsapp-bridge/` -- Baileys-based bidirectional monitoring

## Final Validation Gate (scripts/patch-gsd-final-validation.ps1)
- Script 6: `Invoke-FinalValidation` + `New-DeveloperHandoff` appended to resilience.ps1
- 10 checks at 100% health: dotnet build, npm build, dotnet test, npm test, SQL validation, dotnet audit, npm audit, DB completeness, security compliance, runtime smoke test
- Hard failures (1-4) set health to 99%, loop auto-fixes; warnings (5-7) are advisory
- Max 3 validation attempts via outer do/while loop
- `developer-handoff.md` generated at pipeline exit (10 sections)
- Git commit traceability: code review text used as commit body via `git commit -F`, auto-pushed

## LLM Council (scripts/patch-gsd-council.ps1)
- Script 7: `Invoke-LlmCouncil` appended to resilience.ps1
- 6 council types: convergence (3-agent, blocking), post-research (2-agent), pre-execute (2-agent), post-blueprint (3-agent, blocking), stall-diagnosis (3-agent), post-spec-fix (2-agent, blocking)
- Claude synthesizes consensus verdict for all types
- Outputs: `.gsd/health/council-review.json`, `.gsd/code-review/council-findings.md`
- Prompt templates: `%USERPROFILE%\.gsd-global\prompts\council\` (14 files)
- Config: `global-config.json` -> `council` (enabled, max_attempts, consensus_threshold)

## Parallel Sub-Task Execution (scripts/patch-gsd-parallel-execute.ps1)
- Script 18: splits execute batch into sub-tasks, round-robin across agent pool
- Config: `agent-map.json -> execute_parallel` (enabled, max_concurrent=2, agent_pool, inter_wave_cooldown_seconds=15)
- Agent pool order: deepseek > codex > gemini > kimi > minimax > glm5 > claude (cheapest first)
- Partial success commits completed work; fallback_to_sequential=true for monolithic fallback

## Resilience Hardening (scripts/patch-gsd-resilience-hardening.ps1)
- Script 19: in-place modifications + appended functions to resilience.ps1
- P1: Token costs tracked on ALL attempts (success + failure + quota probes)
- P2: Auth regex fixed -- 403 removed, rate-limit exclusion guard, Gemini 403 routes to quota backoff
- P3: Cumulative quota wait capped at 120 min
- P4: Agent rotation after 1 consecutive quota failure
- New functions: `New-EstimatedTokenData`, `Get-NextAvailableAgent`, `Set-AgentCooldown`

## Quality Gates (scripts/patch-gsd-quality-gates.ps1)
- Script 20: `Test-DatabaseCompleteness`, `Test-SecurityCompliance`, `Invoke-SpecQualityGate`
- DB completeness: zero-cost static scan verifying API->SP->Table->Seed chain
- Security compliance: zero-cost regex scan for OWASP violations
- Spec quality gate: combines Invoke-SpecConsistencyCheck + Claude clarity scoring + cross-artifact consistency
- Cost: ~$0.30 per pipeline run (2 Claude calls for spec checks, rest is free regex)

## Multi-Model LLM Integration (scripts/patch-gsd-multi-model.ps1)
- Script 21: adds 4 OpenAI-compatible REST API providers
- New agents: Kimi K2.5 ($0.60/$2.50/M), DeepSeek V3 ($0.28/$0.42/M), GLM-5 ($1.00/$3.20/M), MiniMax M2.5 ($0.29/$1.20/M)
- Config: `model-registry.json` -- central agent registry (type: cli vs openai-compat, endpoint, api_key_env, model_id)
- Functions: `Invoke-OpenAICompatibleAgent`, `Test-IsOpenAICompatAgent`
- Error mapping: HTTP 429->rate_limit, 402->quota_exhausted, 401->unauthorized, connection_failed
- Connection failure detection: unreachable endpoints -> immediate rotation with 60-min cooldown
- TLS enforcement: Tls12 | Tls13 on every REST call
- Rotation pool: registry-driven via `rotation_pool_default` in model-registry.json (7 agents)
- Env vars: KIMI_API_KEY, DEEPSEEK_API_KEY, GLM_API_KEY, MINIMAX_API_KEY (optional)

## Interface Detection (lib/modules/interfaces.ps1)
- 7 interface types: web, api, database, mcp, browser, mobile, agent
- Design-dir based detection: scans `design\{key}\v##` for versioned specs
- Auto-detection fallback for api (from .sln/.csproj) and database (from .sql files)
- Functions: `Find-ProjectInterfaces`, `Show-InterfaceSummary`, `Build-InterfacePromptContext`

## Proactive Rate Limiter (patch-gsd-rate-limiter.ps1, #39)
- Sliding-window rate limiter: tracks per-agent call timestamps, sleeps exact seconds before exceeding RPM
- Functions: `Wait-ForRateWindow`, `Register-AgentCall`, `Get-AgentRpmLimit`, `Get-RateLimitStatus`
- Injected into: `Invoke-WithRetry` + `Invoke-OpenAICompatibleAgent`
- Config: `agent-map.json -> rate_limiter.safety_factor` (default 0.8 = 80% of stated RPM)
- Effective RPM: claude 8, codex 8, gemini 12, kimi 16, deepseek 48, glm5 24, minimax 24

## Maintenance Mode (scripts/patch-gsd-maintenance-mode.ps1)
- Script 35: post-launch project maintenance
- **gsd-fix**: accepts bug descriptions via CLI args or `-File bugs.md`, auto-creates BUG-xxx requirements
- **gsd-update**: incremental feature addition using `create-phases-incremental.md` prompt
- **--Scope param**: filters plan phase to matching requirements
- **--Incremental flag**: triggers additive Phase 0 that merges new requirements
- Spec versioning: `design/web/v02/` -- each version must contain COMPLETE spec set, not deltas
