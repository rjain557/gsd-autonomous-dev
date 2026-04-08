---
type: knowledge
description: V4.1 model strategy — 3 Max subscriptions + 2 emergency API fallbacks, $0 marginal cost target
date: 2026-04-08
---

# V4.1 Model Strategy

## Principle

Run the entire pipeline on 3 Max/Ultra subscription CLIs for $0 marginal token cost. API models are emergency-only fallbacks — used only when ALL three subscription CLIs are simultaneously on cooldown.

## Subscriptions ($220-320/mo fixed, unlimited tokens)

| Model | CLI | Subscription | RPM | Context | Primary Phases |
|---|---|---|---|---|---|
| Claude | `claude` | Claude Max ($100-200/mo) | 10 | 200K-1M | Review, plan, blueprint analysis |
| Codex | `codex` | ChatGPT Max ($200/mo) | 10 | 200K | Execute (bulk code gen — 60% of tokens) |
| Gemini | `gemini` | Gemini Ultra ($20/mo) | 15 | 1M | Research, bulk review chunks |

**Why this works:** At 10-15 RPM with 30s throttle between phases, a single pipeline iteration uses ~4 requests per agent. A 20-iteration convergence run uses ~80 requests per agent across ~60 minutes — well within daily limits.

## Emergency API Fallbacks (pay-per-token, avoid)

| Model | Cost/M tokens | RPM | When Used |
|---|---|---|---|
| DeepSeek | $0.28/$0.42 | 60 | All 3 subscription CLIs on cooldown simultaneously |
| MiniMax | $0.29/$1.20 | 30 | DeepSeek also exhausted |

**Target API spend: $0/mo for normal operations.** API fallbacks exist for resilience, not regular use.

## Disabled Models

| Model | Reason |
|---|---|
| Kimi | Redundant — 2x DeepSeek cost, no unique capability |
| GLM-5 | Corporate firewall blocks endpoint, highest API cost |

## Phase-to-Agent Routing (Rate-Limit Aware)

The orchestrator picks the first available agent from each phase's priority list, checking rate limits before each call:

| Phase | Priority 1 | Priority 2 | Priority 3 | Emergency |
|---|---|---|---|---|
| Blueprint | Claude | Gemini | Codex | DeepSeek |
| Review | Claude | Gemini | Codex | DeepSeek |
| Plan | Claude | Codex | Gemini | DeepSeek |
| Execute | Codex | Claude | Gemini | DeepSeek |
| Remediate | Claude | Codex | Gemini | MiniMax |
| Gate | Claude | Codex | — | — |
| E2E Validation | Claude | Gemini | Codex | DeepSeek |
| Deploy | Claude | — | — | — |
| Post-Deploy | Claude | Gemini | — | — |

## Rate Limiting Strategy

```
1. Before each LLM call: rateLimiter.waitForSlot(agentId)
   └── Checks 60-second sliding window
   └── If at 80% of RPM: sleeps until slot opens

2. Between pipeline phases: 30s throttle (configurable)
   └── Prevents burst that would exhaust all 3 CLIs simultaneously

3. On 429/quota exhaustion: setCooldown(agentId, 5 minutes)
   └── Agent skipped for 5 minutes
   └── Next agent in priority list takes over

4. If ALL subscription CLIs on cooldown:
   └── Fall back to DeepSeek API (cheapest)
   └── If DeepSeek also exhausted: MiniMax
   └── If everything exhausted: pause pipeline, log to vault
```

## How to Avoid Hitting Limits

1. **Don't run multiple pipelines simultaneously** — each pipeline expects exclusive access to the 3 CLIs
2. **Use 30s+ throttle** between phases (`-ThrottleSeconds 30`)
3. **Keep batch sizes reasonable** (8-14 items) — larger batches = more tokens per call but fewer calls
4. **Review-chunking spreads load**: 50% safety factor = only use half the RPM per review wave
5. **Time-of-day matters**: Run long convergence sessions overnight when subscription limits reset

## TypeScript Harness Integration

The harness defaults to CLI (OAuth) for all calls. The `GSD_LLM_MODE` env var controls behavior:

| Mode | When | How |
|---|---|---|
| `cli` (default) | Normal operation | Uses `claude`/`codex`/`gemini` CLI. $0 cost. JSON schema appended as prompt instructions. |
| `sdk` | Need guaranteed structured output | Uses Anthropic SDK with `tool_use`. Costs per token. Set `ANTHROPIC_API_KEY`. |

## Cost Comparison

| Scenario | V4.1 (3 Max subs) | V4.0 (Pro + API) | V2 (pure API) |
|---|---|---|---|
| Light (5 iters) | $220-320 fixed, $0 variable | $60 + $40 API | $200+ |
| Normal (20 iters) | $220-320 fixed, $0 variable | $60 + $80 API | $400+ |
| Heavy (50 iters) | $220-320 fixed, $0 variable | $60 + $200 API | $800+ |
| **Multiple projects/mo** | **Same $220-320** | $60 + scales | Scales linearly |

**Break-even:** If you run >2 projects per month or >20 iterations total, Max subscriptions pay for themselves.
