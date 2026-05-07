---
type: managed-agent
id: lovable-gpt55-eval-agent
status: Proposed
source_url: https://lovable.dev/blog/gpt-5-5-now-in-lovable
official_probe_reference: https://openai.com/index/introducing-gpt-5-5/
source_access: fetched-2026-04-27
replaces_share_url: https://share.google/XLkyPhdJRClZ05JgZ
owned_upgrade: v7.0-extended-model-pool
activation: model-probe, stuck-task-escalation, monthly-feature-check
---

# Lovable GPT-5.5 Evaluation Agent

## Purpose

Track Lovable's early-access GPT-5.5 production findings as a field signal for GSD model routing, especially stuck-task escalation.

## V7 Additions

- Add `stuck_task_breakthrough` as a routing use case for GPT-5.5 once Codex/API access is verified.
- Treat GPT-5.5 as a premium escalation lane for hard debugging loops, UI polish that will not converge, backend configuration failures, auth flows, realtime sync, and complex multi-file API wiring.
- Add an evaluation metric to GSD runs: tool calls per resolved task. Lovable reports GPT-5.5 used fewer tool calls and fewer output tokens than GPT-5.4 on their workloads, which maps directly to GSD convergence cost.

## Operating Contract

1. Verify GPT-5.5 availability through official OpenAI/Codex probes before active routing.
2. Compare GSD stuck-loop resolution rate before/after enabling the GPT-5.5 escalation lane.
3. Keep GPT-5.5 behind feature flags until local runs confirm the field report on GSD workloads.

## Acceptance Criteria

- GPT-5.5 is used where it can reduce loops, not as the default for cheap bulk execution.
- Routing decisions capture whether GPT-5.5 reduced retries, tool calls, or output tokens.
