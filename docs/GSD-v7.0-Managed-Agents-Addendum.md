---
type: upgrade-addendum
id: gsd-v7.0-managed-agents
title: GSD V7.0 Managed External Source Agents Addendum
status: Proposed
date: 2026-04-27
depends_on: [gsd-v7.0, v6-design, agent-system-design]
---

# GSD V7.0 Managed External Source Agents Addendum

## Executive Summary

The 2026-04-27 source review does not require a disruptive rewrite of the V7 plan. The main V7 upgrades are still directionally right: Hermes, SkillForge, evaluator contracts, fork-join scheduling, model-family split, scratch pads, extended model pool, and UI/mobile skills.

What should be added is a managed external-source layer: source-specific sidecar agents that watch high-value references, translate them into V7/V8 recommendations, and keep vendor/link-specific facts from being smeared into global prompts. The managed agents live in `memory/managed-agents/`.

## Recommended V7 Additions

| Addition | Why now | Upgrade affected |
|---|---|---|
| Managed source-agent catalog | The user supplied source links that should become durable watched inputs, not one-off notes. | New addendum to V7 |
| Simplicity/Surgicality rubric | Karpathy-style guidance maps cleanly to measurable review behavior. | Upgrade 3 |
| DeepSeek V4 direct API probe | DeepSeek V4 is now documented as available through the official API; old aliases retire on 2026-07-24. | Upgrade 7 |
| Optional self-verification mode | Useful for high-risk evaluator contracts, but too expensive as a default. | Upgrade 3 |
| Goose recipe/security watch | Goose validates recipes, subagents, MCP extension catalogs, ACP, and adversary review as patterns worth tracking. | V8 candidate, minor V7 watch |
| Gemini Deep Research routing | Google's Deep Research / Max split maps to interactive vs asynchronous research lanes. | ResearcherAgent / Upgrade 7 |
| Evolver Gene/Capsule experiment | Promising direction for SkillForge evolution, but license and architecture risk make it V8 material. | V8 candidate |
| GPT-5.5 stuck-task escalation | Lovable reports stronger hardest-task performance, fewer tool calls, fewer output tokens, and better unstuck behavior than GPT-5.4. | Upgrade 7 |
| Recurrent-depth model watch | OpenMythos illustrates depth extrapolation and adaptive computation as future routing controls. | V8 candidate |
| AgentSPEX workflow language watch | Declarative typed workflows validate V7's `PipelineGraph` and suggest a future YAML workflow layer. | Upgrade 4 / V8 candidate |
| Production runtime readiness checklist | LangChain's deep-agents runtime frames the non-model infrastructure GSD must cover. | V7 implementation checklist |
| Model-routing by correctness risk | Kilo's Claude/Kimi benchmark shows cheap models are useful for scaffolds but weaker on hard state-machine paths. | Upgrade 5 / CapabilityRouter |
| NIM hosting lane separation | NVIDIA-hosted DeepSeek V4 remains useful even if direct DeepSeek API is live. | Upgrade 7 |

## Source Review Notes

### Karpathy-Inspired Skills

The repository frames four principles: think before coding, simplicity first, surgical changes, and goal-driven execution. GSD already has much of this behavior in developer instructions, but V7 should promote it into evaluator rubrics so reviewers can score it directly.

Managed agent: `memory/managed-agents/karpathy-guidelines-curator-agent.md`

### DeepSeek V4 Direct API

DeepSeek's 2026-04-24 notice says V4 Preview is live, open-weight, available through API, supports 1M context, and can be selected by updating the model to `deepseek-v4-pro` or `deepseek-v4-flash`. It also states `deepseek-chat` and `deepseek-reasoner` retire after 2026-07-24 15:59 UTC.

Managed agent: `memory/managed-agents/deepseek-v4-direct-api-watch-agent.md`

### Self-Verification

Self-verification generates candidate answers, then backward-checks whether each conclusion can recover the original conditions. The tradeoff is cost: multiple candidate inference chains are required. V7 should support it as an optional high-risk evaluator mode, not a blanket review behavior.

Managed agent: `memory/managed-agents/self-verification-rubric-agent.md`

### Goose

Goose is relevant as a pattern source: portable YAML recipes/subrecipes, MCP extension catalogs, ACP server/provider interop, parallel subagents, and security controls including prompt-injection detection and adversary review. V7 should watch it; V8 can decide whether `GsdRecipe` is worth implementing.

