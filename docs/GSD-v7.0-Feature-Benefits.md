---
type: upgrade-summary
id: gsd-v7.0-feature-benefits
title: GSD V7.0 Feature and Pipeline Benefit Summary
status: Proposed
date: 2026-04-27
depends_on: [gsd-v7.0, gsd-v7.0-managed-agents]
---

# GSD V7.0 Feature and Pipeline Benefit Summary

## Executive Summary

V7 turns GSD from a strong multi-agent SDLC pipeline into a more observable, self-improving, risk-aware development runtime. The release keeps V6 compatibility: existing pipeline behavior remains available, while new V7 features are feature-flagged, opt-in, or sidecar-based until proven.

The theme is simple: fewer silent failures, fewer repeated mistakes, better model routing, stronger review independence, better UI/mobile output, and more durable long-running runs.

## Core V7 Features

| Feature | What we are adding | Why it helps the GSD pipeline |
|---|---|---|
| HermesAgent | A notification sidecar for escalations, gate halts, rollback events, budget exhaustion, and post-deploy failures. | Stops long runs from silently pausing. Humans get notified when intervention matters, while normal automation keeps moving. |
| SkillForge | A post-session skill nomination system that mines successful repeated patterns and proposes human-approved skills. | GSD learns from its own wins. Repeated fixes become reusable procedures instead of being rediscovered every run. |
| Evaluator Contracts | A structured contract defining what “done” means before generation starts. | Reduces vague acceptance criteria. Review agents can grade against the agreed target instead of interpreting intent after the fact. |
| Grading Rubrics | Explicit rubric files for review, gate, audit, UI, security, correctness, and quality dimensions. | Turns subjective review into measurable scoring. Makes quality trends auditable across runs. |
| ReviewAuditor Live Tools | Read-only evaluator tooling, including Playwright CLI where useful. | Gives the second-opinion reviewer direct evidence from UI/API behavior, not only code summaries. |
| Fork-Join DAG Pipeline | Replaces hardcoded linear stage flow with a declarative graph, defaulting to V6 sequential behavior. | Allows safe parallelism where stages are independent, such as audit and E2E preparation, without forcing risky parallel remediation. |
| Hard Generator/Evaluator Family Split | Enforces distinct model families between generation and evaluation when enabled. | Reduces self-review bias. A model family that generated code does not get to be the only judge of that code. |
| Agent Scratch Pads | Per-run, append-only scratch memory for each agent with AX/UX/DX views. | Improves debugging and postmortems. Agents and SkillForge can see why a decision was made, not just the final output. |
| Gather/Act/Verify Phase Labels | Agent frontmatter declares how each agent gathers context, acts, and verifies. | Makes agent behavior easier to reason about and tune. Helps route tasks to agents with the right lifecycle shape. |
| Extended Model Pool | Adds probe-gated routing for GPT-5.5/Codex, DeepSeek V4, Gemini Flash-Lite, NVIDIA NIM, and other model lanes. | Improves cost, speed, and availability. V7 can use the right model for the task instead of overusing one premium model. |
| Fluent UI v9 Mastery Skill | A feedforward implementation skill for production-grade Fluent UI React v9 applications. | Raises baseline frontend quality: tokens, accessibility, component choices, states, and interaction polish. |
| Fluent UI v9 Design Review | A dedicated frontend review skill and `/design-review` command. | Catches UI-specific failures that general code review misses, such as raw styling, missing states, weak accessibility, or poor component selection. |
| React Native + Expo Mastery Skill | A mobile implementation skill for iOS/Android apps using React Native and Expo. | Makes mobile a first-class GSD target, not an afterthought bolted onto web specs. |
| React Native Design Review | A mobile-specific review skill and `/mobile-design-review` command with platform parity checks. | Forces review across iOS and Android, including safe areas, offline state, haptics, keyboard behavior, and accessibility. |

## New Managed Source-Agent Layer

V7 also adds managed external source agents under `memory/managed-agents/`. These are not runtime pipeline agents yet. They are source-specific watch contracts that preserve external research, vendor facts, and routing guidance without stuffing everything into global prompts.

