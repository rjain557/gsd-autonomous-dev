---
type: knowledge
description: V6 model strategy — 3 Max subscriptions + 2 emergency API fallbacks, $0 marginal cost target
date: 2026-04-22
version: 6.0.1
---

# V6 Model Strategy

## Principle

Run the entire pipeline on 3 Max/Ultra subscription CLIs for $0 marginal token cost. API models are emergency-only fallbacks — used only when ALL three subscription CLIs are simultaneously on cooldown.

## Subscriptions ($220-320/mo fixed, unlimited tokens)

| Model | CLI | Subscription | RPM | Context | Primary Phases |
|---|---|---|---|---|---|
| Claude | `claude` | Claude Max ($100-200/mo) | 10 | 1M | Review, plan, blueprint analysis — use `claude-opus-4-7` for orchestration |
| Codex | `codex` | ChatGPT Max ($200/mo) | 10 | 272K | Execute (bulk code gen — 60% of tokens) — underlying model now GPT-5.3-Codex or GPT-5.4 |
| Gemini | `gemini` | Gemini Ultra ($20/mo) | 15 | 1M | Research, bulk review chunks — underlying model now Gemini 3 Flash |

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

4. If CLI fails (quota, rate limit, CLI not found):
   └── Auto-fallback to Anthropic SDK (ANTHROPIC_API_KEY, pay-per-token)
   └── Set 5-min cooldown on failed CLI
   └── After cooldown expires: auto-switch back to CLI ($0)

5. If ALL subscription CLIs on cooldown AND no API key:
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

## Dual Auth Strategy (OAuth + API Key)

The harness uses CLI OAuth as primary ($0 marginal cost) and auto-falls back to API key billing when subscription limits are hit. No manual intervention needed.

```
Normal:  CLI (OAuth) ──$0──> LLM response
                |
         On failure (quota/rate limit):
                |
                v
Fallback: SDK (API key) ──pay-per-token──> LLM response
                |                          + set 5-min cooldown on CLI
                v
         After 5 minutes:
                |
                v
Resume:  CLI (OAuth) ──$0──> back to normal
```

| Mode | Auth | Cost | When |
|---|---|---|---|
| `cli` (default) | OAuth via `claude auth login` | $0 (Max subscription) | Normal operation — all calls route here first |
| `sdk` (auto-fallback) | `ANTHROPIC_API_KEY` env var | Pay-per-token | CLI hits rate limit → auto-switches for 5 min → switches back |
| `sdk` (forced) | `GSD_LLM_MODE=sdk` | Pay-per-token | Set explicitly when guaranteed structured output needed |

**Setup:** Set `ANTHROPIC_API_KEY` in your environment even if you normally use OAuth. It's insurance — costs $0 unless CLI fails.

## Feature Check Schedule

Review new Claude/OpenAI/Google features every 30 days. Full checklist: `memory/knowledge/feature-check-schedule.md`

**Last check: 2026-04-22** (early check triggered by V6.5 spec rule #12)
**Next check: 2026-05-22**

## Cost Comparison

| Scenario | V6 (3 Max subs) | Pro + API reference | Pure API reference |
|---|---|---|---|
| Light (5 iters) | $220-320 fixed, $0 variable | $60 + $40 API | $200+ |
| Normal (20 iters) | $220-320 fixed, $0 variable | $60 + $80 API | $400+ |
| Heavy (50 iters) | $220-320 fixed, $0 variable | $60 + $200 API | $800+ |
| **Multiple projects/mo** | **Same $220-320** | $60 + scales | Scales linearly |

**Break-even:** If you run >2 projects per month or >20 iterations total, Max subscriptions pay for themselves.
