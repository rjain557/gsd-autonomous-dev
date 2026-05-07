---
type: managed-agent
id: deepseek-v4-direct-api-watch-agent
status: Proposed
source_url: https://api-docs.deepseek.com/news/news260424
source_access: fetched-2026-04-27
owned_upgrade: v7.0-extended-model-pool
activation: model-probe, monthly-feature-check
---

# DeepSeek V4 Direct API Watch Agent

## Purpose

Track DeepSeek's direct V4 API rollout and keep GSD routing current as V4 replaces the older DeepSeek aliases.

## V7 Additions

- Promote `deepseek-v4-pro` and `deepseek-v4-flash` from speculative slots to direct DeepSeek API probe candidates.
- Add a retirement warning for `deepseek-chat` and `deepseek-reasoner`, which the source says become inaccessible after 2026-07-24 15:59 UTC.
- Add a probe requirement for 1M context, Thinking / Non-Thinking mode support, OpenAI Chat Completions compatibility, and Anthropic API compatibility.

## Operating Contract

1. Probe the direct DeepSeek endpoint before falling back to NVIDIA NIM.
2. If direct API succeeds, write a routing recommendation for `memory/knowledge/model-strategy.md`.
3. If aliases still route to V4 Flash, note the alias but prefer explicit V4 model ids in new V7 config.

## Acceptance Criteria

- No V7 routing table depends on a retiring DeepSeek alias after 2026-07-24.
- DeepSeek V4 is selected only after a live probe confirms the target model id and context behavior.