Managed agent: `memory/managed-agents/goose-patterns-import-agent.md`

### Gemini Deep Research

Google now describes Deep Research and Deep Research Max as autonomous research agents. Deep Research is optimized for interactive speed and cost; Max is aimed at comprehensive asynchronous work with extended test-time compute, web plus proprietary data, MCPs, files, and cited reports. GSD should map these to research-tier routing.

Managed agent: `memory/managed-agents/gemini-deep-research-agent.md`

### EvoMap Evolver

Evolver introduces a Gene/Capsule/Event model for experience-driven test-time evolution. The idea is relevant to SkillForge, but V7 should not adopt the runtime. The safer path is a V8 experiment comparing markdown skills with compact strategy genes on GSD's own session data.

Managed agent: `memory/managed-agents/evomap-evolver-agent.md`

### NVIDIA DeepSeek V4 Pro

The NVIDIA page confirms a NIM model page for `deepseek-ai/deepseek-v4-pro`, but the public page exposed limited machine-readable details in this environment. Keep NIM as a distinct hosting lane with its own probe and fallback behavior.

Managed agent: `memory/managed-agents/nvidia-deepseek-v4-pro-agent.md`

### Lovable GPT-5.5 Field Evaluation

Lovable's early-access testing reports GPT-5.5 outperforming GPT-5.4 on hardest tasks, using fewer tool calls, lowering output tokens, and reducing stuck user messages. V7 should use this as field evidence for a premium stuck-task escalation lane, not as a replacement for official OpenAI availability probes.

Managed agent: `memory/managed-agents/lovable-gpt55-eval-agent.md`

### OpenMythos Recurrent Depth

The OpenMythos tutorial is relevant as architecture signal: recurrent depth, depth extrapolation, adaptive halting, and MoE routing point toward future provider controls for inference depth. V7 should not import this runtime, but V8 should watch for official model APIs exposing reasoning-depth budgets.

Managed agent: `memory/managed-agents/openmythos-depth-routing-agent.md`

### Analytics Vidhya GPT-5.5 Hands-On

Analytics Vidhya's hands-on report reinforces GPT-5.5's target categories: agentic coding, computer/tool workflows, professional knowledge work, and scientific/technical reasoning. The source is secondary; official OpenAI docs remain authoritative for pricing, model ids, API availability, safeguards, and context windows.

Managed agent: `memory/managed-agents/analyticsvidhya-gpt55-field-agent.md`

### AgentSPEX

AgentSPEX proposes typed YAML workflows with explicit control flow, state, branching, loops, parallelism, reusable submodules, sandbox execution, checkpointing, verification, logging, and visual editing. This strongly validates V7's fork-join DAG direction and suggests a V8 candidate: serialize or compile GSD `PipelineGraph` into an inspectable workflow DSL.

Managed agent: `memory/managed-agents/agentspex-workflow-language-agent.md`

### LangChain Production Deep Agents Runtime

LangChain separates the harness from the production runtime underneath it: durable execution, checkpoints, memory, multi-tenancy, human-in-the-loop, streaming, observability, sandboxes, integrations, and cron. GSD already has pieces of this through SQLite state, vault memory, Hermes, scratch pads, hooks, and worktrees. V7 should add a production-runtime readiness checklist so those pieces are evaluated as a coherent runtime.

Managed agent: `memory/managed-agents/langchain-deepagents-runtime-agent.md`

### Kilo Claude Opus 4.7 vs Kimi K2.6 Benchmark

Kilo's benchmark is the clearest routing lesson in this batch: cheaper open-weight models can produce a strong scaffold, but correctness-sensitive workflow engines still need frontier models and targeted reproductions for lease recovery, scheduling, streaming, and other hard paths. V7 should route by task risk, not only by cost, and ReviewAuditor should distrust model self-reports that only say tests passed.

Managed agent: `memory/managed-agents/kilo-model-benchmark-agent.md`

## Implementation Guidance

Do not add these managed agents to `AgentId` yet. They should first be consumed by:

1. `DocGardener`, to verify watched links and stale facts.
2. `SkillForge`, to seed or validate skill nominations.
3. `CapabilityRouter`, to use model-provider watch agents during probe-based routing.
4. The monthly feature-check workflow, to keep source-specific facts current.

Runtime agent classes are only warranted after a managed agent has produced at least one approved V7/V8 change.
