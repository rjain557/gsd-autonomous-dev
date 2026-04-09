---
type: knowledge
description: Full pipeline process map derived from 2026-04-08 audit
---

# Pipeline Process Map

Derived from the 2026-04-08 pipeline audit.

## Convergence Pipeline

1. **Spec Quality Gate** → Blocks on critical spec conflicts
2. **Create Phases** → Extracts requirements into matrix (one-time or incremental)
3. **Main Loop** (up to 20 iterations):
   - Code Review (chunked multi-agent) → health scoring
   - Research (parallel: Gemini+DeepSeek+Kimi) → findings
   - Post-Research Council → validates research
   - Plan (Claude) → generation queue
   - Pre-Execute Council → validates plan
   - Execute (parallel multi-agent OR monolithic Codex) → code changes
   - Build Validation → dotnet build + npm build
   - Stall Detection → batch resize or escalation

## Blueprint Pipeline

1. **Blueprint** (Claude) → file manifest with tiers
2. **Build Loop** (up to 30 iterations per tier):
   - Build (Codex) → source files
   - Verify (Claude) → status updates
   - Supervisor recovery on stall

## V3 Full Pipeline (Post-Convergence)

Phases 1-9: Convergence → Build Gate → Wire-Up → Code Review → Build Verify → Runtime → Smoke Test → Final Review → Dev Handoff
