# GSD V3 Pipeline Details

## Architecture
- 2-model API-only: Claude Sonnet 4.6 (reasoning) + GPT-5.1 Codex Mini (code gen)
- No CLI subscriptions — pure pay-per-token API
- ~85% cost reduction: ~$7.30/100K LOC vs ~$50 (v2)
- ~10x faster: ~1.5 hrs vs 12-15 hrs

## Model IDs (corrected from spec)
- Sonnet: `claude-sonnet-4-6` (spec had `claude-sonnet-4-6-20260310` — doesn't exist)
- Codex Mini: `gpt-5.1-codex-mini` (correct)
- Opus escape hatch: `claude-opus-4-6`
- Codex Full escape hatch: `gpt-5.1-codex`

## 10-Phase Pipeline
```
Phase 0: Cache Warm (Sonnet, real-time)
Phase 1: Spec Gate (Sonnet, batch) — once
Phase 2: Research (Sonnet, batch) — per iteration
Phase 3: Plan (Sonnet, batch) — per iteration
Phase 4a: Execute Skeleton (Codex Mini, real-time, parallel)
Phase 4b: Execute Fill (Codex Mini, real-time, parallel)
Phase 5: Local Validate (local tools, FREE)
Phase 6: Review (Sonnet, batch) — conditional (only failed items)
Phase 7: Verify (Sonnet, real-time) — gates iteration
Phase 8: Spec-Fix (Sonnet, batch) — occasional
```

## Three Modes
- **Greenfield** (`gsd-blueprint.ps1`): New project, max 25 iterations, $50 budget
- **Bug Fix** (`gsd-fix.ps1`): Post-launch bugs, max 5 iterations, $5 budget
- **Feature Update** (`gsd-update.ps1`): Add features, max 20 iterations, $25 budget

## Key Modules (v3/lib/modules/)
- `api-client.ps1`: Sonnet + Codex Mini REST API calls, prompt caching, batch API
- `cost-tracker.ps1`: Real-time cost tracking with budget enforcement
- `local-validator.ps1`: Free quality gate (lint, typecheck, test)
- `phase-orchestrator.ps1`: Main convergence loop, phase routing
- `resilience.ps1`: Pre-flight, file inventory, retry logic
- `supervisor.ps1`: Health scoring, stall detection, notifications

## Config Files (v3/config/)
- `global-config.json`: Pipeline settings, phase order, optimization flags
- `agent-map.json`: Phase-to-model routing, token budgets
- `model-registry.json`: API endpoints, pricing, rate limits

## Entry Points
```powershell
# Greenfield
pwsh -File v3/scripts/gsd-blueprint.ps1 -RepoRoot "C:\repos\project"
# Bug fix
pwsh -File v3/scripts/gsd-fix.ps1 -RepoRoot "C:\repos\project" -Description "bug desc"
# Feature update
pwsh -File v3/scripts/gsd-update.ps1 -RepoRoot "C:\repos\project"
```

## CRITICAL: Codex Models Use Responses API (NOT Chat Completions)
- `gpt-5.1-codex-mini` and `gpt-5.1-codex` ONLY work with `/v1/responses` endpoint
- Chat Completions (`/v1/chat/completions`) returns: "This model is only supported in v1/responses"
- Key differences:
  - System prompt → `instructions` field (not messages[0].role=system)
  - User message → `input` array with role/content objects
  - Max tokens → `max_output_tokens` (not `max_tokens`)
  - Output → `response.output[*].content[*].text` (not choices[0].message.content)
  - Usage → `input_tokens`/`output_tokens` (same field names, different nesting)
  - Finish reason → `response.status` ("completed" = stop, "incomplete" = truncated)

## Bugs Fixed During Install (2026-03-10)
1. `api-client.ps1:360` — `$Phase:` in double-quoted string → `${Phase}:`
2. Model IDs — spec used future dates (20260310) → corrected to current IDs
3. JSON parsing regex — `[\s\S]*?` doesn't work cross-line in PowerShell → `(?s)` flag
4. `requirements-matrix.json` — v2 used split files + `requirements-master.json`, v3 needs single `requirements-matrix.json`
5. `$_.req_id` vs `$_.id` — v2 matrix uses `id`, v3 code expected `req_id`
6. **Codex API endpoint** — was using `/v1/chat/completions` (returns 429/error), switched to `/v1/responses`
7. **Missing Model in error returns** — failed Codex calls had no `Model` key → cost tracker logged "Unknown model pricing:"
8. **No circuit breaker** — 10 reqs x 3 retries hammered API on persistent 429. Added: abort after 6 consecutive 429s
9. **Plan truncation** — fixed max_tokens to scale with requirement count, retry with half batch on truncation

## v2 → v3 Migration
- Merged council-extract files into `requirements-matrix.json` with v3 statuses
- 1160 requirements: 607 satisfied, 337 partial, 216 not_started (52% health)

## DeepSeek Fallback (added 2026-03-10, session 6)
- When Codex Mini fails after all retries (any error), auto-falls back to DeepSeek
- `Invoke-DeepSeekFallback` in api-client.ps1
- Model: `deepseek-chat` via `https://api.deepseek.com/v1/chat/completions`
- Uses OpenAI-compatible chat completions format (NOT Responses API)
- 3 retries, backoff [2, 5, 10]s
- Cost: $0.28/M (cheapest of all models)

## Model Availability (2026-03-10)
| Model | Status | Endpoint | Notes |
|-------|--------|----------|-------|
| Sonnet 4.6 | Working | api.anthropic.com | Primary planner |
| Codex Mini | Unreliable | api.openai.com | 429/400/404 rotating |
| DeepSeek | Working | api.deepseek.com | US endpoint, fallback |
| Kimi | Unreachable | api.moonshot.cn | China, needs VPN |
| GLM5 | Unreachable | open.bigmodel.cn | China, needs VPN |
| MiniMax | Unreachable | api.minimax.chat | China, needs VPN |

## Required Env Vars
- `ANTHROPIC_API_KEY` (sk-ant-...)
- `OPENAI_API_KEY` (sk-proj-...)
- `DEEPSEEK_API_KEY` (sk-...) — fallback
