---
type: managed-agent
id: analyticsvidhya-gpt55-field-agent
status: Proposed
source_url: https://www.analyticsvidhya.com/blog/2026/04/i-tried-the-new-gpt-5-5/
official_probe_reference: https://openai.com/index/introducing-gpt-5-5/
source_access: fetched-2026-04-27
replaces_share_url: https://share.google/fjB5PFDZROUbkdRLI
owned_upgrade: v7.0-extended-model-pool
activation: model-probe, monthly-feature-check
---

# Analytics Vidhya GPT-5.5 Field Agent

## Purpose

Track hands-on GPT-5.5 reports as secondary evidence for task categories where GSD may route to GPT-5.5.

## V7 Additions

- Reinforce GPT-5.5 routing for agentic coding, computer/tool workflows, professional knowledge work, and scientific/technical reasoning.
- Keep the official OpenAI probe as the authority for model ids, API availability, pricing, context windows, and safeguards.
- Add `computer_use_orchestration` as a future route category for tool-heavy SDLC tasks.

## Operating Contract

1. Use this source only as field evidence, not authoritative pricing or release truth.
2. Cross-check any model availability/pricing details against OpenAI docs before changing config.
3. Convert successful local trials into eval cases under `memory/evals/`.

## Acceptance Criteria

- V7 model strategy distinguishes official availability from third-party trial impressions.
- GPT-5.5 is routed only after local/probe confirmation.
