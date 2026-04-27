---
type: knowledge
description: 30-day feature check schedule — review Claude/OpenAI/Google for new capabilities that improve speed, quality, or cost
last_checked: 2026-04-22
next_check: 2026-05-22
---

# 30-Day Feature Check Schedule

## Purpose

Every 30 days, review the latest releases from Anthropic, OpenAI, and Google for new features that could improve the GSD pipeline's speed, quality, or cost. Update this note with findings and apply any beneficial changes.

## Check Sources

| Provider | What to Check | URL |
|---|---|---|
| Anthropic | Claude Code changelog, API changelog, pricing | claude.ai/code, docs.anthropic.com |
| OpenAI | Codex CLI updates, GPT model changes, pricing | platform.openai.com |
| Google | Gemini CLI updates, model changes, context limits | ai.google.dev |
| Claude Code | Sub-agent improvements, agent teams stability, new hooks | code.claude.com/docs/en/changelog |

## Checklist (run every 30 days)

### Claude Code Features
- [ ] Agent teams: still experimental or GA? Any breaking changes?
- [ ] Sub-agents: new capabilities? Better context sharing?
- [ ] Hooks: new hook events? New hook types?
- [ ] Cloud scheduled tasks: new triggers? Better monitoring?
- [ ] MCP: new official MCP servers? Protocol changes?

### Claude API
- [ ] New models? (check if Opus 5 / Sonnet 5 launched)
- [ ] Prompt caching changes? (TTL, cost reduction %)
- [ ] Batch API updates? (latency improvements, cost changes)
- [ ] Tool use improvements? (better JSON schema compliance)
- [ ] Extended thinking changes? (new modes, cost)
- [ ] Rate limit changes for Max plan?

### OpenAI / Codex
- [ ] Codex CLI updates? New commands, flags, approval modes?
- [ ] New models? (GPT-5.1, o3 updates, o4 launch?)
- [ ] Rate limit changes for ChatGPT Max plan? RPM/TPM changes?
- [ ] New features in full-auto mode? Better error handling?
- [ ] Codex agent/sub-agent capabilities? Can Codex spawn sub-tasks?
- [ ] Codex structured output? JSON mode improvements?
- [ ] Codex tool use? Can it call external tools like Claude Code?
- [ ] Codex file editing improvements? Better diff handling?
- [ ] Multi-file generation? Can Codex create multiple files atomically?
- [ ] Codex hooks or extensions? Equivalent of Claude Code hooks?

### Google / Gemini
- [ ] Gemini CLI updates? New commands, approval modes?
- [ ] New models? Context window beyond 1M? Gemini 2.5 Pro updates?
- [ ] Rate limit changes for Ultra plan?
- [ ] Gemini Code Assist features? Inline suggestions, multi-file edits?
- [ ] Gemini agent capabilities? Sub-agent spawning?
- [ ] Gemini tool use? MCP support? External tool calling?
- [ ] Gemini structured output? JSON schema enforcement?
- [ ] Gemini grounding? Can it search code repos natively?
- [ ] Gemini Batch API? Cost reduction for bulk calls?
- [ ] Gemini multimodal for Figma? Can it analyze Figma screenshots directly?

### Skills Marketplace Scan

- [ ] Check github.com/vercel-labs/skills for new official skills
- [ ] Check github.com/agentskillexchange/skills for new security-scanned skills
- [ ] Check github.com/trailofbits/skills for new security research skills
- [ ] Check github.com/anthropics/skills for new Anthropic-published skills
- [ ] Check github.com/AgentSecOps/SecOpsAgentKit for new security ops skills
- [ ] Run `npx skills add <repo> --list` to see what's new before installing
- [ ] Check for caveman updates (token reduction improvements)
- [ ] Check for new .NET / React / SQL Server specific skills
- [ ] Verify installed skills still work after CLI version updates

### Cost Optimization

- [ ] Any subscription price changes?
- [ ] Any new free tiers or credits?
- [ ] API pricing changes for DeepSeek/MiniMax?
- [ ] Can any paid feature replace a custom implementation?
- [ ] Is caveman actually reducing token usage? Check session logs.

## Verification-First Process

NEVER implement a feature based on assumptions or training data. Every feature must be verified before adoption.

### Step 1: Discover
- Read the provider's official changelog and documentation
- Search for the feature name in official docs (not blog posts or community speculation)
- If the feature has a CLI flag, run it locally and confirm it works

### Step 2: Verify
- Run a minimal test: create a throwaway project and test the feature in isolation
- Confirm: does it actually do what the docs say? On your OS? With your subscription tier?
- Document: exact command, exact output, exact behavior observed
- If the feature doesn't work as documented, mark it as "unverified" and move on

### Step 3: Evaluate
- Does it replace custom code? If yes, how many lines does it save?
- Does it reduce cost? Run both paths and compare actual token/dollar costs
- Does it improve quality? Run the same task with and without, compare outputs
- Does it improve speed? Time both paths with the same input
- Is it Claude-only? If yes, keep the TypeScript harness for multi-LLM; use native for orchestration only
- Is it stable? If experimental, add to "watching" table. If GA, proceed to Step 4

