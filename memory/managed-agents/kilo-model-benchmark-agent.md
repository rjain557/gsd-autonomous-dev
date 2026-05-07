---
type: managed-agent
id: kilo-model-benchmark-agent
status: Proposed
source_url: https://blog.kilo.ai/p/we-gave-claude-opus-47-and-kimi-k26
source_access: fetched-2026-04-27
replaces_share_url: https://share.google/2QoDVY4ef8FlkSEYH
owned_upgrade: v7.0-capability-router-and-evaluator-contracts
activation: model-strategy-review, monthly-feature-check
---

# Kilo Model Benchmark Agent

## Purpose

Track model-comparison evidence that separates scaffold generation from correctness-sensitive workflow engineering.

## V7 Additions

- Route open-weight/cost-sensitive models such as Kimi K2.6 toward scaffold generation, prototype breadth, endpoint/table/test-suite creation, and low-risk bulk work.
- Route Claude Opus-class evaluators/generators toward state-machine correctness, lease/claim/recovery semantics, cross-run scheduling, streaming, and other hard-to-test code paths.
- Add targeted reproduction tests as an evaluator-contract requirement for correctness-sensitive systems. Passing model-written tests is not enough.

## Operating Contract

1. Keep cost-per-point as an input to CapabilityRouter, not the whole decision.
2. Require evaluator-generated targeted reproductions for concurrency, lease, scheduling, streaming, auth, and data-integrity code paths.
3. Treat model self-reports as low-trust evidence until independently reviewed.

## Acceptance Criteria

- V7 routing makes an explicit quality/cost tradeoff by task type.
- ReviewAuditor checks the hardest behavioral paths, not only whether tests passed.

