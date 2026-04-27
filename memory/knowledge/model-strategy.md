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

**Last check: 2026-04-23** (V7.0 spec + live research sweep)
**Next check: 2026-05-23**

## Pending Routing Updates (V7.0 Upgrade 5 + 2026-04-23 research sweep)

Not applied to the active routing table above — captured here so the next feature-check review picks them up.

### GPT-5.5 (announced 2026-04-23, API not live at time of writing)

- **Use once API SKU is confirmed** as the generator for long-horizon agentic coding, whole-repo edits (Terminal-Bench 2.0 82.7%, OpenAI MRCR v2 74.0% on 512K–1M context)
- **Keep Claude Opus 4.7 as evaluator** — wins SWE-Bench Pro at 64.3% vs GPT-5.5 at 58.6%; matches V7.0 Upgrade 5's hard-split requirement (generator ≠ evaluator family)
- **Hard rule:** do NOT hard-code `gpt-5.5` as a model id until `developers.openai.com/api/docs/models/gpt-5.5` is reachable and returns a real 200 on a probe call
- **OAuth-Codex path:** GPT-5.5 rolled out to Codex CLI before the API endpoint went live. If `codex` CLI exposes `gpt-5.5` (or equivalent id) and the operator's subscription tier is in the rollout wave, generator work may route to GPT-5.5 at **$0 marginal cost** via the existing Codex OAuth flow. Verify both conditions before flipping the router
- **Pricing (announced):** $5 / $30 per 1M input/output; `GPT-5.5 Pro` tier at $30 / $180. Assume 2x input surcharge above 272K tokens (inherited from GPT-5.4) until confirmed otherwise
- **Context window:** 1M tokens on API, 400K in ChatGPT/Codex

### Gemini 3.1 Flash-Lite (cheap generator lane)

- Add as a third family option for V7.0 `familySplit` tie-breaking — widens the generator pool and keeps cost-sensitive bulk work off Sonnet/Codex-mini when Opus-family evaluation is pinned
- Route candidate for: generator-side bulk execution of small slices, non-critical scaffolding, and high-volume token-sensitive phases
- Concrete routing table update deferred until first GSD project runs with V7.0 Upgrade 5 enabled

### DeepSeek V4 (now live via NVIDIA NIM)

- 1T MoE, ~81% SWE-bench, ~$0.30/MTok via DeepSeek's own API (still gated on direct release per Reuters 2026-04-06)
- **Update 2026-04-23:** `deepseek-ai/deepseek-v4-pro` and `deepseek-ai/deepseek-v4-flash` are both serving via NVIDIA Build (NIM) on the OpenAI-compatible endpoint at $0 marginal cost (free tier). Operators can route to V4 *now* through NIM without waiting for DeepSeek's direct API to confirm
- Action: when V7.0 Upgrade 7 lands, gate the DeepSeek V4 slot on a probe of NIM first (free), then DeepSeek direct (paid) as fallback once it ships

### NVIDIA Build / NIM (4th family — V7.0 family-split tie-breaker)

NVIDIA Build (`build.nvidia.com`) hosts an OpenAI-compatible inference endpoint with a free tier (~1000 requests/day during evaluation, ~40 RPM burst, no published monthly token cap). API key provisioned 2026-04-23 (see `~/.claude/projects/.../memory/api-keys.md`). NVIDIA's lineage is distinct from Anthropic, OpenAI, and Google — making it a legitimate fourth family for V7.0 Upgrade 5's hard generator/evaluator split.

**API basics**

- Endpoint: `POST https://integrate.api.nvidia.com/v1/chat/completions`
- Auth: `Authorization: Bearer $NVIDIA_API_KEY`
- Format: OpenAI Chat Completions schema; tool calling supported on most Llama / Qwen / Mistral / DeepSeek / Nemotron variants
- `max_tokens` cap varies per model (most: 4096; Nemotron Ultra: 8192; Llama 4 Maverick: 8192)
- No native prompt caching — every call is full-cost in tokens (free tier still $0 marginal)
- Quirks: Nemotron variants prefer system content prepended to first user turn for best instruction-following; JSON mode is not universally available — verify per model

**Recommended routing slots (V7.0 high priority)**