### Step 4: Implement
- Create a branch, implement the change, test the full pipeline
- Verify no regressions in existing agents
- Update the developer guide Section 10.11 (move from "not yet confirmed" to "in use")
- Update the change log at the bottom of Section 10.11
- Commit with a clear message explaining what was adopted and why

### Step 5: Monitor
- After 1 week: check vault session logs for any errors related to the new feature
- After 30 days: evaluate whether the feature delivered the expected benefit
- If not: revert and document why in the change log

## Auth Mode Strategy

The pipeline supports dual auth for Claude:

| Mode | Auth | Cost | When Used |
|---|---|---|---|
| CLI (default) | OAuth via `claude auth login` | $0 (Max subscription) | Normal operation |
| SDK (backup) | `ANTHROPIC_API_KEY` env var | Pay-per-token | When CLI hits rate limit |

The pipeline auto-switches: CLI fails → 5-min cooldown → SDK takes over → cooldown expires → back to CLI. Set `ANTHROPIC_API_KEY` in environment to enable the backup.

## Change Log

### 2026-04-23 (V7.0 spec + live research sweep)

**OpenAI:**

- **GPT-5.5 announced 2026-04-23.** Rolled out to ChatGPT Plus/Pro/Business/Enterprise and **Codex CLI first**; API rollout described as "coming very soon" but no public SKU confirmed at time of writing. Do NOT hard-code `gpt-5.5` as a model id in any config or router until a 200 response is verified from a real API probe.
  - Benchmarks: Terminal-Bench 2.0 **82.7%** (vs Opus 4.7 69.4%), SWE-Bench Pro **58.6%** (vs Opus 4.7 64.3%), OpenAI MRCR v2 8-needle 512K–1M ctx **74.0%** (vs Opus 4.7 32.2%)
  - Pricing: $5 / $30 per 1M input/output; `GPT-5.5 Pro` tier at $30 / $180
  - Context: 1M API / 400K ChatGPT+Codex
  - Assume 2x surcharge above 272K input tokens (GPT-5.4 inheritance) until confirmed otherwise
  - **Action for GSD V7.0 Upgrade 5:** once confirmed, route generator work to GPT-5.5; keep Opus 4.7 as evaluator (hard-split family invariant satisfied automatically)
  - **OAuth-Codex access path:** if Codex CLI exposes `gpt-5.5` (likely given rollout order), generator work may route through it at $0 marginal cost via the existing OAuth flow. Verify both (a) CLI exposes the id and (b) the operator's subscription tier is in the rollout wave before flipping the router
- SWE-Bench Verified **deprecated** as internal benchmark — frontier models memorized gold patches. Switch rubric calibration references to **SWE-Bench Pro** (`labs.scale.com/leaderboard/swe_bench_pro_public`)

**Anthropic:**

- **Agent Skills open standard** (`agentskills.io`, `github.com/anthropics/skills`) now adopted by Atlassian, Figma, Canva, Stripe, Notion, Zapier, and OpenAI. V7.0 Upgrade 2 (SkillForge) will emit nominations in this schema for portability
- **Claude Mythos Preview** ("Capybara" tier) released 2026-04-07 — invitation-only tier above Opus, finds zero-days in browsers/OSes; not for general GSD use but note for security-focused projects
- Claude Haiku 4.5 unchanged — still the right Hermes notifier / fast-tier slot
- **Claude Agent SDK Python** added `list_subagents()` / `get_subagent_messages()` helpers — would replace our custom subagent tap logging but introduces a Python runtime dependency. Queued for V8

**Google:**

- **Gemini 3.1 Pro / Flash-Lite / Deep Think** tier split — Flash-Lite is a new cheap-generator lane we should add to the `familySplit` pool for V7.0 Upgrade 5 tie-breaking

**DeepSeek:**

- **V4 (1T MoE, ~81% SWE-bench, ~$0.30/MTok projected)** — Reuters 2026-04-06 says "coming in next few weeks" on Huawei chips; NOT shipped yet. Re-evaluate next feature check

**Microsoft:**

- **Playwright CLI recommended over Playwright MCP** for coding agents — ~4x fewer tokens per evaluator session. V7.0 Upgrade 3 standardizes evaluator tools on Playwright CLI transport; MCP stays as fallback

**Research papers (net-new since 2026-04-22):**

- **Confucius Code Agent** (arXiv:2512.10398) — hierarchical working memory + AX/UX/DX three-audience split. V7.0 Upgrade 6 adopts the AX/UX/DX split in scratch-pad schema. Hierarchical memory tiers queued for V8
- **VMAO fork-join DAG** (EMNLP Findings 2025 extended 2026) — Plan→Execute→Verify→**Replan**→Synthesize. Replan node queued for V8 (overlaps with existing Remediation loop; warrants own release)
- **Harvey "Harness Engineering"** (April 2026) — auto-generated toolkits from I/O examples + rubric. Strict superset of SkillForge Upgrade 2; queued for V8

