# GSD Model Cost/Quality Optimization — per-task model selection

> Goal: pick, for every GSD task, the **cheapest model that still completes it without error** —
> escalating only where quality is binding (security, compliance, legal, deploy, hardest fixes).
> Sources: key vault (providers we hold keys for) + Cortex catalog `claude-memory/topics/model_catalog.md`
> and `topics/models/_index.md` (weekly-verified, **refreshed 2026-06-08**) + repo
> `memory/knowledge/model-strategy.md` + `config/model-registry.json`.
> Prices are $/1M tokens (in/out). **Re-verify weekly** — run `npm run model-sync` for drift; the
> catalog re-verifies pricing. This doc is a recommendation, not an auto-applied config.

## 1. What we have keys for (key vault)

| Provider | Key file | Usable now | Access |
|---|---|---|---|
| Anthropic (Claude) | `anthropic.md` | ✅ | API + **Claude Max CLI** ($0 marginal) |
| OpenAI (GPT/Codex) | `openai.md`, `azure-openai.md` | ✅ | API + **ChatGPT Max CLI** ($0) |
| Google (Gemini) | `gemini.md` | ✅ | Dev API + **Gemini Ultra CLI** ($0) |
| DeepSeek | `deepseek.md` | ✅ | API (gateway) |
| Moonshot (Kimi) | `kimi-moonshot.md`, `moonshot-kimi.md` | ✅ | API (gateway) |
| Zhipu (GLM) | `glm-zhipu.md` | ✅ | API — **use `api.z.ai` intl host** (China host geo-blocked) |
| MiniMax | `minimax.md` | ⚠️ key valid but **account unfunded** (`insufficient balance 1008`) → removed from gateway. Fund before use. |
| NVIDIA Build / NIM | `nvidia-build.md` | ✅ | API (4th family; cheap reasoning + open-weight) |
| Amazon Bedrock | `amazon-bedrock.md` | ✅ | API (alt routing for Claude/Llama; failover) |
| Mistral | — none — | ❌ | **No key.** EU-compliance option only if a key is added. |

All API traffic should route through the **LiteLLM gateway** (`http://10.100.254.102:4000`) with this
repo's `sk-tj-gsd-autonomouse-dev` virtual key so spend is attributed (see Cortex `litellm_gateway`).

## 2. Current model tiers (2026-06-08)

| Tier | Model | In/Out | Reasoning | Sweet spot |
|---|---|--:|:--:|---|
| **triage** | nvidia-nemotron-3-nano-30b | 0.06/0.20 | ✅ | cheapest reasoning; pure classification/extraction |
| triage | gpt-4.1-nano | 0.10/0.40 | — | ultra-cheap routing/extraction |
| triage | deepseek-v4-flash | 0.14/0.28 | ✅ | **best $/quality bulk** — high-volume w/ light reasoning |
| triage | minimax-m2.5 | 0.15/1.15 | — | budget coding bulk (⚠️ funding) |
| triage | gemini-3.1-flash-lite | 0.25/1.50 | — | extraction/summarization, 1M ctx |
| triage | glm-4.7-flash | free | — | zero-cost triage (429 under load → fallback) |
| triage | claude-haiku-4-5 | 1.0/5.0 | ✅ | cheap Claude judgment, fast |
| **decision** | minimax-m3 | 0.30/1.20 | ✅ | **frontier-quality coding at budget cost** (⚠️ funding) |
| decision | deepseek-v4-pro | 1.74/3.48¹ | ✅ | hard code-gen / agentic reasoning, cheap |
| decision | kimi-k2.6 | 0.95/4.0 | ✅ | **agentic coding + multi-agent + visual UI gen** |
| decision | glm-5.1 | 1.4/4.4 | ✅ | budget agentic coding / Claude-Code replacement |
| decision | gemini-3.5-flash | 1.5/9.0 | — | **new mid-tier workhorse**; beats 3.1-pro on coding, multimodal, 1M ctx |
| decision | gpt-5.4 | 2.5/15 | — | balanced general workloads |
| decision | claude-sonnet-4-6 | 3.0/15 | ✅ | **best price/quality for judgment**; only model w/ server-side web_search |
| **escalate** | gemini-3.1-pro | 2.0/12 | ✅ | **2M ctx**, long-doc + multimodal + code reasoning at scale |
| escalate | o3 | 2.0/8.0 | ✅ | complex math/scientific reasoning |
| escalate | gpt-5.5 | 5.0/30 | ✅ | hardest coding/research |
| escalate | claude-opus-4-8 | 5.0/25 | ✅ | **flagship default** — hard multi-step coding agents, long-horizon autonomous |
| **frontier** | claude-fable-5 | 10/50² | ✅ | most capable widely-released model; the hardest reasoning / longest-horizon autonomous runs only |

