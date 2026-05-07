---
type: managed-agent-catalog
id: v7-managed-external-source-agents
status: Proposed
date: 2026-04-27
owner: gsd-v7.0
---

# V7 Managed External Source Agents

These managed agents are V7 sidecar agents for external references supplied during the 2026-04-27 upgrade review. They are not part of the seven-stage pipeline graph and are not `AgentId` runtime classes yet. They are durable source-specific contracts that SkillForge, DocGardener, CapabilityRouter, and the monthly feature-check cadence can adopt when V7 implementation starts.

## Operating Model

- Each managed agent owns one external source URL.
- Each agent records what to monitor, what V7 upgrade it affects, and what artifact it may update.
- Agents are read-only by default. They create recommendations, nominations, or routing proposals; humans approve runtime changes.
- Short `share.google` links were resolved into canonical links when the user provided replacements; each resolved source keeps its original `replaces_share_url` for traceability.

## Catalog

| Source | Managed agent | V7 recommendation |
|---|---|---|
| `https://github.com/forrestchang/andrej-karpathy-skills` | `karpathy-guidelines-curator-agent` | Add a Simplicity/Surgicality rubric dimension and SkillForge seed guidance. |
| `https://api-docs.deepseek.com/news/news260424` | `deepseek-v4-direct-api-watch-agent` | Upgrade model pool from pending V4 to direct DeepSeek V4 API, plus retirement watch for `deepseek-chat` / `deepseek-reasoner`. |
| `https://learnprompting.org/docs/advanced/self_criticism/self_verification` | `self-verification-rubric-agent` | Add optional forward/backward candidate verification to evaluator contracts for high-risk reasoning tasks. |
| `https://goose-docs.ai/` | `goose-patterns-import-agent` | Add recipe/subrecipe import, ACP watch, adversary-reviewer pattern, and MCP extension catalog watch. |
| `https://lovable.dev/blog/gpt-5-5-now-in-lovable` | `lovable-gpt55-eval-agent` | Add GPT-5.5 stuck-task escalation lane and track tool-call/token reductions. |
| `https://blog.google/innovation-and-ai/models-and-research/gemini-models/next-generation-gemini-deep-research/` | `gemini-deep-research-agent` | Add research-tier routing: fast Deep Research for interactive intake, Max for asynchronous due diligence. |
| `https://github.com/EvoMap/evolver` | `evomap-evolver-agent` | Add Gene/Capsule experiment track as a V8 candidate or SkillForge extension. |
| `https://www.marktechpost.com/2026/04/23/a-coding-tutorial-on-openmythos-on-recurrent-depth-transformers-with-depth-extrapolation-adaptive-computation-and-mixture-of-experts-routing/` | `openmythos-depth-routing-agent` | Track recurrent-depth/adaptive-computation controls as a V8 model-routing candidate. |
| `https://www.analyticsvidhya.com/blog/2026/04/i-tried-the-new-gpt-5-5/` | `analyticsvidhya-gpt55-field-agent` | Track GPT-5.5 hands-on field categories while keeping official OpenAI probes authoritative. |
| `https://huggingface.co/papers/2604.13346` | `agentspex-workflow-language-agent` | Validate V7 PipelineGraph direction and queue typed YAML workflow specs as a V8 candidate. |
| `https://www.langchain.com/blog/runtime-behind-production-deep-agents` | `langchain-deepagents-runtime-agent` | Add a production-runtime readiness checklist for durable execution, HITL, observability, and memory. |
| `https://build.nvidia.com/deepseek-ai/deepseek-v4-pro` | `nvidia-deepseek-v4-pro-agent` | Keep NIM probe/routing path for DeepSeek V4 Pro as a distinct hosting lane. |
| `https://blog.kilo.ai/p/we-gave-claude-opus-47-and-kimi-k26` | `kilo-model-benchmark-agent` | Add task-type model routing and targeted reproduction checks for correctness-sensitive paths. |