**NVIDIA Build / NIM API (provisioned 2026-04-23):**

- API key provisioned at `https://build.nvidia.com`; live probe of `https://integrate.api.nvidia.com/v1/models` returned 130+ model ids
- Free tier: ~1000 req/day during evaluation, ~40 RPM burst, no published monthly token cap
- OpenAI Chat Completions schema; tool calling supported on most Llama / Qwen / Mistral / DeepSeek / Nemotron variants
- **NVIDIA becomes the legitimate 4th family for V7.0 Upgrade 5 hard generator/evaluator split** (distinct lineage from Anthropic / OpenAI / Google):
  - Generator: `qwen/qwen3-coder-480b-a35b-instruct` (256K, SWE-bench ~69%) and `mistralai/devstral-2-123b-instruct-2512` (256K, agent-tuned)
  - Evaluator: `nvidia/llama-3.3-nemotron-super-49b-v1.5` (128K, RLHF-tuned, Arena-Hard 88.3)
- **DeepSeek V4 is now live via NIM** (`deepseek-ai/deepseek-v4-pro` and `-flash`) — flips the pending V4 gate from "wait for direct API" to "live now via NIM at $0"
- **Llama 4 Maverick at 1M context** (`meta/llama-4-maverick-17b-128e-instruct`) undercuts Gemini 3.1 Pro for cost-sensitive long-context retrieval at $0
- Quirks: no native prompt caching; `max_tokens` per-model (4096 default, 8192 for Nemotron Ultra and Llama 4 Maverick); some ids redirect via `nvcf.nvidia.com` — probe before pinning; Nemotron variants prefer system content prepended to first user turn
- Concrete routing changes captured in `memory/knowledge/model-strategy.md` under "NVIDIA Build / NIM (4th family — V7.0 family-split tie-breaker)"
- Action for V7.0 Upgrade 7 commit: add `NVIDIA_API_KEY` to `.env.example` (done 2026-04-23) and the runtime probe list, append the recommended ids to the generator/evaluator/bulk/long-context/Hermes priority tables

### 2026-04-22 (Early check — triggered by V7.0 spec rule #12)

**Anthropic:**

- Claude Opus 4.7 (`claude-opus-4-7`) released 2026-04-16. 1M ctx, adaptive thinking, step-change agentic coding. **Use for orchestration/review phases.**
- Claude Sonnet 4.6 + Haiku 4.5 unchanged — remain best workhorse/fast tiers.
- ⚠️ Retire before 2026-06-15: `claude-sonnet-4-20250514`, `claude-opus-4-20250514`
- New: 1M context standard at base price (no surcharge), adaptive thinking (dynamic budget vs fixed)
- Batch API: up to 300K output tokens via beta header — useful for bulk reviews (TODO next sprint)
- Agent teams: still being evaluated

**OpenAI:**

- `gpt-5.1-codex-mini` **obsolete** — replaced by `gpt-5.3-codex` ($1.75/$14/M) for coding tasks
- GPT-5.4 ($2.50/$15/M) now flagship — integrates Codex coding capability into mainline model
- ChatGPT Max subscription CLI now routes to GPT-5.4 / GPT-5.3-Codex depending on task
- Batch API at 50% discount on GPT-5.4-mini — evaluate for bulk review chunks

**Google:**

- Gemini 3 series is current production. Gemini 2.5 Pro free tier **ended 2026-04-01**.
- Current Flash: `gemini-3-flash-preview` ($0.50/$3.00/M) — Gemini Ultra subscription routes here
- Context caching at 90% discount — evaluate for repeated system prompts

**DeepSeek:**

- No config change needed. `deepseek-chat` → V3.2 (same routing key). $0.28/$0.42/M. Cache hit 90% off.

**Kimi:**

- K2.6 released 2026-04-20. 262K ctx, 300 sub-agents, $0.75/$3.50/M. model-registry.json updated to `kimi-k2.6`.

**MiniMax:**

- M1 is current ($0.40/$2.20/M, 1M ctx). `MiniMax-M2.5` doesn't exist — model-registry.json corrected to `MiniMax-M1`.

**GLM:**

- `glm-4.7-flash` is free tier (replaces `glm-4-flash`). Still disabled due to firewall. model-registry.json updated.

### 2026-04-10 (Initial)

- Established 30-day check schedule
- V6: Hybrid architecture (TypeScript harness + Claude Code native features, SQLite state, worktrees)
- Dual auth: CLI OAuth primary, API key backup with auto-switch
- Agent teams: experimental, monitoring for GA
- Prompt caching: not yet applied
- Batch API: not yet applied

### Next Check: 2026-05-22

- Verify Opus 4.7 adaptive thinking vs Sonnet 4.6 extended thinking for orchestrator use — run evals
- Apply Batch API to CodeReviewAgent bulk chunking (50% cost reduction opportunity)
- Apply context caching to agent system prompts (repeated on every call — high cache hit rate expected)
- Check if agent teams reached GA
- Check for Claude Sonnet 5 / Haiku 5 availability