² Fable 5 (`claude-fable-5`, verified via claude-api ref 2026-06-04): $10/$50 is **2× Opus 4.8**, and its
**new tokenizer runs ~30% more tokens** for the same content → **~2.6× Opus 4.8's effective cost**.
API differences: thinking always-on (omit the `thinking` param), `refusal` stop-reason for cyber/bio,
requires 30-day data retention (not ZDR). **Use only when Opus 4.8 demonstrably fails** the task.

¹ deepseek-v4-pro: standard price shown; **cache-hit input ≈ 4× cheaper** — favor it for repeated-context loops.
Legacy `deepseek-chat`/`deepseek-reasoner` **retire 2026-07-24** → migrate to `deepseek-v4-flash/-pro` (registry still says `deepseek-chat` — flagged by `model-sync`).

## 3. Cost regime — full gateway (owner decision 2026-06-11)

**Every LLM call routes through the LiteLLM gateway** (pay-per-token) with this repo's virtual key
`sk-tj-gsd-autonomouse-dev`, so all spend is tracked per project. This **supersedes** the prior
"$0 subscription CLIs first" model — the subscription CLIs are OAuth and can't be metered through
the gateway, so they're no longer the default path. Wiring + env contract:
`memory/knowledge/litellm-gateway.md`. Since every token now costs real dollars, the per-task picks
in §4 matter more than ever: **pick the cheapest model meeting the task's quality bar; never pay
escalate/frontier prices for triage work.** (The CLI path remains available as a $0 fallback only if
`GSD_LLM_MODE=cli` is set explicitly.)

**Where Fable 5 fits:** it is a **frontier escalation of last resort**, not a tier any task defaults
to. At ~2.6× Opus 4.8's effective cost, route to it only when Opus 4.8 (the escalate default) has
demonstrably failed a binding task — e.g. an overnight autonomous refactor that Opus can't complete,
or the single hardest remediation slice after Opus stalls. For everything else, the escalate ceiling
is Opus 4.8 / gpt-5.5 / gemini-3.1-pro.

## 4. Per-task model recommendation

Quality bar: 🟢 mechanical (errors cheap) · 🟡 judgment (errors costly) · 🔴 binding (errors unacceptable).

| GSD task / agent | Phase | Bar | $0 CLI default | Gateway primary (cheapest-sufficient) | Escalate to | Why |
|---|---|:--:|---|---|---|---|
| RequirementsAgent | A | 🟡 | Claude | claude-sonnet-4-6 | opus-4-8 | spec fidelity = judgment; web parts need web_search (Claude-only) |
| ArchitectureAgent | B | 🟡 | Claude | claude-sonnet-4-6 | opus-4-8 / gemini-3.1-pro | threat model reasoning; long-doc → gemini-3.1-pro (2M) |
| FigmaIntegrationAgent | C | 🟡 | Gemini | **gemini-3.5-flash** (multimodal, cheap) | gemini-3.1-pro | visual validation = multimodal; Gemini strongest here |
| PhaseReconcileAgent | A/B | 🟡 | Claude | claude-sonnet-4-6 | gemini-3.1-pro | cross-doc judgment; long ctx → gemini-3.1-pro |
| BlueprintFreezeAgent | D | 🟡 | Claude | claude-sonnet-4-6 | opus-4-8 | freezing UI/UX spec — precision |
| ContractFreezeAgent (SCG1) | E | 🔴 | Claude | claude-sonnet-4-6 | opus-4-8 | OpenAPI↔SP mapping is gate-critical; mechanical mapping bulk → deepseek-v4-pro |
| BlueprintAnalysisAgent (drift) | F1 | 🟢 | Gemini | **deepseek-v4-flash** / gemini-3.5-flash | sonnet-4-6 | scan/compare; large repo read → gemini (1M ctx) |
| CodeReviewAgent | F2 | 🟡 | Claude | **claude-sonnet-4-6** (correctness) | opus-4-8 (adversarial) | bug-catching is judgment; bulk trivial chunks → gemini-3.5-flash |
| RemediationAgent | F3 | 🟡 | Codex | **minimax-m3** / kimi-k2.6 / deepseek-v4-pro | opus-4-8 / gpt-5.5 | coding; cheap coders handle most, hardest fixes escalate |
| QualityGateAgent | F4 | 🟢 | Claude | **deepseek-v4-flash** / haiku-4-5 | — | work is mostly non-LLM (semgrep/dotnet/npm); LLM only interprets |
| E2EValidationAgent | F5 | 🟡 | Claude | kimi-k2.6 / minimax-m3 (test gen) | sonnet-4-6 | test authoring = coding; failure analysis = judgment |
| DeployAgent | F6 | 🔴 | Claude | **claude-sonnet-4-6** | opus-4-8 | safety-critical, low token — buy reliability, not cheapness |
| PostDeployValidationAgent | G | 🟡 | Claude | claude-sonnet-4-6 | — | live-env judgment, low volume |
| SecurityAgent (binding signoff) | — | 🔴 | Claude | **claude-opus-4-8** | gpt-5.5 (2nd opinion) | binding security signoff — top tier only |
| ComplianceAgent (16 frameworks) | — | 🔴 | Claude | **gemini-3.1-pro** (2M ctx) / opus-4-8 | opus-4-8 | long compliance docs + accuracy-critical |
| LegalAgent (MSA/BAA/EULA) | — | 🔴 | Claude | **claude-sonnet-4-6** | opus-4-8 | Anthropic strongest on legal drafting; UPL boundary |
| PMAgent (tracking/calendar) | — | 🟢 | — | **deepseek-v4-flash** / gemini-3.1-flash-lite | — | low-stakes structuring — cheapest reasoning |
| Orchestrator (routing) | all | 🟡 | (harness) | **claude-haiku-4-5** / deepseek-v4-flash | sonnet-4-6 | frequent + cheap; routing errors costly → haiku reasoning |
| Researcher / ScoutAgent | — | 🟢 | Gemini | **gemini-3.5-flash** (1M ctx) / deepseek-v4-flash | sonnet-4-6 (web_search) | high-volume scan; grounded web research → Claude only |
| KnowledgeHarvester / DocGardener | — | 🟢 | — | **nvidia-nemotron-nano** / gpt-4.1-nano / deepseek-v4-flash | — | pure mechanical, highest volume → absolute cheapest |

