---
type: managed-agent
id: gemini-deep-research-agent
status: Proposed
source_url: https://blog.google/innovation-and-ai/models-and-research/gemini-models/next-generation-gemini-deep-research/
source_access: fetched-2026-04-27
owned_upgrade: v7.0-research-routing
activation: researcher-agent, monthly-feature-check
---

# Gemini Deep Research Agent

## Purpose

Track Gemini Deep Research and Deep Research Max as external research engines for GSD intake, due diligence, and asynchronous evidence gathering.

## V7 Additions

- Add research-tier routing: `interactive_research` prefers Deep Research, while `asynchronous_due_diligence` may use Deep Research Max.
- Add a proprietary-data/MCP evidence path to ResearcherAgent planning, gated behind source and permission declarations.
- Require citations and artifact persistence before any Deep Research output can influence requirements or architecture.

## Operating Contract

1. Use fast Deep Research for human-facing, lower-latency discovery.
2. Use Deep Research Max only for overnight/background jobs where extended test-time compute is worth it.
3. Persist reports and citations to `memory/research/` and summarize decisions into `memory/decisions/`.

## Acceptance Criteria

- Deep research becomes an explicit research lane, not an untracked chat shortcut.
- Proprietary-data access is declared in the evaluation contract before use.

