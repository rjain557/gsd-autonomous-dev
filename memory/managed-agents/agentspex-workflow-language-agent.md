---
type: managed-agent
id: agentspex-workflow-language-agent
status: Proposed
source_url: https://huggingface.co/papers/2604.13346
source_access: fetched-2026-04-27
replaces_share_url: https://share.google/j452l8oHBqOMyG5mM
owned_upgrade: v7.0-fork-join-dag
activation: pipeline-graph-design-review, monthly-feature-check
---

# AgentSPEX Workflow Language Agent

## Purpose

Track AgentSPEX as validation for V7's declarative pipeline graph and as a possible V8 workflow-spec language.

## V7 Additions

- Add a V8 candidate for serializing `PipelineGraph` to a typed YAML workflow format with explicit state, branching, loops, parallel nodes, reusable submodules, checkpoints, verification, and logging.
- Add a V7 design-review question for `PipelineGraph`: are control flow, state transitions, and retry/verification semantics explicit enough to inspect and replay?
- Keep GSD's TypeScript harness as the execution engine for V7; do not adopt AgentSPEX directly.

## Operating Contract

1. Watch the paper/project for concrete schema and execution semantics.
2. Compare AgentSPEX typed steps against GSD `PipelineGraph`, `ExecutionGraph`, and evaluator contracts.
3. Propose a GSD workflow-spec adapter only after the V7 DAG implementation stabilizes.

## Acceptance Criteria

- V7's fork-join DAG stays inspectable and replayable.
- Any future YAML workflow layer remains generated from, or compiled into, the TypeScript source of truth.