## 5. Cost-minimization rules (apply in order)

1. **$0 first.** If a sequential pipeline phase can run on a subscription CLI within RPM, use it.
2. **Cheapest-sufficient on the gateway.** For API work, start at the lowest tier in §4 that meets the
   bar; only escalate on a real failure/low-confidence signal (capability-escalation already exists).
3. **Never overpay for 🟢 mechanical work** — route it to deepseek-v4-flash / nvidia-nemotron-nano /
   gpt-4.1-nano, never to sonnet/opus.
4. **Never underpay for 🔴 binding work** — Security/Compliance/Legal/Deploy/SCG1 stay on
   Claude (opus-4-8 / sonnet-4-6) or gemini-3.1-pro regardless of cost. A bad signoff costs more than tokens.
5. **Exploit cheap coders** — minimax-m3 ($0.30/$1.20) and kimi-k2.6 carry most code-gen/remediation; reserve
   opus-4-8 / gpt-5.5 for the slice that actually failed a cheaper model.
6. **Use 2M context deliberately** — gemini-3.1-pro for whole-repo/whole-doc tasks (compliance, long
   reconcile), but watch the **>200k-token price doubling**; chunk when feasible.
7. **Cache-hit loops** — for repeated-context remediation/review, deepseek-v4-pro's cache pricing beats nominal.
8. **Batch APIs = 50% off** (Gemini/Anthropic) for non-interactive bulk review — use for review-chunk waves.

## 6. Action items to realize the savings

- [ ] **Fund MiniMax** (or keep it out) — m3 at $0.30/$1.20 is the best budget coder but the account
      returns `insufficient balance`. Until funded, use kimi-k2.6 / deepseek-v4-pro as the coding primary.
- [ ] **Fix registry drift** (`npm run model-sync`): `deepseek-chat`→`deepseek-v4-pro/flash` (hard
      deadline 2026-07-24), `MiniMax-M1`→`minimax-m3`. Re-enable kimi/glm5 in `config/model-registry.json`
      if adopting them as gateway coders.
- [ ] **Add gateway aliases** for the picks above (triage-/decision-/escalate-) in
      `tech-web-myjian/infrastructure/litellm/config.yaml` then `docker compose up -d --force-recreate litellm`.
- [ ] **Wire complexity routing**: map the §4 tiers into `config/global-config.json` complexity routing
      (low→triage, medium→decision, high→escalate) and `memory/knowledge/model-strategy.md`.
- [ ] **Opus 4.8** is the new flagship (same price as 4.7) — update any `claude-opus-4-7` references to `-4-8`.
