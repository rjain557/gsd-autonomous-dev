---
type: managed-agent
id: langchain-deepagents-runtime-agent
status: Proposed
source_url: https://www.langchain.com/blog/runtime-behind-production-deep-agents
source_access: fetched-2026-04-27
replaces_share_url: https://share.google/MFbM0WEkjOtFQpqY6
owned_upgrade: v7.0-production-runtime-readiness
activation: architecture-review, monthly-feature-check
---

# LangChain Deep Agents Runtime Agent

## Purpose

Track production-runtime requirements for long-running agents and map them to GSD's V7 runtime plan.

## V7 Additions

- Add a production-runtime readiness checklist covering durable execution, checkpoints, long-term memory, multi-tenancy, human-in-the-loop, streaming/progress, observability, sandboxes, integrations, and cron.
- Strengthen Hermes + scratch pads + SQLite state as the GSD-native answer to production runtime needs.
- Add a V8 candidate for formal human-in-the-loop interrupts/resume, beyond Hermes one-way notifications.

## Operating Contract

1. Compare GSD runtime capabilities against the production-runtime checklist before V7 implementation freeze.
2. Mark gaps as V7 blocker, V7 acceptable deferral, or V8 candidate.
3. Preserve GSD's model-agnostic, repo/vault-owned architecture.

## Acceptance Criteria

- V7 is evaluated as a production runtime, not only a prompt harness.
- Long-running GSD milestones can survive crashes, pauses, and human review points with explicit state.