| Managed source feature | Source-driven addition | Why it helps |
|---|---|---|
| Managed Source-Agent Catalog | A durable note for every watched source link. | Prevents one-off research from disappearing. Gives DocGardener, SkillForge, and model probes a stable source contract. |
| Karpathy Simplicity/Surgicality Rubric | Adds review criteria for minimal diffs, explicit assumptions, and goal-traceable changes. | Reduces overengineering and drive-by refactors. Keeps remediation tightly scoped. |
| DeepSeek V4 Direct API Watch | Tracks `deepseek-v4-pro`, `deepseek-v4-flash`, and retirement of older aliases. | Keeps cheap codegen/remediation lanes current and avoids routing to retiring model IDs. |
| NVIDIA Build/NIM Lane | Authenticated probe confirmed 136 model IDs and successful smoke tests for DeepSeek V4 Flash and Nemotron Super. | Gives GSD a free development/evaluation model lane and a fourth family for generator/evaluator split. |
| Self-Verification Mode | Optional forward/backward candidate verification for high-risk reasoning tasks. | Adds deeper verification for architecture, security, compliance, and routing decisions without slowing every task. |
| Goose Pattern Watch | Tracks recipes, subrecipes, ACP, subagents, MCP catalogs, and adversary review. | Gives V8 a practical path for portable workflows and security-review patterns while keeping V7 stable. |
| Gemini Deep Research Routing | Separates interactive research from deeper asynchronous due diligence. | ResearcherAgent can pick the right research depth for intake, vendor review, and evidence-heavy decisions. |
| GPT-5.5 Stuck-Task Escalation | Uses field reports and official probes to route stuck loops to GPT-5.5 when available. | Helps break hard debugging, auth, realtime sync, backend config, and multi-file API wiring loops with fewer retries. |
| OpenMythos Depth Watch | Tracks recurrent-depth and adaptive-computation ideas. | Queues future routing controls for reasoning depth if providers expose them. No risky V7 runtime dependency. |
| AgentSPEX Workflow Watch | Tracks typed YAML workflows with explicit state, branching, loops, parallelism, checkpoints, and replay. | Validates V7 PipelineGraph and suggests a future inspectable workflow-spec layer. |
| LangChain Production Runtime Checklist | Adds a checklist for durable execution, checkpoints, memory, HITL, streaming, observability, sandboxes, integrations, and cron. | Ensures GSD is evaluated as a production-grade development runtime, not just a prompt harness. |
| Kilo Model Benchmark Routing Lesson | Routes cheap/open-weight models to scaffolds and frontier/evaluator passes to correctness-sensitive paths. | Improves cost/performance decisions. Passing tests is not enough for leases, scheduling, streaming, auth, and data integrity. |
| EvoMap Evolver Watch | Tracks Gene/Capsule/Event strategy memory as a possible SkillForge evolution. | Preserves a promising self-improvement direction for V8 without destabilizing V7. |

## NVIDIA Build/NIM In V7

The NVIDIA key was found in vault/project memory and authenticated successfully on 2026-04-27. The model endpoint returned 136 model IDs, and small chat completion smoke tests succeeded.

| V7 lane | Recommended NVIDIA-hosted models |
|---|---|
| Cheap bulk codegen | `deepseek-ai/deepseek-v4-flash`, `minimaxai/minimax-m2.7`, `qwen/qwen3-coder-480b-a35b-instruct` |
| Heavy remediation/codegen | `deepseek-ai/deepseek-v4-pro`, `mistralai/devstral-2-123b-instruct-2512` |
| Evaluator/reviewer | `nvidia/llama-3.3-nemotron-super-49b-v1.5`, `nvidia/nemotron-3-super-120b-a12b`, `openai/gpt-oss-120b` |
| Long-context research | `meta/llama-4-maverick-17b-128e-instruct`, `deepseek-ai/deepseek-v4-pro` |
| Code search/embeddings | `nvidia/nv-embedcode-7b-v1`, `baai/bge-m3`, `snowflake/arctic-embed-l` |
| Guardrails/security | `nvidia/gliner-pii`, `nvidia/nemotron-content-safety-reasoning-4b`, `meta/llama-guard-4-12b` |