| Slot | Model id | Params | Context | Why |
|---|---|---|---|---|
| Generator (4th-family) | `qwen/qwen3-coder-480b-a35b-instruct` | 480B MoE (35B active) | 256K | SWE-bench Verified ~69%, LiveCodeBench ~74% — open-weight peer to Codex-mini for whole-repo edits |
| Generator (agentic) | `mistralai/devstral-2-123b-instruct-2512` | 123B dense | 256K | Mistral's agent-tuned coder; reliable tool calling; SWE-bench ~63% |
| Evaluator (4th-family) | `nvidia/llama-3.3-nemotron-super-49b-v1.5` | 49B dense | 128K | NVIDIA RLHF-tuned for skeptical reward modeling; Arena-Hard 88.3, MT-Bench 9.0 — distinct from Anthropic evaluator lineage |
| Bulk code-gen | `deepseek-ai/deepseek-v4-pro` | 1T MoE | 128K | SWE-bench ~81%, HumanEval 92% — flips the V4 gate above |
| Bulk code-gen (cheap) | `deepseek-ai/deepseek-v4-flash` | ~37B active MoE | 128K | SWE-bench ~73% — replaces DeepSeek-Chat in cost lane at $0 |

**Worth-considering (medium priority — adopt when first project hits the slot)**

| Slot | Model id | Params | Context | Why |
|---|---|---|---|---|
| Long-context retrieval | `meta/llama-4-maverick-17b-128e-instruct` | 17B active / 128 experts | **1M** | Free 1M-context lane that undercuts Gemini 3.1 Pro for cost-sensitive RAG; RULER@1M ~80% |
| Generator alt | `qwen/qwen3.5-397b-a17b` | 397B MoE (17B active) | 256K | LiveCodeBench ~76% — newer Qwen flagship with improved tool use vs qwen3-coder |
| Evaluator alt (heavy) | `mistralai/mistral-large-3-675b-instruct-2512` | 675B MoE | 256K | MMLU-Pro 78, GPQA 64 — strong code-review judgment |
| Evaluator (cheap) | `nvidia/nemotron-3-super-120b-a12b` | 120B MoE (12B active) | 128K | Arena-Hard ~91 — newer Nemotron family at lower active-param count |
| Hermes notification | `openai/gpt-oss-120b` | 120B dense | 128K | OpenAI open-weight, tool-call native, free on NIM — fallback when Haiku 4.5 is on cooldown |
| Bulk code-gen (small) | `mistralai/codestral-22b-instruct-v0.1` | 22B | 32K | HumanEval 81 — fits remediation micro-fixes |

**Skip (informational):** `bigcode/starcoder2-15b`, `meta/codellama-70b`, `ibm/granite-34b-code-instruct`, `google/codegemma-7b`, `microsoft/phi-4-mini-instruct`, `mistralai/mixtral-8x22b-instruct-v0.1`, `meta/llama-3.1-405b-instruct`, `nvidia/nemotron-4-340b-instruct`, `qwen/qwen2.5-coder-32b-instruct` — superseded by entries in the tables above.

**Concrete routing-table updates planned for V7.0 Upgrade 7 commit**

1. **Generator priority list** (Phase Execute / Remediate): append Qwen3-Coder 480B then Devstral 2 123B as 4th-family options. Satisfies Upgrade 5 hard family-split when Anthropic and OpenAI are both pinned to evaluator duty
2. **Evaluator priority list** (Phase Review / Gate): append Llama 3.3 Nemotron Super 49B v1.5 as 4th-family fallback
3. **Bulk code-gen API fallback table:** replace MiniMax second-emergency slot with `deepseek-ai/deepseek-v4-flash` via NIM ($0 vs $0.29/$1.20). Keep MiniMax as third
4. **Long-context retrieval:** add Llama 4 Maverick as Gemini 3.1 Pro fallback (1M context, free tier)
5. **Hermes notification cheap lane:** add `openai/gpt-oss-120b` as free alternative to Haiku 4.5 on cooldown
6. **Env var:** add `NVIDIA_API_KEY` to `.env.example` and to the runtime check list

**Free-tier caveats**

- Per-model RPM and daily caps vary; check the model's page on `build.nvidia.com` before routing high-volume bulk work
- Treat free-tier exhaustion as a graceful router fallback, not a hard pipeline failure — the existing Anthropic / OpenAI / Google subscription CLIs remain primary
- No SLA on free tier; expect occasional 429s and cold-start latency on niche models
- Some model ids are served via `nvcf.nvidia.com` redirect — always probe before pinning

## Cost Comparison

| Scenario | V6 (3 Max subs) | Pro + API reference | Pure API reference |
|---|---|---|---|
| Light (5 iters) | $220-320 fixed, $0 variable | $60 + $40 API | $200+ |
| Normal (20 iters) | $220-320 fixed, $0 variable | $60 + $80 API | $400+ |
| Heavy (50 iters) | $220-320 fixed, $0 variable | $60 + $200 API | $800+ |
| **Multiple projects/mo** | **Same $220-320** | $60 + scales | Scales linearly |

**Break-even:** If you run >2 projects per month or >20 iterations total, Max subscriptions pay for themselves.
