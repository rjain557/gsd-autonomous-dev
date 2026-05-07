---
name: active-tasks
description: Current running tasks, PIDs, monitoring checklist
type: project
---

# Active Tasks (Updated 2026-04-27 America/Los_Angeles)

## Task 0: V7 managed external source agents
- **Status**: completed
- **Scope**: reviewed V6/V7 repo and vault memory, reviewed user-supplied V7 upgrade links, created `docs/GSD-v7.0-Managed-Agents-Addendum.md`, linked it from `docs/GSD-v7.0-Upgrade.md`, indexed it in `memory/MEMORY.md`, and created `memory/managed-agents/` source-specific managed-agent notes
- **Outcome**: V7 now has durable watch contracts for Karpathy guidelines, DeepSeek V4 direct API, self-verification, Goose, Gemini Deep Research, EvoMap Evolver, NVIDIA DeepSeek V4 Pro, GPT-5.5 field reports, OpenMythos recurrent-depth routing, AgentSPEX typed workflows, LangChain production runtime, and Kilo model-routing benchmarks
- **Follow-up if resumed**: implement the approved V7 source-agent recommendations into rubric files, model probes, and pipeline-graph implementation tasks

## Task 1: 4.2 docs and memory alignment
- **Status**: completed
- **Scope**: aligned `readme.md`, `CLAUDE.md`, `docs/GSD-Developer-Guide.md`, `docs/GSD-Workstation-Setup.md`, `docs/workstation.md`, `docs/GSD-Installation-Graphify.md`, `memory/MEMORY.md`, and `memory/knowledge/tools-reference.md` to V6
- **Outcome**: canonical docs now describe the V6 augmentation stack, current skill layout, unified CLI/resume commands, and `.claude/settings.json` hook/MCP wiring accurately
- **Follow-up if resumed**: sweep secondary legacy docs for leftover pre-V6 wording where it affects onboarding

## Task 2: tech-web-chatai.v8 recovery handoff
- **Pipeline status**: stopped by user; no matching pipeline process found in follow-up check
- **App status**: frontend build passes, API build passes, runtime validation passes (`178 passed, 0 failed`)
- **Latest visible run**: `full-pipeline-2026-03-25_120636.log`
- **Current blocker**: stale smoke-test autofix loop touched dependency/design/app files and needs review before the next trusted rerun

## Ready for next session
- Review and clean up the unsafe smoke-test edits from the `12:10` to `12:27` window.
- Start exactly one visible PowerShell pipeline from `runtime`.
- Monitor the new pipeline every minute and intervene only on real failures, not false-positive drift.

## Last Updated
2026-04-27 America/Los_Angeles