NVIDIA Build/NIM is appropriate for GSD because the intended use is AI-driven software development: internal code generation, review, remediation, testing, and evaluation. NVIDIA documents free Developer Program access for prototyping, research, development, and testing. GSD should not route live customer-facing production app traffic through this lane.

## How V7 Improves Each Pipeline Stage

| Pipeline area | V7 improvement |
|---|---|
| Requirements / Intake | Gemini Deep Research and managed source agents improve evidence gathering. Evaluator contracts make acceptance criteria explicit earlier. |
| Architecture | Self-verification can be enabled for high-risk architecture decisions. AgentSPEX/LangChain runtime lessons make state and control flow more explicit. |
| Blueprint Freeze | Evaluation contracts define what downstream agents must satisfy. UI/mobile mastery skills improve web and mobile implementation guidance. |
| Code Review | Rubrics, Simplicity/Surgicality checks, model-family split, and ReviewAuditor reduce shallow or biased review. |
| Remediation | NVIDIA/DeepSeek/GPT-5.5 lanes improve cost and stuck-loop handling. Scratch pads make failed attempts diagnosable. |
| Quality Gate | Guardrail/security models can augment Semgrep and existing checks. Targeted reproductions catch hard behavioral bugs beyond “tests passed.” |
| E2E Validation | Fork-join scheduling allows safe parallel prep. Playwright CLI keeps evaluator evidence concise. |
| Deploy / Post-Deploy | Hermes reports rollback, halt, and live-failure signals. Runtime-readiness checks improve durability and observability. |
| Long-Running Runs | SQLite state, scratch pads, DAG execution, Hermes, and production-runtime checklist make runs easier to resume, debug, and trust. |

## Expected Pipeline Benefits

| Benefit | What changes in practice |
|---|---|
| Lower silent-failure risk | Hermes notifies when a run pauses, rolls back, or hits a critical gate. |
| Better convergence | GPT-5.5 escalation, SkillForge, scratch pads, and targeted reproduction tests reduce repeated loops. |
| Lower development cost | NVIDIA Build/NIM and DeepSeek V4 provide free/cheap development lanes before premium model escalation. |
| Stronger quality control | Evaluator contracts, rubrics, model-family split, and ReviewAuditor make review more independent and measurable. |
| Better UI/mobile output | Fluent and React Native mastery/review skills raise frontend and mobile quality before client review. |
| More durable automation | DAG scheduling, checkpoints/state, runtime checklist, and scratch memory improve long-run reliability. |
| Safer model routing | CapabilityRouter can choose models by task type, risk, cost, context, and evaluator independence. |
| More institutional learning | SkillForge and managed source agents turn pipeline experience and external research into reusable assets. |

## What Stays Deferred

| Deferred item | Why not V7 |
|---|---|
| Bidirectional Hermes ack/reply | Requires inbound listeners and more security surface. V7 keeps notifications one-way. |
| Auto-promoting skills without approval | Too risky. SkillForge nominates; humans approve. |
| Full AgentSPEX-style YAML workflow runtime | Useful idea, but V7 should stabilize `PipelineGraph` first. |
| Evolver Gene/Capsule runtime | Promising but experimental and license-sensitive. Keep as V8 research. |
| Dynamic reasoning-depth routing | Wait until official providers expose safe controls. |
| Production customer-serving use of NVIDIA Build | Not needed. GSD uses it for development/testing only. |

## Bottom Line

V7 should make GSD faster, cheaper, more reliable, and more reviewable without throwing away V6. The big win is not one single feature; it is the combination:

- Hermes makes failures visible.
- SkillForge and scratch pads make learning durable.
- Rubrics and model-family split make review more trustworthy.
- DAG scheduling improves throughput.
- NVIDIA/DeepSeek/GPT-5.5 routing improves cost and stuck-loop handling.
- UI/mobile skills improve client-facing output quality.
- Managed source agents keep the system current without bloating prompts.

