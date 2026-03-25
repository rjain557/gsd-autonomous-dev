# GSD Autonomous Development Engine - Developer Guide

**Version:** 3.0.0
**Date:** March 2026
**Classification:** Confidential - Internal Use Only

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | February 2026 | Initial release |
| 1.1.0 | March 2026 | Codex CLI update, multi-agent support, supervisor, cost tracking |
| 1.2.0 | March 2026 | LLM Council, parallel execution, resilience hardening |
| 1.5.0 | March 2026 | Quality gates (DB completeness, security compliance, spec validation), chunked council reviews |
| 1.6.0 | March 2026 | Multi-model LLM integration (4 REST agents), API/Database interface auto-detection, REST agent error handling |
| 1.6.1 | March 2026 | Added Chapters 13-15: Coding Standards & Methodologies, Database Coding Standards, Compliance & Security Coding (88+ rules with IDs) |
| 1.7.0 | March 2026 | REST agent connectivity fixes: Kimi switched to international endpoint (api.moonshot.ai), GLM-5 switched to international endpoint (api.z.ai), connection_failed fast-fail with 60-min cooldown, TLS 1.2/1.3 enforcement, enabled flag check, updated model strengths/weaknesses |
| 2.0.0 | March 2026 | 9 new scripts (30 total): Differential code review, pre-execute compile gate, per-requirement acceptance tests, contract-first API validation, visual validation (Figma screenshot diff), design token enforcement, compliance engine (per-iteration audit + DB migration + PII tracking), speed optimizations (research skip, smart batch, prompt dedup), agent intelligence (performance scoring, warm-start). Added Chapters 16-18. Total validation gates: 14. |
| 2.1.0 | March 2026 | Runtime smoke tests (Script 32: DI validation, API endpoint checks, seed FK order). Partitioned code review (Script 33: 3-way parallel with agent rotation). LOC-cost integration (Script 34: baseline tracking, grand totals, cost-per-line in every notification). Maintenance mode (Script 35): `gsd-fix` (text/file/directory with screenshots), `gsd-update`, `--Scope`, `--Incremental`, `-BugDir`. Added Chapters 17.7-17.8, expanded Chapter 19, added Chapter 20. |
| 2.2.0 | March 2026 | Council-based requirements verification (Script 36): 3-phase parallel pipeline -- partitioned extract (each agent processes 1/3 of specs in chunks via `Start-Job`), cross-verification (different agent checks each extraction), Claude synthesis. Live progress monitoring (disk polling every 15s + heartbeat). Ntfy push notifications at every phase with token cost breakdown. `gsd-verify-requirements` standalone command with `-SkipAgent`, `-SkipVerify`, `-ChunkSize`. Convergence pipeline Phase 0 council integration. Added Chapter 21. |
| 2.3.0 | March 2026 | Model version pinning: `--model` flag enforced on all CLI invocations (claude-sonnet-4-6, gpt-5.4, gemini-3.0-pro). `agent_models` config block in global-config.json for zero-reinstall model upgrades. `$script:CLAUDE_MODEL` / `$script:GEMINI_MODEL` / `$script:CODEX_MODEL` script-scope constants in resilience.ps1. `--allowed-tools` kebab-case fix across all scripts. `disabled:` and `connection_failed:` error prefixes in Get-FailureDiagnosis (triggers immediate fallback). ImageMagick three-tier visual diff (SHA256 → pixel diff → file-size fallback). HSL/oklch/hwb design token detection. Incremental file map threshold (≤20 files prunes cache; >20 full rebuild). SEC-NET-05/SEC-FE-01 `[AllowAnonymous]` exclusion. Binary file skip logging in LOC tracking. `gsd-update` matrix existence guard. `Initialize-ProjectInterfaces` guard in gsd-assess. Set-Content error handling in convergence fix. Per-project supervisor pattern memory. |
| 3.0.0 | March 2026 | **V3 Pipeline — API-only architecture.** Replaced 7-agent CLI+REST system with 2-model API-only pipeline (Sonnet 4.6 + Codex Mini), ~85% cheaper, ~10x faster. 7-model weighted round-robin execute pool. Anti-plateau protection (graduated escalation). Spec alignment guard (drift detection). Decomposition budget (20/iter max, depth ≤4). Confidence-gated review. Speculative execution (+40% speed). Checkpoint and recovery. Centralized logging with per-repo iteration tracking. **New: Full Pipeline Orchestrator** (gsd-full-pipeline.ps1) — 5-phase end-to-end quality gate (wire-up → code-review → smoke-test → final-review → handoff). **New: Smoke Testing** (gsd-smoketest.ps1) — 9-phase integration validation with tiered LLM cost optimization (~85% cheaper). **New: Wire-Up Phase** — mock data detection, route-role matrix, integration gap prevention. **New: 3-Model Code Review** (gsd-codereview.ps1) — Claude+Codex+Gemini consensus with auto-fix cycles. **New: Tiered LLM Cost Optimization** — 4-tier model routing (local/cheap/mid/premium) for smoke testing. **New: LLM Pre-Validate Fix Phase** — proactive error fixing before local build. **New: Existing Codebase Mode** (gsd-existing.ps1) — deep extraction, code inventory, satisfaction verification. **New: Supervision Insights** — cross-session learning for pipeline improvement. Added Chapters 22-27. |

---

# Chapter 1: Introduction

## 1.1 Why We Built This

Traditional software development with AI assistants is manual, fragile, and expensive. A developer copies and pastes prompts into ChatGPT or Claude, manually reviews the output, fixes issues, copies the next piece of context, and repeats. There is no memory between sessions, no automatic recovery from failures, and no way to verify that the generated code actually matches the specifications. A single network timeout or quota exhaustion kills the entire workflow and the developer has to start over. Even worse, there is no guarantee that the AI understood the spec correctly -- contradictions between specification documents go undetected until code review reveals the damage.

The GSD Engine automates the entire develop-review-fix loop. **V3** (current) is a 2-model, API-only pipeline that uses Claude Sonnet for all reasoning phases and Codex Mini for code generation, with 5 additional models (DeepSeek, Kimi, MiniMax, Gemini, GLM-5) available in the execute rotation pool. V3 is approximately 85% cheaper and 10x faster than V2, achieved through prompt caching, batch API usage, structured JSON output, and elimination of CLI process spawning overhead.

The engine runs autonomously until the codebase matches the specification. It handles crashes, quota limits, network failures, JSON corruption, stalls, and specification contradictions without human intervention. When the engine reaches 100% health, it runs a comprehensive quality pipeline: 3-model code review (Claude + Codex + Gemini consensus), 9-phase smoke testing (build, database, API, auth, routes, RBAC, mock data detection), wire-up verification (integration gap prevention), and developer handoff documentation generation.

The result: a developer writes specifications, runs one command, and gets a fully built, verified, compliant codebase. What used to take weeks of manual AI-assisted development happens overnight. The engine tracks actual API costs in real time with tiered model routing (~85% cheaper smoke testing), generates developer handoff documentation, auto-commits to git with health scores, and sends push notifications to your phone so you can monitor progress from anywhere.

> **V2 (legacy)**: The original 7-agent CLI+REST system (44 install scripts) remains in the `scripts/` directory for reference. V2 used three CLI agents (Claude Code, Codex CLI, Gemini CLI) plus four REST API agents (Kimi, DeepSeek, GLM-5, MiniMax). V3 replaces all CLI invocations with direct API calls.

## 1.2 Design Philosophy

- **Token-optimized agent assignment** -- Claude handles judgment-heavy phases (review, plan, verify) where reasoning quality matters. Codex and Gemini handle high-volume generation and research where throughput matters. Each draws from independent API quota pools.
- **Specification-driven** -- Code matches specifications, not the other way around. The engine extracts requirements from specs and Figma, tracks them in a matrix, and converges until every requirement is satisfied.
- **Self-healing** -- Retry with batch reduction, checkpoint/resume, health regression rollback, network polling, quota backoff, agent timeout watchdog, and a supervisor that root-causes stalls across projects.
- **Idempotent** -- Safe to re-run, safe to interrupt (Ctrl+C) and resume. The engine picks up from the last checkpoint. Safe to install over an existing installation.
- **Observable** -- Health scores, push notifications via ntfy.sh, remote monitoring via QR code, live cost tracking, and structured error logs.
- **Quality-gated** -- Database completeness verification, OWASP security compliance scanning, spec clarity scoring, cross-artifact consistency checks, and multi-agent council review at convergence.

## 1.3 What Was Built

The GSD Engine provides three core capabilities:

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `gsd-assess` | Scan codebase, detect interfaces, generate file map, classify work | Pre-flight analysis on any repo |
| `gsd-converge` | 5-phase convergence loop to fix existing code toward 100% | Existing codebase needs to match specs |
| `gsd-blueprint` | 3-phase spec-to-code pipeline for greenfield development | New project, build from specs + Figma |

V3 quality pipeline (post-convergence):

| Command | Purpose | When to Use |
|---------|---------|-------------|
| `gsd-full-pipeline` | End-to-end quality orchestrator (wire-up → review → smoke → handoff) | After convergence reaches 100% health |
| `gsd-codereview` | 3-model code review (Claude + Codex + Gemini) with auto-fix | Standalone quality check on any repo |
| `gsd-smoketest` | 9-phase integration validation with tiered cost optimization | Verify runtime integration after code review |
| `gsd-existing` | Existing codebase mode (deep extract, inventory, verify) | Verify existing code against specs |

Supporting utilities:

| Command | Purpose |
|---------|---------|
| `gsd-status` | Health dashboard for current project |
| `gsd-init` | Initialize `.gsd/` folder without running iterations |
| `gsd-remote` | Launch remote monitoring with QR code |
| `gsd-costs` | Estimate API costs, compare pipelines, generate client quotes |
| `gsd-fix` | Quick bug fix mode with text, file, or directory input |
| `gsd-update` | Incremental feature addition from updated specs |
| `gsd-verify-requirements` | Council-based 3-agent requirements verification |

---

# Chapter 2: Architecture

## 2.1 System Overview

The GSD Engine is a PowerShell-based orchestration framework that coordinates seven AI agents -- three CLI (Claude Code, Codex CLI, Gemini CLI) and four REST API (Kimi K2.5, DeepSeek V3, GLM-5, MiniMax M2.5) -- through iterative loops. The developer provides specifications and Figma designs; the engine handles everything else.

```
┌─────────────────────────────────────────────────────────┐
│                      DEVELOPER                          │
│   Provides: Specs (docs/) + Figma (design/) + .sln     │
│   Receives: Working code + developer-handoff.md         │
└────────────────────────┬────────────────────────────────┘
                         │
                    gsd-converge / gsd-blueprint
                         │
┌────────────────────────▼────────────────────────────────┐
│                    GSD ENGINE                            │
│  ┌──────────────────────────────────────────────────┐   │
│  │              PowerShell Orchestrator              │   │
│  │  convergence-loop.ps1 / blueprint-pipeline.ps1   │   │
│  └──────┬──────────────┬──────────────┬─────────────┘   │
│         │              │              │                  │
│  ┌──────▼──────┐ ┌─────▼──────┐ ┌────▼───────┐         │
│  │ Claude Code │ │ Codex CLI  │ │ Gemini CLI │         │
│  │  Reasoning  │ │ Generation │ │  Research   │         │
│  │  ~3K/iter   │ │ ~65K/iter  │ │  ~20K/iter  │         │
│  └─────────────┘ └────────────┘ └────────────┘         │
│  ┌──────────┐ ┌──────────┐ ┌──────┐ ┌─────────┐       │
│  │ Kimi K2.5│ │DeepSeek  │ │GLM-5 │ │ MiniMax │       │
│  │  $0.60/M │ │ $0.28/M  │ │$1.00 │ │ $0.29/M │       │
│  │  REST API │ │ REST API │ │ REST │ │ REST API│       │
│  └──────────┘ └──────────┘ └──────┘ └─────────┘       │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │              Resilience Layer                     │   │
│  │  Retry, Checkpoint, Lock, Quota, Network,        │   │
│  │  Watchdog, Regression, Supervisor, Council        │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │              Quality Gates                        │   │
│  │  Spec Clarity, DB Completeness, Security Scan,   │   │
│  │  Final Validation (build, test, audit)            │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

## 2.2 Agent Assignment

The seven-model architecture uses a core 3-model phase owner set plus 4 optional review/failover providers. Each agent is assigned to phases that match its strengths:

| Agent | Role | Phases | Approx. Tokens/Iter | Why This Agent |
|-------|------|--------|---------------------|----------------|
| **Claude Code** | Reasoning & analysis | Review, Plan, Verify, Blueprint, Spec check | ~3-5K output | Best judgment, catches nuance, understands requirements |
| **Codex CLI** | Code generation | Execute, Build | ~65-80K output | Fastest code gen, largest output window |
| **Gemini CLI** | Research & spec-fix | Research, Spec-fix | ~20K output | Saves Claude/Codex quota for their strengths |

Gemini is optional. If not installed, the engine falls back to Codex for research phases.

Agent assignment can be overridden by the supervisor at runtime via `.gsd/supervisor/agent-override.json`, and parallel execution distributes sub-tasks round-robin across all three agents.

## 2.3 Convergence Loop (5-Phase)

The convergence pipeline (`gsd-converge`) runs a 5-phase loop that iteratively fixes existing code to match specifications:

```
┌─────────────────────────────────────────────────────────┐
│                 CONVERGENCE PIPELINE                     │
│                                                         │
│  ┌─── One-time ───┐                                    │
│  │ Spec Quality    │◄── Blocks if clarity < 70         │
│  │ Gate            │                                    │
│  │ Create-phases   │◄── Claude extracts requirements   │
│  └────────┬────────┘                                    │
│           │                                             │
│  ┌────────▼────────────────────────────────────────┐    │
│  │              ITERATION LOOP                      │    │
│  │                                                  │    │
│  │  Phase 1: CODE-REVIEW (Claude)                   │    │
│  │    Score health, update requirement statuses      │    │
│  │                                                  │    │
│  │  Phase 2: RESEARCH (Gemini, read-only)           │    │
│  │    Investigate patterns, dependencies, tech       │    │
│  │    ► Post-research council (non-blocking)         │    │
│  │                                                  │    │
│  │  Phase 3: PLAN (Claude)                          │    │
│  │    Prioritize next batch, write instructions      │    │
│  │    ► Pre-execute council (non-blocking)           │    │
│  │                                                  │    │
│  │  Phase 4: EXECUTE (Codex, parallel optional)     │    │
│  │    Generate code for batch items                  │    │
│  │                                                  │    │
│  │  Phase 5: Stall/regression checks                │    │
│  │    Revert if health drops >5%                     │    │
│  │                                                  │    │
│  │  At 100%: Council gate (blocking)                 │    │
│  │           DB completeness check                   │    │
│  │           Security compliance scan                │    │
│  │           Final validation (build, test, audit)   │    │
│  └──────────────────────────────────────────────────┘    │
│                                                         │
│  Output: developer-handoff.md + git commit + push       │
└─────────────────────────────────────────────────────────┘
```

### Phase Details

| Phase | Agent | Input | Output | Tokens |
|-------|-------|-------|--------|--------|
| Create-phases | Claude | Specs, Figma | requirements-matrix.json | ~3K (one-time) |
| Code-review | Claude | Source code, matrix | health-current.json, review-current.md | ~3K |
| Research | Gemini | Matrix, source | research findings | ~20K |
| Plan | Claude | Matrix, research | queue-current.json, current-assignment.md | ~2K |
| Execute | Codex | Assignment, queue | Source code files | ~65K |

## 2.4 Blueprint Pipeline (3-Phase)

The blueprint pipeline (`gsd-blueprint`) builds a project from scratch using specifications and Figma designs:

```
┌─────────────────────────────────────────────────────────┐
│                  BLUEPRINT PIPELINE                      │
│                                                         │
│  ┌─── One-time ───┐                                    │
│  │ Spec Quality    │◄── Blocks if clarity < 70         │
│  │ Gate            │                                    │
│  │ BLUEPRINT       │◄── Claude reads all specs + Figma │
│  │ (Claude)        │    Produces blueprint.json         │
│  │                 │    (~5K tokens, exhaustive)        │
│  │ Post-blueprint  │◄── Council validates manifest     │
│  │ Council         │                                    │
│  └────────┬────────┘                                    │
│           │                                             │
│  ┌────────▼────────────────────────────────────────┐    │
│  │              ITERATION LOOP                      │    │
│  │                                                  │    │
│  │  Phase 1: VERIFY (Claude)                        │    │
│  │    Binary check: file exists + meets criteria     │    │
│  │    Update statuses, write next-batch.json         │    │
│  │    (~2K tokens per iteration)                     │    │
│  │                                                  │    │
│  │  Phase 2: BUILD (Codex)                          │    │
│  │    Generate complete files for batch items         │    │
│  │    (~80K tokens per iteration)                    │    │
│  │                                                  │    │
│  │  Phase 3: Stall/regression checks                │    │
│  │                                                  │    │
│  │  At 100%: DB completeness + Security scan         │    │
│  │           Final validation (build, test, audit)   │    │
│  └──────────────────────────────────────────────────┘    │
│                                                         │
│  Output: developer-handoff.md + git commit + push       │
└─────────────────────────────────────────────────────────┘
```

### When to Use Each Pipeline

| Scenario | Pipeline | Why |
|----------|----------|-----|
| New project, no existing code | `gsd-blueprint` | Generates from specs via blueprint manifest |
| New project, partial code exists | `gsd-assess` then `gsd-blueprint -BuildOnly` | Assessment classifies existing code; blueprint fills gaps |
| Existing project, needs fixes | `gsd-converge` | Reviews against specs, fixes iteratively |
| Blueprint at 60-80%, stuck | Switch to `gsd-converge` | Convergence handles iterative fix-verify better |
| Quick assessment only | `gsd-assess` | Work classification without modifying code |

## 2.5 Data Flow Diagrams

### gsd-assess Flow

```
Developer runs: gsd-assess
         │
         ▼
┌─────────────────┐     ┌──────────────────┐
│ Find-Project    │────►│ Detect interfaces │
│ Interfaces      │     │ (web, mcp, mobile │
└────────┬────────┘     │  browser, agent)  │
         │              └──────────────────┘
         ▼
┌─────────────────┐     ┌──────────────────┐
│ Update-FileMap  │────►│ .gsd/assessment/  │
│ (inventory)     │     │ file-map.md       │
└────────┬────────┘     └──────────────────┘
         │
         ▼
┌─────────────────┐     ┌──────────────────┐
│ Claude assess   │────►│ Work classif.    │
│ (per interface) │     │ (skip/refactor/  │
└─────────────────┘     │  extend/build)   │
                        └──────────────────┘
```

### gsd-converge Per-Iteration Flow

```
Iteration N starts
         │
         ▼
┌──────────────────┐  health-current.json
│  CODE-REVIEW     │─────────────────────►  .gsd/health/
│  (Claude)        │  review-current.md
└────────┬─────────┘─────────────────────►  .gsd/code-review/
         │
         ▼
┌──────────────────┐  research findings
│  RESEARCH        │─────────────────────►  .gsd/research/
│  (Gemini)        │
└────────┬─────────┘
         │  ► Post-research council (non-blocking feedback)
         ▼
┌──────────────────┐  queue-current.json
│  PLAN            │─────────────────────►  .gsd/generation-queue/
│  (Claude)        │  current-assignment.md
└────────┬─────────┘─────────────────────►  .gsd/agent-handoff/
         │  ► Pre-execute council (non-blocking feedback)
         ▼
┌──────────────────┐  source code files
│  EXECUTE         │─────────────────────►  src/
│  (Codex parallel)│  handoff-log.jsonl
└────────┬─────────┘─────────────────────►  .gsd/agent-handoff/
         │
         ▼
   Health check ──► If regression >5%: REVERT
         │
         ▼
   If 100%: Council gate ──► DB check ──► Security scan ──► Final validation
```

### gsd-blueprint Per-Iteration Flow

```
Iteration N starts
         │
         ▼
┌──────────────────┐  blueprint.json (updated statuses)
│  VERIFY          │─────────────────────────────────────►  .gsd/blueprint/
│  (Claude)        │  next-batch.json
└────────┬─────────┘─────────────────────────────────────►  .gsd/blueprint/
         │
         ▼
┌──────────────────┐  source code files
│  BUILD           │─────────────────────────────────────►  src/
│  (Codex)         │  build-log.jsonl
└────────┬─────────┘─────────────────────────────────────►  .gsd/blueprint/
         │
         ▼
   Health check ──► If regression: REVERT
         │
         ▼
   If 100%: DB check ──► Security scan ──► Final validation
```

## 2.6 Installed Directory Structure

After running `install-gsd-all.ps1`, the engine creates:

```
%USERPROFILE%\.gsd-global\
│
├── bin\                              # CLI wrappers (added to PATH)
│   ├── gsd-converge.cmd              # Convergence loop launcher
│   ├── gsd-blueprint.cmd             # Blueprint pipeline launcher
│   ├── gsd-status.cmd                # Health status dashboard
│   ├── gsd-remote.cmd                # Remote monitoring launcher
│   └── gsd-costs.cmd                 # Token cost calculator
│
├── config\
│   ├── global-config.json            # Global settings (notifications, patterns, phases, council, quality_gates)
│   └── agent-map.json                # Agent-to-phase assignments + parallel execution config
│
├── lib\modules\
│   ├── resilience.ps1                # Retry, checkpoint, lock, rollback, adaptive batch, hardening,
│   │                                 # final validation, council, parallel execute, quality gates
│   ├── interfaces.ps1                # Multi-interface detection + auto-discovery
│   └── interface-wrapper.ps1         # Context builder for agent prompts
│
├── prompts\
│   ├── claude\                       # Claude Code prompt templates
│   │   ├── code-review.md            # Health scoring and requirement status updates
│   │   ├── plan.md                   # Batch prioritization and execution instructions
│   │   ├── verify.md                 # Blueprint verification (binary file checks)
│   │   ├── verify-storyboard.md      # Storyboard-aware verification (data flow tracing)
│   │   ├── assess.md                 # Codebase assessment prompt
│   │   ├── spec-clarity-check.md     # Pre-generation spec quality audit
│   │   └── cross-artifact-consistency.md  # Post-Figma-Make cross-reference validation
│   ├── codex\                        # Codex prompt templates
│   │   ├── execute.md                # Code generation for convergence batches
│   │   └── execute-subtask.md        # Sub-task prompt for parallel execution
│   ├── gemini\                       # Gemini prompt templates
│   │   ├── research.md               # Technical research (read-only)
│   │   └── resolve-spec-conflicts.md # Spec contradiction resolution
│   ├── council\                      # LLM Council review templates (14 files)
│   │   ├── codex-review.md           # Codex implementation quality review
│   │   ├── gemini-review.md          # Gemini requirements/spec alignment review
│   │   ├── claude-synthesize.md      # Claude consensus synthesis
│   │   ├── codex-review-chunked.md   # Chunked review variant
│   │   ├── gemini-review-chunked.md  # Chunked review variant
│   │   └── ...                       # (stall, post-research, pre-execute, post-blueprint, post-spec-fix)
│   └── shared\                       # Shared reference documents
│       ├── security-standards.md     # 88+ OWASP security rules by layer
│       ├── coding-conventions.md     # .NET/React/SQL naming and formatting
│       └── database-completeness-review.md  # DB chain verification rules
│
├── blueprint\
│   ├── scripts\
│   │   ├── blueprint-pipeline.ps1    # Blueprint generation + build loop
│   │   ├── supervisor-blueprint.ps1  # Supervisor wrapper for blueprint
│   │   └── assess.ps1                # Assessment script (gsd-assess)
│   └── prompts\codex\
│       ├── build.md                  # Code generation for blueprint batches
│       └── partial-repo-guide.md     # Guidance for partial/existing repos
│
├── scripts\
│   ├── convergence-loop.ps1          # 5-phase convergence engine
│   ├── supervisor-converge.ps1       # Supervisor wrapper for convergence
│   ├── gsd-profile-functions.ps1     # PowerShell profile functions
│   └── token-cost-calculator.ps1     # Token cost estimator (gsd-costs)
│
├── supervisor\
│   └── pattern-memory.jsonl          # Cross-project failure patterns + fixes
│
├── pricing-cache.json                # Cached LLM pricing data (auto-updated from LiteLLM)
├── KNOWN-LIMITATIONS.md              # Full scenario matrix
└── VERSION                           # Installed version stamp
```

## 2.7 Per-Project State (.gsd/ Folder)

Each project gets a `.gsd/` folder tracking all state:

```
.gsd\
├── health\
│   ├── health-current.json           # Current health score + breakdown
│   ├── health-history.jsonl          # Health progression per iteration
│   ├── requirements-matrix.json      # All requirements with statuses
│   ├── engine-status.json            # Live engine state (phase, agent, heartbeat)
│   ├── final-validation.json         # Validation gate results
│   ├── council-review.json           # Latest council review verdict
│   └── drift-report.md              # Requirements drift analysis
│
├── code-review\
│   ├── review-current.md             # Latest code review findings
│   └── council-findings.md           # Council review details
│
├── generation-queue\
│   └── queue-current.json            # Prioritized batch for next iteration
│
├── agent-handoff\
│   ├── current-assignment.md         # Instructions for executing agent
│   └── handoff-log.jsonl             # Agent completion logs
│
├── research\                         # Gemini research findings
│
├── specs\                            # SDLC reference + Figma mapping
│
├── assessment\                       # gsd-assess output
│   └── file-map.md                   # Complete file inventory
│
├── blueprint\                        # Blueprint pipeline state
│   ├── blueprint.json                # Full manifest
│   ├── next-batch.json               # Current build batch
│   └── build-log.jsonl               # Build completion log
│
├── costs\
│   ├── token-usage.jsonl             # Append-only token cost log (ground truth)
│   └── cost-summary.json             # Rolling totals by agent/phase/run
│
├── logs\
│   └── errors.jsonl                  # Structured error log
│
├── supervisor\
│   ├── supervisor-state.json         # Recovery attempt tracking
│   ├── last-run-summary.json         # Pipeline exit state
│   ├── error-context.md              # Error info injected into prompts
│   ├── prompt-hints.md               # Persistent agent behavior hints
│   ├── agent-override.json           # Phase-to-agent reassignment
│   ├── agent-cooldowns.json          # Agent quota cooldown tracking
│   ├── diagnosis-{N}.md              # Root-cause analysis per attempt
│   └── escalation-report.md          # Human escalation (after max attempts)
│
└── .gsd-checkpoint.json              # Crash recovery checkpoint
```

---

# Chapter 3: Installation

## 3.1 Prerequisites

### Required Software

| Tool | Version | Install Command | Purpose |
|------|---------|-----------------|---------|
| PowerShell | 5.1+ (Windows) | Pre-installed | Script execution |
| Node.js | 18+ | `winget install OpenJS.NodeJS.LTS` | CLI tools runtime |
| npm | 9+ | Included with Node.js | Package manager |
| .NET SDK | 8.x | `winget install Microsoft.DotNet.SDK.8` | Backend compilation |
| Git | 2.x+ | `winget install Git.Git` | Version control |
| Claude Code CLI | Latest | `npm install -g @anthropic-ai/claude-code` | AI reasoning agent |
| Codex CLI | Latest | `npm install -g @openai/codex` | AI code generation agent |

### Optional Software

| Tool | Purpose | Install Command |
|------|---------|-----------------|
| Gemini CLI | Three-model optimization (research, spec-fix) | `npm install -g @google/gemini-cli` |
| sqlcmd | SQL syntax validation during final validation | `winget install Microsoft.SqlServer.SqlCmd` |
| ntfy app | Mobile push notifications | iOS App Store / Google Play |

## 3.2 API Key Configuration

Each CLI must be authenticated. There are two methods:

**Method 1: Interactive Login (default)**

```powershell
claude    # Follow interactive auth flow
codex     # Follow interactive auth flow
gemini    # Follow Google OAuth flow (opens browser)
```

**Method 2: API Keys (recommended for autonomous pipelines)**

API keys bypass interactive rate limits and allow higher throughput. Configure them during installation or separately:

```powershell
# Interactive setup (prompts for each key)
powershell -ExecutionPolicy Bypass -File scripts/setup-gsd-api-keys.ps1

# Check current key status
powershell -ExecutionPolicy Bypass -File scripts/setup-gsd-api-keys.ps1 -Show

# Clear all keys
powershell -ExecutionPolicy Bypass -File scripts/setup-gsd-api-keys.ps1 -Clear
```

API keys are stored as persistent User-level environment variables (never committed to git):

| Environment Variable | CLI | Get Key From |
|---------------------|-----|-------------|
| `ANTHROPIC_API_KEY` | Claude Code | https://console.anthropic.com/settings/keys |
| `OPENAI_API_KEY` | Codex | https://platform.openai.com/api-keys |
| `GOOGLE_API_KEY` | Gemini | https://aistudio.google.com/apikey |

You can use either method or both. API keys take priority when set.

## 3.3 Running the Master Installer

```powershell
git clone <your-gsd-repo-url>
cd gsd-autonomous-dev
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-all.ps1
```

The master installer runs 21 scripts in dependency order. It also runs `install-gsd-prerequisites.ps1` as a pre-flight check. On first run, it prompts for API keys if not already configured.

| Order | Script | What It Installs |
|-------|--------|-----------------|
| 1 | install-gsd-global.ps1 | API key setup, global directory, engine, config, profile, gsd-costs |
| 2 | install-gsd-blueprint.ps1 | Blueprint pipeline, assess script, prompts |
| 3 | patch-gsd-partial-repo.ps1 | gsd-assess command, file map generation, partial repo handling |
| 4 | patch-gsd-resilience.ps1 | Resilience module (retry, checkpoint, lock, watchdog timeout) |
| 5 | patch-gsd-hardening.ps1 | Hardening (quota, network, boundary, notifications, heartbeat) |
| 6 | patch-gsd-final-validation.ps1 | Final validation gate + developer handoff report |
| 7 | patch-gsd-figma-make.ps1 | Interface detection, _analysis/_stubs discovery |
| 8 | final-patch-1-spec-check.ps1 | Spec consistency checker |
| 9 | final-patch-2-sql-cli.ps1 | SQL validation, CLI version checks |
| 10 | final-patch-3-storyboard-verify.ps1 | Storyboard-aware verification prompts |
| 11 | final-patch-4-blueprint-pipeline.ps1 | Sync installed blueprint pipeline from canonical repo source |
| 12 | final-patch-5-convergence-pipeline.ps1 | Sync installed convergence pipeline from canonical repo source |
| 13 | final-patch-6-assess-limitations.ps1 | Final assess script with known limitations |
| 14 | final-patch-7-spec-resolve.ps1 | Spec conflict auto-resolution via Gemini |
| 15 | patch-gsd-supervisor.ps1 | Self-healing supervisor (recovery, error context, pattern memory) |
| 16 | patch-false-converge-fix.ps1 | Fix false convergence exit + orphaned profile code |
| 17 | patch-gsd-council.ps1 | LLM Council (multi-agent review gate at 100% health) |
| 18 | patch-gsd-parallel-execute.ps1 | Parallel sub-task execution (split batch, round-robin agents) |
| 19 | patch-gsd-resilience-hardening.ps1 | Resilience hardening (token tracking, auth fix, quota cap, agent rotation) |
| 20 | patch-gsd-quality-gates.ps1 | Quality gates (DB completeness, security standards, spec validation) |
| 21 | patch-gsd-multi-model.ps1 | Multi-model LLM integration (4 REST agents, model registry, error handling) |

Optional standalone scripts (not run by installer):

| Script | Purpose |
|--------|---------|
| setup-gsd-api-keys.ps1 | Manage API key environment variables (set, show, clear) |
| setup-gsd-convergence.ps1 | Per-project convergence config (run manually if needed) |
| install-gsd-keybindings.ps1 | VS Code keyboard shortcuts (Ctrl+Shift+G chords) |
| token-cost-calculator.ps1 | Token cost estimator (also installed globally as gsd-costs) |

The repository contains 27 scripts total: 1 master installer, 1 pre-flight check, 21 scripts run by installer, and 4 standalone utilities.

## 3.4 Post-Install Verification

```powershell
# Restart terminal first (or reload profile)
. $PROFILE

# Verify commands are available
gsd-status

# Verify prerequisites
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-prerequisites.ps1 -VerifyOnly

# Verify installed version
Get-Content "$env:USERPROFILE\.gsd-global\VERSION"
```

## 3.5 VS Code Integration

### Tasks

Two VS Code tasks are registered during installation:

- **GSD: Convergence Loop** -- runs `gsd-converge`
- **GSD: Blueprint Pipeline** -- runs `gsd-blueprint`

### Keyboard Shortcuts

Install with: `powershell -ExecutionPolicy Bypass -File scripts/install-gsd-keybindings.ps1`

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+G, C` | Run convergence loop |
| `Ctrl+Shift+G, B` | Run blueprint pipeline |
| `Ctrl+Shift+G, S` | Show status dashboard |

These use a chord sequence: hold Ctrl+Shift+G, release, then press the second key.

## 3.6 Multi-Workstation Setup

The engine state is stored in two places:

1. **Global engine** (`~/.gsd-global/`) -- installed per workstation
2. **Project state** (`.gsd/`) -- committed to git, portable between workstations

To work from a second workstation:

```powershell
# On workstation 2: install the engine
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-all.ps1

# Pull project state
cd C:\path\to\your\repo
git pull

# Resume -- the engine picks up from the checkpoint
gsd-converge -SkipInit
```

Lock files prevent concurrent runs. If a lock file is stale (older than 120 minutes), the engine automatically claims it.

## 3.7 Updating and Uninstalling

### Updating

The installer is idempotent. Re-run to pick up updates:

```powershell
cd gsd-autonomous-dev
git pull
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-all.ps1
```

Existing configurations and project data are preserved.

### Uninstalling

```powershell
# Remove global engine
Remove-Item -Recurse -Force "$env:USERPROFILE\.gsd-global"

# Remove profile entries (manual)
notepad $PROFILE
# Remove all gsd-related lines

# Remove API keys (optional)
powershell -ExecutionPolicy Bypass -File scripts/setup-gsd-api-keys.ps1 -Clear

# Remove per-project state (in each repo)
Remove-Item -Recurse -Force .gsd
```

---

# Chapter 4: Usage Guide

## 4.1 First Project Setup

### Expected Project Structure

```
C:\repos\my-app\
├── .git\                             # Git repository
├── .sln                              # .NET solution file
├── design\
│   └── web\v01\                      # Figma designs (versioned)
│       ├── _analysis\                # 12 Figma Make deliverables
│       │   ├── 01-layout-hierarchy.md
│       │   ├── 02-component-catalog.md
│       │   ├── 03-navigation-map.md
│       │   ├── 04-design-tokens.md
│       │   ├── 05-interaction-patterns.md
│       │   ├── 06-api-contracts.md
│       │   ├── 07-state-machines.md
│       │   ├── 08-accessibility-spec.md
│       │   ├── 09-responsive-breakpoints.md
│       │   ├── 10-error-states.md
│       │   ├── 11-api-to-sp-map.md
│       │   └── 12-mock-data.md
│       └── _stubs\                   # Backend stubs from Figma Make
│           ├── 01-tables.sql
│           ├── 02-stored-procedures.sql
│           └── 03-seed-data.sql
├── docs\
│   ├── Phase-A-Requirements.md       # SDLC specifications
│   ├── Phase-B-Design.md
│   ├── Phase-C-Architecture.md
│   ├── Phase-D-Implementation.md
│   └── Phase-E-Testing.md
└── src\                              # Source code
    ├── MyApp.Api\                    # .NET 8 backend
    └── myapp-ui\                     # React 18 frontend
```

### Step-by-Step: New Project (Blueprint)

```powershell
cd C:\repos\my-app

# 1. Initialize GSD state
gsd-init

# 2. Assess the codebase
gsd-assess

# 3. Estimate costs before starting
gsd-costs -ProjectPath "C:\repos\my-app"

# 4. Run blueprint pipeline
gsd-blueprint
```

### Step-by-Step: Existing Project (Convergence)

```powershell
cd C:\repos\my-app

# 1. Initialize
gsd-init

# 2. Assess
gsd-assess

# 3. Run convergence
gsd-converge
```

## 4.2 Running gsd-assess

Scans the codebase, detects interfaces, generates a file map, and runs a Claude assessment.

```powershell
gsd-assess              # Full assessment
gsd-assess -MapOnly     # Regenerate file map without Claude assessment
gsd-assess -DryRun      # Preview without executing
```

**Output:** `.gsd/assessment/` folder with file inventories, pattern detection, spec coverage analysis, and work classification (skip/refactor/extend/build_new).

## 4.3 Running gsd-converge

Runs the 5-phase convergence loop to fix existing code toward 100% health.

```powershell
gsd-converge                              # Full convergence
gsd-converge -SkipResearch                # Skip Gemini research phase (saves tokens)
gsd-converge -DryRun                      # Preview without executing
gsd-converge -MaxIterations 5             # Limit iterations
gsd-converge -SkipInit                    # Skip initial requirements check, use existing matrix
gsd-converge -ThrottleSeconds 60          # 60s delay between phases
gsd-converge -AutoResolve                 # Auto-fix spec conflicts via Gemini
gsd-converge -NtfyTopic "my-topic"        # Override notification topic
gsd-converge -SupervisorAttempts 3        # Max supervisor recovery attempts
gsd-converge -NoSupervisor               # Bypass supervisor entirely
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-DryRun` | false | Preview mode, no agent calls or code changes |
| `-SkipInit` | false | Skip initial requirements check, use existing matrix |
| `-SkipResearch` | false | Skip Gemini/Codex research phase (saves tokens) |
| `-SkipSpecCheck` | false | Skip spec consistency check before starting |
| `-AutoResolve` | false | Auto-resolve spec conflicts via Gemini |
| `-BatchSize` | 8 | Items per execute cycle (adaptive: shrinks on failure, grows on success) |
| `-MaxIterations` | 50 | Safety limit on total iterations |
| `-StallThreshold` | 3 | Consecutive zero-progress iterations before stall declaration |
| `-ThrottleSeconds` | 0 | Delay between phases (useful for rate limiting) |
| `-NtfyTopic` | auto | Override notification topic |
| `-SupervisorAttempts` | 5 | Max supervisor recovery attempts |
| `-NoSupervisor` | false | Bypass supervisor entirely |

## 4.4 Running gsd-blueprint

Runs the 3-phase blueprint pipeline for greenfield development.

```powershell
gsd-blueprint                             # Full pipeline
gsd-blueprint -BlueprintOnly              # Generate manifest only (no build)
gsd-blueprint -BuildOnly                  # Build from existing manifest
gsd-blueprint -VerifyOnly                 # Verify existing files only
gsd-blueprint -DryRun                     # Preview without executing
gsd-blueprint -MaxIterations 10           # Limit build iterations
gsd-blueprint -BatchSize 15              # Items per build cycle
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-DryRun` | false | Preview mode |
| `-BlueprintOnly` | false | Generate blueprint.json only |
| `-BuildOnly` | false | Skip blueprint, start at build phase |
| `-VerifyOnly` | false | Verify existing files only |
| `-BatchSize` | 15 | Items per build cycle |
| `-MaxIterations` | 50 | Safety limit |
| `-StallThreshold` | 3 | Stall detection threshold |
| `-ThrottleSeconds` | 0 | Delay between phases |
| `-SkipSpecCheck` | false | Skip spec quality gate |
| `-AutoResolve` | false | Auto-fix spec conflicts |

## 4.5 Running gsd-status

```powershell
gsd-status    # Shows health score, iteration, phase, costs
```

Displays the current project health dashboard including health score, requirement breakdown, current phase, iteration count, and accumulated costs.

## 4.6 Running gsd-costs

```powershell
# Quick estimate from existing blueprint
gsd-costs -ProjectPath "C:\repos\my-app"

# Manual estimate for a new project
gsd-costs -TotalItems 150 -Pipeline blueprint

# Compare both pipelines side-by-side
gsd-costs -TotalItems 150 -ShowComparison

# Use Claude Opus instead of default Sonnet
gsd-costs -TotalItems 150 -ClaudeModel opus

# Detailed per-item breakdown
gsd-costs -TotalItems 150 -Detailed

# Client quote with 7x markup
gsd-costs -TotalItems 150 -ClientQuote -Markup 7 -ClientName "Acme Corp"

# View actual costs from a completed run
gsd-costs -ShowActual

# Force refresh pricing data
gsd-costs -UpdatePricing
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ProjectPath` | (current dir) | Path to project with blueprint.json |
| `-TotalItems` | (from blueprint) | Total items to build |
| `-CompletedItems` | 0 | Items already completed |
| `-Pipeline` | blueprint | Pipeline type (blueprint/convergence) |
| `-BatchSize` | 15 | Items per batch |
| `-BatchEfficiency` | 0.85 | Expected success rate per batch |
| `-RetryRate` | 0.15 | Expected retry rate |
| `-ClaudeModel` | sonnet | Claude model (sonnet/opus/haiku) |
| `-ShowComparison` | false | Side-by-side pipeline comparison |
| `-ShowActual` | false | Show actual costs from completed runs |
| `-Detailed` | false | Per-item breakdown |
| `-ClientQuote` | false | Generate client-facing quote |
| `-Markup` | 7 | Client markup multiplier |
| `-ClientName` | "" | Client name for quote header |
| `-UpdatePricing` | false | Force refresh pricing cache |

### Client Quote Complexity Tiers

| Tier | Item Count | Suggested Markup |
|------|-----------|-----------------|
| Standard | <= 100 | 5x |
| Complex | <= 250 | 7x |
| Enterprise | <= 500 | 7-10x |
| Enterprise+ | > 500 | 10x |

## 4.7 Monitoring a Running Pipeline

### Terminal Output

The engine outputs progress information with status icons:

```
[*] Iteration 5 | Health: 72.5% | Batch: 8
[>] Phase: execute (codex)
[+] Requirements satisfied: 29/40
[-] Build check: PASSED
[!] Warning: 2 NuGet vulnerabilities
```

### Push Notifications (ntfy.sh)

1. Install the ntfy app on your phone (free, no account required)
2. Run any pipeline -- note the topic at startup: `ntfy topic (auto): gsd-rjain-patient-portal`
3. Subscribe to that topic in the ntfy app

Notification events include:

| Event | Description |
|-------|-------------|
| `iteration_complete` | Health score after each iteration |
| `converged` | Pipeline reached 100% and passed validation |
| `stalled` | No progress for N consecutive iterations |
| `quota_exhausted` | All quota retries exhausted |
| `error` | Unrecoverable error occurred |
| `heartbeat` | Periodic status update (every 60s during agent calls) |
| `supervisor_active` | Supervisor recovery started |
| `supervisor_recovered` | Supervisor fixed the issue |
| `supervisor_escalation` | Supervisor gave up, human needed |
| `validation_failed` | Final validation check failed |
| `validation_passed` | Final validation passed |

All notifications that include status information also include running token cost data. Terminal notifications include per-agent cost breakdown.

### Remote Monitoring

```powershell
gsd-remote    # Displays QR code -- scan with phone
```

### Reading State Files Directly

```powershell
# Current health
Get-Content .gsd\health\health-current.json | ConvertFrom-Json

# Engine status (phase, agent, heartbeat)
Get-Content .gsd\health\engine-status.json | ConvertFrom-Json

# Cost summary
Get-Content .gsd\costs\cost-summary.json | ConvertFrom-Json

# Recent errors
Get-Content .gsd\logs\errors.jsonl | ForEach-Object { $_ | ConvertFrom-Json } | Select-Object -Last 5
```

## 4.8 Interrupting and Resuming

### Safe Interruption

Press `Ctrl+C` at any time. The engine saves a checkpoint before each phase. On resume:

```powershell
# Resume from checkpoint
gsd-converge -SkipInit

# Or for blueprint
gsd-blueprint -BuildOnly
```

The engine reads `.gsd/.gsd-checkpoint.json` and picks up from the last completed phase.

### What State Is Preserved

- Health score and history
- Requirements matrix with all statuses
- All generated code (committed to git)
- Cost tracking data
- Error logs
- Supervisor state and pattern memory

### Transferring to Another Workstation

```powershell
# Workstation 1: commit and push state
git add .gsd/
git commit -m "Save GSD state for transfer"
git push

# Workstation 2: pull and resume
git pull
gsd-converge -SkipInit
```

---

# Chapter 5: Resilience and Self-Healing

## 5.1 Retry with Batch Reduction

`Invoke-WithRetry` wraps every agent call with automatic retry logic:

- **Max retries:** 3 per agent call
- **Batch reduction:** 50% on each failure (e.g., 8 -> 4 -> 2)
- **Minimum batch:** 2 items
- **Retry delay:** 10 seconds between attempts

Token costs are tracked on ALL attempts (success and failure), with estimation when agents return error text instead of structured JSON.

## 5.2 Checkpoint and Recovery

`Save-Checkpoint` records state before each phase:

```json
{
  "pipeline": "converge",
  "iteration": 5,
  "phase": "execute",
  "health": 72.5,
  "batch_size": 8,
  "status": "in_progress",
  "timestamp": "2026-03-02T10:30:00Z",
  "pid": 12345
}
```

On crash, `Restore-Checkpoint` reads this file and resumes from the last completed phase. The checkpoint is also read by the background heartbeat job for ntfy status notifications.

## 5.3 Lock File Management

`New-Lock` and `Remove-Lock` prevent concurrent pipeline runs on the same project:

- Lock file: `.gsd/.gsd-lock`
- Contains PID of the running process
- Stale lock detection: 120 minutes (auto-claimed)
- If another process holds the lock, the engine exits with a warning

## 5.4 Health Regression Protection

After each iteration, the engine compares the new health score to the previous one. If health drops by more than 5%, the engine automatically reverts:

1. Restores the previous checkpoint
2. Logs the regression to `errors.jsonl`
3. Sends an ntfy notification
4. Continues with a reduced batch size

## 5.5 Quota and Rate Limit Handling

`Wait-ForQuotaReset` detects quota exhaustion and rate limits:

- Exponential backoff: 5 -> 10 -> 20 -> 40 -> 60 minute cap per cycle
- Up to 24 cycles (24 hours maximum per quota wait)
- Cumulative cap: 120 minutes total across all quota waits (prevents 14+ hour sleeps)
- Agent rotation: After 3 consecutive quota failures on one agent, switches to next available agent (codex -> claude -> gemini)
- Agent cooldowns tracked in `.gsd/supervisor/agent-cooldowns.json`

Authentication detection has been hardened:
- 403 responses are NOT treated as auth failures (they indicate rate limits)
- Gemini 403 specifically routes to quota backoff rather than auth retry

## 5.6 Network Failure Handling

`Test-NetworkAvailability` polls for internet connectivity:

- 30-second polling interval
- Tests connectivity to multiple endpoints
- Resumes automatically when connection restored
- Sends ntfy notification when network drops and recovers

## 5.7 Build Validation and Auto-Fix

After each execute phase:
1. Runs `dotnet build` (if .sln exists)
2. Runs `npm run build` (if package.json exists)
3. On failure: dispatches Codex to fix build errors
4. Retries build after fix

## 5.8 Agent Watchdog

Every agent call has a 30-minute watchdog timer:

- If an agent hangs for 30 minutes, the process is killed
- The engine retries with a reduced batch
- Timeout events are logged to `errors.jsonl`
- Notification sent via ntfy

## 5.9 The Supervisor

The supervisor is an outer loop that wraps the entire pipeline. When a pipeline exits (stalled, crashed, or max iterations without convergence):

```
┌──────────────────────────────────────────────────┐
│                 SUPERVISOR LOOP                   │
│                                                  │
│  Attempt 1:                                      │
│    1. Run pipeline normally                      │
│    2. Pipeline exits (stalled/crashed)           │
│    3. L1: Pattern match errors.jsonl (free)      │
│    4. L2: Claude diagnoses root cause (~1 call)  │
│    5. L3: Claude generates fix (~1 call)         │
│       Modifies: prompts, queue, matrix, specs    │
│    6. Restart pipeline in new terminal           │
│                                                  │
│  Attempt 2-5: Repeat with new diagnosis          │
│    - Won't repeat same fix (strategies_tried)    │
│    - Learns from cross-project patterns          │
│                                                  │
│  After max attempts:                             │
│    - Generate escalation-report.md               │
│    - Send urgent ntfy notification               │
│    - Exit for human intervention                 │
└──────────────────────────────────────────────────┘
```

**Pattern memory** (`~/.gsd-global/supervisor/pattern-memory.jsonl`) stores successful fixes across all projects. When a similar failure pattern is detected in a different project, the supervisor tries the known fix first.

**Supervisor parameters:**
- `-SupervisorAttempts 5` (default max attempts)
- `-NoSupervisor` (bypass supervisor entirely)

## 5.10 Final Validation Gate

When health reaches 100%, `Invoke-FinalValidation` runs 9 checks:

| Check | Type | Failure Action |
|-------|------|---------------|
| 1. `dotnet build` (strict) | Hard | Health -> 99%, loop auto-fixes |
| 2. `npm run build` | Hard | Health -> 99%, loop auto-fixes |
| 3. `dotnet test` | Hard | Health -> 99%, loop auto-fixes |
| 4. `npm test` | Hard | Health -> 99%, loop auto-fixes |
| 5. SQL validation | Warning | Advisory, included in handoff |
| 6. `dotnet audit` | Warning | Advisory, included in handoff |
| 7. `npm audit` | Warning | Advisory, included in handoff |
| 8. DB completeness | Hard | Health -> 99%, coverage < 90% fails |
| 9. Security compliance | Hard/Warn | Critical = hard failure, High = warning |

Maximum 3 validation attempts. The outer do/while loop wraps the main iteration loop, allowing the engine to fix validation failures and retry.

After the pipeline exits (converged, stalled, or max iterations), `New-DeveloperHandoff` generates `developer-handoff.md` with:

1. Quick Start (auto-detected build commands)
2. Database Setup (SQL files, connection strings)
3. Environment Configuration (config files, .env)
4. Project Structure (file tree)
5. Requirements Status (grouped table)
6. Validation Results
7. Known Issues (remaining gaps, recent errors)
8. Health Progression (ASCII chart)
9. Cost Summary (by agent and phase)
10. Council Review Results

The handoff file is committed and pushed to the remote repository.

---

# Chapter 6: Configuration Reference

## 6.1 Global Configuration (global-config.json)

Location: `%USERPROFILE%\.gsd-global\config\global-config.json`

```json
{
  "notifications": {
    "ntfy_topic": "auto",
    "notify_on": ["iteration_complete", "converged", "stalled", "quota_exhausted", "error"]
  },
  "patterns": {
    "backend": ".NET 8 with Dapper",
    "database": "SQL Server stored procedures only",
    "frontend": "React 18",
    "api": "Contract-first, API-first",
    "compliance": ["HIPAA", "SOC 2", "PCI", "GDPR"]
  },
  "phase_order": ["code-review", "create-phases", "research", "plan", "execute"],
  "council": {
    "enabled": true,
    "max_attempts": 2,
    "consensus_threshold": 0.66,
    "chunking": {
      "enabled": true,
      "max_chunk_size": 25,
      "min_group_size": 5,
      "strategy": "auto",
      "cooldown_seconds": 5,
      "min_requirements_to_chunk": 30
    }
  },
  "quality_gates": {
    "database_completeness": {
      "enabled": true,
      "require_seed_data": true,
      "min_coverage_pct": 90
    },
    "security_compliance": {
      "enabled": true,
      "block_on_critical": true,
      "warn_on_high": true
    },
    "spec_quality": {
      "enabled": true,
      "min_clarity_score": 70,
      "check_cross_artifact": true
    }
  },
  "agent_models": {
    "claude": "claude-sonnet-4-6",
    "gemini": "gemini-3.0-pro",
    "codex":  "gpt-5.4"
  }
}
```

### notifications

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `ntfy_topic` | string | "auto" | "auto" for per-project topics (gsd-{username}-{reponame}), or a specific string |
| `notify_on` | string[] | (all events) | Events that trigger push notifications |

Full event list: `iteration_complete`, `no_progress`, `execute_failed`, `build_failed`, `regression_reverted`, `converged`, `stalled`, `quota_exhausted`, `error`, `heartbeat`, `agent_timeout`, `progress_response`, `supervisor_active`, `supervisor_diagnosis`, `supervisor_fix`, `supervisor_restart`, `supervisor_recovered`, `supervisor_escalation`, `validation_failed`, `validation_passed`

### patterns

Project technology patterns enforced by all pipelines, injected into agent prompts.

| Field | Type | Description |
|-------|------|-------------|
| `backend` | string | Backend framework and ORM |
| `database` | string | Database access pattern |
| `frontend` | string | Frontend framework |
| `api` | string | API design approach |
| `compliance` | string[] | Regulatory compliance requirements |

### phase_order

Defines the convergence loop phase sequence. Each phase maps to a specific agent and prompt template.

### council

LLM Council configuration for multi-agent cross-validation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Enable/disable all council reviews |
| `max_attempts` | int | 2 | Max convergence council runs per pipeline |
| `consensus_threshold` | float | 0.66 | Fraction of reviewers that must agree |

Council types:

| Type | Pipeline | Blocking | Reviewers | Synthesizer |
|------|----------|----------|-----------|-------------|
| convergence | Both | Yes (resets health to 99%) | Codex + Gemini | Claude |
| post-research | Convergence | No (feedback only) | Codex + Gemini | Claude |
| pre-execute | Convergence | No (feedback only) | Codex + Gemini | Claude |
| post-blueprint | Blueprint | Yes (regenerates manifest) | Codex + Gemini | Claude |
| stall-diagnosis | Both | N/A (diagnostic) | Codex + Gemini | Claude |
| post-spec-fix | Both | Yes (retries resolution) | Codex + Gemini | Claude |

### council.chunking

For large projects, requirements are auto-chunked into smaller groups for focused reviews.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Enable/disable chunked reviews |
| `max_chunk_size` | int | 25 | Max requirements per chunk |
| `min_group_size` | int | 5 | Groups smaller than this get merged |
| `strategy` | string | "auto" | Chunking strategy |
| `cooldown_seconds` | int | 5 | Pause between chunks |
| `min_requirements_to_chunk` | int | 30 | Skip chunking below this count |

Strategies: **auto** (discovers best field), **field:X** (force group by field), **id-range** (sequential blocks).

### quality_gates

Controls three quality gate checks that run during pipeline execution.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `database_completeness.enabled` | bool | true | Enable DB completeness check |
| `database_completeness.require_seed_data` | bool | true | Require seed data for every table |
| `database_completeness.min_coverage_pct` | int | 90 | Minimum coverage % to pass |
| `security_compliance.enabled` | bool | true | Enable security scan |
| `security_compliance.block_on_critical` | bool | true | Critical violations are hard failures |
| `security_compliance.warn_on_high` | bool | true | High severity shown as warnings |
| `spec_quality.enabled` | bool | true | Enable spec quality gate |
| `spec_quality.min_clarity_score` | int | 70 | Minimum clarity score (0-100) |
| `spec_quality.check_cross_artifact` | bool | true | Run cross-artifact consistency check |

### agent_models

Pins the exact model version passed to each CLI agent via `--model`. Loaded once at pipeline startup from global-config.json; script-scope constants (`$script:CLAUDE_MODEL`, `$script:GEMINI_MODEL`, `$script:CODEX_MODEL`) propagate to every CLI call in resilience.ps1 and all pipeline scripts.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `claude` | string | "claude-sonnet-4-6" | Claude Code model ID |
| `gemini` | string | "gemini-3.0-pro" | Gemini CLI model ID |
| `codex` | string | "gpt-5.4" | Codex CLI model ID |

To upgrade a model without reinstalling, edit this section and restart the pipeline. To use Opus for the next run: `"claude": "claude-opus-4-6"`.

## 6.2 Agent Assignment (agent-map.json)

Location: `%USERPROFILE%\.gsd-global\config\agent-map.json`

Phase-to-agent mapping with parallel execution configuration:

```json
{
  "code-review": "claude",
  "create-phases": "claude",
  "research": "gemini",
  "plan": "claude",
  "execute": "codex",
  "blueprint": "claude",
  "build": "codex",
  "verify": "claude",
  "execute_parallel": {
    "enabled": true,
    "max_concurrent": 3,
    "agent_pool": ["codex", "claude", "gemini"],
    "strategy": "round-robin",
    "fallback_to_sequential": true,
    "subtask_timeout_minutes": 30
  }
}
```

### execute_parallel

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | true | Master switch. false = monolithic behavior |
| `max_concurrent` | int | 3 | Max parallel agent jobs per wave |
| `agent_pool` | string[] | ["codex","claude","gemini"] | Agents to rotate through |
| `strategy` | string | "round-robin" | "round-robin" or "all-same" |
| `fallback_to_sequential` | bool | true | Fall back to monolithic if all fail |
| `subtask_timeout_minutes` | int | 30 | Per-subtask watchdog timeout |

## 6.3 Blueprint Configuration (blueprint-config.json)

Created per-project during blueprint initialization. Contains the blueprint manifest path, batch size, and stall threshold.

## 6.4 Per-Project State Files

### health-current.json

```json
{
  "health_score": 72.5,
  "total_requirements": 40,
  "satisfied": 25,
  "partial": 8,
  "not_started": 7,
  "iteration": 5
}
```

### engine-status.json

Live engine state updated at every state transition and every 60 seconds:

```json
{
  "pid": 23340,
  "state": "running",
  "phase": "research",
  "agent": "gemini",
  "iteration": 4,
  "attempt": "1/3",
  "batch_size": 8,
  "health_score": 87.5,
  "last_heartbeat": "2026-03-02T22:27:00Z",
  "started_at": "2026-03-02T22:00:00Z",
  "elapsed_minutes": 27,
  "sleep_until": null,
  "sleep_reason": null,
  "last_error": null,
  "errors_this_iteration": 0,
  "recovered_from_error": false
}
```

| Field | Type | Description |
|-------|------|-------------|
| `state` | string | starting, running, sleeping, stalled, completed, converged |
| `phase` | string | Current pipeline phase |
| `agent` | string | Active agent ("claude", "codex", "gemini") |
| `sleep_until` | string/null | When sleep ends (quota backoff) |
| `sleep_reason` | string/null | Why sleeping (quota_backoff, rate_limit) |

### final-validation.json

```json
{
  "passed": true,
  "hard_failures": [],
  "warnings": ["NuGet vulnerabilities: 2 package(s) flagged"],
  "iteration": 12,
  "timestamp": "2026-03-03T14:30:00Z",
  "checks": {
    "dotnet_build": { "passed": true },
    "npm_build": { "passed": true },
    "dotnet_test": { "passed": true, "summary": ["Tests passed: 42"] },
    "npm_test": { "passed": true },
    "sql": { "passed": true },
    "dotnet_audit": { "passed": false, "vulnerabilities": ["High: Package 1.2.3"] },
    "npm_audit": { "passed": true }
  }
}
```

### token-usage.jsonl

Append-only log (ground truth for cost data):

```json
{"timestamp":"2026-03-02T14:30:00Z","pipeline":"converge","iteration":5,"phase":"code-review","agent":"claude","batch_size":8,"success":true,"is_fallback":false,"tokens":{"input":45000,"output":3200,"cached":12000},"cost_usd":0.183,"duration_seconds":120,"num_turns":4}
```

### cost-summary.json

Rolling totals updated after each agent call:

```json
{
  "project_start": "2026-03-01T10:00:00Z",
  "last_updated": "2026-03-02T14:30:00Z",
  "total_calls": 47,
  "total_cost_usd": 12.45,
  "total_tokens": { "input": 2100000, "output": 156000, "cached": 890000 },
  "by_agent": {
    "claude": { "calls": 28, "cost_usd": 7.20 },
    "codex": { "calls": 12, "cost_usd": 3.90 },
    "gemini": { "calls": 7, "cost_usd": 1.35 }
  },
  "by_phase": {
    "code-review": { "calls": 10, "cost_usd": 2.10 },
    "research": { "calls": 10, "cost_usd": 1.35 },
    "plan": { "calls": 10, "cost_usd": 1.80 },
    "execute": { "calls": 10, "cost_usd": 3.20 }
  },
  "runs": [
    { "started": "2026-03-01T10:00:00Z", "ended": "2026-03-01T12:30:00Z", "calls": 25, "cost_usd": 6.00 }
  ]
}
```

### supervisor-state.json

```json
{
  "pipeline": "converge",
  "attempt": 2,
  "max_attempts": 5,
  "start_time": "2026-03-02T10:00:00Z",
  "strategies_tried": [
    {"category": "build_loop", "fix": "Added namespace constraints", "attempt": 1}
  ],
  "diagnoses": [
    {"attempt": 1, "category": "build_loop", "root_cause": "DTO namespace mismatch"}
  ]
}
```

## 6.5 Environment Variables

### API Key Variables

| Variable | Used By | Expected Prefix | Key Source |
|----------|---------|----------------|-----------|
| `ANTHROPIC_API_KEY` | Claude Code | sk-ant- | console.anthropic.com |
| `OPENAI_API_KEY` | Codex | sk- | platform.openai.com |
| `GOOGLE_API_KEY` | Gemini | AIza | aistudio.google.com |

### System Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| `USERPROFILE` | All scripts | Home directory for .gsd-global |
| `USERNAME` | Notifications | Auto-generates ntfy topic |
| `PATH` | CLI wrappers | Must include .gsd-global\bin |

## 6.6 Pricing Cache

Location: `%USERPROFILE%\.gsd-global\pricing-cache.json`

Auto-generated by `gsd-costs`. Stores cached LLM pricing from the LiteLLM open-source database.

### Supported Models

| Cache Key | Model Name | Default Role |
|-----------|-----------|--------------|
| `claude_sonnet` | Claude Sonnet 4.6 | Review, Plan, Verify, Blueprint |
| `claude_opus` | Claude Opus 4.6 | Premium alternative to Sonnet |
| `claude_haiku` | Claude Haiku 4.5 | Economy alternative |
| `codex` | GPT 5.3 Codex | Build, Execute |
| `codex_gpt51` | GPT Codex 5.1 | Alternative code gen |
| `gemini` | Gemini 3.1 Pro | Research, Spec-fix |
| `kimi` | Kimi K2.5 (Moonshot) | Council review, rotation fallback |
| `deepseek` | DeepSeek V3 | Council review, rotation fallback |
| `glm5` | GLM-5 (Zhipu AI) | Council review, rotation fallback |
| `minimax` | MiniMax M2.5 | Council review, rotation fallback |

### Cache Freshness

| Age | Behavior |
|-----|----------|
| < 14 days | Fresh -- used directly |
| 14-60 days | Aging -- auto-refresh attempted |
| > 60 days | Stale -- warning displayed |
| No cache | Fetches from web, falls back to hardcoded prices |

---

# Chapter 7: Multi-Interface Support

## 7.1 Component Architecture

A complete project has three foundational layers. All UI interfaces communicate with the database through the API:

```
UI Interfaces (web, mobile, mcp, browser, agent)
        │
    REST API / Backend (.NET Controllers → Services → Dapper)
        │
    Database (SQL Server stored procs → tables → seed data)
```

## 7.2 Interface Types

The engine detects and supports seven interface types:

| Type | Description | Detection Pattern | Auto-Detect |
|------|-------------|-------------------|-------------|
| `web` | Web application UI | `design/web/v##` | No |
| `api` | REST API / Backend | `design/api/v##` | Yes (.sln, .csproj) |
| `database` | Database / SQL Schema | `design/database/v##` | Yes (.sql files) |
| `mcp` | Admin/management portal | `design/mcp/v##` | No |
| `browser` | Browser extension | `design/browser/v##` | No |
| `mobile` | iOS/Android mobile app | `design/mobile/v##` | No |
| `agent` | Background agent/service | `design/agent/v##` | No |

The `api` and `database` types support dual detection: design-dir based (like other types) and auto-detected from project structure when design directories don't exist.

## 7.3 Directory Structure

```
design\
├── web\
│   └── v01\                    # Version folder
│       ├── _analysis\          # 12 Figma Make deliverables
│       └── _stubs\             # Backend stubs (SQL)
├── api\
│   └── v01\
│       ├── _analysis\
│       └── _stubs\
├── database\
│   └── v01\
│       ├── _analysis\
│       └── _stubs\
├── mcp\
│   └── v01\
│       ├── _analysis\
│       └── _stubs\
└── mobile\
    └── v01\
        ├── _analysis\
        └── _stubs\
```

## 7.4 Figma Make Integration

Each interface version folder should contain 12 analysis deliverables in `_analysis/`:

| # | File | Content |
|---|------|---------|
| 1 | `01-layout-hierarchy.md` | Page and component hierarchy |
| 2 | `02-component-catalog.md` | Component inventory with props |
| 3 | `03-navigation-map.md` | Route structure and navigation flows |
| 4 | `04-design-tokens.md` | Colors, typography, spacing tokens |
| 5 | `05-interaction-patterns.md` | Click, hover, drag behaviors |
| 6 | `06-api-contracts.md` | API endpoint definitions |
| 7 | `07-state-machines.md` | Component state transitions |
| 8 | `08-accessibility-spec.md` | ARIA labels, keyboard navigation |
| 9 | `09-responsive-breakpoints.md` | Breakpoint definitions |
| 10 | `10-error-states.md` | Error handling UI patterns |
| 11 | `11-api-to-sp-map.md` | API endpoint to stored procedure mapping |
| 12 | `12-mock-data.md` | Mock data for development |

And 3 backend stubs in `_stubs/`:

| File | Content |
|------|---------|
| `01-tables.sql` | CREATE TABLE statements |
| `02-stored-procedures.sql` | CREATE PROCEDURE statements |
| `03-seed-data.sql` | INSERT/MERGE seed data |

## 7.5 Auto-Discovery

`Find-ProjectInterfaces` recursively scans the repository:

1. Checks `design/` folder for interface type subfolders
2. Finds the latest version folder (highest `v##`)
3. Detects `_analysis/` and `_stubs/` presence
4. Returns a list of interface objects with type, path, version, and available deliverables

The engine processes each interface independently, passing interface-specific context to all agent prompts.

## 7.6 Auto-Detection from Project Structure

When `design/api/` or `design/database/` directories don't exist, the engine auto-detects these interfaces from the project structure:

**API Detection:**
- Scans for `.sln` or `.csproj` files in the repository
- Discovers `Controllers/`, `Services/`, `Models/`, `Repositories/`, `Middleware/` directories
- Excludes paths under `design/`, `node_modules/`, `bin/`, `obj/`, and `_stubs/`
- Displayed as "Auto-detected from {solution-name}.sln"

**Database Detection:**
- Scans for `database/`, `db/`, `sql/`, or `migrations/` directories
- Counts `.sql` files recursively within those directories
- Excludes paths under `design/`, `node_modules/`, `bin/`, `obj/`, and `_stubs/`
- Displayed as "Auto-detected from N SQL files"

Auto-detected interfaces appear in the summary with limited metadata (no `_analysis/` or `_stubs/`) but are still tracked as project components and included in the interface context injected into agent prompts.

---

# Chapter 8: Script Reference

## 8.1 User Commands

### gsd-assess

Scans codebase, detects interfaces, generates file map, classifies work.

```powershell
gsd-assess              # Full assessment
gsd-assess -MapOnly     # File map only (no Claude call)
gsd-assess -DryRun      # Preview mode
```

Output: `.gsd/assessment/` with file inventories, pattern detection (framework, ORM, styling), spec coverage analysis, and work classification per item (skip, refactor, extend, build_new).

### gsd-converge

5-phase convergence loop. See Section 4.3 for full parameter reference.

### gsd-blueprint

3-phase blueprint pipeline. See Section 4.4 for full parameter reference.

### gsd-status

Health dashboard showing current score, iteration, phase, requirement breakdown, and costs.

### gsd-costs

Token cost estimator with pipeline comparison and client quoting. See Section 4.6 for full parameter reference.

### gsd-fix

Quick bug fix mode. Accepts bug descriptions as arguments, from a file, or from a directory containing rich artifacts. Auto-creates `BUG-xxx` requirement entries in the matrix, writes error context for agent injection, and runs a short convergence cycle with small batch size. Options: `-File bugs.md` (load from file), `-BugDir ./bugs/issue/` (directory with bug.md + screenshots/logs/files), `-Scope "source:bug_report"` (default scope), `-MaxIterations 5` (default), `-BatchSize 3` (default), `-DryRun`.

### gsd-update

Incremental feature update mode. Reads new/updated specs and adds requirements to the existing matrix without losing satisfied items. Uses `create-phases-incremental.md` prompt. Options: `-Scope "source:v02_spec"`, `-MaxIterations`, `-DryRun`.

### gsd-init

Initializes `.gsd/` folder structure without running any iterations. Creates all subdirectories and configuration templates.

### gsd-remote

Launches remote monitoring server and displays a QR code for phone access.

### gsd-verify-requirements

Council-based requirements verification. All 3 agents independently extract requirements, then Claude synthesizes a merged, deduplicated, confidence-scored matrix.

```powershell
gsd-verify-requirements                     # 3-agent parallel extraction
gsd-verify-requirements -Sequential         # One agent at a time
gsd-verify-requirements -DryRun             # Preview without running
gsd-verify-requirements -SkipAgent gemini   # Skip unavailable agent
gsd-verify-requirements -PreserveExisting   # Merge into existing matrix
```

Output: `.gsd/health/requirements-matrix.json` with `confidence` and `found_by` fields. See Chapter 21 for details.

## 8.2 Installation Scripts

### install-gsd-all.ps1 (Master Installer)

Orchestrates all 36 install/patch scripts in dependency order. Pre-checks for Git, Node.js, and CLI tools. Writes VERSION file. Reports pass/fail summary.

Parameters: `-AnthropicKey`, `-OpenAIKey`, `-GoogleKey` for non-interactive API key setup.

### install-gsd-prerequisites.ps1

Environment validator. Checks/installs all required tools (PowerShell, Node.js, Git, .NET, Claude/Codex CLIs). Handles API key interactive prompts.

Parameters: `-SkipOptional`, `-VerifyOnly`, `-Force`, `-SkipAuth`

### install-gsd-global.ps1

Core engine installer. Creates `~/.gsd-global/` directory structure, copies engine scripts, generates prompt templates, configures PowerShell profile with gsd-* commands.

### install-gsd-blueprint.ps1

Blueprint pipeline installer. Creates `~/.gsd-global/blueprint/` with pipeline script, prompts, and assess script. Installs Codex build prompt with security standards reference.

### patch-gsd-partial-repo.ps1

Adds `gsd-assess` standalone command, `Update-FileMap` function for file inventory generation, and partial repo handling prompts for both Claude and Codex.

### patch-gsd-resilience.ps1

Core resilience module. Creates `resilience.ps1` with: `Invoke-WithRetry` (retry + batch reduction), pre-flight validation (tools, .sln, git, disk), `New-Lock`/`Remove-Lock`, `Save-Checkpoint`/`Restore-Checkpoint`, health regression protection, structured error logging.

### patch-gsd-hardening.ps1

Hardening layer: JSON validation with rollback, quota detection with exponential backoff, network polling, per-iteration disk checks, agent boundary enforcement, CLI version checks, SQL linting, automatic test generation, heartbeat and notification system.

### patch-gsd-final-validation.ps1

Adds `Invoke-FinalValidation` (9 checks at 100% health) and `New-DeveloperHandoff` (generates comprehensive handoff document). Hard failures loop back; warnings are advisory.

### patch-gsd-figma-make.ps1

Multi-interface detection (`Find-ProjectInterfaces`), Figma Make `_analysis/` and `_stubs/` integration, per-interface prompts, known-limitations matrix.

### final-patch-1-spec-check.ps1

Adds `Invoke-SpecConsistencyCheck` -- pre-iteration spec auditor that detects contradictions in data types, API contracts, navigation, business rules, design systems, and database definitions. Blocks pipeline on critical conflicts.

### final-patch-2-sql-cli.ps1

SQL syntax validation via sqlcmd (parse-only mode), CLI version compatibility checking, enhanced `Test-SqlFiles` with pattern detection (string concatenation, missing TRY/CATCH, missing audit columns).

### final-patch-3-storyboard-verify.ps1

Creates `verify-storyboard.md` prompt that traces data flows end-to-end: component -> hook -> endpoint -> service -> stored procedure. Catches logic bugs that unit tests miss.

### final-patch-4-blueprint-pipeline.ps1

Syncs the installed blueprint pipeline from the canonical repository source file so the deployed runtime stays aligned with the maintained repo implementation.

### final-patch-5-convergence-pipeline.ps1

Syncs the installed convergence pipeline from the canonical repository source file so later patches extend the same runtime the repo documents and tests.

### final-patch-6-assess-limitations.ps1

Final `gsd-assess` script with multi-interface support, `KNOWN-LIMITATIONS.md` audit (16 closed gaps, 5 remaining), master installer copy.

### final-patch-7-spec-resolve.ps1

Adds `Invoke-SpecConflictResolution` -- uses Gemini to auto-resolve spec contradictions. Includes post-spec-fix council gate. Writes resolution summary and log.

### patch-gsd-supervisor.ps1

Self-healing supervisor: `Save-TerminalSummary`, `Invoke-SupervisorDiagnosis` (L1 pattern match, L2 AI diagnosis), `Invoke-SupervisorFix` (L3 AI fix), `New-EscalationReport`. Pattern memory across projects.

### patch-false-converge-fix.ps1

Bug fix: moves variable initialization before try block to prevent false convergence exit. Cleans orphaned profile code.

### patch-gsd-council.ps1

LLM Council system: `Invoke-LlmCouncil` with 6 council types, `Build-RequirementChunks` for large projects, prompt templates for Codex/Gemini reviewers and Claude synthesizer.

### patch-gsd-parallel-execute.ps1

Parallel sub-task execution: `Invoke-ParallelExecute` splits batches, dispatches round-robin, manages waves with cooldown, handles partial success, falls back to monolithic.

### patch-gsd-resilience-hardening.ps1

Token tracking on all attempts (success + failure + estimation), auth detection fix (403 is rate limit not auth), cumulative quota cap (120 min), agent rotation after 1 consecutive failure (reduced from 3 by multi-model patch).

### patch-gsd-quality-gates.ps1

Quality gates: `Test-DatabaseCompleteness` (zero-cost static scan), `Test-SecurityCompliance` (zero-cost regex scan), `Invoke-SpecQualityGate` (enhanced spec validation). Creates 5 shared prompt templates. Updates council reviews with security checklists.

### patch-gsd-multi-model.ps1

Multi-model LLM integration: Adds 4 OpenAI-compatible REST agents (Kimi K2.5, DeepSeek V3, GLM-5, MiniMax M2.5). Creates `model-registry.json` for registry-driven agent management. Adds `Invoke-OpenAICompatibleAgent` (REST adapter), `Test-IsOpenAICompatAgent` (registry lookup). Patches `Get-FailureDiagnosis` for REST agent HTTP error mapping (steps 13B/13C). Expands council reviewer pool, reduces rotation threshold from 3 to 1 consecutive failures, adds cooldown-aware supervisor routing. Generic council template `openai-compat-review.md`.

### patch-gsd-differential-review.ps1

Differential code review: Reviews only files changed since last iteration using git diff. Adds `Get-DifferentialContext` and `Save-ReviewedCommit` to resilience.ps1. Creates `code-review-differential.md` prompt template. Maintains cache at `.gsd/cache/reviewed-files.json`. Falls back to full review if >50% files changed or cache expired. Config: `differential_review` in global-config.json.

### patch-gsd-pre-execute-gate.ps1

Pre-execute compile gate: Runs `dotnet build` + `npm run build` BEFORE committing code. If build fails, sends errors back to executing agent for immediate fix (same context window). Max 2 fix attempts. Adds `Invoke-PreExecuteGate` to resilience.ps1. Creates `fix-compile-errors.md` prompt template. Config: `pre_execute_gate` in global-config.json.

### patch-gsd-acceptance-tests.ps1

Per-requirement acceptance tests: Auto-generates and runs tests per requirement. Plan phase outputs `acceptance_test` field per requirement (file_exists, pattern_match, build_check, dotnet_test, npm_test). Adds `Test-RequirementAcceptance` to resilience.ps1. Results saved to `.gsd/tests/acceptance-results.json`. Config: `acceptance_tests` in global-config.json.

### patch-gsd-api-contract-validation.ps1

Contract-first API validation: Zero-cost static scan validating controllers against OpenAPI specs (`06-api-contracts.md`). Checks route coverage, HTTP methods, parameter types, [Authorize] compliance, inline SQL detection, SP mapping. Adds `Test-ApiContractCompliance` to resilience.ps1. Creates `api-contract-validation.md` reference. Config: `api_contract_validation` in global-config.json.

### patch-gsd-visual-validation.ps1

Visual validation: Compares generated React components against Figma exported screenshots using Playwright. Uses three-tier diff: (1) SHA-256 hash equality (instant pass); (2) ImageMagick pixel diff via `magick compare -metric AE -fuzz 2%` (accurate); (3) file-size ratio with warning when ImageMagick is not installed. Flags >15% deviation. Adds `Invoke-VisualValidation` to resilience.ps1. Config: `visual_validation` in global-config.json.

### patch-gsd-design-token-enforcement.ps1

Design token enforcement: Zero-cost regex scan detecting hardcoded CSS values (colors, font sizes, spacing, border radii). Cross-references against design tokens file. Allows CSS custom properties (`var(--xxx)`). Adds `Test-DesignTokenCompliance` to resilience.ps1. Config: `design_token_enforcement` in global-config.json.

### patch-gsd-compliance-engine.ps1

Compliance engine with three sub-systems: (1) `Invoke-PerIterationCompliance` -- structured rule engine with 20+ SEC-*/COMP-* rules scanning every iteration (SQL injection, XSS, eval, hardcoded secrets, missing [Authorize], PII in logs, HIPAA/SOC2/PCI/GDPR patterns). SEC-NET-05 and SEC-FE-01 use `(?s)` multiline mode with `(?!.*\[AllowAnonymous])` negative lookahead so intentionally anonymous endpoints are not flagged. (2) `Test-DatabaseMigrationIntegrity` -- FK consistency, index coverage, seed data referential integrity. (3) `Invoke-PiiFlowAnalysis` -- traces PII fields through API->controller->SP->table, checks logging/encryption/UI masking. All zero-cost static scans. Config: `compliance_engine` in global-config.json.

### patch-gsd-speed-optimizations.ps1

Five speed optimizations: (1) `Test-ShouldSkipResearch` -- skip research when health improving and no new requirements. (2) `Get-OptimalBatchSize` -- data-driven batch sizing from token history. (3) `Update-FileMapIncremental` -- threshold-based incremental file map: ≤20 changed files prunes deleted entries from the cached map (sub-second); >20 files triggers full rebuild via `Update-FileMap`. (4) `Resolve-PromptWithDedup` -- {{SECURITY_STANDARDS}} and {{CODING_CONVENTIONS}} template variables. (5) Token budget headers and inter-agent handoff protocols added to 4 prompt templates. Config: `speed_optimizations` in global-config.json.

### patch-gsd-agent-intelligence.ps1

Agent intelligence: (1) `Update-AgentPerformanceScore` -- tracks efficiency (requirements/1K tokens) and reliability (1 - regression rate) per agent. `Get-BestAgentForPhase` -- data-driven agent routing. (2) `Save-ProjectPatterns` + `Get-WarmStartPatterns` -- caches detected patterns by project type (dotnet-react, dotnet-api, react-spa) for warm-starting new projects. Global cache at `~/.gsd-global/intelligence/`. Config: `agent_intelligence` in global-config.json.

### patch-gsd-loc-tracking.ps1

LOC tracking: (1) `Update-LocMetrics` -- captures `git diff --numstat` after each execute phase, tracks lines added/deleted/net per iteration with file-level detail. (2) `Get-LocNotificationText` -- compact LOC string for ntfy notifications. Cross-references cost-summary.json to compute cost-per-added-line and cost-per-net-line. Patches both pipeline scripts and heartbeat to include LOC in all ntfy messages. Adds LOC section to developer-handoff.md. Output: `.gsd/costs/loc-metrics.json`. Config: `loc_tracking` in global-config.json.

### patch-gsd-runtime-smoke-test.ps1

Runtime smoke tests: (1) `Test-SeedDataFkOrder` -- static scan of SQL seed files checking INSERT order vs FK constraints. (2) `Find-ApiEndpoints` -- discovers API routes from Controller files and OpenAPI spec. (3) `Invoke-ApiSmokeTest` -- starts the app via `dotnet run`, hits discovered endpoints, checks for 500s. (4) `Invoke-RuntimeSmokeTest` -- orchestrator running all three checks. Creates `health-endpoint.md` and `di-service-lifetime.md` prompt templates. Config: `runtime_smoke_test` in global-config.json.

### patch-gsd-partitioned-code-review.ps1

Partitioned code review: (1) `Split-RequirementsIntoPartitions` -- divides requirements into 3 balanced groups. (2) `Get-SpecAndFigmaPaths` -- resolves spec and Figma deliverable paths. (3) `Invoke-PartitionedCodeReview` -- launches 3 parallel agents with rotation-based assignment, merges results. (4) `Merge-PartitionedReviews` -- combines partition results into single health score. (5) `Update-CoverageMatrix` -- tracks which agent reviewed which requirement. Auto-patches `Invoke-WithRetry` for gemini dispatch if missing. Creates partition-specific prompt templates. Output: `.gsd/code-review/coverage-matrix.json`. Config: `partitioned_code_review` in global-config.json.

### patch-gsd-loc-cost-integration.ps1

LOC-Cost integration: (1) `Save-LocBaseline` -- records starting git commit hash for LOC tracking at pipeline start. (2) `Complete-LocTracking` -- computes grand total LOC diff from baseline commit to HEAD at pipeline end. (3) `Get-LocCostSummaryText` -- returns multi-line LOC vs Cost summary for final ntfy notifications. (4) `Get-LocContextForReview` -- returns LOC history table for injection into code review prompts. Bridges LOC tracking and cost tracking for running cost-per-line metrics and enhanced notifications.

### patch-gsd-maintenance-mode.ps1

Maintenance mode for post-launch updates: (1) `gsd-fix` command -- accepts bug descriptions via CLI args or file, auto-creates `BUG-xxx` requirement entries with `source: bug_report`, writes error-context.md, runs short convergence cycle with small batch/iterations. (2) `gsd-update` command -- incremental feature addition using `create-phases-incremental.md` prompt that preserves existing satisfied requirements and adds new ones from updated specs. (3) `--Scope` parameter on `gsd-converge` -- filters plan phase to only select matching requirements (by source or ID) while code-review still sees everything. (4) `--Incremental` flag -- triggers additive Phase 0 that merges new requirements into existing matrix. Config: `maintenance_mode` in global-config.json.

### patch-gsd-council-requirements.ps1

Council-based requirements verification: All 3 agents independently extract requirements from specs, Figma, and code, then Claude synthesizes a merged, deduplicated, confidence-scored `requirements-matrix.json`. (1) `Invoke-CouncilRequirements` -- dispatches 3 parallel jobs, collects JSON outputs, runs Claude synthesis with fallback to local merge. (2) `Merge-CouncilRequirementsLocal` -- PowerShell fallback using token-overlap Jaccard similarity deduplication. (3) `gsd-verify-requirements` profile function -- standalone command for any repo. Creates 5 prompt templates in `prompts/council/`. Patches convergence pipeline Phase 0 to use council when `council_requirements.enabled = true`. Config: `council_requirements` in global-config.json.

## 8.3 Standalone Utilities

### setup-gsd-api-keys.ps1

Manages API key environment variables. Stores as persistent User-level environment variables with prefix validation and masked display.

```powershell
.\scripts\setup-gsd-api-keys.ps1          # Interactive setup
.\scripts\setup-gsd-api-keys.ps1 -Show    # Display masked status
.\scripts\setup-gsd-api-keys.ps1 -Clear   # Remove all keys
```

### setup-gsd-convergence.ps1

Per-project bootstrap. Creates `.gsd/` directory tree with 16 subdirectories, generates config files, prompt templates, and convergence orchestrator. Detects Figma version, references SDLC docs.

### install-gsd-keybindings.ps1

Adds VS Code keyboard shortcuts (Ctrl+Shift+G chord prefix) for blueprint, convergence, and status commands.

### token-cost-calculator.ps1

~1048 lines. Estimates API costs using dynamic pricing from LiteLLM. Supports 6 models, two pipelines, client quoting with configurable markup, actual vs estimated comparison.

## 8.4 Key Internal Functions

### Invoke-WithRetry

```
Invoke-WithRetry -Phase <string> -Agent <string> -PromptPath <string>
    -OutputPath <string> [-BatchSize <int>] [-RetryMax <int>]
```

Wraps agent calls with retry logic, batch reduction, token tracking, and error logging. Returns structured result with success/failure, token counts, and cost.

### Update-FileMap

```
Update-FileMap -RepoRoot <string> -GsdDir <string>
```

Generates `.gsd/assessment/file-map.md` -- complete inventory of all source files with type classification and line counts.

### Save-Checkpoint / Restore-Checkpoint

```
Save-Checkpoint -Pipeline <string> -Iteration <int> -Phase <string>
    -Health <double> -BatchSize <int>
Restore-Checkpoint
```

Crash recovery. Saves state to `.gsd/.gsd-checkpoint.json`. Restore reads it and returns the checkpoint object.

### Wait-ForQuotaReset

```
Wait-ForQuotaReset [-MaxCycles <int>] [-InitialWaitMinutes <int>]
```

Exponential backoff for quota exhaustion: 5 -> 10 -> 20 -> 40 -> 60 min cap. Sends ntfy notifications. Respects cumulative 120-minute cap.

### Test-NetworkAvailability

```
Test-NetworkAvailability
```

Polls for internet connectivity at 30-second intervals. Blocks until connection restored.

### Invoke-FinalValidation

```
Invoke-FinalValidation -RepoRoot <string> -GsdDir <string> -Iteration <int>
```

Runs 9 validation checks at 100% health. Returns `@{ Passed; HardFailures; Warnings }`.

### Invoke-LlmCouncil

```
Invoke-LlmCouncil -CouncilType <string> -GsdDir <string> -Iteration <int>
    -Health <double> [-ChunkedReview <bool>]
```

Multi-agent review gate. Dispatches to Codex + Gemini reviewers, Claude synthesizes verdict.

### Invoke-SupervisorDiagnosis / Invoke-SupervisorFix

```
Invoke-SupervisorDiagnosis -GsdDir <string> -Attempt <int>
Invoke-SupervisorFix -GsdDir <string> -Diagnosis <object>
```

L2 diagnosis via Claude (reads errors, determines root cause). L3 fix via Claude (modifies prompts/specs/queue to resolve issue).

### Test-DatabaseCompleteness

```
Test-DatabaseCompleteness -RepoRoot <string> -GsdDir <string>
```

Zero-token static scan. Discovers API endpoints, stored procedures, tables, and seed data. Cross-references the full chain. Returns `@{ Passed; Coverage; MissingStoredProcs; MissingSeedData; Issues }`.

### Test-SecurityCompliance

```
Test-SecurityCompliance -RepoRoot <string> -GsdDir <string>
```

Zero-token regex scan for OWASP patterns:

| Pattern | Severity | What It Catches |
|---------|----------|-----------------|
| String concat + SELECT | Critical | SQL injection |
| dangerouslySetInnerHTML without DOMPurify | Critical | XSS |
| eval() / new Function() | Critical | Code injection |
| localStorage with token/password/secret | Critical | Secrets in browser storage |
| Hardcoded connection strings | Critical | Exposed credentials |
| BinaryFormatter | Critical | Deserialization CVE |
| [HttpPost/Put/Delete] without [Authorize] | High | Missing auth |
| CREATE TABLE without CreatedAt | Medium | Missing audit columns |
| console.log with password/token/ssn | High | Sensitive data in logs |

Returns `@{ Passed; Violations; ViolationCount; Report }`.

### Invoke-SpecQualityGate

```
Invoke-SpecQualityGate -RepoRoot <string> -GsdDir <string>
    [-SkipClarityCheck <bool>]
```

Orchestrates spec validation: existing `Invoke-SpecConsistencyCheck` + Claude clarity scoring (1 call, ~2K tokens) + Claude cross-artifact consistency (1 call, ~2K tokens). Returns `@{ Passed; ClarityScore; ConsistencyPassed; Issues }`.

### Get-FailureDiagnosis

```
Get-FailureDiagnosis -Agent <string> -ExitCode <int>
    -OutputText <string> -Phase <string>
```

Analyzes agent failure output to determine root cause and recommend recovery action. Handles all 7 agents: Gemini (sandbox restrictions, model unavailable, prompt too large), Codex (loop limits, no output), Claude (max turns), and REST agents (HTTP 429 rate limit, 402 quota exhausted, 401 auth failure, 5xx server error, timeout). REST agents fall back to claude for read-only phases (review, council, research, plan); retry for write phases.

### Invoke-OpenAICompatibleAgent

```
Invoke-OpenAICompatibleAgent -AgentName <string> -Prompt <string>
    [-TimeoutSeconds <int>]
```

Generic REST adapter for OpenAI-compatible chat completions API. Reads config from model-registry.json, resolves API key from environment, builds request, calls `Invoke-RestMethod`, returns synthetic JSON envelope with usage tokens. Maps HTTP errors to GSD error taxonomy (rate_limit, unauthorized, server_error, quota_exhausted).

### Test-IsOpenAICompatAgent

```
Test-IsOpenAICompatAgent -AgentName <string>
```

Checks model-registry.json to determine if a given agent name is an openai-compat REST agent. Returns `$true` for kimi, deepseek, glm5, minimax (when registered and enabled).

### Get-DifferentialContext

```
Get-DifferentialContext -GsdDir <string> -GlobalDir <string> -Iteration <int> -RepoRoot <string>
```

Computes git diff since last reviewed commit. Returns `UseDifferential` flag, `DiffContent` (truncated to 50KB), and `ChangedFiles` list. Falls back to full review if cache expired, >50% files changed, or first run.

### Invoke-PreExecuteGate

```
Invoke-PreExecuteGate -RepoRoot <string> -GsdDir <string> -GlobalDir <string>
    -Iteration <int> -Health <decimal> [-ExecuteAgent <string>]
```

Runs dotnet build + npm build before git commit. On failure, sends errors to executing agent for fix. Returns `Passed` flag, `FixApplied` indicator, and `Errors` text.

### Test-RequirementAcceptance

```
Test-RequirementAcceptance -GsdDir <string> -GlobalDir <string>
    -RepoRoot <string> -Iteration <int>
```

Runs acceptance tests from queue-current.json `acceptance_test` fields. Supports file_exists, pattern_match, build_check, dotnet_test, npm_test. Saves results to `.gsd/tests/acceptance-results.json`.

### Test-ApiContractCompliance

```
Test-ApiContractCompliance -RepoRoot <string> -GsdDir <string> -GlobalDir <string>
```

Zero-cost static scan validating controllers against 06-api-contracts.md. Checks route coverage, HTTP methods, [Authorize], inline SQL, SP mapping. Returns blocking issues and warnings.

### Invoke-VisualValidation

```
Invoke-VisualValidation -RepoRoot <string> -GsdDir <string>
    -GlobalDir <string> -Iteration <int>
```

Screenshots React components via Playwright, compares against Figma exports. Falls back to component-match heuristic when Playwright unavailable. Reports pixel diff percentage per component.

### Test-DesignTokenCompliance

```
Test-DesignTokenCompliance -RepoRoot <string> -GsdDir <string> -GlobalDir <string>
```

Scans CSS/SCSS/TSX for hardcoded colors, font sizes, spacing, border radii. Cross-references against design tokens file. Allows CSS custom properties and configured exceptions.

### Invoke-PerIterationCompliance

```
Invoke-PerIterationCompliance -RepoRoot <string> -GsdDir <string>
    -GlobalDir <string> -Iteration <int>
```

Structured rule engine scanning 20+ SEC-*/COMP-* compliance rules every iteration. Reports critical/high/medium violations with file paths and line numbers.

### Test-DatabaseMigrationIntegrity

```
Test-DatabaseMigrationIntegrity -RepoRoot <string> -GsdDir <string> -GlobalDir <string>
```

Zero-cost SQL file scan for FK consistency (referenced tables exist), index coverage (WHERE columns indexed), and seed data integrity (INSERT targets exist).

### Invoke-PiiFlowAnalysis

```
Invoke-PiiFlowAnalysis -RepoRoot <string> -GsdDir <string> -GlobalDir <string>
```

Traces PII fields through codebase. Checks for PII in log output (critical), unencrypted PII storage (high), and unmasked PII in UI (high). Configurable PII field registry.

### Update-AgentPerformanceScore

```
Update-AgentPerformanceScore -GsdDir <string> -GlobalDir <string>
    -Agent <string> -Phase <string> -TokensUsed <int>
    -RequirementsSatisfied <int> -RequirementsRegressed <int> -Iteration <int>
```

Tracks per-agent efficiency (requirements/1K tokens) and reliability (1 - regression rate). Stores scores in `.gsd/intelligence/agent-scores.json` and global `~/.gsd-global/intelligence/agent-scores-global.json`.

### Get-OptimalBatchSize

```
Get-OptimalBatchSize -GsdDir <string> -GlobalDir <string>
    -CurrentBatchSize <int> -Iteration <int>
```

Calculates optimal batch size from historical token usage data. Formula: `floor(context_limit * 0.7 / avg_tokens_per_requirement)`. Bounded by min_batch and max_batch config.

### Update-LocMetrics

```
Update-LocMetrics -RepoRoot <string> -GsdDir <string> -GlobalDir <string>
    -Iteration <int> [-Pipeline <string>]
```

Captures `git diff --numstat HEAD~1 HEAD` after each execute phase commit. Tracks lines added, deleted, net, and files changed per iteration. Cross-references cost-summary.json to compute cost-per-added-line and cost-per-net-line. Saves to `.gsd/costs/loc-metrics.json`.

### Get-LocNotificationText

```
Get-LocNotificationText -GsdDir <string> [-Cumulative]
```

Returns compact LOC string for ntfy notifications. Without `-Cumulative`, shows last iteration metrics. With `-Cumulative`, shows pipeline totals with cost-per-line.

### Find-ProjectInterfaces

```
Find-ProjectInterfaces -RepoRoot <string>
```

Recursively scans `design/` for 7 interface types (web, api, database, mcp, browser, mobile, agent). Auto-detects API from .sln/.csproj and Database from .sql files when design directories don't exist. Returns array of interface objects with type, path, version, and available deliverables.

### Invoke-ParallelExecute

```
Invoke-ParallelExecute -Requirements <array> -GsdDir <string>
    -Iteration <int>
```

Splits requirements into independent sub-tasks, dispatches round-robin across agent pool, manages waves with cooldown, handles partial success.

### Get-NextAvailableAgent / Set-AgentCooldown

```
Get-NextAvailableAgent -PreferredAgent <string> -GsdDir <string>
Set-AgentCooldown -Agent <string> -Minutes <int> -GsdDir <string>
```

Agent rotation for quota management. Checks cooldown timestamps, returns next available agent from pool.

### Test-SeedDataFkOrder / Invoke-RuntimeSmokeTest

```
Test-SeedDataFkOrder -RepoRoot <string> -GsdDir <string>
Invoke-RuntimeSmokeTest -RepoRoot <string> -GsdDir <string>
```

Static FK order validation and full runtime smoke test orchestrator (seed FK check + endpoint discovery + HTTP 500 detection). See Section 17.7.

### Split-RequirementsIntoPartitions / Invoke-PartitionedCodeReview

```
Split-RequirementsIntoPartitions -Matrix <object>
Invoke-PartitionedCodeReview -Iteration <int> -Matrix <object>
```

3-partition parallel code review with agent rotation. Splits requirements into balanced groups, dispatches simultaneously, merges results. See Section 17.8.

### Save-LocBaseline / Complete-LocTracking

```
Save-LocBaseline -GsdDir <string>
Complete-LocTracking -GsdDir <string>
```

Pipeline-level LOC tracking: records starting commit at launch, computes grand total diff at completion. See Section 19.2.

### Invoke-CouncilRequirements / Merge-CouncilRequirementsLocal

```
Invoke-CouncilRequirements -RepoRoot <string> -GsdDir <string>
Merge-CouncilRequirementsLocal -GsdDir <string>
```

3-agent parallel requirements extraction with confidence scoring. `Merge-CouncilRequirementsLocal` provides PowerShell fallback using Jaccard similarity deduplication when the synthesis agent fails. See Chapter 21.

---

# Chapter 9: Troubleshooting

## 9.1 Installation Issues

### "running scripts is disabled on this system"

```powershell
powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1
```

### "gsd-assess is not recognized"

Profile not loaded. Restart terminal or: `. $PROFILE`

Verify profile exists:
```powershell
Test-Path $PROFILE
cat $PROFILE | Select-String "gsd"
```

### "command claude not found" or "command codex not found"

```powershell
npm install -g @anthropic-ai/claude-code
npm install -g @openai/codex
```

### "command gemini not found"

Gemini is optional. Without it, the engine falls back to Codex for research:
```powershell
npm install -g @google/gemini-cli
gemini    # First run authenticates
```

### Install script fails partway through

The installer is idempotent. Re-run to pick up where it left off.

## 9.2 Runtime Issues

### Stale lock file

If a previous run was killed abruptly:

```powershell
# Check lock age
Get-Content .gsd\.gsd-lock

# Remove manually if stale
Remove-Item .gsd\.gsd-lock
```

Locks older than 120 minutes are automatically reclaimed.

### Quota exhausted

The engine handles this automatically:
1. Exponential backoff (5-60 min cycles)
2. After 1 consecutive failure: agent rotation (across 7-agent pool)
3. Cumulative cap: 120 minutes total
4. ntfy notification sent
5. REST agents: HTTP 429/402/401/5xx mapped to same error taxonomy as CLI agents

To manually reset:
```powershell
Remove-Item .gsd\supervisor\agent-cooldowns.json
```

### Network unavailable

The engine polls every 30 seconds and resumes when connectivity returns.

### Codex exit code 2

Codex CLI returns exit code 2 for various errors. The engine:
1. Logs the error
2. Reduces batch size by 50%
3. Retries up to 3 times
4. Falls back to Claude if Codex continues failing

### Health regression after iteration

If health drops >5%:
1. Changes are automatically reverted (git checkout)
2. Previous checkpoint restored
3. Batch size reduced
4. ntfy notification sent

## 9.3 Agent-Specific Issues

### Claude Code authentication failure

```powershell
# Re-authenticate
claude

# Or set API key
$env:ANTHROPIC_API_KEY = "sk-ant-..."
[System.Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", $env:ANTHROPIC_API_KEY, "User")
```

### Codex CLI flag changes

The engine validates CLI versions at startup. If Codex CLI updates break flags:
1. Check version: `codex --version`
2. Update: `npm install -g @openai/codex`
3. The engine will warn about untested versions

### Gemini OAuth expired

```powershell
gemini    # Re-authenticate via browser
```

## 9.4 Spec Consistency Conflicts

### Reading the report

```powershell
# View spec report
Get-Content .gsd\health\spec-consistency-report.json | ConvertFrom-Json | Format-List

# Or the markdown version
Get-Content .gsd\health\spec-consistency-report.md
```

### Common conflict types

| Type | Example | Resolution |
|------|---------|------------|
| Data type mismatch | Spec says `string`, API says `int` | Fix the authoritative source |
| API contract conflict | Two specs define same endpoint differently | Gemini auto-resolve with `-AutoResolve` |
| Navigation conflict | Two screens claim same route | Fix in Figma Make outputs |
| Business rule conflict | Contradictory validation rules | Spec author decides |

### Auto-resolution

```powershell
gsd-converge -AutoResolve    # Gemini resolves automatically
```

## 9.5 Quality Gate Issues

### Database completeness check failing

```
ERROR: DB completeness: 65% (below 90% threshold)
Missing stored procedures: usp_User_GetById, usp_Order_Create
Missing seed data: Users, OrderStatuses
```

**Fix:** The engine automatically sets health to 99% and loops. The execute phase will generate the missing stored procedures and seed data.

**Manual override:** Set `quality_gates.database_completeness.enabled = false` in `global-config.json`.

### Security compliance violations

```
CRITICAL: SQL injection risk in UserRepository.cs:45
CRITICAL: dangerouslySetInnerHTML without DOMPurify in Dashboard.tsx:112
HIGH: Missing [Authorize] on OrderController
```

**Fix:** Critical violations block the pipeline. The execute phase will fix them on the next iteration.

**Patterns detected:** SQL injection, XSS, eval(), localStorage secrets, hardcoded credentials, BinaryFormatter, missing auth, missing audit columns, sensitive data in logs.

### Spec quality gate blocking pipeline

```
BLOCKED: Spec clarity score 58 (threshold: 70)
Issues: 12 ambiguous requirements, 3 missing acceptance criteria
```

**Fix:** Improve spec quality before running pipeline. Or lower the threshold:
```json
"spec_quality": { "min_clarity_score": 50 }
```

### Cross-artifact consistency mismatches

```
Entity 'PatientRecord' in TypeScript differs from 'Patient_Record' in SQL
Field 'dateOfBirth' missing from C# DTO
```

**Fix:** The engine reports these before code generation starts. Fix the Figma Make outputs to ensure consistency.

## 9.6 Reading Error Logs

```powershell
# Recent errors
Get-Content .gsd\logs\errors.jsonl |
  ForEach-Object { $_ | ConvertFrom-Json } |
  Select-Object -Last 10 |
  Format-Table timestamp, category, phase, message -AutoSize
```

Error categories:

| Category | Description |
|----------|-------------|
| `quota` | API quota exhausted |
| `network` | Network connectivity lost |
| `disk` | Insufficient disk space |
| `corrupt_json` | Agent returned invalid JSON |
| `boundary_violation` | Agent wrote to forbidden path |
| `agent_crash` | Agent process crashed |
| `health_regression` | Health dropped after iteration |
| `spec_conflict` | Specification contradictions found |
| `watchdog_timeout` | Agent exceeded 30-minute timeout |
| `build_fail` | Compilation or build failed |
| `fallback_success` | Primary agent failed, fallback succeeded |
| `validation_fail` | Final validation check failed |

---

# Chapter 10: Cost Management

## 10.1 Token Budget Per Iteration

### Convergence Pipeline

| Phase | Agent | Input Tokens | Output Tokens | Cost (Sonnet) |
|-------|-------|-------------|---------------|---------------|
| Code-review | Claude | ~45,000 | ~3,000 | ~$0.18 |
| Research | Gemini | ~30,000 | ~5,000 | ~$0.12 |
| Plan | Claude | ~20,000 | ~2,000 | ~$0.09 |
| Execute | Codex | ~40,000 | ~65,000 | ~$0.98 |
| **Total per iteration** | | | | **~$1.37** |

### Blueprint Pipeline

| Phase | Agent | Input Tokens | Output Tokens | Cost (Sonnet) |
|-------|-------|-------------|---------------|---------------|
| Verify | Claude | ~15,000 | ~2,000 | ~$0.08 |
| Build | Codex | ~50,000 | ~80,000 | ~$1.21 |
| **Total per iteration** | | | | **~$1.29** |

Blueprint also has a one-time cost for the blueprint phase (~$0.35) and council reviews (~$0.30 each).

## 10.2 Pre-Run Estimation

```powershell
# From existing blueprint
gsd-costs -ProjectPath "C:\repos\my-app"

# Manual estimate
gsd-costs -TotalItems 150 -Pipeline blueprint

# Compare pipelines
gsd-costs -TotalItems 150 -ShowComparison

# Detailed per-item breakdown
gsd-costs -TotalItems 150 -Detailed
```

### Token Estimates Per Item Type

| Item Type | Output Tokens | Examples |
|-----------|---------------|---------|
| sql-migration | 1,000 | CREATE TABLE, ALTER TABLE |
| stored-procedure | 2,000 | CRUD procedures |
| controller | 5,000 | API controllers |
| service | 3,500 | Business logic services |
| dto | 1,500 | Data transfer objects |
| component | 4,000 | React UI components |
| hook | 2,500 | React hooks |
| middleware | 2,000 | API middleware |
| config | 1,500 | Configuration files |
| test | 3,000 | Unit/integration tests |
| compliance | 2,000 | Audit, logging, security |
| routing | 1,500 | Route definitions |
| (default) | 3,500 | Any unrecognized type |

## 10.3 Live Cost Tracking

Costs are tracked automatically from the first pipeline run:

- **token-usage.jsonl** -- Append-only log of every agent call (ground truth)
- **cost-summary.json** -- Rolling totals by agent, phase, and run

View at any time:

```powershell
# Summary
gsd-costs -ShowActual

# Raw data
Get-Content .gsd\costs\cost-summary.json | ConvertFrom-Json

# Per-call detail
Get-Content .gsd\costs\token-usage.jsonl |
  ForEach-Object { $_ | ConvertFrom-Json } |
  Select-Object timestamp, phase, agent, cost_usd |
  Format-Table -AutoSize
```

Token costs are tracked on ALL attempts (success and failure). When an agent returns error text instead of structured JSON, costs are estimated from the response size.

## 10.4 Client Quoting

```powershell
gsd-costs -TotalItems 150 -ClientQuote -Markup 7 -ClientName "Acme Corp"
```

### Complexity Tiers

| Tier | Item Count | Suggested Markup | Rationale |
|------|-----------|-----------------|-----------|
| Standard | <= 100 | 5x | Simple projects, standard patterns |
| Complex | <= 250 | 7x | Multi-interface, compliance requirements |
| Enterprise | <= 500 | 7-10x | Large scale, multiple integrations |
| Enterprise+ | > 500 | 10x | Maximum complexity |

### Subscription Cost Comparison

The calculator compares API costs against subscription plans:

| Service | Monthly Cost |
|---------|-------------|
| Claude Pro | $20 |
| Claude Max | $100-200 |
| ChatGPT Plus | $20 |
| ChatGPT Pro | $200 |
| Gemini Advanced | $20 |
| Minimum bundle (Pro tiers) | $60/month |

---

# Chapter 11: Quality Gates

## 11.1 Overview

The GSD Engine enforces three categories of quality gates that run at different points in the pipeline:

| Gate | When | Cost | Failure Action |
|------|------|------|---------------|
| Spec Quality Gate | Pipeline start (once) | ~$0.30 (2 Claude calls) | Blocks if clarity < 70 |
| DB Completeness | Before final validation | $0 (static scan) | Hard failure if < 90% |
| Security Compliance | Before final validation | $0 (regex scan) | Critical = hard failure |
| Final Validation | At 100% health | $0 (build/test) | Hard failures loop back |
| LLM Council | At 100% health | ~$0.50 (3 agent calls) | Blocks, resets to 99% |

## 11.2 Spec Quality Gate

Runs once at pipeline start. Three checks:

1. **Spec Consistency Check** (existing) -- Detects contradictions in data types, API contracts, navigation, business rules
2. **Spec Clarity Check** (Claude) -- Scores specification quality 0-100:
   - 90-100: PASS -- Specs are clear and complete
   - 70-89: WARN -- Minor ambiguities, pipeline proceeds
   - 0-69: BLOCK -- Too many ambiguities, fix specs first
3. **Cross-Artifact Consistency** (Claude) -- After Figma Make, validates:
   - Entity names identical across all 12 analysis files (case-sensitive)
   - Field names match: TypeScript types = C# DTOs = SQL columns
   - Every API endpoint has SP row in `11-api-to-sp-map.md`
   - Every SP has table definition, every table has seed data
   - Mock data IDs match seed data IDs, FK references consistent

## 11.3 Database Completeness

Zero-token-cost static analysis verifying the full database chain:

```
API Endpoint --> Controller --> Repository --> Stored Procedure
    --> Functions/Views --> Tables --> Seed Data
```

### Enhanced Tier Structure

| Tier | Layer | What's Checked |
|------|-------|---------------|
| 1 | Tables + Migrations + Indexes | CREATE TABLE statements exist for all entities |
| 1.5 | Functions, Views, Computed Columns | Supporting database objects |
| 2 | Stored Procedures | All CRUD + business logic SPs exist |
| 2.5 | Seed Data Scripts | INSERT/MERGE per table group |
| 3 | API Endpoints | Controllers with proper routes |
| 4 | Frontend Components | React components match routes |
| 5 | Integration | End-to-end wiring |
| 6 | Compliance | Audit, encryption, access control |

### How It Works

1. Discovers API endpoints from `11-api-to-sp-map.md` or `[Http*]` attributes in `.cs` files
2. Discovers stored procedures from `.sql` files matching `CREATE PROC`
3. Discovers tables from `.sql` files matching `CREATE TABLE`
4. Discovers seed data from `.sql` files matching `INSERT INTO` or `MERGE`
5. Cross-references the chain: API -> SP -> Tables -> Seed data
6. Writes `.gsd/assessment/db-completeness.json`
7. Fails if coverage < 90% (configurable)

## 11.4 Security Compliance

Zero-token-cost regex scan of all source files:

| Pattern | Severity | What It Catches |
|---------|----------|-----------------|
| String concatenation + SQL keywords | Critical | SQL injection |
| `dangerouslySetInnerHTML` without DOMPurify | Critical | XSS |
| `eval()` / `new Function()` | Critical | Code injection |
| `localStorage` with token/password/secret | Critical | Secrets in browser |
| Hardcoded connection strings | Critical | Exposed credentials |
| `BinaryFormatter` | Critical | Deserialization CVE |
| `[HttpPost]` without `[Authorize]` on class | High | Missing authentication |
| `CREATE TABLE` without `CreatedAt` | Medium | Missing audit columns |
| `console.log` with password/token/ssn | High | Sensitive data in logs |

Critical violations are hard failures (block pipeline). High violations are warnings. All findings are written to `.gsd/assessment/security-compliance.json`.

## 11.5 Security Standards Reference

The engine enforces 88+ security rules organized by layer:

### .NET 8 Backend (28 rules)

- Authentication: `[Authorize]` on all controllers, JWT validation, CORS configuration
- Data protection: Parameterized queries only, AES-256 for PHI, TLS 1.2+ enforced
- Security headers: HSTS, X-Content-Type-Options, X-Frame-Options, CSP
- Anti-CSRF: `[ValidateAntiForgeryToken]` on state-changing endpoints
- Deserialization: No BinaryFormatter, whitelist-based JSON converters
- SSRF: Validate and whitelist external URLs

### SQL Server (18 rules)

- Parameterized queries only (never string concatenation)
- No dynamic SQL (`EXEC()` or `sp_executesql` with user input)
- Row-level security where applicable
- Audit triggers on all tables with PHI
- Principle of least privilege for service accounts

### React 18 (16 rules)

- No `dangerouslySetInnerHTML` (use DOMPurify if unavoidable)
- No `eval()` or `new Function()`
- HTTPS only for all API calls
- No secrets in localStorage (use httpOnly cookies)
- CSP meta tags, input sanitization, XSS-safe rendering

### Compliance (26 rules)

- **HIPAA**: Encrypt PHI at rest (TDE) and in transit (TLS), audit log all PHI access, 6-year retention
- **SOC 2**: Role-based access control, change management trails, monitoring
- **PCI**: Tokenize card data, never store raw card numbers, network isolation
- **GDPR**: Consent tracking, data export endpoint, data deletion endpoint

## 11.6 Coding Conventions

Enforced via agent prompts:

### .NET Conventions

- PascalCase for classes and methods
- camelCase for parameters and local variables
- _camelCase for private fields
- Allman brace style (opening brace on new line)
- SOLID principles enforced
- One class per file

### React Conventions

- Functional components with hooks only
- One component per file
- Hooks at the top of the component
- Props interface defined above component
- Named exports (not default)

### SQL Conventions

- PascalCase singular table names (e.g., `Patient`, not `patients`)
- `usp_Entity_Action` naming for stored procedures (e.g., `usp_Patient_GetById`)
- SET NOCOUNT ON in all procedures
- TRY/CATCH with THROW for error handling
- Explicit column lists (never `SELECT *`)

---

# Chapter 12: LLM Models and Capabilities

## 12.1 Supported Models

The GSD Engine supports 7 AI agents across two types:

| Agent | Provider | Type | Input $/M | Output $/M | Context | Primary Role |
|-------|----------|------|-----------|------------|---------|-------------|
| Claude | Anthropic | CLI | $3.00 | $15.00 | 200K | Reasoning (review, plan, synthesis) |
| Codex | OpenAI | CLI | $1.50 | $6.00 | 200K | Code generation (execute, build) |
| Gemini | Google | CLI | $1.25 | $10.00 | 1M | Research (read-only plan mode) |
| Kimi K2.5 | Moonshot AI | REST | $0.60 | $2.50 | 128K | Council review, rotation fallback |
| DeepSeek V3 | DeepSeek | REST | $0.28 | $0.42 | 64K | Council review, rotation fallback |
| GLM-5 | Zhipu AI | REST | $1.00 | $3.20 | 128K | Council review, rotation fallback |
| MiniMax M2.5 | MiniMax | REST | $0.29 | $1.20 | 200K | Council review, rotation fallback |

## 12.2 Model Strengths, Weaknesses, and Pipeline Roles

Understanding each model's capabilities is essential for knowing why the engine assigns specific agents to specific phases. The GSD engine is designed to exploit each model's strengths while avoiding their weaknesses.

### Claude (Anthropic) — The Judge

| Attribute | Detail |
|-----------|--------|
| **Strengths** | Best-in-class reasoning, nuanced judgment, accurate scoring, strong architecture understanding, excellent at synthesizing multiple perspectives, handles complex multi-step analysis |
| **Weaknesses** | Most expensive ($3.00/$15.00 per M), can be slower on large code generation tasks, quota limits can be reached quickly during heavy use |
| **Pipeline Role** | Code review (scoring health), plan (prioritization), council synthesis (consensus verdict), supervisor diagnosis (root-cause analysis) |
| **Fallback Behavior** | Last resort for all other agents — if any agent fails, Claude handles the phase |
| **Best For** | Tasks requiring judgment, scoring, analysis, and decision-making where accuracy matters more than speed |

### Codex (OpenAI) — The Builder

| Attribute | Detail |
|-----------|--------|
| **Strengths** | Fast code generation, optimized for execution tasks, good at following structured instructions, `--full-auto` mode for autonomous operation, handles large batch sizes efficiently |
| **Weaknesses** | Limited reasoning compared to Claude, loop detection can trigger early exit on complex tasks, may need batch size reduction for complex changes |
| **Pipeline Role** | Execute phase (bulk code generation), build phase (blueprint pipeline), council reviewer, parallel sub-task execution |
| **Fallback Behavior** | Falls back to Claude when exit code != 0 or loop detection triggers |
| **Best For** | High-volume code generation, file creation, and structured modifications where speed matters |

### Gemini (Google) — The Researcher

| Attribute | Detail |
|-----------|--------|
| **Strengths** | Excellent in plan mode (read-only analysis), largest context window (1M tokens), strong at research and pattern analysis, saves Claude/Codex quota for judgment and execution |
| **Weaknesses** | OAuth tokens can expire mid-run requiring re-authentication, optional (engine works without it), 403 errors sometimes misclassified as auth failures (engine handles this) |
| **Pipeline Role** | Research phase (read-only plan mode analysis), spec conflict resolution (`--yolo` mode), council reviewer |
| **Fallback Behavior** | Falls back to Codex. Engine continues without Gemini if not installed. |
| **Best For** | Deep codebase analysis, spec understanding, and research where the large context window allows processing entire project state |

### Kimi K2.5 (Moonshot AI) — The Multilingual Reviewer

| Attribute | Detail |
|-----------|--------|
| **Strengths** | Good multilingual support, 128K context window, reliable for review tasks, cost-effective ($0.60/$2.50 per M), international endpoint via Cloudflare CDN |
| **Weaknesses** | May timeout on very large prompts, requires API key from international platform (platform.moonshot.ai), less tested on complex architectural decisions |
| **Pipeline Role** | Council reviewer, rotation fallback pool member |
| **Fallback Behavior** | Routes to next available agent on failure; falls back to Claude for read-only phases |
| **Best For** | Independent code review with a different perspective, diversifying the council review pool |

### DeepSeek V3 (DeepSeek) — The Budget Option

| Attribute | Detail |
|-----------|--------|
| **Strengths** | Cheapest option at $0.28/$0.42 per M tokens (5-35x cheaper than CLI agents), good code comprehension, strong at structured review tasks |
| **Weaknesses** | Rate limits can be aggressive, 64K context window is smallest of all agents, may struggle with very large codebases in a single review |
| **Pipeline Role** | Council reviewer, rotation fallback pool member, cost optimization for review-heavy pipelines |
| **Fallback Behavior** | Routes to next available agent on rate limit; falls back to Claude for read-only phases |
| **Best For** | Council reviews where cost is a priority, projects with many iterations where review costs accumulate |

### GLM-5 (Zhipu AI) — The Generalist

| Attribute | Detail |
|-----------|--------|
| **Strengths** | Good general reasoning, 128K context window, balanced code analysis capabilities, reliable for structured tasks |
| **Weaknesses** | Mid-range pricing ($1.00/$3.20 per M), international endpoint (api.z.ai) may require firewall whitelist (IPs: 128.14.69.x), less specialized than Claude for judgment or Codex for generation |
| **Pipeline Role** | Council reviewer, rotation fallback pool member |
| **Fallback Behavior** | Routes to next available agent on failure; falls back to Claude for read-only phases |
| **Best For** | Expanding the council pool with another perspective, fallback when preferred agents are quota-exhausted |

### MiniMax M2.5 (MiniMax) — The Balanced Reviewer

| Attribute | Detail |
|-----------|--------|
| **Strengths** | Balanced price/performance ($0.29/$1.20 per M), 200K context window (largest among REST agents), reliable council reviews |
| **Weaknesses** | Less battle-tested than Claude/Codex, fewer edge-case handling capabilities |
| **Pipeline Role** | Council reviewer, rotation fallback pool member |
| **Fallback Behavior** | Routes to next available agent on failure; falls back to Claude for read-only phases |
| **Best For** | Council reviews needing large context, cost-effective alternative when multiple reviews needed |

### How Models Work Together in the Pipeline

The 7-agent architecture is designed so that each model handles the work it does best:

```
 Code Review (Claude)     ← Judgment: score health, identify issues
       ↓
 Research (Gemini)         ← Analysis: read-only codebase scan (1M context)
       ↓
 Council Review            ← Multi-perspective: 2-5 independent agents review
   (Codex + Gemini +         findings, Claude synthesizes consensus
    REST agents)
       ↓
 Plan (Claude)             ← Prioritization: decide what to fix next
       ↓
 Execute (Codex)           ← Generation: write code at high speed
       ↓                      Parallel: round-robin across agent pool
 Validation                ← Quality: build, test, security, DB checks
```

**Cost optimization strategy**: Claude handles ~3K tokens per iteration (judgment). Codex handles ~70K tokens (generation). Gemini handles ~23K tokens (research). REST agents handle ~4K tokens each (council reviews at 5-35x lower cost). This assignment minimizes total cost while maximizing quality.

### Phase-to-Agent Assignment Table

| Phase | Primary Agent | Why | Fallback |
|-------|--------------|-----|----------|
| Code Review | Claude | Best judgment for scoring health | -- |
| Research | Gemini | Excellent in read-only plan mode | Codex |
| Plan | Claude | Best prioritization reasoning | -- |
| Execute | Codex | Fastest code generation | Claude |
| Council Review | Codex + Gemini + REST | Independent multi-perspective review | Next available |
| Council Synthesis | Claude | Best consensus reasoning | -- |
| Supervisor Diagnosis | Claude | Best root-cause analysis | Next available (cooldown-aware) |
| Spec Resolution | Gemini | Read-only conflict analysis | Codex |

## 12.3 Model Configuration

All agents are configured in `model-registry.json`:

```json
{
  "agents": {
    "kimi": {
      "type": "openai-compat",
      "endpoint": "https://api.moonshot.ai/v1/chat/completions",
      "api_key_env": "KIMI_API_KEY",
      "model_id": "kimi-k2.5",
      "enabled": true,
      "pricing": { "input_per_m": 0.60, "output_per_m": 2.50 }
    }
  },
  "rotation_pool_default": ["claude", "codex", "gemini", "kimi", "deepseek", "glm5", "minimax"]
}
```

**To add a new REST agent:** Add an entry to `agents` with type `openai-compat`, set the API key environment variable, add to `rotation_pool_default`.

**To disable an agent:** Set `"enabled": false` in model-registry.json, remove from `rotation_pool_default`, and remove from `council.reviewers` in agent-map.json. You can optionally add `"disabled_reason"` to document why.

> **Note:** Kimi uses the international endpoint (`api.moonshot.ai`, Cloudflare CDN). Get your API key from [platform.moonshot.ai](https://platform.moonshot.ai). GLM-5 uses the international endpoint (`api.z.ai`, ZenLayer CDN). Get your API key and subscription from [z.ai](https://z.ai). Both endpoints require API keys from their respective international platforms — keys from the Chinese platforms (.cn) will not work.

## 12.4 Model Cost Comparison

### Per-Iteration Cost by Agent (Convergence Pipeline)

| Phase | Agent | Input Tokens | Output Tokens | Cost (Sonnet) |
|-------|-------|-------------|---------------|--------------|
| Code Review | Claude | ~2,000 | ~1,000 | $0.02 |
| Research | Gemini | ~3,000 | ~20,000 | $0.20 |
| Plan | Claude | ~1,500 | ~500 | $0.01 |
| Execute | Codex | ~5,000 | ~65,000 | $0.40 |
| **Total** | | | | **~$0.63** |

### Council Review Cost Per Agent

| Agent | Input ~2K / Output ~2K | Cost |
|-------|----------------------|------|
| Claude | 2K in + 2K out | $0.036 |
| Codex | 2K in + 2K out | $0.015 |
| Gemini | 2K in + 2K out | $0.023 |
| DeepSeek | 2K in + 2K out | $0.001 |
| Kimi | 2K in + 2K out | $0.006 |
| MiniMax | 2K in + 2K out | $0.003 |

Using REST agents for council reviews is 5-35x cheaper than CLI agents.

## 12.5 Error Handling by Agent Type

### CLI Agents (claude, codex, gemini)

CLI agents run in isolated child processes. Errors are detected from exit codes and stdout patterns:
- Exit code 0 = success
- Exit code != 0 = failure (diagnosed by Get-FailureDiagnosis)
- Stdout patterns: "sandbox.*restrict", "loop.*detect", "max.*turns"

### REST Agents (kimi, deepseek, glm5, minimax)

REST agents are invoked via `Invoke-OpenAICompatibleAgent`. HTTP errors are mapped to GSD taxonomy:

| HTTP Status | GSD Category | Engine Action |
|-------------|-------------|---------------|
| 200 | success | Process response |
| 401 | unauthorized | Fail (check API key) |
| 402 | quota_exhausted | Wait + rotate |
| 429 | rate_limit | Backoff + rotate |
| 500-504 | server_error | Retry |
| Timeout | timeout | Retry with reduced batch |

Both agent types use the same retry/fallback/rotation infrastructure.

## 12.6 Model-Specific Operational Notes

### CLI Agent Notes

- **Claude**: Always the last-resort fallback. Never disable Claude — the engine requires it for synthesis and judgment phases. If Claude hits quota, the engine waits (exponential backoff) rather than substituting.
- **Codex**: Must run with `--full-auto` mode for autonomous operation. If Codex triggers loop detection (exit code 2), the engine reduces batch size by 50% and retries. Monitor for loop detection in projects with circular dependencies.
- **Gemini**: Requires `--approval-mode plan` for read-only research. Re-authenticate via browser (`gemini auth`) if OAuth expires mid-run. The engine automatically falls back to Codex if Gemini is unavailable.

### REST Agent Notes

- **All REST agents**: API keys are optional and warn-only. If an API key is missing, that agent is excluded from the rotation pool automatically. No engine restart needed. TLS 1.2+ is enforced on all REST calls.
- **Kimi K2.5**: Uses international endpoint (`api.moonshot.ai`, Cloudflare CDN) for global accessibility. Requires API key from [platform.moonshot.ai](https://platform.moonshot.ai). Note: keys from the China platform (`platform.moonshot.cn`) may not work on the international endpoint.
- **DeepSeek V3**: Aggressive rate limits — the engine rotates away after 1 consecutive failure. Best value for high-volume review tasks. Requires active billing credits (HTTP 402 if depleted).
- **GLM-5**: Uses international endpoint (`api.z.ai`, ZenLayer CDN). Requires API key and subscription from [z.ai](https://z.ai). May require firewall whitelist for IPs 128.14.69.x on corporate networks.
- **MiniMax M2.5**: Largest context window among REST agents (200K). Good for reviewing large requirement batches in council chunked reviews.

### Connection Failure Detection

REST agents that return `connection_failed:` errors (unreachable endpoints, DNS resolution failures, connection refused) trigger **immediate rotation** — no retries, no diagnosis overhead. The failed agent is placed on a 60-minute cooldown. This prevents the engine from wasting attempts on endpoints that will never respond.

Error patterns detected: `Unable to connect`, `No such host`, `ConnectFailure`, `connection refused`, `actively refused`, `unreachable`, `SocketException`, `NameResolutionFailure`, `timed out`.

Disabled agents (those with `"enabled": false` in model-registry.json) return `connection_failed:` immediately without making any HTTP calls.

### Rotation and Failover

The engine uses a 7-agent rotation pool defined in `model-registry.json`. When any agent fails:
1. `Get-FailureDiagnosis` classifies the error (rate_limit, quota_exhausted, unauthorized, timeout, server_error, connection_failed)
2. For connection_failed: immediate rotation with 60-minute cooldown (no retries)
3. For rate_limit/quota: `Set-AgentCooldown` places the agent on 30-minute cooldown
4. `Get-NextAvailableAgent` selects the next agent not on cooldown (skips disabled agents)
5. For read-only phases (research, review, verify, plan, council): falls back to Claude
6. For execution phases: retries with reduced batch

The rotation threshold is **1 consecutive failure** (reduced from 3 by the multi-model patch) for immediate failover across all 7 agents.

---

# Chapter 13: Coding Standards & Methodologies

The GSD engine enforces coding standards through agent prompts and council reviews. These standards are defined in `%USERPROFILE%\.gsd-global\prompts\shared\coding-conventions.md` and are checked by council reviewers at every review gate. Violations are flagged and the engine iterates until code conforms.

This chapter documents the coding methodologies enforced by the GSD Engine across all pipelines. These standards are not optional -- they are injected into every agent prompt and validated by quality gates. Code that violates these patterns is flagged during review and blocked at final validation.

## 13.1 Spec-Driven Development

The GSD Engine follows a strict specification-driven development model. Code is generated from specifications, never the other way around. The flow is:

1. **Design**: Build the frontend prototype in Figma Make
2. **Analyze**: Figma Make generates 12 analysis deliverables + backend/database stubs
3. **Assess**: `gsd-assess` reads all specs and creates work classification
4. **Build**: `gsd-blueprint` or `gsd-converge` generates code to match specs
5. **Verify**: Claude verifies every requirement against actual code, traces data paths end-to-end

Specifications are the single source of truth. If the code doesn't match the spec, the code is wrong -- not the spec. The engine never modifies specifications to match existing code (unless explicitly running the spec-fix phase with Gemini for contradiction resolution).

## 13.2 Contract-First, API-First Development

Every API endpoint is defined in the specification documents before any code is generated. The contract is established through the 12 Figma Make analysis deliverables:

| Deliverable | Defines |
|---|---|
| `06-api-contracts.md` | Every HTTP endpoint with request/response shapes |
| `11-api-to-sp-map.md` | End-to-end traceability: Frontend Hook -> API Route -> Controller -> Stored Procedure -> Tables |
| `05-data-types.md` | TypeScript interfaces that become C# DTOs |

The API contract flows through every layer:

```
Frontend Hook  ->  API Route  ->  Controller  ->  Service  ->  Repository  ->  Stored Procedure  ->  Tables
   (React)        (HTTP)        (.NET 8)      (.NET 8)     (.NET 8)        (SQL Server)         (SQL Server)
```

Every layer must match. The engine validates this chain during database completeness checks and storyboard verification. An endpoint that exists in the controller but has no matching stored procedure is a hard failure.

## 13.3 Backend Coding Standards (.NET 8)

The GSD Engine enforces .NET 8 with Dapper as the backend framework. Entity Framework is explicitly prohibited -- all database access goes through stored procedures via Dapper.

### Project Structure

```
src/
  MyApp.Api/
    Controllers/          # API controllers (one per entity group)
    Program.cs            # Host configuration, DI, middleware
  MyApp.Core/
    DTOs/                 # Data transfer objects (request + response)
    Interfaces/           # Service and repository interfaces
    Services/             # Business logic services
  MyApp.Infrastructure/
    Repositories/         # Dapper-based repository implementations
    DependencyInjection.cs
```

### Controller Patterns

Every controller follows this pattern:

```csharp
[ApiController]
[Route("api/tenants/{tenantId}/[controller]")]
[Authorize]
public class EntityController : ControllerBase
{
    private readonly IEntityService _service;

    public EntityController(IEntityService service)
    {
        _service = service;
    }

    /// <summary>Get all entities for tenant</summary>
    [HttpGet]
    public async Task<ActionResult<List<EntityDto>>> GetAll(
        [FromRoute] string tenantId)
    {
        var result = await _service.GetAllAsync(tenantId);
        return Ok(result);
    }

    /// <summary>Create a new entity</summary>
    [HttpPost]
    public async Task<ActionResult<EntityDto>> Create(
        [FromRoute] string tenantId,
        [FromBody] CreateEntityRequest request)
    {
        var result = await _service.CreateAsync(tenantId, request);
        return CreatedAtAction(nameof(GetById), new { tenantId, id = result.Id }, result);
    }
}
```

Key rules:
- Every controller must have `[ApiController]` and `[Authorize]` attributes
- Route pattern: `api/tenants/{tenantId}/[controller]` for tenant-scoped resources
- Use `[FromRoute]`, `[FromBody]`, `[FromQuery]` parameter annotations explicitly
- Async/await throughout -- no synchronous database calls
- Return appropriate HTTP status codes (200, 201, 400, 404)
- XML doc comments on every action method

### DTO Patterns

```csharp
public class EntityDto
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = string.Empty;

    [JsonPropertyName("name")]
    [Required]
    [StringLength(200)]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("createdAt")]
    public DateTime CreatedAt { get; set; }

    [JsonPropertyName("modifiedAt")]
    public DateTime ModifiedAt { get; set; }
}
```

Key rules:
- Property names in PascalCase (C# convention) with `[JsonPropertyName("camelCase")]` for serialization
- Data annotations for validation: `[Required]`, `[StringLength]`, `[Range]`, `[EmailAddress]`
- Separate request DTOs (CreateEntityRequest, UpdateEntityRequest) from response DTOs (EntityDto)
- Default values on string properties (`= string.Empty`) to avoid null reference issues

### Repository Pattern (Dapper)

```csharp
public class EntityRepository : IEntityRepository
{
    private readonly IDbConnection _connection;

    public EntityRepository(IDbConnection connection)
    {
        _connection = connection;
    }

    public async Task<IEnumerable<EntityDto>> GetAllAsync(string tenantId)
    {
        return await _connection.QueryAsync<EntityDto>(
            "usp_Entity_GetAll",
            new { TenantId = tenantId },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<int> CreateAsync(string tenantId, CreateEntityRequest request)
    {
        var parameters = new DynamicParameters();
        parameters.Add("TenantId", tenantId);
        parameters.Add("Name", request.Name);
        parameters.Add("NewId", dbType: DbType.Int32, direction: ParameterDirection.Output);

        await _connection.ExecuteAsync(
            "usp_Entity_Create",
            parameters,
            commandType: CommandType.StoredProcedure);

        return parameters.Get<int>("NewId");
    }
}
```

Key rules:
- Every repository method calls exactly one stored procedure via Dapper
- Always use `CommandType.StoredProcedure` -- never inline SQL
- Use `DynamicParameters` for output parameters
- No string concatenation in any query -- all parameters are passed as objects

## 13.4 SP-Only Pattern

The SP-Only pattern is the most important architectural constraint enforced by the GSD Engine. Every API endpoint maps to exactly one stored procedure. No exceptions.

| Layer | Calls | Via |
|---|---|---|
| Controller | Service | Dependency injection |
| Service | Repository | Dependency injection |
| Repository | Stored Procedure | Dapper `CommandType.StoredProcedure` |

What is **prohibited**:
- Inline SQL in any C# file
- Entity Framework DbContext or LINQ-to-SQL
- Raw ADO.NET queries
- String concatenation to build SQL
- Multiple database calls per API endpoint (use a single SP with JOINs or temp tables)

What is **required**:
- One SP per endpoint (CRUD operations: GetAll, GetById, Create, Update, Delete)
- Complex operations use a single SP with transactions
- Stored procedures handle all business logic that touches data
- The C# service layer handles orchestration and validation only

## 13.5 Frontend Coding Standards (React 18)

The GSD Engine enforces React 18 with functional components and hooks. Class components are prohibited.

### Component Patterns

```tsx
interface EntityListProps {
  tenantId: string;
  onEntitySelect: (entity: EntityDto) => void;
}

export const EntityList: React.FC<EntityListProps> = ({ tenantId, onEntitySelect }) => {
  const { data, isLoading, error } = useEntities(tenantId);

  if (isLoading) return <LoadingSkeleton />;
  if (error) return <ErrorCard message={error.message} onRetry={() => {}} />;
  if (!data?.length) return <EmptyState message="No entities found" />;

  return (
    <div className="entity-list">
      {data.map((entity) => (
        <EntityCard
          key={entity.id}
          entity={entity}
          onClick={() => onEntitySelect(entity)}
        />
      ))}
    </div>
  );
};
```

Key rules:
- Functional components only with TypeScript interfaces for props
- Custom hooks for all data fetching and state management
- Handle all states: loading, error, empty, and populated
- Use `key` prop on all list items
- Destructure props in the function signature

### Hook Patterns

```tsx
export function useEntities(tenantId: string) {
  const [data, setData] = useState<EntityDto[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    const fetchData = async () => {
      try {
        setIsLoading(true);
        const response = await apiClient.get(`/api/tenants/${tenantId}/entities`);
        setData(response.data);
      } catch (err) {
        setError(err instanceof Error ? err : new Error('Unknown error'));
      } finally {
        setIsLoading(false);
      }
    };
    fetchData();
  }, [tenantId]);

  return { data, isLoading, error };
}
```

Key rules:
- One hook per entity or feature area
- Return `{ data, isLoading, error }` consistently
- Handle errors with try/catch -- never let unhandled promises propagate
- Include dependency arrays on all useEffect calls

## 13.6 Blueprint Tier Structure

When the GSD Engine generates code via the blueprint pipeline, it follows a strict tier ordering. Each tier depends on the previous tier being complete. This ensures that database tables exist before stored procedures reference them, and stored procedures exist before controllers call them.

| Tier | Name | Contents | Depends On |
|---|---|---|---|
| 1 | Database Foundation | Tables, migrations, indexes, constraints, foreign keys | Nothing |
| 1.5 | Database Functions & Views | Views for complex reads, scalar/table-valued functions | Tier 1 |
| 2 | Stored Procedures | All CRUD + business logic SPs | Tier 1, 1.5 |
| 2.5 | Seed Data | INSERT scripts per table group, FK-consistent, matching Figma mock data | Tier 1, 2 |
| 3 | API Layer | .NET 8 controllers, services, repositories, DTOs, validators | Tier 2 |
| 4 | Frontend Components | React 18 components matching Figma exactly | Tier 3 |
| 5 | Integration & Config | Routing, auth flows, middleware, DI, config files | Tier 3, 4 |
| 6 | Compliance & Polish | Audit logging, encryption, RBAC, error boundaries, accessibility | Tier 5 |

The blueprint manifest (`blueprint.json`) assigns each item to a tier, and the build phase processes tiers in order. Items within the same tier can be built in parallel.

## 13.7 Figma Make Integration (12 Deliverables)

The Figma Make prompt generates 12 analysis deliverables that serve as the complete specification for the AI coding agents. These are the "contract" between design and code.

| # | File | What It Defines | Engine Uses It For |
|---|---|---|---|
| 01 | `screen-inventory.md` | All screens with layout, data, interactions | Blueprint item generation |
| 02 | `component-inventory.md` | Reusable components with props, states, variants | Component-level work items |
| 03 | `design-system.md` | Colors, typography, spacing, tokens | Design token validation |
| 04 | `navigation-routing.md` | Routes, navigation tree, deep linking | Route scaffolding |
| 05 | `data-types.md` | TypeScript interfaces for all entities | Type generation, DTO mapping |
| 06 | `api-contracts.md` | Every API endpoint with request/response shapes | Controller scaffolding |
| 07 | `hooks-state.md` | React hooks with return shapes, API calls | Hook generation |
| 08 | `mock-data-catalog.md` | All mock data with exact values | Seed data validation |
| 09 | `storyboards.md` | User flows with step-by-step actions | Storyboard-aware verification |
| 10 | `screen-state-matrix.md` | Loading/error/empty states per screen | State coverage verification |
| 11 | `api-to-sp-map.md` | Frontend -> API -> SP -> Table traceability | End-to-end chain verification |
| 12 | `implementation-guide.md` | Build order, architecture decisions | Build ordering |

Additionally, the Figma Make prompt generates backend and database stubs:

| Stub | Location | Content |
|---|---|---|
| Controllers | `_stubs/backend/Controllers/*.cs` | .NET 8 controller stubs with method signatures |
| DTOs | `_stubs/backend/Models/*.cs` | C# DTO classes matching TypeScript types |
| Tables | `_stubs/database/01-tables.sql` | SQL Server CREATE TABLE statements |
| Stored Procedures | `_stubs/database/02-stored-procedures.sql` | SP stubs with TRY/CATCH skeleton |
| Seed Data | `_stubs/database/03-seed-data.sql` | INSERT statements matching mock data exactly |

All 12 analysis files must be present. The engine validates by exact filename and reports `_analysis/ (12/12 deliverables)` during assessment.

---

---

## 13.8 .NET 8 / C# Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Classes, structs, enums | PascalCase | `UserService`, `OrderStatus` |
| Interfaces | I + PascalCase | `IUserRepository`, `IAuthService` |
| Methods, properties | PascalCase | `GetUserById()`, `IsActive` |
| Parameters, locals | camelCase | `userId`, `orderTotal` |
| Private fields | _camelCase | `_userRepository`, `_logger` |
| Constants | PascalCase | `MaxLoginAttempts`, `DefaultPageSize` |
| DTOs | PascalCase + Dto suffix | `UserResponseDto`, `CreateOrderRequestDto` |

## 13.9 .NET Formatting Standards

- **Indentation**: 4 spaces (never tabs)
- **Max line length**: 120 characters
- **Braces**: Allman style (opening brace on new line)
- **Spacing**: One blank line between methods, two between classes
- **Usings**: `using` directives outside namespace declarations
- **Strings**: String interpolation `$"{name}"` over concatenation
- **Null handling**: Null-conditional (`?.`) and null-coalescing (`??`) operators preferred

## 13.10 .NET Architecture Patterns

All .NET projects follow a layered architecture enforced by the engine:

```
Controller (thin, returns IActionResult)
    ↓
Service (IUserService → UserService, business logic)
    ↓
Repository (IUserRepository → UserRepository, Dapper + SPs)
    ↓
Stored Procedure (SQL Server)
```

**Rules**:
- **Repository pattern**: `IUserRepository` → `UserRepository` using Dapper with stored procedures (never Entity Framework)
- **Service layer**: `IUserService` → `UserService` containing all business logic
- **Controllers**: Thin — delegate to services, return `IActionResult`, no business logic
- **DTOs**: Separate request/response models — never expose database entities
- **Dependency injection**: Constructor injection for all services, registered in `Program.cs`
- **One class per file**: Filename must match class name exactly

## 13.11 .NET Error Handling

- Catch **specific** exceptions — never bare `catch (Exception)`
- Use `using` statements or `using` declarations for `IDisposable` resources
- `async/await` for all I/O-bound operations
- `ILogger<T>` with structured logging (Serilog pattern)
- Log levels used appropriately: Error, Warning, Information, Debug
- `.ConfigureAwait(false)` in library code

## 13.12 SOLID Principles

The engine enforces SOLID principles in all generated code:

| Principle | Rule | Enforcement |
|-----------|------|-------------|
| **Single Responsibility** | One class = one reason to change | Council review checks class scope |
| **Open/Closed** | Extend via interfaces, not modification | Interface-first architecture |
| **Liskov Substitution** | Derived types substitutable for base | Repository/service pattern |
| **Interface Segregation** | Small, focused interfaces | Separate I*Repository per entity |
| **Dependency Inversion** | Depend on abstractions, not concrete types | Constructor injection everywhere |

## 13.13 React 18 Conventions

### Component Structure Rules
- **Functional components** with hooks ONLY (no class components)
- One component per file, **named export**
- Props interface defined **above** the component
- Hooks at the **top** of component body
- Event handlers named `handleXxx` (e.g., `handleSubmit`)

### React Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Components | PascalCase | `UserProfile`, `OrderList` |
| Files | PascalCase.tsx | `UserProfile.tsx` |
| Hooks | use + PascalCase | `useAuth()`, `useOrders()` |
| Props interfaces | ComponentName + Props | `UserProfileProps` |
| CSS modules | camelCase | `styles.headerContainer` |
| Constants | UPPER_SNAKE_CASE | `MAX_RETRIES`, `API_BASE_URL` |

### React Patterns
- Error boundaries at route level
- Loading states / skeleton screens for all async operations
- Input validation before API submission
- Environment variables for API endpoints
- Responsive design matching Figma breakpoints exactly
- Accessibility: ARIA labels, keyboard navigation, focus management

## 13.14 SQL Server Conventions

### SQL Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Tables | PascalCase, singular | `User`, `OrderItem` |
| Columns | PascalCase | `FirstName`, `CreatedAt` |
| Stored procedures | usp_Entity_Action | `usp_User_GetById`, `usp_Order_Create` |
| Views | vw_Description | `vw_ActiveUsers`, `vw_OrderSummary` |
| Functions | fn_Description | `fn_CalculateTotal`, `fn_FormatDate` |
| Indexes | IX_Table_Column(s) | `IX_User_Email`, `IX_Order_UserId` |
| Primary keys | PK_Table | `PK_User`, `PK_Order` |
| Foreign keys | FK_Child_Parent | `FK_OrderItem_Order` |

### SQL Structure Rules
- `SET NOCOUNT ON` at top of every SP
- `BEGIN TRY / END TRY / BEGIN CATCH / THROW / END CATCH` in all SPs
- Audit columns on every table: `CreatedAt`, `CreatedBy`, `ModifiedAt`, `ModifiedBy`
- Explicit column lists (never `SELECT *`)
- `IF EXISTS` for idempotent migrations
- `GRANT EXECUTE ON [dbo].[usp_Entity_Action] TO [AppRole]`
- Comments for complex business logic within SPs
- Consistent parameter naming: `@EntityId`, `@UserId`, `@TenantId`

### Seed Data Rules
- `MERGE` or `IF NOT EXISTS` pattern for idempotency
- Foreign key references must be consistent (no orphan IDs)
- Realistic recent timestamps (not future dates)
- Group INSERTs by entity with comments
- Match Figma mock data exactly (same values, same IDs)

---

# Chapter 14: Database Coding Standards

The GSD engine enforces a complete data chain from API endpoint through to seed data. These standards are defined in `%USERPROFILE%\.gsd-global\prompts\shared\database-completeness-review.md` and validated by `Test-DatabaseCompleteness` at every quality gate checkpoint.

This chapter documents the SQL Server database coding standards enforced by the GSD Engine. All database access goes through stored procedures -- no ORM queries, no inline SQL.

## 14.1 Stored Procedure Naming Convention

All stored procedures follow the naming pattern:

```
usp_[Entity]_[Operation]
```

| Operation | Convention | Example |
|---|---|---|
| Get all | `usp_Entity_GetAll` | `usp_Project_GetAll` |
| Get by ID | `usp_Entity_GetById` | `usp_Project_GetById` |
| Create | `usp_Entity_Create` | `usp_Project_Create` |
| Update | `usp_Entity_Update` | `usp_Project_Update` |
| Delete | `usp_Entity_Delete` | `usp_Project_Delete` |
| Search/filter | `usp_Entity_Search` | `usp_Project_Search` |
| Bulk operations | `usp_Entity_BulkCreate` | `usp_Project_BulkCreate` |
| Custom business logic | `usp_Entity_[Action]` | `usp_Project_Archive` |

## 14.2 Stored Procedure Template

Every stored procedure must follow this template:

```sql
CREATE PROCEDURE usp_Entity_GetAll
    @TenantId NVARCHAR(50),
    @PageNumber INT = 1,
    @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT
            e.Id,
            e.Name,
            e.Status,
            e.CreatedAt,
            e.ModifiedAt
        FROM Entity e
        WHERE e.TenantId = @TenantId
          AND e.IsDeleted = 0
        ORDER BY e.CreatedAt DESC
        OFFSET (@PageNumber - 1) * @PageSize ROWS
        FETCH NEXT @PageSize ROWS ONLY;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
```

Key rules:
- `SET NOCOUNT ON` at the start of every SP
- `BEGIN TRY / BEGIN CATCH` wrapping all logic -- no exceptions
- `THROW` in the CATCH block to propagate errors
- All parameters are typed and use `@ParameterName` syntax
- No string concatenation anywhere -- all values are parameters
- `GO` statement after each SP to separate batches

## 14.3 Create (INSERT) Pattern

```sql
CREATE PROCEDURE usp_Entity_Create
    @TenantId NVARCHAR(50),
    @Name NVARCHAR(200),
    @Description NVARCHAR(MAX) = NULL,
    @CreatedBy NVARCHAR(100),
    @NewId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        INSERT INTO Entity (TenantId, Name, Description, CreatedBy, CreatedAt, ModifiedAt)
        VALUES (@TenantId, @Name, @Description, @CreatedBy, GETUTCDATE(), GETUTCDATE());

        SET @NewId = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
```

Key rules:
- Use `OUTPUT` parameter for identity returns on INSERT operations
- Use `SCOPE_IDENTITY()` -- never `@@IDENTITY`
- Always set `CreatedAt` and `ModifiedAt` to `GETUTCDATE()`
- Use `NVARCHAR` for all string columns (Unicode support)

## 14.4 Update Pattern

```sql
CREATE PROCEDURE usp_Entity_Update
    @Id INT,
    @TenantId NVARCHAR(50),
    @Name NVARCHAR(200),
    @Description NVARCHAR(MAX) = NULL,
    @ModifiedBy NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        UPDATE Entity
        SET Name = @Name,
            Description = @Description,
            ModifiedBy = @ModifiedBy,
            ModifiedAt = GETUTCDATE()
        WHERE Id = @Id
          AND TenantId = @TenantId;

        IF @@ROWCOUNT = 0
            THROW 50001, 'Entity not found or access denied.', 1;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
```

Key rules:
- Always include `TenantId` in the WHERE clause for tenant-scoped operations
- Check `@@ROWCOUNT` after UPDATE/DELETE to detect missing records
- Use custom error numbers (50001+) for business logic errors
- Always update `ModifiedAt` and `ModifiedBy` on UPDATE

## 14.5 Delete Pattern (Soft Delete)

```sql
CREATE PROCEDURE usp_Entity_Delete
    @Id INT,
    @TenantId NVARCHAR(50),
    @DeletedBy NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        UPDATE Entity
        SET IsDeleted = 1,
            DeletedBy = @DeletedBy,
            DeletedAt = GETUTCDATE(),
            ModifiedAt = GETUTCDATE()
        WHERE Id = @Id
          AND TenantId = @TenantId
          AND IsDeleted = 0;

        IF @@ROWCOUNT = 0
            THROW 50002, 'Entity not found or already deleted.', 1;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
```

Key rules:
- Use soft deletes (IsDeleted flag) -- never `DELETE FROM` in production
- All SELECT queries must include `AND IsDeleted = 0`
- Track `DeletedBy` and `DeletedAt` for audit trail

## 14.6 Table Design Standards

```sql
CREATE TABLE Entity (
    Id              INT IDENTITY(1,1) PRIMARY KEY,
    TenantId        NVARCHAR(50)    NOT NULL,
    Name            NVARCHAR(200)   NOT NULL,
    Description     NVARCHAR(MAX)   NULL,
    Status          NVARCHAR(50)    NOT NULL DEFAULT 'Active',
    IsDeleted       BIT             NOT NULL DEFAULT 0,
    CreatedBy       NVARCHAR(100)   NOT NULL,
    CreatedAt       DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
    ModifiedBy      NVARCHAR(100)   NULL,
    ModifiedAt      DATETIME2       NOT NULL DEFAULT GETUTCDATE(),
    DeletedBy       NVARCHAR(100)   NULL,
    DeletedAt       DATETIME2       NULL,

    CONSTRAINT FK_Entity_Tenant FOREIGN KEY (TenantId)
        REFERENCES Tenant(Id)
);

CREATE INDEX IX_Entity_TenantId ON Entity(TenantId);
CREATE INDEX IX_Entity_Status ON Entity(Status) WHERE IsDeleted = 0;
```

Required columns on every table:

| Column | Type | Purpose |
|---|---|---|
| CreatedAt | DATETIME2 | When the record was created (UTC) |
| CreatedBy | NVARCHAR(100) | Who created the record |
| ModifiedAt | DATETIME2 | Last modification timestamp (UTC) |
| ModifiedBy | NVARCHAR(100) | Who last modified the record |
| IsDeleted | BIT | Soft delete flag (default 0) |

Required columns on tenant-scoped tables:

| Column | Type | Purpose |
|---|---|---|
| TenantId | NVARCHAR(50) | Tenant isolation -- every query must filter by TenantId |

Index requirements:
- Index on every foreign key column
- Filtered index on frequently queried columns with `WHERE IsDeleted = 0`
- Composite index on `(TenantId, Status)` for common filter patterns

## 14.7 Seed Data Standards

Seed data must match the Figma mock data exactly. The engine uses the `MERGE` or `IF NOT EXISTS` pattern for idempotent execution:

```sql
-- Seed: Tenants
IF NOT EXISTS (SELECT 1 FROM Tenant WHERE Id = 'tenant-001')
BEGIN
    INSERT INTO Tenant (Id, Name, Status, CreatedBy, CreatedAt, ModifiedAt)
    VALUES ('tenant-001', 'Acme Corp', 'Active', 'SYSTEM', GETUTCDATE(), GETUTCDATE());
END

-- Seed: Users (depends on Tenant)
IF NOT EXISTS (SELECT 1 FROM [User] WHERE Id = 'user-001')
BEGIN
    INSERT INTO [User] (Id, TenantId, Email, DisplayName, Role, CreatedBy, CreatedAt, ModifiedAt)
    VALUES ('user-001', 'tenant-001', 'admin@acme.com', 'Admin User', 'Admin', 'SYSTEM', GETUTCDATE(), GETUTCDATE());
END
```

Key rules:
- Insert order must respect foreign key constraints (Tenant before User, User before dependent entities)
- Use `IF NOT EXISTS` for idempotent execution -- safe to re-run
- IDs in seed data must match IDs used in mock data and between related tables
- Use realistic, recent timestamps
- Use `'SYSTEM'` as `CreatedBy` for seed data

## 14.8 SQL Validation Rules

The GSD Engine runs regex-based SQL validation on every iteration. These patterns are hard failures:

| Pattern | Detection | Why |
|---|---|---|
| String concatenation + SQL keywords | `'+.*SELECT`, `'+.*INSERT`, `'+.*UPDATE`, `'+.*DELETE`, `'+.*EXEC` | SQL injection vulnerability |
| Missing TRY/CATCH | SP body without `BEGIN TRY` | Unhandled errors crash the application |
| Missing audit columns | `CREATE TABLE` without `CreatedAt` | Compliance requirement (HIPAA, SOC 2) |
| No `SET NOCOUNT ON` | SP body without `SET NOCOUNT ON` | Performance issue (extra result sets) |

These violations are detected by `Test-SqlFiles` in resilience.ps1 and reported in the code review. Critical violations block convergence.

---

---

## 14.9 Required Data Chain

Every data path must be complete end-to-end before the project is done:

```
API Endpoint → Controller Method → Repository/Service → Stored Procedure
    → Functions/Views (if complex) → Tables → Seed Data
```

Every link in this chain must exist. Missing links = incomplete project. The engine's `Test-DatabaseCompleteness` function validates this chain statically at zero token cost.

## 14.10 Enhanced Blueprint Tier Structure

The blueprint pipeline generates code in tiers to ensure dependencies are built before dependents:

| Tier | Name | Contents |
|------|------|----------|
| 1 | Database Foundation | Tables, migrations, indexes, constraints |
| 1.5 | Database Functions & Views | Views for complex reads, scalar/table-valued functions |
| 2 | Stored Procedures | All CRUD + business logic SPs |
| 2.5 | Seed Data | INSERT scripts per table group, FK-consistent, matching Figma mock data |
| 3 | API Layer | .NET 8 controllers, services, repositories, DTOs, validators |
| 4 | Frontend Components | React 18 components matching Figma exactly |
| 5 | Integration & Config | Routing, auth flows, middleware, DI, config files |
| 6 | Compliance & Polish | Audit logging, encryption, RBAC, error boundaries, accessibility |

## 14.11 Stored Procedure Patterns

### Naming Convention
```
usp_Entity_Action
    usp_User_GetById
    usp_User_GetAll
    usp_User_Create
    usp_User_Update
    usp_User_Delete
    usp_User_Search
```

### Create (INSERT) Pattern
```sql
CREATE PROCEDURE [dbo].[usp_User_Create]
    @FirstName NVARCHAR(100),
    @LastName NVARCHAR(100),
    @Email NVARCHAR(255),
    @CreatedBy NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        INSERT INTO [dbo].[User] (FirstName, LastName, Email, CreatedAt, CreatedBy, ModifiedAt, ModifiedBy)
        VALUES (@FirstName, @LastName, @Email, GETUTCDATE(), @CreatedBy, GETUTCDATE(), @CreatedBy);

        SELECT SCOPE_IDENTITY() AS UserId;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
GRANT EXECUTE ON [dbo].[usp_User_Create] TO [AppRole];
GO
```

### Read (SELECT) Pattern
```sql
CREATE PROCEDURE [dbo].[usp_User_GetById]
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT UserId, FirstName, LastName, Email, CreatedAt, ModifiedAt
        FROM [dbo].[User]
        WHERE UserId = @UserId;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
```

### Update Pattern
```sql
CREATE PROCEDURE [dbo].[usp_User_Update]
    @UserId INT,
    @FirstName NVARCHAR(100),
    @LastName NVARCHAR(100),
    @Email NVARCHAR(255),
    @ModifiedBy NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        UPDATE [dbo].[User]
        SET FirstName = @FirstName,
            LastName = @LastName,
            Email = @Email,
            ModifiedAt = GETUTCDATE(),
            ModifiedBy = @ModifiedBy
        WHERE UserId = @UserId;

        SELECT @@ROWCOUNT AS RowsAffected;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
```

### Delete Pattern
```sql
CREATE PROCEDURE [dbo].[usp_User_Delete]
    @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DELETE FROM [dbo].[User]
        WHERE UserId = @UserId;

        SELECT @@ROWCOUNT AS RowsAffected;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
```

## 14.12 Migration Patterns

### Naming Convention
```
V001__CreateUserTables.sql
V002__CreateOrderTables.sql
V003__AddAuditTriggers.sql
V004__SeedData.sql
```

### Table Creation Pattern
```sql
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'User')
BEGIN
    CREATE TABLE [dbo].[User] (
        UserId INT IDENTITY(1,1) NOT NULL,
        FirstName NVARCHAR(100) NOT NULL,
        LastName NVARCHAR(100) NOT NULL,
        Email NVARCHAR(255) NOT NULL,
        IsActive BIT NOT NULL DEFAULT 1,
        CreatedAt DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        CreatedBy NVARCHAR(100) NOT NULL,
        ModifiedAt DATETIME2 NOT NULL DEFAULT GETUTCDATE(),
        ModifiedBy NVARCHAR(100) NOT NULL,
        CONSTRAINT PK_User PRIMARY KEY CLUSTERED (UserId),
        CONSTRAINT UQ_User_Email UNIQUE (Email)
    );

    CREATE NONCLUSTERED INDEX IX_User_Email ON [dbo].[User] (Email);
    CREATE NONCLUSTERED INDEX IX_User_IsActive ON [dbo].[User] (IsActive) INCLUDE (FirstName, LastName, Email);
END
GO
```

**Rules**:
- `IF NOT EXISTS` wrapping for idempotent execution
- `IDENTITY(1,1)` for auto-increment primary keys
- `DATETIME2` over `DATETIME` (higher precision)
- `GETUTCDATE()` for all timestamps (never `GETDATE()`)
- Audit columns on every table: `CreatedAt`, `CreatedBy`, `ModifiedAt`, `ModifiedBy`
- Named constraints: `PK_Table`, `FK_Child_Parent`, `UQ_Table_Column`
- Indexes on foreign keys and commonly queried columns

## 14.13 Seed Data Standards

### Idempotent Pattern
```sql
-- Users
IF NOT EXISTS (SELECT 1 FROM [dbo].[User] WHERE Email = 'john.smith@example.com')
BEGIN
    INSERT INTO [dbo].[User] (FirstName, LastName, Email, CreatedAt, CreatedBy, ModifiedAt, ModifiedBy)
    VALUES ('John', 'Smith', 'john.smith@example.com', '2026-01-15T10:00:00', 'seed', '2026-01-15T10:00:00', 'seed');
END

-- Orders (references Users)
IF NOT EXISTS (SELECT 1 FROM [dbo].[Order] WHERE OrderNumber = 'ORD-2026-001')
BEGIN
    INSERT INTO [dbo].[Order] (UserId, OrderNumber, TotalAmount, Status, CreatedAt, CreatedBy, ModifiedAt, ModifiedBy)
    VALUES (
        (SELECT UserId FROM [dbo].[User] WHERE Email = 'john.smith@example.com'),
        'ORD-2026-001', 149.99, 'Completed', '2026-01-20T14:30:00', 'seed', '2026-01-20T14:30:00', 'seed'
    );
END
```

**Rules**:
- `IF NOT EXISTS` or `MERGE` pattern for idempotency — seed scripts must be safe to re-run
- Foreign key references via subquery (not hardcoded IDs) for portability
- Realistic recent timestamps (not future dates)
- Group INSERTs by entity with header comments
- Match Figma mock data exactly (same values from `_analysis/08-mock-data-catalog.md`)
- No orphan IDs — every FK reference must resolve to an existing parent record

## 14.14 Verification Rules

The engine validates these 10 rules at every quality gate:

| # | Rule | Failure Type |
|---|------|-------------|
| 1 | Every endpoint in `06-api-contracts.md` MUST have a stored procedure | Hard |
| 2 | Every row in `11-api-to-sp-map.md` must be complete (no empty cells) | Hard |
| 3 | Every stored procedure MUST reference tables that exist in migrations | Hard |
| 4 | Complex queries (JOINs of 3+ tables) SHOULD use a view | Warning |
| 5 | Reusable calculations SHOULD use scalar functions | Warning |
| 6 | Every table MUST have seed data with realistic sample records | Hard (if require_seed_data=true) |
| 7 | Seed data foreign keys MUST reference existing parent records | Hard |
| 8 | Seed data values MUST match Figma mock data (from `08-mock-data-catalog.md`) | Warning |
| 9 | No orphaned SPs (defined but unreachable from any API endpoint) | Warning |
| 10 | No orphaned tables (defined but unreferenced by any SP) | Warning |

## 14.15 Cross-Reference Sources

| Source File | Purpose |
|-------------|---------|
| `_analysis/06-api-contracts.md` | All API endpoints with HTTP method, route, request/response |
| `_analysis/11-api-to-sp-map.md` | Frontend Hook → API → Controller → SP → Tables chain |
| `_analysis/08-mock-data-catalog.md` | Exact mock data values for seed scripts |
| `_stubs/database/01-tables.sql` | Table structure stubs from Figma Make |
| `_stubs/database/02-stored-procedures.sql` | SP signature stubs from Figma Make |
| `_stubs/database/03-seed-data.sql` | Seed data stubs from Figma Make |

## 14.16 View and Function Patterns

### Views (vw_ prefix)
Use views when a query JOINs 3 or more tables:

```sql
CREATE OR ALTER VIEW [dbo].[vw_OrderDetails]
AS
    SELECT
        o.OrderId,
        o.OrderNumber,
        u.FirstName + ' ' + u.LastName AS CustomerName,
        oi.ProductName,
        oi.Quantity,
        oi.UnitPrice,
        (oi.Quantity * oi.UnitPrice) AS LineTotal
    FROM [dbo].[Order] o
    INNER JOIN [dbo].[User] u ON o.UserId = u.UserId
    INNER JOIN [dbo].[OrderItem] oi ON o.OrderId = oi.OrderId;
GO
```

### Scalar Functions (fn_ prefix)
Use scalar functions for reusable calculations:

```sql
CREATE OR ALTER FUNCTION [dbo].[fn_CalculateOrderTotal]
(
    @OrderId INT
)
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @Total DECIMAL(18,2);
    SELECT @Total = SUM(Quantity * UnitPrice)
    FROM [dbo].[OrderItem]
    WHERE OrderId = @OrderId;
    RETURN ISNULL(@Total, 0);
END
GO
```

---

# Chapter 15: Compliance & Security Coding

The GSD engine enforces 88+ security rules across all technology layers. These standards are defined in `%USERPROFILE%\.gsd-global\prompts\shared\security-standards.md`, scanned by `Test-SecurityCompliance` at every quality gate, and checked by council reviewers. Each rule has a unique ID for traceability.

This chapter documents the compliance frameworks and security coding standards enforced by the GSD Engine. The engine scans for OWASP patterns, validates compliance requirements, and blocks deployments that fail security checks.

## 15.1 Compliance Frameworks

The GSD Engine enforces four compliance frameworks simultaneously:

| Framework | Scope | Key Requirements |
|---|---|---|
| HIPAA | Protected Health Information | Encryption at rest and in transit, audit logging, access controls, minimum necessary access |
| SOC 2 | Service Organization Controls | Audit trails, change management, logical access controls, monitoring |
| PCI DSS | Payment Card Data | Encryption, key management, network segmentation, logging, access control |
| GDPR | Personal Data (EU) | Data minimization, right to erasure, consent management, data portability |

These are configured in `global-config.json`:

```json
"compliance": ["HIPAA", "SOC 2", "PCI", "GDPR"]
```

Every agent prompt includes these compliance requirements. Code generated by the engine must satisfy all four frameworks. The security compliance quality gate validates enforcement.

## 15.2 OWASP Security Scanning

The engine runs automated security scanning based on OWASP patterns. This is a zero-token-cost regex scan that runs before final validation.

### Critical Violations (Hard Failures)

These block convergence. Code with critical violations cannot reach 100% health.

| Vulnerability | Detection Pattern | Layer | Prevention |
|---|---|---|---|
| SQL Injection | String concatenation + SQL keywords in `.cs` files | Backend | Use parameterized stored procedures via Dapper |
| Cross-Site Scripting (XSS) | `dangerouslySetInnerHTML` without DOMPurify in `.tsx/.jsx` files | Frontend | Use DOMPurify.sanitize() or avoid dangerouslySetInnerHTML |
| Code Injection | `eval()` or `new Function()` in `.ts/.tsx/.js/.jsx` files | Frontend | Never use eval or dynamic code execution |
| Secrets in Browser Storage | `localStorage` + sensitive keywords (password, secret, token, apiKey) in `.ts/.tsx` files | Frontend | Use httpOnly cookies for sensitive data |
| Hardcoded Credentials | Connection strings, passwords, or API keys in source code | All | Use environment variables and configuration |

### High Severity (Warnings)

These are flagged in the developer handoff report but do not block convergence.

| Vulnerability | Detection Pattern | Layer | Prevention |
|---|---|---|---|
| Missing Authorization | Controllers without `[Authorize]` attribute | Backend | Add `[Authorize]` to every controller class |
| Missing HTTPS Enforcement | HTTP URLs in configuration | All | Use HTTPS everywhere |
| Missing Rate Limiting | API endpoints without throttling | Backend | Add rate limiting middleware |

### Medium Severity (Warnings)

| Vulnerability | Detection Pattern | Layer | Prevention |
|---|---|---|---|
| Missing Audit Columns | `CREATE TABLE` without `CreatedAt`/`ModifiedAt` | Database | Include audit columns on every table |
| Missing Input Validation | DTOs without `[Required]` or `[StringLength]` annotations | Backend | Add data annotations to all DTO properties |
| Missing Error Boundaries | React components without error boundaries | Frontend | Wrap top-level components in ErrorBoundary |

## 15.3 Quality Gates

The GSD Engine runs three quality gate checks that validate completeness, security, and spec quality before declaring a project complete.

### Gate 1: Spec Quality (Pre-Generation)

Runs once at pipeline start. Ensures specifications are clear and consistent before code generation begins.

| Check | Method | Cost | Threshold |
|---|---|---|---|
| Spec consistency | Local regex scan | Free | Block on contradictions |
| Spec clarity | Claude AI analysis | ~$0.15 | Block if score < 70%, warn 70-85% |
| Cross-artifact consistency | Claude AI analysis | ~$0.15 | Block on mismatches between deliverables |

The spec clarity score measures:
- Are acceptance criteria specific and testable?
- Are data types fully defined?
- Are edge cases documented?
- Are error states specified?
- Are RBAC rules explicit?

### Gate 2: Database Completeness (Pre-Validation)

Runs when health reaches 100%. Zero token cost (regex scan). Minimum coverage: 90%.

Verifies the full chain exists for every endpoint:

```
API Endpoint  ->  Stored Procedure  ->  Tables  ->  Seed Data
     |                  |                  |            |
  [HttpGet]      CREATE PROC        CREATE TABLE    INSERT INTO
  [HttpPost]     usp_Entity_*       Entity          Entity
```

The check scans:
- `_analysis/11-api-to-sp-map.md` for the expected mapping
- `.cs` files for `[Http*]` attributes in controllers
- `.sql` files for `CREATE PROC`, `CREATE TABLE`, `INSERT INTO` statements
- Results written to `.gsd/assessment/db-completeness.json`

### Gate 3: Security Compliance (Pre-Validation)

Runs when health reaches 100%. Zero token cost (regex scan).

- **Critical violations**: Hard failure -- health set to 99%, pipeline continues to fix
- **High/medium violations**: Warnings included in developer handoff report

Configuration in `global-config.json`:

```json
"quality_gates": {
    "database_completeness": {
        "enabled": true,
        "require_seed_data": true,
        "min_coverage_pct": 90
    },
    "security_compliance": {
        "enabled": true,
        "block_on_critical": true,
        "warn_on_high": true
    },
    "spec_quality": {
        "enabled": true,
        "min_clarity_score": 70,
        "check_cross_artifact": true
    }
}
```

## 15.4 Security Coding Patterns by Layer

### Backend (.NET 8) Security

| Pattern | Implementation | Compliance |
|---|---|---|
| Authentication | JWT Bearer tokens via `[Authorize]` attribute | SOC 2, HIPAA |
| Authorization | Role-based access control (RBAC) via `[Authorize(Roles = "Admin")]` | SOC 2, HIPAA |
| Input Validation | Data annotations on DTOs (`[Required]`, `[StringLength]`, `[Range]`) | OWASP |
| SQL Injection Prevention | Parameterized stored procedures via Dapper -- no inline SQL | OWASP, PCI |
| Audit Logging | CreatedBy/ModifiedBy/DeletedBy tracked on every write operation | HIPAA, SOC 2 |
| Encryption in Transit | HTTPS enforced via middleware | HIPAA, PCI |
| Error Handling | Global exception handler returns sanitized errors (no stack traces) | OWASP |
| CORS | Configured explicitly -- no wildcard origins | OWASP |

### Frontend (React 18) Security

| Pattern | Implementation | Compliance |
|---|---|---|
| XSS Prevention | Never use `dangerouslySetInnerHTML` without DOMPurify | OWASP |
| Sensitive Data | Never store tokens/passwords in localStorage -- use httpOnly cookies | OWASP, PCI |
| Dynamic Code | Never use `eval()` or `new Function()` | OWASP |
| Auth Token Handling | Store JWT in httpOnly secure cookie, not accessible to JavaScript | OWASP |
| Error Boundaries | Wrap top-level routes in React ErrorBoundary components | SOC 2 |
| Content Security Policy | Set CSP headers to prevent script injection | OWASP |

### Database (SQL Server) Security

| Pattern | Implementation | Compliance |
|---|---|---|
| Parameterized Queries | All input via SP parameters -- no string concatenation | OWASP, PCI |
| Tenant Isolation | Every query includes `WHERE TenantId = @TenantId` | HIPAA, SOC 2 |
| Soft Deletes | Never hard-delete records -- set IsDeleted flag | HIPAA (retention), GDPR (audit) |
| Audit Columns | CreatedAt, CreatedBy, ModifiedAt, ModifiedBy on every table | HIPAA, SOC 2 |
| Encryption at Rest | SQL Server Transparent Data Encryption (TDE) | HIPAA, PCI |
| Minimum Privilege | Application user has EXECUTE permission only -- no direct table access | SOC 2, PCI |

## 15.5 Tenant Isolation

Multi-tenancy is enforced at every layer. A tenant must never be able to access another tenant's data.

| Layer | Enforcement Mechanism |
|---|---|
| API Route | `tenantId` in the URL path: `/api/tenants/{tenantId}/...` |
| Controller | Validates `tenantId` from route matches the authenticated user's tenant claim |
| Service | Passes `tenantId` to every repository method |
| Repository | Passes `@TenantId` parameter to every stored procedure |
| Stored Procedure | Includes `WHERE TenantId = @TenantId` in every query |
| Table | `TenantId NVARCHAR(50) NOT NULL` column with foreign key to Tenant table |

The engine validates tenant isolation during code review. A stored procedure that queries data without filtering by `TenantId` on a tenant-scoped table is flagged as a critical security violation.

## 15.6 Final Validation Gate

When health reaches 100%, the engine runs a comprehensive final validation before declaring convergence. This is the last line of defense.

| # | Check | Type | Description |
|---|---|---|---|
| 1 | .NET build | Hard | `dotnet build --no-restore` -- zero compilation errors |
| 2 | npm build | Hard | `npm run build` -- frontend compiles cleanly |
| 3 | .NET tests | Hard | `dotnet test --no-build` -- all tests pass |
| 4 | npm tests | Hard | `npm test` (CI=true) -- all tests pass |
| 5 | SQL validation | Warn | Pattern violations in SQL files |
| 6 | .NET vulnerability audit | Warn | `dotnet list package --vulnerable` |
| 7 | npm vulnerability audit | Warn | `npm audit --audit-level=high` |
| 8 | Database completeness | Hard | Full chain API -> SP -> Table -> Seed verified |
| 9 | Security compliance | Hard/Warn | Critical = hard failure, High/Medium = warning |

Hard failures reset health to 99% and inject the failure details into agent prompts via `error-context.md`. The engine then loops to fix the issues automatically. Up to 3 validation attempts are allowed before the pipeline exits to prevent infinite loops.

---

## 15.7 .NET 8 Backend Security

### Authentication & Authorization

| ID | Rule |
|----|------|
| SEC-NET-01 | `[Authorize]` attribute on ALL controller classes |
| SEC-NET-02 | `[ValidateAntiForgeryToken]` on POST/PUT/DELETE actions |
| SEC-NET-03 | HttpOnly + Secure + SameSite=Strict on all cookies |
| SEC-NET-04 | Session timeout max 60 minutes, no sliding expiration |
| SEC-NET-05 | JWT: 15-min access token, 7-day refresh token, signed with RS256 |
| SEC-NET-06 | Login throttling: rate limit on auth endpoints |
| SEC-NET-07 | Identical error messages for bad username vs bad password |
| SEC-NET-08 | ASP.NET Core Identity for auth — never custom implementations |
| SEC-NET-09 | Verify user access to the specific resource, not just existence |

### Input Validation

| ID | Rule |
|----|------|
| SEC-NET-10 | Whitelist validation: accept known-good, reject everything else |
| SEC-NET-11 | `SqlParameter` or Dapper `@params` for ALL database queries |
| SEC-NET-12 | `IPAddress.TryParse()` and `Uri.CheckHostName()` for IP/URL input |
| SEC-NET-13 | Never use `[AllowHtml]` without proven safe content |
| SEC-NET-14 | FluentValidation or DataAnnotations on all request DTOs |

### Data Protection & Cryptography

| ID | Rule |
|----|------|
| SEC-NET-15 | AES-256 for PII/PHI encryption at rest (Data Protection API) |
| SEC-NET-16 | TLS 1.2+ enforced in Program.cs — never SSL |
| SEC-NET-17 | PBKDF2 or bcrypt for password hashing with unique salt |
| SEC-NET-18 | SHA-512 for non-password hashing |
| SEC-NET-19 | Never implement custom cryptography |
| SEC-NET-20 | Keys in Azure Key Vault or DPAPI — never in code or config files |
| SEC-NET-21 | Unique nonce for every encryption operation |
| SEC-NET-22 | Connection strings in environment variables or secret manager |

### Security Headers

| ID | Rule |
|----|------|
| SEC-NET-23 | `X-Content-Type-Options: nosniff` |
| SEC-NET-24 | `X-Frame-Options: DENY` |
| SEC-NET-25 | `Content-Security-Policy: default-src 'self'` (strict, no inline scripts) |
| SEC-NET-26 | `Strict-Transport-Security: max-age=15768000` (HSTS, 6 months) |
| SEC-NET-27 | Remove server version headers |

### Error Handling & Logging

| ID | Rule |
|----|------|
| SEC-NET-28 | Catch specific exception types — never bare `catch (Exception)` |
| SEC-NET-29 | `ILogger<T>` with structured logging (Serilog pattern) |
| SEC-NET-30 | Never log passwords, tokens, API keys, SSN, card numbers, PHI |
| SEC-NET-31 | Log context: userId, requestId, timestamp, operation |
| SEC-NET-32 | Production: no debug flags, no stack traces in responses |
| SEC-NET-33 | `async/await` for all I/O; `.ConfigureAwait(false)` in library code |

### Deserialization & SSRF Prevention

| ID | Rule |
|----|------|
| SEC-NET-34 | Never use `BinaryFormatter` (CVE risk) |
| SEC-NET-35 | Use `System.Text.Json` or `DataContractSerializer` |
| SEC-NET-36 | Validate integrity before deserializing untrusted data |
| SEC-NET-37 | Validate/whitelist URLs before server-side HTTP requests |
| SEC-NET-38 | Never auto-follow redirects to prevent internal resource access |

## 15.8 SQL Server Security

### Access Control

| ID | Rule |
|----|------|
| SEC-SQL-01 | Stored procedures ONLY — no inline SQL from application layer |
| SEC-SQL-02 | All parameters use `SqlDbType` with explicit size |
| SEC-SQL-03 | No dynamic SQL (`sp_executesql`) with unvalidated input |
| SEC-SQL-04 | Row-level security via WHERE clause on TenantId/OrgId |
| SEC-SQL-05 | Least privilege: app account has EXECUTE only, never db_owner |
| SEC-SQL-06 | Windows Integrated Auth when possible; SQL auth only with rotated passwords |

### Structure & Patterns

| ID | Rule |
|----|------|
| SEC-SQL-07 | `BEGIN TRY / END TRY / BEGIN CATCH / THROW / END CATCH` in all SPs |
| SEC-SQL-08 | Audit columns on every table: CreatedAt, CreatedBy, ModifiedAt, ModifiedBy |
| SEC-SQL-09 | Audit log INSERT on all INSERT/UPDATE/DELETE of sensitive data |
| SEC-SQL-10 | Explicit column lists in SELECT — never `SELECT *` |
| SEC-SQL-11 | Strong typing for all parameters (no sql_variant or NVARCHAR(MAX) for IDs) |
| SEC-SQL-12 | IF EXISTS checks for idempotent migrations |
| SEC-SQL-13 | GRANT EXECUTE permissions explicitly in each SP |
| SEC-SQL-14 | Proper indexing on foreign keys and lookup columns |
| SEC-SQL-15 | `SET NOCOUNT ON` at top of every SP |

### Encryption & Backup

| ID | Rule |
|----|------|
| SEC-SQL-16 | TDE (Transparent Data Encryption) for PHI/PII databases |
| SEC-SQL-17 | TLS 1.2+ for all database connections |
| SEC-SQL-18 | Encrypted backups stored separately with restricted access |

## 15.9 React 18 Frontend Security

### XSS Prevention

| ID | Rule |
|----|------|
| SEC-FE-01 | No `dangerouslySetInnerHTML` without DOMPurify sanitization |
| SEC-FE-02 | No `eval()` or `new Function()` anywhere |
| SEC-FE-03 | JSX auto-escaping for all text content |
| SEC-FE-04 | DOMPurify for any user-generated HTML rendering |

### Data & Token Handling

| ID | Rule |
|----|------|
| SEC-FE-05 | HTTPS only for all API calls (enforce in axios/fetch config) |
| SEC-FE-06 | Never store tokens, PII, passwords in `localStorage` |
| SEC-FE-07 | Use httpOnly + Secure + SameSite=Strict cookies for auth tokens |
| SEC-FE-08 | `Authorization: Bearer <token>` header — never in URL parameters |
| SEC-FE-09 | Token refresh/rotation mechanism |

### Error Handling

| ID | Rule |
|----|------|
| SEC-FE-10 | Error boundaries at route level — never expose stack traces |
| SEC-FE-11 | User-friendly error messages, no technical details |
| SEC-FE-12 | Remove `console.log` debug statements before production |
| SEC-FE-13 | Never log sensitive data (tokens, passwords, SSN) to console |

### Dependencies

| ID | Rule |
|----|------|
| SEC-FE-14 | `npm audit` in CI/CD — fix high/critical vulnerabilities |
| SEC-FE-15 | Exact version pinning in package.json |
| SEC-FE-16 | Subresource Integrity (SRI) hashes for CDN-hosted libraries |

## 15.10 HIPAA Compliance (Health Data)

| ID | Rule |
|----|------|
| COMP-HIPAA-01 | PHI encrypted at rest (AES-256 / TDE) and in transit (TLS 1.2+) |
| COMP-HIPAA-02 | Audit trail for all PHI access: who, what, when, from where |
| COMP-HIPAA-03 | Role-based access control for PHI endpoints |
| COMP-HIPAA-04 | Minimum necessary: grant only permissions needed for role |
| COMP-HIPAA-05 | Data isolation by organization/practice |
| COMP-HIPAA-06 | 6+ year log retention |
| COMP-HIPAA-07 | Incident reporting within 24 hours |

## 15.11 SOC 2 Compliance (Trust & Security)

| ID | Rule |
|----|------|
| COMP-SOC2-01 | Change control: log all production changes with approval |
| COMP-SOC2-02 | Security monitoring: failed logins, privilege escalation |
| COMP-SOC2-03 | Incident response playbook documented |
| COMP-SOC2-04 | Backup tested regularly, RTO/RPO targets defined |
| COMP-SOC2-05 | Code review mandatory for all production changes |
| COMP-SOC2-06 | Vulnerability scan + patch within SLA (critical: 24-48 hrs) |

## 15.12 PCI DSS Compliance (Payment Card Data)

| ID | Rule |
|----|------|
| COMP-PCI-01 | Never store raw card numbers — use payment processor tokens |
| COMP-PCI-02 | Card data encrypted in transit (TLS 1.2+) and at rest (AES-256) |
| COMP-PCI-03 | Isolate payment systems via firewall/VLAN |
| COMP-PCI-04 | Multi-factor auth for admin access |
| COMP-PCI-05 | Never log card numbers |
| COMP-PCI-06 | Quarterly external penetration testing |

## 15.13 GDPR Compliance (EU Privacy)

| ID | Rule |
|----|------|
| COMP-GDPR-01 | APIs for data export, deletion, portability |
| COMP-GDPR-02 | Explicit consent tracking for data processing |
| COMP-GDPR-03 | Data minimization: collect only necessary data |
| COMP-GDPR-04 | Privacy by design: encrypt PII by default |
| COMP-GDPR-05 | Breach notification within 72 hours |
| COMP-GDPR-06 | Data retention/deletion schedules enforced |

---

# Chapter 16: Speed Optimizations

## 16.1 Overview

Version 2.0.0 introduces five speed optimizations that reduce wall-clock time per iteration by 30-50% while maintaining quality. All optimizations are configurable via `speed_optimizations` in global-config.json.

## 16.2 Differential Code Review

Instead of re-reviewing the entire codebase every iteration, the engine reviews only files changed since the last successful review.

**How it works:**
1. After each code-review, `Save-ReviewedCommit` stores the current git commit hash in `.gsd/cache/reviewed-files.json`
2. Before next code-review, `Get-DifferentialContext` computes `git diff` since that commit
3. If <50% of files changed, uses `code-review-differential.md` prompt (focused on diff only)
4. If >50% changed or cache expired, falls back to full review

**Configuration:**

| Setting | Default | Description |
|---------|---------|-------------|
| `differential_review.enabled` | true | Enable differential review |
| `differential_review.max_diff_pct` | 50 | Max % files changed before full review |
| `differential_review.cache_ttl_iterations` | 10 | Rebuild cache every N iterations |

**Estimated savings:** 40-60% of code-review tokens, 30% faster per iteration.

## 16.3 Conditional Research Skip

Skips the research phase when health is improving and no new "not_started" requirements are in the batch.

**Logic:**
- If `health_delta >= min_health_delta` AND batch has zero `not_started` items: skip research
- Always runs research on first iteration
- Always runs research when health is stalled or declining

**Configuration:**

| Setting | Default | Description |
|---------|---------|-------------|
| `speed_optimizations.conditional_research_skip.enabled` | true | Enable skip |
| `speed_optimizations.conditional_research_skip.min_health_delta` | 1 | Min health improvement to skip |

**Estimated savings:** 5-15K tokens and 60-90s on 50%+ of iterations.

## 16.4 Smart Batch Sizing

Calculates optimal batch size from historical token usage instead of using a fixed default.

**Formula:** `optimal = floor(context_limit * utilization_target / avg_tokens_per_requirement)`

The engine tracks `avg_tokens_per_requirement` from cost-summary.json across iterations and adjusts automatically.

**Configuration:**

| Setting | Default | Description |
|---------|---------|-------------|
| `speed_optimizations.smart_batch_sizing.enabled` | true | Enable smart sizing |
| `speed_optimizations.smart_batch_sizing.context_limit_tokens` | 128000 | Model context window |
| `speed_optimizations.smart_batch_sizing.utilization_target` | 0.7 | Target utilization |
| `speed_optimizations.smart_batch_sizing.min_batch` | 2 | Floor |
| `speed_optimizations.smart_batch_sizing.max_batch` | 12 | Ceiling |

## 16.5 Prompt Template Deduplication

Security standards and coding conventions are injected via template variables instead of being duplicated across prompts.

**Template variables:**
- `{{SECURITY_STANDARDS}}` -- resolved from `prompts/shared/security-standards.md`
- `{{CODING_CONVENTIONS}}` -- resolved from `prompts/shared/coding-conventions.md`

The `Resolve-PromptWithDedup` function handles injection during prompt resolution.

## 16.6 Token Budget Headers

All prompt templates now include explicit output constraints and inter-agent handoff protocols:

```
## Output Constraints
- Maximum output: 3000 tokens
- Format: JSON + markdown (no prose)

## Input Context
You will receive: requirements-matrix.json
Previous phase output: execute phase committed code to git
```

This prevents token bloat and gives agents clear expectations about input format.

---

# Chapter 17: Validation Gates Reference

## 17.1 Complete Validation Gate Inventory

Version 2.0.0 provides 14 validation gates across the pipeline lifecycle:

| # | Gate | Type | Cost | When | Blocking |
|---|------|------|------|------|----------|
| 1 | Test-PreFlight | CLI/project checks | Free | Pre-pipeline | Yes |
| 2 | Test-DiskSpace | Disk check | Free | Pre-iteration | Yes |
| 3 | Invoke-SpecQualityGate | Spec clarity + consistency | ~$0.30 | Pre-pipeline | Configurable |
| 4 | Invoke-PerIterationCompliance | SEC-*/COMP-* rule scan | Free | Every iteration | Critical only |
| 5 | Test-ApiContractCompliance | Controller vs OpenAPI | Free | Post-execute | Configurable |
| 6 | Test-DesignTokenCompliance | CSS hardcoded values | Free | Post-execute | Configurable |
| 7 | Invoke-PreExecuteGate | dotnet build + npm build | Free | Pre-commit | Yes (with fix) |
| 8 | Test-RequirementAcceptance | Per-requirement tests | Free | Post-execute | Configurable |
| 9 | Invoke-VisualValidation | Figma screenshot diff | Free | Post-execute | Configurable |
| 10 | Test-DatabaseMigrationIntegrity | FK/index/seed checks | Free | Post-execute | High severity |
| 11 | Invoke-PiiFlowAnalysis | PII flow tracking | Free | Post-execute | Critical only |
| 12 | Test-HealthRegression | Health drop >5% | Free | Post-iteration | Yes (revert) |
| 13 | Invoke-FinalValidation | Build/test/audit suite | Free | At 100% health | Hard failures |
| 14 | Invoke-LlmCouncil | Multi-agent review | ~$0.50 | At 100% health | Block vote |

## 17.2 Pre-Execute Compile Gate

The pre-execute gate ensures only code that compiles gets committed to git.

**Flow:**
1. Execute phase generates code
2. `Invoke-PreExecuteGate` runs `dotnet build` + `npm run build`
3. If build fails: sends errors to executing agent via `fix-compile-errors.md` prompt
4. Agent fixes in-place (same context window = cheaper fix)
5. Re-validates after fix
6. Max 2 fix attempts, then commits as-is for next iteration

**Configuration:**

| Setting | Default | Description |
|---------|---------|-------------|
| `pre_execute_gate.enabled` | true | Enable gate |
| `pre_execute_gate.max_fix_attempts` | 2 | Fix attempts before fallthrough |
| `pre_execute_gate.include_tests` | false | Also run tests pre-commit |

## 17.3 Per-Requirement Acceptance Tests

Each requirement can define an acceptance test in queue-current.json:

```json
{
  "req_id": "REQ-042",
  "acceptance_test": {
    "type": "pattern_match",
    "file": "src/Controllers/UserController.cs",
    "patterns": ["[Authorize]", "[HttpGet]"]
  }
}
```

**Test types:**

| Type | What It Checks | Cost |
|------|---------------|------|
| `file_exists` | Target files were created | Free |
| `pattern_match` | Generated code contains required patterns | Free |
| `build_check` | Project compiles after changes | Free |
| `dotnet_test` | Specific .NET test class passes | Free |
| `npm_test` | Specific frontend test passes | Free |

## 17.4 Contract-First API Validation

Zero-cost static scan that validates controllers against `06-api-contracts.md`:

| Check | Severity | Description |
|-------|----------|-------------|
| Missing endpoint | Blocking | Documented endpoint has no controller action |
| Wrong HTTP method | Blocking | Route exists but method attribute doesn't match |
| Missing [Authorize] | Warning | Controller has no auth attribute |
| Inline SQL | Blocking | Direct SQL instead of stored procedure |
| Undocumented SP | Warning | SP in map not referenced in controllers |

## 17.5 Visual Validation

Compares generated React components against Figma design exports:

**With Playwright installed:** Full screenshot capture and pixel comparison
**Without Playwright:** Component-match heuristic (checks if component files exist for each design screenshot)

Place Figma exports as PNG files in `design/screenshots/` with filenames matching component names.

## 17.6 Design Token Enforcement

Scans for hardcoded CSS values that should use design tokens:

| Pattern | Type | Example Violation |
|---------|------|-------------------|
| Hex colors | color | `color: #3498db` instead of `var(--primary)` |
| RGB/RGBA | color | `background: rgb(52,152,219)` |
| Pixel font-size | typography | `font-size: 14px` instead of `var(--text-sm)` |
| Pixel spacing | spacing | `margin: 16px` instead of `var(--space-4)` |
| Pixel border-radius | border | `border-radius: 8px` instead of `var(--radius-md)` |

Allowed exceptions: `#000`, `#fff`, `transparent`, `inherit`, `currentColor`, and any line using `var(--xxx)`.

## 17.7 Runtime Smoke Tests

After the static validation gates, runtime smoke tests catch errors that only surface when the application actually starts:

| Check | What It Catches | Cost |
|-------|----------------|------|
| **Seed Data FK Order** | INSERT ordering violations — parent tables must be inserted before child tables | Free (static scan) |
| **API Endpoint Discovery** | Discovers all GET endpoints from `[Http*]` attributes and OpenAPI spec | Free (static scan) |
| **API Smoke Test** | Starts the app via `dotnet run`, hits every GET endpoint, checks for HTTP 500s | Free (no LLM calls) |
| **Health Endpoint** | Verifies `/api/health` returns healthy status with DB connectivity | Free |

**How it runs:**
1. `Test-SeedDataFkOrder` scans SQL seed files for FK constraint violations (static, zero-cost)
2. `Find-ApiEndpoints` discovers routes from Controller files and OpenAPI spec
3. `Invoke-ApiSmokeTest` starts the application, hits discovered endpoints, reports 500s
4. `Invoke-RuntimeSmokeTest` orchestrates all three checks and returns combined results

**Configuration:** `runtime_smoke_test` in global-config.json

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | true | Enable/disable runtime smoke tests |
| `startup_timeout_seconds` | 30 | Max time to wait for app startup |
| `request_timeout_seconds` | 10 | Timeout per endpoint request |
| `max_endpoints_to_test` | 50 | Cap on endpoints to test |
| `health_endpoint` | /api/health | Required health check endpoint |
| `fail_on_any_500` | true | Treat any 500 as a hard failure |
| `seed_fk_check_enabled` | true | Enable FK order validation |

**Prompt templates:** `health-endpoint.md` (mandates `/api/health`), `di-service-lifetime.md` (prevents scoped-from-root DI errors)

## 17.8 Partitioned Code Review

Replaces single-agent code review with a 3-partition parallel review system. Each iteration, requirements are split into three groups and reviewed simultaneously by different agents.

**Partition Focus Areas:**

| Partition | Focus | Review Emphasis |
|-----------|-------|----------------|
| A | Implementation & Architecture | DI patterns, SOLID, contracts, error handling |
| B | Data Flow & Integration | E2E chains, API wiring, seed data, migrations |
| C | Security, Compliance & UX | OWASP, HIPAA, Figma match, accessibility |

**Agent Rotation:** Assignments rotate every iteration for full coverage:

```
Iter 1: A=Claude   B=Gemini  C=Codex
Iter 2: A=Gemini   B=Codex   C=Claude
Iter 3: A=Codex    B=Claude  C=Gemini
(repeats every 3 iterations)
```

After 3 iterations, every requirement has been reviewed by all 3 LLMs. Coverage tracked in `.gsd/code-review/coverage-matrix.json`.

**How it works:**
1. `Split-RequirementsIntoPartitions` divides requirements into 3 balanced groups
2. 3 agents run simultaneously, each with a partition-specific prompt
3. `Merge-PartitionedReviews` combines results into single health score
4. `Update-CoverageMatrix` records which agent reviewed which requirement

**Fallback:** If fewer than 3 requirements or if all partitions fail, falls back to single Claude review automatically.

**Configuration:** `partitioned_code_review` in global-config.json

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | true | Enable partitioned review |
| `partition_count` | 3 | Number of partitions (always 3) |
| `rotation_enabled` | true | Rotate agent assignments each iteration |
| `merge_strategy` | strict_union | How to merge partition results |
| `timeout_seconds` | 300 | Per-partition timeout |
| `fallback_to_single` | true | Fall back to single agent on failure |
| `cooldown_between_agents` | 5 | Seconds between agent launches |

**Prompt templates:** `code-review-partition-A.md`, `code-review-partition-B.md`, `code-review-partition-C.md` (in `prompts/shared/`)

**Output files:** `.gsd/code-review/coverage-matrix.json`, `.gsd/code-review/rotation-history.jsonl`

---

# Chapter 18: Compliance Engine and Agent Intelligence

## 18.1 Per-Iteration Compliance Audit

Unlike the quality gates that run only at 100% health, the compliance engine scans every iteration with a structured rule engine.

**Rule categories:**

| Category | Rule IDs | Count | Examples |
|----------|----------|-------|----------|
| Network Security | SEC-NET-01 to SEC-NET-08 | 8 | SQL injection, XSS, eval, hardcoded secrets |
| SQL Security | SEC-SQL-01 to SEC-SQL-03 | 3 | String concatenation, dynamic SQL |
| Frontend Security | SEC-FE-01 to SEC-FE-02 | 2 | Missing CSRF, unvalidated redirect |
| HIPAA | COMP-HIPAA-01 to COMP-HIPAA-02 | 2 | PII in logs, unencrypted PII |
| SOC 2 | COMP-SOC2-01 | 1 | Missing audit log |
| PCI | COMP-PCI-01 to COMP-PCI-02 | 2 | Card data in logs, unmasked display |

**Output:** `.gsd/validation/compliance-scan.json` with pass/fail per rule ID, severity, and violation details.

## 18.2 Database Migration Validation

Three zero-cost SQL file scans:

1. **Foreign Key Consistency:** Every `REFERENCES` clause points to a table defined in `CREATE TABLE`
2. **Index Coverage:** Every column used in `WHERE` clauses has an index or is a primary key
3. **Seed Data Integrity:** Every `INSERT INTO` targets a table that exists in `CREATE TABLE`

**Output:** `.gsd/validation/db-migration-results.json`

## 18.3 PII Flow Tracking

Traces configurable PII field names through the entire codebase:

| Check | Severity | What It Detects |
|-------|----------|-----------------|
| PII in logs | Critical | `_logger.LogInfo(user.SSN)` |
| Unencrypted PII | High | `user.SSN = value` without Encrypt/Hash |
| Unmasked PII in UI | High | `{user.ssn}` in JSX without mask function |

**Default PII fields:** email, ssn, social_security, date_of_birth, dob, phone, address, name, first_name, last_name, credit_card, card_number, cvv, password, secret, token

**Output:** `.gsd/validation/pii-flow-results.json`

## 18.4 Agent Performance Scoring

The engine tracks two metrics per agent:

- **Efficiency:** `requirements_satisfied / (tokens_used / 1000)` -- how many requirements an agent satisfies per 1K tokens
- **Reliability:** `1 - (regressions / total_satisfied)` -- how often agent's work survives the next code review

**Overall score:** `reliability * 0.6 + min(1, efficiency) * 0.4`

`Get-BestAgentForPhase` uses these scores to recommend the best agent for each phase, after collecting enough samples (configurable `min_samples`, default 3).

**Output:** `.gsd/intelligence/agent-scores.json` (per-project), `~/.gsd-global/intelligence/agent-scores-global.json` (cross-project)

## 18.5 Warm-Start for New Projects

When a project reaches 100% health, `Save-ProjectPatterns` caches its detected patterns by project type:

| Project Type | Detection | Example |
|-------------|-----------|---------|
| `dotnet-react` | .sln + package.json with "react" | Full-stack web app |
| `dotnet-api` | .sln without React | Backend API |
| `react-spa` | package.json with "react", no .sln | Frontend SPA |

When starting a new project, `Get-WarmStartPatterns` loads patterns from the most recent project of the same type, giving the create-phases phase a head start.

**Cache location:** `~/.gsd-global/intelligence/pattern-cache.json`

---

# Chapter 19: LOC Tracking and Cost-per-Line Metrics

## 19.1 Overview

The LOC tracking system measures AI-generated lines of code per iteration, correlating them with API costs to produce cost-per-line metrics. This data appears in:

- **ntfy notifications** (per-iteration and completion messages)
- **Developer handoff** (LOC section with per-iteration breakdown)
- **loc-metrics.json** (machine-readable data for dashboards)

## 19.2 How It Works

**Per-iteration tracking:** After each execute phase commit, `Update-LocMetrics` runs `git diff --numstat HEAD~1 HEAD` to capture:

| Metric | Description |
|--------|-------------|
| Lines Added | New lines of code created by AI |
| Lines Deleted | Lines removed or replaced by AI |
| Net Lines | Added minus Deleted (net codebase growth) |
| Files Changed | Number of source files touched |

**Filtering:** Only source files matching `include_extensions` are counted. Paths matching `exclude_paths` (node_modules, .gsd, dist, bin, etc.) are excluded.

**Grand total tracking:** At pipeline start, `Save-LocBaseline` records the current git commit hash. At pipeline end, `Complete-LocTracking` computes a grand total diff from the baseline commit to HEAD, avoiding cumulative drift from per-iteration counting.

**Code review awareness:** `Get-LocContextForReview` injects a LOC history table into code review prompts, giving the review agent visibility into code churn patterns across iterations. This helps identify low-productivity iterations.

| Function | When It Runs | What It Does |
|----------|-------------|-------------|
| `Update-LocMetrics` | After each execute phase | Per-iteration LOC diff |
| `Save-LocBaseline` | Pipeline start | Records starting commit hash |
| `Complete-LocTracking` | Pipeline end | Grand total LOC from baseline to HEAD |
| `Get-LocContextForReview` | Before code review | Injects LOC history into review prompts |
| `Get-LocCostSummaryText` | Final notification | Multi-line LOC vs Cost summary |

## 19.3 Cost-per-Line Calculation

When `cost_per_line` is enabled, the system cross-references `cost-summary.json`:

```
Cost per Added Line = total_cost_usd / cumulative_lines_added
Cost per Net Line   = total_cost_usd / cumulative_lines_net
```

**Example:** If a pipeline run costs $4.50 and produces 3,000 net lines of code, the cost per net line is $0.0015 (~$1.50 per 1,000 lines).

## 19.4 Notification Integration

LOC metrics appear in all ntfy notification types, including cost-per-line on every iteration:

**Per-iteration** (includes cost-per-line via `Get-LocNotificationText`):
```
Iter 3 Complete
my-project | Health: 65% (+12%) | Batch: 5
Cost: $0.45 run / $1.23 total | 89K tok
LOC: +250 / -30 net 220 | 12 files | $0.003/line
```

**Completion** (grand totals via `Get-LocCostSummaryText`):
```
CONVERGED!
my-project | 100% in 8 iterations
--- LOC vs Cost ---
Lines: +3,200 / -180 net 3,020
Files: 95 | Iterations: 8
Total cost: $4.50
Cost/added line: $0.0014
Productivity: 716 lines/$
```

## 19.5 Developer Handoff LOC Section

The developer handoff document includes a "Lines of Code (AI-Generated)" section with:

- Cumulative metrics table (added, deleted, net, files, iterations)
- Cost-per-line calculations
- Per-iteration LOC breakdown table

## 19.6 Configuration

```json
"loc_tracking": {
    "enabled": true,
    "include_extensions": [".cs", ".ts", ".tsx", ".js", ".jsx", ".css", ".scss", ".html", ".sql", ".json", ".md"],
    "exclude_paths": [".gsd/", "node_modules/", "bin/", "obj/", "dist/", "build/", "package-lock.json"],
    "track_per_file": true,
    "cost_per_line": true
}
```

**Output:** `.gsd/costs/loc-metrics.json`

---

# Chapter 20: Maintenance Mode (Post-Launch Updates)

## 20.1 Overview

After a project reaches 100% health and is published, the GSD Engine supports ongoing maintenance through three new capabilities:

| Capability | Command | Use Case |
|------------|---------|----------|
| Bug fixes | `gsd-fix "description"` | Quick fix of production bugs |
| Feature updates | `gsd-update` | Add new features from updated specs |
| Scoped convergence | `gsd-converge --Scope "source:bug_report"` | Target specific requirement groups |

All three build on the existing convergence pipeline with minimal new infrastructure.

## 20.2 Bug Fix Mode (gsd-fix)

The `gsd-fix` command is a shortcut for fixing production bugs. It auto-creates requirement entries in the matrix, writes error context for agent injection, and runs a short convergence cycle.

### Usage

```powershell
# Fix a single bug
gsd-fix "Login fails when email contains + character"

# Fix multiple bugs
gsd-fix "Login fails with +" "Report totals include voided records" "API returns 500 on null input"

# Fix from a file (one bug per line, or markdown list)
gsd-fix -File bugs.md

# Fix from a directory with screenshots, logs, and detailed markdown
gsd-fix -BugDir ./bugs/login-issue/

# Dry run (preview without executing)
gsd-fix "Login fails with +" -DryRun
```

### What gsd-fix Does

1. Parses bug descriptions from arguments, file, or directory
2. Creates requirement entries in `requirements-matrix.json`:
   - `req_id`: `BUG-001`, `BUG-002`, etc.
   - `source`: `bug_report`
   - `status`: `not_started`
   - `priority`: `critical`
   - `spec_version`: `fix`
3. If `-BugDir` is used, copies all artifacts (screenshots, logs, files) to `.gsd/supervisor/bug-artifacts/BUG-xxx/`
4. Recalculates health score (drops from 100% based on new items)
5. Writes bug details to `.gsd/supervisor/error-context.md` (injected into all agent prompts):
   - Screenshot references (Claude reads images during code-review/plan phases)
   - Log file snippets (first 20 lines inlined for context)
   - Full markdown bug report appended
6. Calls `gsd-converge` with fix-optimized defaults:
   - `MaxIterations`: 5
   - `BatchSize`: 3
   - `SkipResearch`: true (saves tokens)
   - `Scope`: `source:bug_report` (only fixes bugs, ignores feature requirements)

### Input Modes

**Mode 1: CLI Arguments** — Quick, one-line descriptions:
```powershell
gsd-fix "Login fails when email contains '+' character"
```

**Mode 2: Bug File** — One bug per line (plain text or markdown list):
```markdown
- Login fails when email contains '+' character
- Report totals include voided records in SUM
- API returns 500 when userId is null
```

**Mode 3: Bug Directory** — Rich input with screenshots, logs, and files:
```
bugs/login-issue/
  bug.md              # Detailed description with steps to reproduce
  error-screenshot.png # Screenshot of the error
  server.log          # Relevant log extract
  repro.http          # HTTP request that triggers the bug
```

The `bug.md` file uses standard markdown. The first `# heading` becomes the bug description in the matrix. The full content (including image references) gets written to `error-context.md` for agent injection.

```markdown
# Login fails when email contains + character

## Steps to Reproduce
1. Enter email: user+tag@example.com
2. Click Login
3. See 400 Bad Request error

![Error screenshot](error-screenshot.png)

## Server Log
See server.log — stack trace at line 42 shows URL encoding issue in AuthController.

## Expected: Login succeeds
## Actual: 400 Bad Request
```

Claude (multimodal) can read the screenshots during code-review and plan phases since they are referenced in the error context and stored in `.gsd/supervisor/bug-artifacts/BUG-xxx/`.

### Cost Estimate

| Bugs | Iterations | Est. Cost |
|------|-----------|-----------|
| 1-3 | 3-5 | $4-8 |
| 5-10 | 5-8 | $8-15 |

## 20.3 Incremental Feature Updates (gsd-update)

The `gsd-update` command adds new requirements from updated specs without losing existing satisfied items.

### Workflow

1. Create new spec version: `design/web/v02/_analysis/` with updated Figma Make 12-file set
2. Run `gsd-update`
3. The engine reads existing matrix, preserves all satisfied requirements, adds new ones
4. Convergence runs on the merged matrix

### Usage

```powershell
# Add new requirements and converge
gsd-update

# Add requirements then converge only new features
gsd-update -Scope "source:v02_spec"

# Preview what would be added
gsd-update -DryRun
```

### Spec Versioning

```
design/
  web/v01/              # Original release specs (keep for reference)
    _analysis/          # Full 12-file set for v1.0
  web/v02/              # Feature update
    _analysis/          # Full 12-file set (v01 content + new features)
```

**Key rule**: Each version must contain the COMPLETE spec set, not just deltas. The engine reads the full `_analysis/` directory -- if v02 only has new feature specs, the engine loses context on existing functionality.

### How Incremental Create-Phases Works

The `create-phases-incremental.md` prompt instructs Claude to:

1. Read the existing `requirements-matrix.json` completely
2. Read the latest design specs
3. Identify requirements in new specs NOT already in the matrix
4. Append new requirements with `status: not_started` and `spec_version: v02`
5. Preserve all existing entries (satisfied, partial, not_started)
6. Recalculate health score with new totals

### Cost Estimate

| New Features | Iterations | Est. Cost |
|-------------|-----------|-----------|
| 5-10 | 8-15 | $12-25 |
| 20-30 | 15-25 | $25-45 |
| 50+ | 20-40 | $30-60 |

## 20.4 Scoped Convergence (--Scope)

The `--Scope` parameter filters which requirements the plan phase can select for each batch, while code-review still evaluates all requirements (to catch regressions).

### Scope Syntax

```powershell
# By source field
gsd-converge --Scope "source:v02_spec"         # Only v02 features
gsd-converge --Scope "source:bug_report"        # Only bugs

# By requirement ID
gsd-converge --Scope "id:BUG-001,BUG-002,REQ-105"  # Specific items

# Combined with other flags
gsd-converge --Scope "source:bug_report" -MaxIterations 5 -BatchSize 3
```

### How Scope Works

| Phase | Scope Applied? | Behavior |
|-------|---------------|----------|
| Code Review | No | Reviews ALL requirements (catches regressions) |
| Research | No | Researches patterns for scoped items |
| Plan | Yes | Only selects requirements matching scope for batch |
| Execute | Yes (via plan) | Only executes scoped batch items |
| Council | No | Reviews all code changes |

### When to Use Scope

| Situation | Scope Value |
|-----------|-------------|
| Fix only bugs after mixed bug+feature update | `source:bug_report` |
| Work only on v02 features | `source:v02_spec` |
| Fix 3 specific requirements | `id:REQ-101,REQ-102,REQ-103` |
| Full convergence (default) | (empty, no scope) |

## 20.5 Mixed Mode (Bugs + Features)

When you have both bugs to fix and features to add:

1. Add v02 specs to `design/web/v02/_analysis/`
2. Run `gsd-update` to add feature requirements
3. Run `gsd-fix "bug1" "bug2"` to add bug requirements
4. Write priority instructions to `.gsd/supervisor/prompt-hints.md`:
   ```
   ## Priority Override
   Fix ALL bug_report requirements BEFORE any v02_spec requirements.
   Bugs are production-critical.
   ```
5. Run `gsd-converge` (no scope = work on everything, prompt-hints enforce priority)

### Separate Cost Tracking

To track costs separately for bugs vs features, run them as separate sessions:

```powershell
# Session 1: Fix bugs (note cost-summary.json before/after)
gsd-converge --Scope "source:bug_report" -MaxIterations 5

# Session 2: Build features
gsd-converge --Scope "source:v02_spec"
```

## 20.6 Quick Reference

| Situation | Command |
|-----------|---------|
| Brand new project | `gsd-blueprint` |
| Existing code to fix | `gsd-converge` |
| Production bugs | `gsd-fix "description"` |
| New features from specs | `gsd-update` |
| Targeted work | `gsd-converge --Scope "source:..."` |
| Add requirements without rebuilding matrix | `gsd-converge --Incremental` |

## 20.7 Configuration

```json
"maintenance_mode": {
    "enabled": true,
    "fix_defaults": {
        "max_iterations": 5,
        "batch_size": 3,
        "skip_research": true
    },
    "scope_filter": {
        "enabled": true,
        "review_all_on_scope": true,
        "scope_plan_and_execute": true
    },
    "incremental_phases": {
        "enabled": true,
        "preserve_satisfied": true,
        "add_spec_version_tag": true
    }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `fix_defaults.max_iterations` | 5 | Max iterations for gsd-fix |
| `fix_defaults.batch_size` | 3 | Batch size for gsd-fix |
| `fix_defaults.skip_research` | true | Skip research phase for bug fixes |
| `scope_filter.review_all_on_scope` | true | Code-review sees all requirements even when scoped |
| `scope_filter.scope_plan_and_execute` | true | Plan/execute only work on scoped items |
| `incremental_phases.preserve_satisfied` | true | Never modify satisfied requirements during incremental update |
| `incremental_phases.add_spec_version_tag` | true | Tag new requirements with spec_version field |

---

# Chapter 21: Council-Based Requirements Verification

## 21.1 Overview

The standard Phase 0 (create-phases) uses a single Claude agent to extract requirements. Council-based verification uses a 3-phase parallel pipeline: partitioned extract, cross-verify, and synthesize. Each agent processes 1/3 of the spec files, then a different agent checks their work before Claude synthesizes the final matrix.

### Why Partitioned Extract + Cross-Verify?

- **Parallel execution**: All agents run simultaneously via `Start-Job` -- 2-3x faster than sequential
- **Partitioned workload**: Each agent reads only 1/3 of specs, chunked into batches of ~10 files -- fits within per-request token limits and avoids quota exhaustion
- **Cross-verification**: A different agent reviews each extraction, catching missed requirements and false positives
- **Agent specialization**: Claude focuses on architecture/compliance, Codex on implementation/patterns, Gemini on spec/Figma alignment
- **Confidence scoring**: Requirements confirmed by both extractor AND verifier = "high", added by verifier = "medium", unverified = "low"

## 21.2 Usage

```powershell
# Run standalone on any repo
cd D:\vscode\your-project
gsd-verify-requirements

# Options
gsd-verify-requirements -DryRun             # Preview file counts without running agents
gsd-verify-requirements -SkipAgent claude   # Skip agent (e.g., quota exhausted)
gsd-verify-requirements -SkipVerify         # Extract only, skip cross-verification phase
gsd-verify-requirements -PreserveExisting   # Backup and merge into existing matrix
gsd-verify-requirements -ChunkSize 5        # Smaller chunks per LLM call (default: 10)
```

## 21.3 How It Works

| Phase | Agents | Action | Execution |
|-------|--------|--------|-----------|
| 1. EXTRACT | Claude, Codex, Gemini | Each processes 1/3 of spec files in chunks of ~10 | Parallel (`Start-Job`) |
| 2. CROSS-VERIFY | Codex→checks Claude, Gemini→checks Codex, Claude→checks Gemini | Reads extraction + same source files, adds missed, corrects statuses, flags false positives | Parallel (`Start-Job`) |
| 3. SYNTHESIZE | Claude | Merges all verified outputs, deduplicates, assigns confidence scores | Sequential |
| Fallback | PowerShell | Local token-overlap merge if synthesis agent fails | Sequential |

### Cross-Verification Chain

```
Claude extracts  →  Codex verifies
Codex extracts   →  Gemini verifies
Gemini extracts  →  Claude verifies
```

Each verifier can: confirm requirements, add missed ones, correct statuses, and flag false positives.

### Confidence Scoring

| Level | Criteria | Meaning |
|-------|----------|---------|
| High | Confirmed by both extractor AND verifier | Requirement is real |
| Medium | Added or corrected by verifier | Likely real, verifier caught it |
| Low | Unverified (verifier failed/skipped) | Flagged for human review |

## 21.4 Output Files

| File | Description |
|------|-------------|
| `.gsd/health/requirements-matrix.json` | Final merged matrix with `confidence`, `found_by`, `verified_by` fields |
| `.gsd/health/council-extract-{agent}.json` | Combined per-agent extraction (all chunks merged) |
| `.gsd/health/council-extract-{agent}-chunk{N}.json` | Individual chunk outputs |
| `.gsd/health/council-verify-{agent}-by-{verifier}.json` | Cross-verification results |
| `.gsd/health/council-requirements-report.md` | Confidence breakdown and low-confidence items |
| `.gsd/health/health-current.json` | Initial health score |
| `.gsd/health/drift-report.md` | Not-started and partial requirements |

## 21.5 Schema Extensions

New fields added to each requirement (backward compatible):

```json
{
  "id": "REQ-001",
  "confidence": "high|medium|low",
  "found_by": ["claude", "codex", "gemini"],
  "verified_by": "codex"
}
```

New meta fields:

```json
{
  "meta": {
    "extraction_method": "council|single",
    "agents_participated": ["claude", "codex", "gemini"],
    "timestamp": "2026-03-05T10:00:00Z"
  }
}
```

## 21.6 Progress Monitoring and Notifications

The council pipeline sends **ntfy push notifications** at every phase transition and on chunk completion, with token cost breakdown:

| Event | Priority | Example Message |
|-------|----------|-----------------|
| Phase 1 start | default | "2 agents (codex, gemini) extracting from 195 spec files in parallel" |
| Chunk progress | low | "codex chunk 3/10 done (47 reqs so far)" |
| Phase 1 done | default | "codex OK / gemini OK" + cost breakdown |
| Phase 2 start | default | "2 extractions being cross-verified in parallel" |
| Phase 2 done | default | "Cross-verification complete" + cost |
| Phase 3 start | default | "Merging 2 agent outputs into requirements matrix" |
| Final result | high | "Requirements matrix: 245 requirements" + full cost |

The terminal also shows live progress by polling for chunk output files on disk every 15 seconds, plus heartbeat messages every 60 seconds showing agent job states.

The ntfy topic is auto-initialized to `gsd-{username}-{reponame}` or read from `global-config.json` → `notifications.ntfy_topic`.

## 21.7 Convergence Pipeline Integration

When `council_requirements.enabled = true` in `global-config.json`, the convergence pipeline Phase 0 automatically uses council extraction instead of single-agent. Falls back to single-agent if council fails.

### Configuration

```json
{
  "council_requirements": {
    "enabled": true,
    "agents": ["claude", "codex", "gemini"],
    "min_agents_for_merge": 2,
    "chunk_size": 10,
    "timeout_seconds": 600,
    "cooldown_between_agents": 5,
    "fallback_to_single": true
  }
}
```

## 21.8 Error Handling

| Scenario | Recovery |
|----------|----------|
| 1 agent fails extraction | Proceed with remaining; cross-verify what completed |
| Agent job times out | Check disk for partial output; recover if chunks were written |
| Verifier fails | Extraction accepted as-is (unverified, confidence = "low") |
| All agents fail | Fall back to single-agent create-phases |
| Synthesis fails | Local PowerShell merge (token-overlap Jaccard dedup) |
| Gemini CLI error | Uses `--approval-mode yolo` (not `full`). Check `~/.gemini/settings.json` if errors persist |

## 21.9 Cost Estimate

| Phase | Agent | Est. Cost (200 spec files) |
|-------|-------|-----------|
| Extract | Claude (1/3 files, ~7 chunks) | ~$0.50 |
| Extract | Codex (1/3 files, ~7 chunks) | ~$0.00 |
| Extract | Gemini (1/3 files, ~7 chunks) | ~$0.00 |
| Cross-Verify | 3 verifications | ~$0.30 |
| Synthesize | Claude | ~$0.07 |
| **Total** | | **~$0.87** |

Note: Costs scale with spec file count. Chunking into batches of 10 keeps each LLM call within token limits. Use `-SkipAgent claude` to reduce costs when Claude quota is exhausted (Codex + Gemini are free/cheap).

---

# Chapter 22: V3 Pipeline Architecture

## 22.1 Overview

The V3 pipeline is a 2-model, API-only convergence engine. Claude Sonnet handles all reasoning (research, plan, review, verify) and Codex Mini handles all code generation (execute), with 5 additional models in the execute rotation pool. V3 eliminates all CLI tool dependencies — every LLM interaction is a direct HTTP API call.

## 22.2 Model Architecture

### Reasoning Phases (Claude Sonnet)

| Phase | Model | Notes |
|-------|-------|-------|
| Cache Warm | claude-sonnet-4-6 | Warms cache prefix (90% input discount) |
| Spec Gate | claude-sonnet-4-6 | Spec validation + requirement extraction |
| Spec Align | claude-sonnet-4-6 | Drift detection |
| Research | claude-sonnet-4-6 | Configurable via phase_model_overrides |
| Plan | claude-sonnet-4-6 | Implementation planning + confidence scoring |
| Review | claude-sonnet-4-6 | Diff-based code review |
| Verify | claude-sonnet-4-6 | Satisfaction verification |

### Code Generation (7-Model Execute Pool)

| Model | Provider | Weight | Selection Frequency | Max Output Tokens |
|-------|----------|--------|--------------------|--------------------|
| Codex Mini | OpenAI | 3 | ~30% | 16,384 |
| DeepSeek Chat | DeepSeek | 2 | ~20% | 8,192 |
| Kimi | Moonshot AI | 1 | ~10% | 8,192 |
| MiniMax | MiniMax | 1 | ~10% | 8,192 |
| Claude Sonnet | Anthropic | 1 | ~10% | 8,192 |
| Gemini Flash | Google | 1 | ~10% | 8,192 |
| GLM-5 | Zhipu AI | 1 | ~10% | 8,192 |

Models without configured API keys are automatically excluded. Rate-limited models are rotated immediately.

### API Endpoints

| Model | Endpoint | Auth Header | Format |
|-------|----------|-------------|--------|
| Claude Sonnet | `https://api.anthropic.com/v1/messages` | `x-api-key` | Anthropic Messages |
| Codex Mini | `https://api.openai.com/v1/responses` | `Bearer` token | OpenAI Responses API (NOT /chat/completions) |
| DeepSeek | `https://api.deepseek.com/v1/chat/completions` | `Bearer` token | OpenAI-compatible |
| Kimi | `https://api.moonshot.ai/v1/chat/completions` | `Bearer` token | OpenAI-compatible |
| MiniMax | `https://api.minimax.io/v1/chat/completions` | `Bearer` token | OpenAI-compatible |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent` | API key param | Google AI |
| GLM-5 | `https://open.bigmodel.cn/api/paas/v4/chat/completions` | `Bearer` token | OpenAI-compatible |

### Model Pricing (per million tokens)

| Model | Input | Output | Cache Write | Cache Read |
|-------|-------|--------|-------------|------------|
| claude-sonnet-4-6 | $3.00 | $15.00 | $3.75 | $0.30 |
| gpt-5.1-codex-mini | $0.25 | $2.00 | — | — |
| deepseek-chat | $0.28 | $0.28 | — | — |
| moonshot-v1-8k | $0.20 | $2.00 | — | — |
| MiniMax-Text-01 | $0.20 | $1.10 | — | — |
| gemini-2.5-flash | $0.15 | $0.60 | — | — |
| glm-4-flash | $0.10 | $0.10 | — | — |

## 22.3 Convergence Loop Phases (10-Phase)

Each iteration executes these phases in sequence:

```
Phase 0:  Cache Warm          → Sonnet (warms prompt cache, 5-min TTL)
Phase 1:  Spec Gate           → Sonnet (extract/validate requirements)
Phase 1b: Spec Alignment      → Sonnet (drift detection, blocks >20%)
Phase 2:  Research            → Sonnet (analyze reqs, size estimates)
Phase 3:  Plan                → Sonnet (implementation plans, confidence scores)
Phase 4:  Execute-Skeleton    → Execute Pool (structural code, ~30% tokens)
Phase 5:  Execute-Fill        → Execute Pool (implementations, ~70% tokens)
Phase 6:  Local Validate      → No LLM (dotnet build, npm build, tsc)
Phase 7:  Review              → Sonnet (diff-based review)
Phase 8:  Verify              → Sonnet (satisfaction check)
```

### Two-Stage Execute

Execute is split into two passes:
1. **Skeleton** (Pass 1): Type definitions, interfaces, class stubs, function signatures (~30% token budget)
2. **Fill** (Pass 2): Function bodies, business logic, error handling, data access (~70% token budget)

The skeleton is validated for structural correctness before proceeding to fill.

## 22.4 Anti-Plateau Protection

| Consecutive Zero-Delta Iterations | Action |
|-----------------------------------|--------|
| 3 | Warning: flag stuck requirements (failed 3+ times) |
| 4 | Escalate: route stuck reqs to larger models, increase batch size |
| 5 | Force break: defer all stuck reqs, exit convergence, generate gap report |

Deferred requirements are re-checked every 10 iterations in case dependencies have been resolved.

## 22.5 Decomposition Budget

| Setting | Value | Purpose |
|---------|-------|---------|
| Max new sub-reqs per iteration | 20 | Prevents runaway sub-requirement explosion |
| Max depth | 4 | Limits decomposition nesting |
| Defer excess | Enabled | Excess sub-reqs deferred to next iteration |

Decomposition spiral prevention: when large files are blocked (e.g., App.tsx, Program.cs), requirements depending on them are NOT decomposed — they are marked "waiting for blocker file" instead.

## 22.6 Confidence-Gated Review

| Condition | Action |
|-----------|--------|
| Plan confidence >= 0.9 AND local validation passes | Skip Review entirely |
| Plan confidence >= 0.7 | Always send to Review |
| Trivial categories (CRUD, config, DTO, seed data, SQL views) | Eligible for review skip |

Reduces Sonnet API calls by 30-40% on typical projects.

## 22.7 Speculative Execution

When health is improving (delta > 0), the pipeline starts the next iteration's Research + Plan phases while the current iteration's Review is still in-flight. Provides ~40% speed improvement at ~2% wasted computation cost.

Automatically disabled when the pipeline stalls (zero delta).

## 22.8 Checkpoint and Recovery

Checkpoints are saved after each phase:

```json
{
  "iteration": 15,
  "phase": "execute-fill",
  "health": 72.5,
  "batch_size": 10,
  "mode": "feature_update",
  "cache_state": { "version": 3, "valid": true }
}
```

Resume from crash:

```powershell
pwsh -NoExit -Command "& gsd-update.ps1 -RepoRoot 'C:\repos\project' -StartIteration 15"
```

## 22.9 Pipeline Modes

| Mode | Budget Cap | Max Iterations | Batch Size | Phases Active |
|------|-----------|----------------|------------|---------------|
| greenfield | $100 | 50 | 3-15 | All (0→1→1b→2→3→4→5→6→7→8) |
| feature_update | $50 | 30 | 3-15 | Skip cache-warm |
| bug_fix | $25 | 20 | 1-5 | Skip cache-warm, spec-gate |
| existing_codebase | $10 | 15 | 3-10 | Deep extract + code inventory + targeted |

---

# Chapter 23: Full Pipeline Orchestrator

## 23.1 Overview

The Full Pipeline Orchestrator (`gsd-full-pipeline.ps1`) takes generated code from convergence and runs 5 sequential quality phases to produce production-ready code with developer handoff documentation. This is the final quality gate after the convergence pipeline reaches 100% health.

## 23.2 Phase Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    FULL PIPELINE ORCHESTRATOR                     │
│                                                                   │
│  Phase 1: WIRE-UP ──────────────────────────────────────────────│
│    Mock data scan │ Route-role matrix │ Integration wiring        │
│                                                                   │
│  Phase 2: CODE REVIEW ──────────────────────────────────────────│
│    Claude + Codex + Gemini consensus │ Auto-fix cycles           │
│                                                                   │
│  Phase 3: SMOKE TEST ───────────────────────────────────────────│
│    9-phase integration validation │ Tiered cost optimization     │
│                                                                   │
│  Phase 4: FINAL REVIEW ────────────────────────────────────────│
│    Post-smoke-test verification │ Lower severity threshold       │
│                                                                   │
│  Phase 5: HANDOFF ──────────────────────────────────────────────│
│    PIPELINE-HANDOFF.md │ All output files │ Phase summary table  │
└─────────────────────────────────────────────────────────────────┘
```

## 23.3 Parameters

```powershell
gsd-full-pipeline.ps1
    -RepoRoot <string>           # Mandatory: repository path
    -ConnectionString <string>   # SQL Server connection for DB validation
    -AzureAdConfig <string>      # JSON: {tenantId, clientId, audience, instance, scopes}
    -TestUsers <string>          # JSON array: [{username, password, roles}]
    -StartFrom <string>          # Resume point: wireup|codereview|smoketest|finalreview|handoff
    -MaxCycles <int>             # Review-fix cycles per phase (default: 3)
    -MaxReqs <int>               # Requirements per batch (default: 50)
    -SkipWireUp                  # Skip wire-up phase
    -SkipCodeReview              # Skip code review phase
    -SkipSmokeTest               # Skip smoke test phase
```

## 23.4 Phase Details

### Phase 1: Wire-Up

Detects integration gaps that code review alone cannot catch. Scans for:

- **Mock data patterns**: `useState([{...}])` hardcoded data, `const mockX = [...]`, TODO/FIXME markers, placeholder URLs, hardcoded credentials
- **Route-role matrix**: Maps every route → role → guard. Identifies unguarded routes, orphan navigation items, unused roles
- **Integration wiring**: Verifies controllers are discoverable, services registered in DI, connection strings configured, auth middleware ordered correctly, CORS policies set

### Phase 2: Code Review

3-model consensus review with automated fix cycles:

1. Send requirement + code to Claude, Codex, and Gemini in parallel
2. Aggregate issues by severity (critical/high/medium/low)
3. Issues found by multiple models receive higher confidence
4. Fix model (Claude by default) generates and applies corrections
5. Re-review until clean or MaxCycles reached

### Phase 3: Smoke Test

9-phase integration validation (see Chapter 24 for full details).

### Phase 4: Final Review

Second 3-model review pass after smoke test fixes have been applied. Uses a lower severity threshold to catch remaining low-level issues.

### Phase 5: Handoff

Auto-generates `PIPELINE-HANDOFF.md` with:
- Phase status/duration/summary table
- All output file paths (reviews, smoke test reports, gap reports, logs)
- Remaining issues (if any) with suggested next steps

## 23.5 Resumability

The pipeline is resumable via `-StartFrom`:

```powershell
# Skip wire-up and code review, start from smoke test
gsd-full-pipeline.ps1 -RepoRoot "C:\repo" -StartFrom smoketest
```

Phase status and duration are tracked in the pipeline log at `~/.gsd-global/logs/{repo}/full-pipeline-{timestamp}.log`.

## 23.6 Output Files

| File | Location | Content |
|------|----------|---------|
| Pipeline handoff | `PIPELINE-HANDOFF.md` (repo root) | Phase summary + all output paths |
| Review report | `.gsd/code-review/review-report.json` | Structured issues per requirement |
| Review summary | `.gsd/code-review/review-summary.md` | Human-readable findings |
| Smoke test report | `.gsd/smoke-test/smoke-test-report.json` | Per-phase validation results |
| Mock data scan | `.gsd/smoke-test/mock-data-scan.json` | Mock data patterns found |
| Route-role matrix | `.gsd/smoke-test/route-role-matrix.json` | RBAC gaps |
| Gap report | `.gsd/smoke-test/gap-report.md` | Integration issues |
| Pipeline log | `~/.gsd-global/logs/{repo}/full-pipeline-{ts}.log` | Centralized log |

---

# Chapter 24: Smoke Testing

## 24.1 Overview

The smoke test (`gsd-smoketest.ps1`) performs 9-phase integration validation to verify that generated code actually works at runtime — not just that files exist. It uses tiered LLM cost optimization to reduce costs by ~85% compared to using premium models for all checks.

## 24.2 Parameters

```powershell
gsd-smoketest.ps1
    -RepoRoot <string>           # Mandatory: repository path
    -ConnectionString <string>   # SQL Server connection for DB validation
    -MaxCycles <int>             # Fix attempts before stopping (default: 3)
    -FixModel <string>           # claude or codex (default: claude)
    -TestUsers <string>          # JSON array: [{username, password, roles}]
    -AzureAdConfig <string>      # JSON: {tenantId, clientId, audience, instance, scopes}
    -SkipBuild                   # Skip build validation phase
    -SkipDbValidation            # Skip database validation phase
    -CostOptimize <bool>         # Use tiered models (default: $true)
```

## 24.3 Nine Validation Phases

| # | Phase | Tier | Cost | What It Checks |
|---|-------|------|------|----------------|
| 1 | Build Validation | LOCAL | $0 | `dotnet build` + `npm run build` pass without errors |
| 2 | Database Validation | CHEAP | ~$0.05 | Tables, stored procedures, columns, FKs, migrations exist |
| 3 | API Smoke Test | MID | ~$0.10 | Controllers discoverable, middleware order, DI registration, CORS |
| 4 | Frontend Route Validation | LOCAL | $0 | Route-component mapping, lazy load imports resolve |
| 5 | Auth Flow Validation | MID | ~$0.10 | JWT/Azure AD config, auth guards, token refresh logic |
| 6 | Module Completeness | CHEAP | ~$0.05 | API + frontend + DB present per module |
| 7 | Mock Data Detection | LOCAL | $0 | Hardcoded data, TODO/FIXME, console.log, placeholder URLs |
| 8 | RBAC Matrix | LOCAL | $0 | Route → role → guard mapping, unguarded routes |
| 9 | Integration Gap Report | PREMIUM | ~$0.50 | Aggregated findings analysis + fix recommendations |

**Total estimated cost per run: ~$0.50-1.00** (vs $5-8 without tiered optimization)

## 24.4 Tiered LLM Cost Optimization

Four tiers route each task to the cheapest suitable model:

| Tier | Cost/1M Tokens | Models | Task Types |
|------|---------------|--------|------------|
| **LOCAL** | $0 | None (regex/file analysis) | Build validation, mock data scan, route parsing, RBAC matrix, placeholder detection |
| **CHEAP** | $0.14-0.21 | DeepSeek, Kimi, MiniMax | DB schema check, module completeness, config validation |
| **MID** | $1.50 | Codex Mini | API wiring check, auth flow check, DI registration check |
| **PREMIUM** | $9.00 | Claude Sonnet | Security review, gap report, fix generation, architecture analysis |

### Fallback Chains

```
CHEAP:   DeepSeek → Kimi → MiniMax → Codex Mini (mid-tier fallback)
MID:     Codex Mini
PREMIUM: Claude Sonnet only
```

### Cost Distribution

- ~60% of work is LOCAL (zero cost)
- ~20% of work uses CHEAP models ($0.14-0.28/M tokens)
- ~15% of work uses MID tier (~$1.50/M tokens)
- ~5% of work uses PREMIUM (fixes only, ~$9/M tokens)

## 24.5 Mock Data Detector

Scans for 12 patterns indicating incomplete integration:

| Pattern | Severity | Suggestion |
|---------|----------|------------|
| `useState([{...}])` hardcoded data | High | Replace with useQuery/useEffect + fetch |
| `const mockX = [...]` or `{...}` | High | Remove mock data; fetch from API |
| TODO/FIXME/HACK/XXX/FILL/PLACEHOLDER | Medium | Implement actual functionality |
| `console.log/error/warn/debug` | Low | Remove or use proper logger |
| Placeholder URLs (localhost, example.com) | Critical | Replace with real API base URL |
| Hardcoded credentials | Critical | Move to environment variables |
| `import ...mock` | High | Replace with real API service |
| `Promise.resolve([...])` | High | Replace with real fetch/axios |
| Placeholder DB connection string | Critical | Configure real database |
| Placeholder Azure AD config | Critical | Configure real Azure AD credentials |
| Hardcoded role assignment | Medium | Pull from auth token claims |

### Stub Detection

| Type | Description | Severity |
|------|-------------|----------|
| `empty_function` | `() => {}` | Medium |
| `static_hook` | Hook returns hardcoded data | High |
| `fake_service` | Service file with no HTTP calls | High |
| `not_implemented` | Throws NotImplementedException | High |
| `hardcoded_return` | Repository returns hardcoded list | High |
| `no_di` | Controller with no dependency injection | High |

Usage:

```powershell
. ./mock-data-detector.ps1
$results = Invoke-MockDataScan -RepoRoot "C:\repo" -OutputFile ".gsd/smoke-test/mock-data-scan.json"
# Returns: MockPatterns, StubImplementations, PlaceholderConfigs, Summary
```

## 24.6 Route-Role Matrix

Maps every route to its required roles and auth guards:

```powershell
$matrix = Build-RouteRoleMatrix -RepoRoot "C:\repo"
# Returns: Routes, Roles, RolePermissions, NavigationItems, Gaps, Summary
```

### Auto-Detection

The matrix builder auto-detects configuration files:

| File Type | Checked Locations |
|-----------|-------------------|
| Router | `src/App.tsx`, `src/router.tsx`, `src/routes.tsx`, `src/app/routes.tsx` |
| RBAC | `src/config/rbac.ts`, `src/config/roles.ts`, `src/auth/rbac.ts` |
| Navigation | `src/config/navigation.ts`, `src/config/sidebar.ts`, `src/components/Sidebar.tsx` |

### Gap Types

| Gap Type | Description | Severity |
|----------|-------------|----------|
| `unguarded_route` | Route has no auth guard | High |
| `orphan_nav` | Nav item with no matching route | High |
| `hidden_route` | Route exists but no nav entry | Medium |
| `empty_role` | Role has no accessible routes | High |
| `missing_file` | Router/RBAC/Nav file not found | Critical |

## 24.7 Output Files

| File | Content |
|------|---------|
| `.gsd/smoke-test/smoke-test-report.json` | Structured results per phase |
| `.gsd/smoke-test/smoke-test-summary.md` | Human-readable summary |
| `.gsd/smoke-test/gap-report.md` | Integration issues categorized by severity |
| `.gsd/smoke-test/mock-data-scan.json` | Mock data pattern findings |
| `.gsd/smoke-test/route-role-matrix.json` | Authorization matrix + gaps |

---

# Chapter 25: Wire-Up Phase and Integration Gap Prevention

## 25.1 Problem Statement

The convergence pipeline verifies that code files exist and match specifications. But file existence does not guarantee runtime functionality. A project can pass code review with 100% health yet fail to run because:

- Frontend components use hardcoded mock data instead of API calls
- Controllers exist but are not registered in DI
- Routes exist but have no auth guards
- Connection strings use placeholder values
- Auth middleware is in the wrong order

## 25.2 Wire-Up Verification Layers

### Backend Wiring

| Check | What It Verifies |
|-------|-----------------|
| Controller discovery | Correct namespace, `[ApiController]`, `[Route]` attributes |
| DI registration | `builder.Services.AddScoped<>()` for all services/repositories |
| Connection string | Real value in appsettings.json (not `Server=YOUR_SERVER`) |
| Auth middleware order | `UseAuthentication()` BEFORE `UseAuthorization()` |
| CORS policy | Frontend origin allowed |
| Health endpoint | `/api/health` or `/health` exists |
| Model/DTO matching | Property names match frontend expectations |

### Frontend Wiring

| Check | What It Verifies |
|-------|-----------------|
| Route registration | Every page component imported and routed in App.tsx |
| API base URL | From env config (not hardcoded `localhost:0000`) |
| Auth provider | Context/provider wraps app, provides tokens to API calls |
| Protected routes | Auth guards on protected routes (ProtectedRoute, RequireAuth) |
| Navigation | Correct items shown per role |
| Real API calls | Mock hooks replaced with real fetch/useQuery calls |

### Database Wiring

| Check | What It Verifies |
|-------|-----------------|
| Connection string | appsettings.json matches real database |
| Stored procedures | All SPs referenced in code exist in SQL files |
| Parameter matching | C# parameter names/types match SQL parameter names/types |
| Seed data | Lookup table seed scripts exist |

### Auth Wiring

| Check | What It Verifies |
|-------|-----------------|
| Config values | Azure AD/JWT has real values (not placeholder GUIDs) |
| Frontend auth | MSAL/auth provider configured |
| Token refresh | Refresh logic exists (not just initial auth) |
| Logout | Clears tokens and redirects |
| Role claims | Correctly mapped from token |

## 25.3 Wire-Up Output Schema

```json
{
  "wire_up_results": [
    {
      "layer": "backend | frontend | database | auth | cross-cutting",
      "component": "file path or component name",
      "status": "wired | broken | missing",
      "issue": "description if broken/missing",
      "fix": "exact code change needed",
      "severity": "critical | high | medium | low",
      "related_reqs": ["REQ-xxx"]
    }
  ],
  "summary": {
    "total_checked": 0,
    "wired": 0,
    "broken": 0,
    "missing": 0,
    "critical_issues": 0
  }
}
```

---

# Chapter 26: 3-Model Code Review with Auto-Fix

## 26.1 Overview

The code review system (`gsd-codereview.ps1`) uses 3-model consensus (Claude + Codex + Gemini) to identify issues, then auto-fixes them through iterative cycles. Issues found by multiple models receive higher confidence scores.

## 26.2 Parameters

```powershell
gsd-codereview.ps1
    -RepoRoot <string>           # Mandatory: repository path
    -Models <string>             # Comma-separated: "claude,codex,gemini" (default)
    -FixModel <string>           # claude or codex (default: claude)
    -MaxReqs <int>               # Requirements to review per run (default: 50)
    -MaxCycles <int>             # Review-fix cycles (default: 5)
    -MinSeverityToFix <string>   # critical|high|medium|low (default: medium)
    -ReviewOnly                  # Skip auto-fix, just report
    -Severity <string>           # Filter output: critical|high|medium|low|all (default: all)
    -OutputFormat <string>       # json or markdown (default: json)
    -SkipReqs <int>              # Skip first N requirements (default: 0)
    -RunSmokeTest                # After review, run smoke test automatically
    -ConnectionString <string>   # Passed to smoke test if -RunSmokeTest
    -TestUsers <string>          # Passed to smoke test if -RunSmokeTest
    -AzureAdConfig <string>      # Passed to smoke test if -RunSmokeTest
```

## 26.3 Review Workflow

```
Review Cycle N:
  ┌─────────────────────────────────────────────────┐
  │ Send requirement + code to Claude   ──► Issues  │
  │ Send requirement + code to Codex    ──► Issues  │
  │ Send requirement + code to Gemini   ──► Issues  │
  └──────────────────┬──────────────────────────────┘
                     │
                     ▼
  ┌─────────────────────────────────────────────────┐
  │ Aggregate issues by severity                     │
  │ Issues from 2+ models = higher confidence        │
  └──────────────────┬──────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        │ Critical/High found?    │
        │ YES                NO   │
        ▼                    ▼    │
  Fix model generates    Output   │
  corrections            report   │
        │                         │
        ▼                         │
  Apply fixes to files            │
        │                         │
        ▼                         │
  Re-review (Cycle N+1)          │
  (repeat until clean or          │
   MaxCycles reached)             │
  └───────────────────────────────┘
```

## 26.4 Severity Levels

| Severity | Level | Examples |
|----------|-------|---------|
| Critical | 4 | Missing auth, SQL injection, hardcoded secrets |
| High | 3 | Missing error handling, broken API contracts, no DI |
| Medium | 2 | Code style violations, missing validation, dead code |
| Low | 1 | Console.log statements, minor naming issues |

## 26.5 Output Schema

```json
{
  "model_results": {
    "claude": { "issues": [...], "passed": false },
    "codex": { "issues": [...], "passed": true },
    "gemini": { "issues": [...], "passed": false }
  },
  "aggregated_issues": [
    {
      "requirement_id": "REQ-001",
      "models_reporting": ["claude", "gemini"],
      "severity": "high",
      "category": "missing_implementation",
      "description": "...",
      "evidence": { "code": "...", "location": "..." },
      "fix_applied": true
    }
  ],
  "final_issues": 3,
  "passed": false
}
```

## 26.6 Output Files

| File | Content |
|------|---------|
| `.gsd/code-review/review-report.json` | Structured issues per requirement |
| `.gsd/code-review/review-summary.md` | Human-readable summary |

---

# Chapter 27: Existing Codebase Mode

## 27.1 Overview

Existing Codebase Mode (`gsd-existing.ps1`) is for repositories with significant existing code that needs verification against specifications. Instead of generating everything from scratch, it inventories existing code, maps it to requirements, and only executes against verified gaps.

## 27.2 When to Use

- A project was built manually and you need to assess spec compliance
- Code was generated by another tool and needs verification
- You inherited a codebase and need to identify gaps against specs
- You want to verify satisfaction before running a full pipeline

## 27.3 How It Differs from Other Modes

| Aspect | Greenfield | Feature Update | Existing Codebase |
|--------|-----------|----------------|-------------------|
| Starting point | No code | Working code + new specs | Code exists, unknown compliance |
| Primary goal | Build everything | Add new features | Verify and fill gaps |
| Spec-gate | Generate 36-100 reqs | Validate new sections | Deep-extract 400-600 reqs |
| Verification | File existence | File existence | Read actual code implementations |
| Execute phase | Generate everything | Build new features | Skip already-satisfied, fill gaps only |
| Typical cost | $50-400 | $50-400 | $5-10 |
| Typical duration | Hours | Hours | 15-30 minutes |

## 27.4 Parameters

```powershell
gsd-existing.ps1
    -RepoRoot <string>           # Mandatory: repository path
    -NtfyTopic <string>          # Notification topic (default: "auto")
    -SkipSpecGate                # Skip spec gate validation
    -DeepVerify <bool>           # Enable deep code reading (default: $true)
    -StartIteration <int>        # Resume from specific iteration (default: 1)
```

## 27.5 6-Phase Flow

```
spec-align → deep-extract → code-inventory → satisfaction-verify → targeted-execute → verify
```

| Phase | Purpose | LLM | Output |
|-------|---------|-----|--------|
| 1. Spec Align | Validate spec consistency, detect drift | Sonnet | Drift report |
| 2. Deep Extract | Extract requirements from ALL specs (not code) | Sonnet (16K-32K) | Deduplicated requirements matrix |
| 3. Code Inventory | Scan source files, detect stubs | Local + Sonnet | File-to-capability map |
| 4. Satisfaction Verify | Read actual code to verify each requirement | Sonnet | Status updates (satisfied/partial/not_started) |
| 5. Targeted Execute | Generate code only for gaps | 7-model pool | Source code files |
| 6. Verify | Final binary satisfaction check | Sonnet | Updated requirements matrix |

### Key Design Decision: Requirements from Specs, Not Code

Requirements are always extracted from specification documents, never from code. Code is used only as evidence of satisfaction. This prevents circular reasoning where the pipeline generates requirements that match existing code instead of identifying what the specs actually require.

## 27.6 Expected Cost

| Cost Component | Estimate |
|----------------|----------|
| Spec align + deep extract | $1-2 |
| Code inventory | $1-2 |
| Satisfaction verify | $1-3 |
| Targeted execute (gaps only) | $2-5 |
| **Total** | **$5-10** |

This is 10-80x cheaper than running a full greenfield or feature_update pipeline.

## 27.7 Direct Fixes Alongside Pipeline

Direct fixes via Claude Code are 10-100x more efficient than pipeline execution for small, well-understood gaps:

1. Run Existing Codebase Mode for discovery and verification
2. Review the gap list (requirements still at not_started or partial)
3. For simple gaps (missing imports, config values, small functions): fix directly
4. For complex gaps (new controllers, multi-file features): let the pipeline handle them
5. Re-run verification to confirm all gaps are closed

## 27.8 Configuration

```json
{
  "existing_codebase_mode": {
    "deep_extraction": true,
    "code_inventory_on_start": true,
    "verify_by_reading_code": true,
    "skip_satisfied_in_execute": true,
    "stub_detection_patterns": ["TODO", "FILL", "NotImplementedException", "throw new NotImplementedException"]
  }
}
```

## 27.9 Stub Detection Patterns

The code inventory phase scans for stubs that indicate incomplete implementation:

| Pattern | Language | Indicates |
|---------|----------|-----------|
| `NotImplementedException` | C# | Stub method |
| `throw new NotImplementedException` | C# | Placeholder method |
| `TODO` | Any | Incomplete implementation |
| `FILL` | Any | Placeholder value |
| `PLACEHOLDER` | Any | Temporary value |
| `() => {}` | TypeScript/JS | Empty function body |
| `return []` / `return {}` | TypeScript/JS | Hardcoded empty return |

---

# Chapter 28: LLM Pre-Validate Fix Phase

## 28.1 Overview

The LLM Pre-Validate Fix Phase (`gsd-validation-fixer.ps1`) runs BEFORE local build validation. It proactively detects and fixes common code generation errors (wrong namespaces, missing usings, non-existent types, stubs) to reduce downstream build failures.

### Previous Flow (wasteful)

```
Execute → Local Build (fails) → LLM Fix → Rebuild → (repeat)
```

### New Flow (proactive)

```
Execute → LLM Pre-Validate → Quick Namespace Fixes → Sonnet Review → Local Build (confirms) → Targeted Fix (remaining)
```

## 28.2 Parameters

```powershell
gsd-validation-fixer.ps1
    -RepoRoot <string>           # Mandatory: repository path
    -RequirementIds <string[]>   # Mandatory: requirement IDs to fix
    -MaxAttempts <int>           # Max fix attempts (default: 10)
    -PreValidate                 # Run in proactive mode (before local build)
```

## 28.3 Fix Attempt Loop

Each attempt runs these validators in order:

1. **C# Backend Build** — `dotnet build` in the server project
2. **TypeScript Type-check** — `npx tsc --noEmit`
3. **C# Test Build** — Tests compile
4. **Unit Tests** — Best effort, non-blocking

## 28.4 Quick Namespace Fixes (Zero LLM Cost)

The fixer applies regex-based namespace remapping for known disease patterns before invoking any LLM:

| Pattern | Replacement |
|---------|-------------|
| `using TcaiPlatform.GDPR(.Models)?;` | `using Technijian.Api.GDPR;` |
| `using TcaiPlatform.Auth;` | `using Technijian.Api.Auth;` |
| `using TcaiPlatform.Security;` | `using Technijian.Api.Security;` |
| `using System.Data.SqlClient;` | `using Microsoft.Data.SqlClient;` |
| `using Backend.Controllers;` | `using Technijian.Api.Controllers;` |
| `namespace TCAI.Controllers;` | `namespace Technijian.Api.Controllers;` |

(60+ patterns total for project-specific namespace remapping)

## 28.5 Multi-File Grouping

When multiple files have related errors, they are grouped for efficient LLM fixing:

- Groups error files by parent directory
- Detects shared imports/types across files
- Merges related groups for cross-file LLM fixes
- Max 5 files per LLM call (reduces API costs)

---

# Chapter 29: Centralized Logging and Iteration Tracking

## 29.1 Log Directory Structure

```
~/.gsd-global/logs/{repo-name}/
├── run-2026-03-24_100000.log              # Pipeline run log
├── run-2026-03-24_100000.json             # Structured run metadata
├── smoketest-2026-03-24_100100.log        # Smoke test log
├── codereview-2026-03-24_100200.log       # Code review log
├── full-pipeline-2026-03-24_100300.log    # Full pipeline log
├── latest.log                             # Symlink to latest run
├── iteration-counter.json                 # Persistent iteration counter
└── iterations/
    ├── iter-0001.json                     # Per-iteration metrics
    ├── iter-0002.json
    └── ...
```

## 29.2 Iteration Counter

Persistent across pipeline restarts and mode changes:

```json
{
  "next_iteration": 5,
  "repo": "tech-web-chatai.v8",
  "repo_root": "D:\\vscode\\tech-web-chatai.v8",
  "created": "2026-03-24T10:00:00Z"
}
```

## 29.3 Per-Iteration Log Schema

```json
{
  "iteration_number": 1,
  "global_iteration_number": 47,
  "health": { "start": 19.4, "end": 22.5, "delta": 3.1 },
  "cost": { "total": 5.32, "by_model": { "claude": 4.50, "codex": 0.82 } },
  "duration_minutes": 12.5,
  "batch_info": { "size": 10, "satisfied": 3, "partial": 5, "not_started": 2 },
  "decomposition": { "added": 2, "depth": 2 },
  "models_used": ["claude-sonnet-4-6", "gpt-5.1-codex-mini"],
  "phases": ["research", "plan", "execute", "local-validate"],
  "timestamp": "2026-03-24T10:01:30Z"
}
```

## 29.4 Console Output Format

```
ITERATION 5 / 50 (Global #47) | Health 19.4%→22.5% (+3.1%) | Cost $5.32 | 10 reqs | 12.5 min
```

## 29.5 Supervision Insights

Cross-session learning is recorded at `~/.gsd-global/logs/supervision-insights.md`:

- Disease patterns (e.g., "DI registration gaps cause 40% of failures")
- Fix effectiveness (e.g., "Namespace fixes have 85% success rate")
- Model performance (e.g., "DeepSeek better than Codex for >16K tokens")
- Cost optimization opportunities
- Common integration gaps

The monitoring system reads insights at session start, records observations during pipeline runs, and summarizes findings at end. Insights inform model routing, error anticipation, batch sizing, and cost alerts.

---

# Appendices

## Appendix A: Complete File Inventory

### Global Engine Files (~/.gsd-global/)

| Path | Description |
|------|-------------|
| `bin/gsd-converge.cmd` | Convergence loop CLI wrapper |
| `bin/gsd-blueprint.cmd` | Blueprint pipeline CLI wrapper |
| `bin/gsd-status.cmd` | Health dashboard CLI wrapper |
| `bin/gsd-remote.cmd` | Remote monitoring CLI wrapper |
| `bin/gsd-costs.cmd` | Token cost calculator CLI wrapper |
| `config/global-config.json` | Global settings |
| `config/agent-map.json` | Agent-to-phase mapping + parallel config |
| `config/model-registry.json` | Central agent registry (CLI + REST, endpoints, API keys, pricing) |
| `lib/modules/resilience.ps1` | Core resilience module (~2000+ lines) |
| `lib/modules/interfaces.ps1` | Multi-interface detection |
| `lib/modules/interface-wrapper.ps1` | Agent prompt context builder |
| `scripts/convergence-loop.ps1` | 5-phase convergence engine |
| `scripts/supervisor-converge.ps1` | Supervisor wrapper for convergence |
| `scripts/gsd-profile-functions.ps1` | PowerShell profile functions |
| `scripts/token-cost-calculator.ps1` | Token cost estimator |
| `blueprint/scripts/blueprint-pipeline.ps1` | Blueprint generation + build loop |
| `blueprint/scripts/supervisor-blueprint.ps1` | Supervisor wrapper for blueprint |
| `blueprint/scripts/assess.ps1` | Assessment script |
| `blueprint/prompts/codex/build.md` | Codex build prompt |
| `blueprint/prompts/codex/partial-repo-guide.md` | Partial repo handling guide |
| `prompts/claude/code-review.md` | Health scoring prompt |
| `prompts/claude/plan.md` | Batch prioritization prompt |
| `prompts/claude/verify.md` | Blueprint verification prompt |
| `prompts/claude/verify-storyboard.md` | Data flow verification prompt |
| `prompts/claude/assess.md` | Codebase assessment prompt |
| `prompts/claude/spec-clarity-check.md` | Spec quality audit prompt |
| `prompts/claude/cross-artifact-consistency.md` | Cross-reference validation prompt |
| `prompts/codex/execute.md` | Code generation prompt |
| `prompts/codex/execute-subtask.md` | Parallel sub-task prompt |
| `prompts/gemini/research.md` | Technical research prompt |
| `prompts/gemini/resolve-spec-conflicts.md` | Spec resolution prompt |
| `prompts/council/*.md` | 19 council review + requirements templates |
| `prompts/shared/security-standards.md` | 88+ OWASP security rules |
| `prompts/shared/coding-conventions.md` | .NET/React/SQL conventions |
| `prompts/shared/database-completeness-review.md` | DB chain verification rules |
| `prompts/shared/api-contract-validation.md` | API contract validation rules |
| `prompts/claude/code-review-differential.md` | Differential code review prompt |
| `prompts/codex/fix-compile-errors.md` | Pre-execute compile fix prompt |
| `intelligence/agent-scores-global.json` | Cross-project agent performance scores |
| `intelligence/pattern-cache.json` | Warm-start pattern cache by project type |
| `supervisor/pattern-memory.jsonl` | Cross-project failure patterns |
| `pricing-cache.json` | LLM pricing data |
| `KNOWN-LIMITATIONS.md` | Scenario matrix |
| `VERSION` | Installed version |

### V3 Pipeline Files (v3/)

| Path | Description |
|------|-------------|
| `v3/scripts/gsd-full-pipeline.ps1` | End-to-end quality orchestrator (5 phases) |
| `v3/scripts/gsd-smoketest.ps1` | 9-phase integration validation |
| `v3/scripts/gsd-codereview.ps1` | 3-model code review with auto-fix |
| `v3/scripts/gsd-existing.ps1` | Existing codebase verification pipeline |
| `v3/scripts/gsd-update.ps1` | Feature update convergence entry point |
| `v3/scripts/gsd-blueprint.ps1` | Greenfield build entry point |
| `v3/scripts/gsd-fix.ps1` | Bug fix mode entry point |
| `v3/scripts/gsd-validation-fixer.ps1` | LLM-assisted build error fixer |
| `v3/lib/modules/api-client.ps1` | Direct HTTP API client for all 7 models |
| `v3/lib/modules/phase-orchestrator.ps1` | 10-phase convergence loop engine |
| `v3/lib/modules/cost-tracker.ps1` | Per-phase, per-model cost tracking |
| `v3/lib/modules/mock-data-detector.ps1` | Mock data + stub + placeholder scanner |
| `v3/lib/modules/route-role-matrix.ps1` | RBAC route-role-guard matrix builder |
| `v3/config/global-config.json` | V3 pipeline configuration |
| `v3/config/model-tiers.json` | Tiered cost optimization model assignments |
| `v3/prompts/sonnet/01-spec-gate.md` | Spec validation + requirement extraction |
| `v3/prompts/sonnet/01b-spec-align.md` | Spec drift detection |
| `v3/prompts/sonnet/02-research.md` | Requirement analysis + size estimates |
| `v3/prompts/sonnet/03-plan.md` | Implementation planning + confidence scoring |
| `v3/prompts/sonnet/06-review.md` | Code review + integration verification |
| `v3/prompts/sonnet/07-verify.md` | Satisfaction verification |
| `v3/prompts/sonnet/08-smoke-test.md` | Smoke test phase instructions |
| `v3/prompts/sonnet/09-wire-up.md` | Wire-up verification checklist |
| `v3/prompts/sonnet/09-deep-extract.md` | Granular requirement extraction |
| `v3/prompts/sonnet/10-code-inventory.md` | Source file scan + stub detection |
| `v3/prompts/sonnet/11-verify-satisfaction.md` | Code reading verification |
| `v3/prompts/codex-mini/04a-execute-skeleton.md` | Structural code generation |
| `v3/prompts/codex-mini/04b-execute-fill.md` | Implementation fill |
| `v3/prompts/codex-mini/04b-execute-fill-bugfix.md` | Bug fix mode fill |
| `v3/prompts/shared/coding-conventions.md` | Project coding standards |
| `v3/prompts/shared/integration-checklist.md` | 5-layer integration checklist |
| `v3/prompts/shared/smoke-test-conventions.md` | Integration test patterns |
| `v3/prompts/shared/system-prompt.md` | Core system instructions |

### Centralized Logs (~/.gsd-global/logs/)

| Path | Description |
|------|-------------|
| `{repo-name}/run-{timestamp}.log` | Pipeline run log |
| `{repo-name}/run-{timestamp}.json` | Structured run metadata |
| `{repo-name}/smoketest-{timestamp}.log` | Smoke test log |
| `{repo-name}/codereview-{timestamp}.log` | Code review log |
| `{repo-name}/full-pipeline-{timestamp}.log` | Full pipeline log |
| `{repo-name}/latest.log` | Pointer to latest run |
| `{repo-name}/iteration-counter.json` | Persistent iteration counter |
| `{repo-name}/iterations/iter-NNNN.json` | Per-iteration metrics |
| `supervision-insights.md` | Cross-session learning |

## Appendix B: Prompt Templates

| Template | Agent | Purpose | Approx. Output |
|----------|-------|---------|----------------|
| `claude/code-review.md` | Claude | Score health, update statuses | ~3K tokens |
| `claude/plan.md` | Claude | Prioritize batch, write instructions | ~2K tokens |
| `claude/verify.md` | Claude | Binary file existence check | ~2K tokens |
| `claude/verify-storyboard.md` | Claude | End-to-end data flow verification | ~3K tokens |
| `claude/assess.md` | Claude | Codebase assessment | ~5K tokens |
| `claude/spec-clarity-check.md` | Claude | Spec quality scoring | ~2K tokens |
| `claude/cross-artifact-consistency.md` | Claude | Cross-reference validation | ~2K tokens |
| `codex/execute.md` | Codex | Code generation (convergence) | ~65K tokens |
| `codex/execute-subtask.md` | Codex | Parallel sub-task generation | ~20K tokens |
| `codex/build.md` | Codex | Code generation (blueprint) | ~80K tokens |
| `gemini/research.md` | Gemini | Technical research (read-only) | ~20K tokens |
| `gemini/resolve-spec-conflicts.md` | Gemini | Spec contradiction resolution | ~5K tokens |
| `council/codex-review.md` | Codex | Implementation quality review | ~2K tokens |
| `council/gemini-review.md` | Gemini | Requirements alignment review | ~2K tokens |
| `council/claude-synthesize.md` | Claude | Consensus synthesis | ~1K tokens |
| `council/openai-compat-review.md` | REST agents | Generic implementation quality review | ~2K tokens |
| `claude/code-review-differential.md` | Claude | Differential (changed files only) review | ~2K tokens |
| `codex/fix-compile-errors.md` | Codex | Pre-execute compile error fix | ~5K tokens |
| `shared/api-contract-validation.md` | Reference | API contract validation rules | N/A |
| `claude/create-phases.md` | Claude | Phase 0: build requirements matrix from specs | ~5K tokens |
| `claude/create-phases-incremental.md` | Claude | Phase 0: add new requirements to existing matrix | ~5K tokens |
| `council/requirements-extract-claude.md` | Claude | Architecture & compliance requirements extraction | ~5K tokens |
| `council/requirements-extract-codex.md` | Codex | Implementation & code gap requirements extraction | ~5K tokens |
| `council/requirements-extract-gemini.md` | Gemini | Spec & Figma alignment requirements extraction | ~5K tokens |
| `council/requirements-synthesize.md` | Claude | 3-agent merge, dedup, and confidence scoring | ~5K tokens |
| `council/requirements-synthesize-partial.md` | Claude | 2-agent fallback synthesis (max medium confidence) | ~5K tokens |

## Appendix C: Notification Events

| Event | Trigger | Content |
|-------|---------|---------|
| `iteration_complete` | End of each iteration | Health score, iteration count, costs |
| `no_progress` | Zero health improvement | Warning, stall count |
| `execute_failed` | Execute phase failed all retries | Error details |
| `build_failed` | Post-execute build check failed | Build errors |
| `regression_reverted` | Health dropped >5% | Previous/new scores |
| `converged` | 100% health + validation passed | Final costs, time elapsed |
| `stalled` | Stall threshold reached | Health score, attempts |
| `quota_exhausted` | All quota retries exhausted | Agent, wait time |
| `error` | Unrecoverable error | Error category, message |
| `heartbeat` | Every 60 seconds during agent calls | Phase, agent, health, costs |
| `agent_timeout` | 30-minute watchdog triggered | Agent, phase |
| `progress_response` | Response to "progress" command | Full status + costs |
| `supervisor_active` | Supervisor recovery started | Attempt number |
| `supervisor_diagnosis` | Root cause identified | Category, root cause |
| `supervisor_fix` | Fix applied | Fix description |
| `supervisor_restart` | Pipeline restarting | Attempt number |
| `supervisor_recovered` | Supervisor fixed the issue | Total attempts |
| `supervisor_escalation` | Max attempts exhausted | Escalation report |
| `validation_failed` | Final validation check failed | Failed checks |
| `validation_passed` | All validation checks passed | Summary |

## Appendix D: Error Categories

| Category | Description | Auto-Recovery |
|----------|-------------|---------------|
| `quota` | API quota exhausted | Exponential backoff + agent rotation |
| `network` | Network connectivity lost | 30s polling until restored |
| `disk` | Insufficient disk space | Alert, pause execution |
| `corrupt_json` | Agent returned invalid JSON | Rollback, retry with smaller batch |
| `boundary_violation` | Agent wrote to forbidden path | Revert changes, re-prompt |
| `agent_crash` | Agent process crashed (exit code != 0) | Retry with batch reduction |
| `health_regression` | Health dropped >5% after iteration | Git revert, restore checkpoint |
| `spec_conflict` | Specification contradictions detected | Auto-resolve via Gemini or block |
| `watchdog_timeout` | Agent exceeded 30-minute timeout | Kill process, retry |
| `build_fail` | Compilation or build failed | Dispatch Codex to fix |
| `fallback_success` | Primary agent failed, fallback worked | Log and continue |
| `validation_fail` | Final validation check failed | Set health to 99%, loop back |

## Appendix E: Glossary

| Term | Definition |
|------|-----------|
| **Convergence** | The process of iteratively fixing code until it matches specifications (health reaches 100%) |
| **Blueprint** | A manifest listing every file a project needs, generated from specs and Figma |
| **Health Score** | Percentage of requirements satisfied (0-100%) |
| **Iteration** | One complete pass through all pipeline phases |
| **Batch Size** | Number of requirements addressed per execute/build cycle |
| **Stall Threshold** | Consecutive zero-progress iterations before declaring stalled |
| **Supervisor** | Outer recovery loop that diagnoses and fixes pipeline failures |
| **Council** | Multi-agent review gate where Codex + Gemini review and Claude synthesizes verdict |
| **Agent Override** | Supervisor-assigned phase-to-agent reassignment |
| **Checkpoint** | Saved state for crash recovery |
| **Pattern Memory** | Cross-project database of failure patterns and successful fixes |
| **Escalation** | When supervisor exhausts all recovery attempts and needs human intervention |
| **Figma Make** | Tool that generates 12 analysis deliverables and 3 SQL stubs from Figma designs |
| **Quality Gate** | Automated check that must pass before pipeline proceeds |
| **Spec Clarity Score** | 0-100 rating of specification quality (ambiguity, completeness, testability) |
| **Token Budget** | Estimated token usage per phase/iteration for cost planning |
| **Developer Handoff** | Auto-generated markdown document with everything needed to continue development |
| **Drift Report** | Analysis of how requirements have changed since last iteration |
| **Heartbeat** | 60-second periodic status update during long agent calls |
| **Agent Cooldown** | Temporary lockout of an agent after consecutive quota failures |
| **Chunked Review** | Breaking large requirement sets into smaller groups for focused council reviews |
| **Model Registry** | Central JSON config (model-registry.json) defining all 7 agents with type, endpoint, API key, pricing |
| **REST Agent** | OpenAI-compatible API agent (Kimi, DeepSeek, GLM-5, MiniMax) invoked via HTTP instead of CLI |
| **Rotation Pool** | Ordered list of agents available for failover when current agent hits quota limits |
| **Interface Auto-Detection** | Automatic discovery of API (.sln/.csproj) and Database (.sql) components from project structure |
| **Component Architecture** | Three-layer project model: UI Interfaces → REST API → Database |
| **Full Pipeline** | 5-phase post-convergence quality gate: wire-up → code review → smoke test → final review → handoff |
| **Smoke Test** | 9-phase integration validation (build, DB, API, routes, auth, modules, mock data, RBAC, gap report) |
| **Wire-Up** | Verification that all layers are integrated (backend DI, frontend routes, auth, database connections) |
| **Mock Data Detector** | Scanner that identifies hardcoded data, TODOs, placeholder URLs, and stub implementations |
| **Route-Role Matrix** | RBAC visibility map: every route → required roles → auth guards, with gap detection |
| **Tiered Cost Optimization** | 4-tier model routing (local/cheap/mid/premium) that reduces smoke test costs ~85% |
| **3-Model Consensus** | Code review pattern: Claude + Codex + Gemini review independently, issues from 2+ models get higher confidence |
| **Execute Pool** | 7-model weighted round-robin pool for code generation (Codex 3x, DeepSeek 2x, others 1x) |
| **Anti-Plateau** | Graduated escalation when health score stops improving (warn → escalate → force break) |
| **Decomposition Budget** | Limit on sub-requirements per iteration (max 20) and nesting depth (max 4) to prevent explosion |
| **Spec Alignment Guard** | Pre-pipeline check that blocks execution if specs have drifted >20% from requirements matrix |
| **Confidence-Gated Review** | Optimization that skips Sonnet review for high-confidence (>=0.9), locally-validated changes |
| **Pre-Validate Fix** | LLM-assisted error fixing that runs before local build to reduce downstream failures |
| **Supervision Insights** | Cross-session learning file that records disease patterns, fix effectiveness, and model performance |
| **Existing Codebase Mode** | Pipeline mode for verifying existing code against specs: deep extract → inventory → verify → targeted fix |
| **Centralized Logging** | Global log directory (~/.gsd-global/logs/) with per-repo, per-run, and per-iteration structured logs |

---

## Appendix F: Constants and Defaults

| Constant | Default | Description |
|----------|---------|-------------|
| `SUPERVISOR_MAX_ATTEMPTS` | 5 | Max recovery attempts before escalation |
| `SUPERVISOR_TIMEOUT_HOURS` | 24 | Wall-clock time limit for supervisor |
| `AGENT_WATCHDOG_MINUTES` | 30 | Watchdog timeout per agent call |
| `RETRY_MAX` | 3 | Max retries per agent call |
| `MIN_BATCH_SIZE` | 2 | Minimum batch size after reduction |
| `BATCH_REDUCTION_FACTOR` | 0.5 | Batch reduction on failure |
| `RETRY_DELAY_SECONDS` | 10 | Delay between retries |
| `LOCK_STALE_MINUTES` | 120 | Lock file age before auto-reclaim |
| `HEALTH_REGRESSION_THRESHOLD` | 5 | Max % drop before revert |
| `QUOTA_CUMULATIVE_MAX_MINUTES` | 120 | Total quota wait cap |
| `QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE` | 1 | Failures before agent switch (reduced from 3 by multi-model patch) |
| `HEARTBEAT_INTERVAL_SECONDS` | 60 | ntfy heartbeat frequency |

### Default Batch Sizes

| Pipeline | Default | Description |
|----------|---------|-------------|
| Blueprint (`-BatchSize`) | 15 | Items per build cycle |
| Convergence (`-BatchSize`) | 8 | Items per execute cycle |

### V3 Pipeline Constants

| Constant | Default | Description |
|----------|---------|-------------|
| `DECOMP_MAX_PER_ITERATION` | 20 | Max new sub-requirements per iteration |
| `DECOMP_MAX_DEPTH` | 4 | Max decomposition nesting depth |
| `ANTI_PLATEAU_WARN` | 3 | Zero-delta iterations before warning |
| `ANTI_PLATEAU_ESCALATE` | 4 | Zero-delta iterations before model escalation |
| `ANTI_PLATEAU_BREAK` | 5 | Zero-delta iterations before force break |
| `CONFIDENCE_SKIP_THRESHOLD` | 0.9 | Plan confidence to skip review |
| `SPEC_DRIFT_WARN` | 5% | Drift threshold for warning |
| `SPEC_DRIFT_BLOCK` | 20% | Drift threshold for pipeline block |
| `CACHE_TTL_MINUTES` | 5 | Prompt cache time-to-live |
| `CODEREVIEW_MAX_CYCLES` | 5 | Max review-fix cycles |
| `CODEREVIEW_MIN_SEVERITY` | medium | Minimum severity to auto-fix |
| `SMOKETEST_MAX_CYCLES` | 3 | Max smoke test fix attempts |
| `VALIDATION_FIXER_MAX_ATTEMPTS` | 10 | Max build fix attempts |
| `VALIDATION_FIXER_GROUP_SIZE` | 5 | Max files per LLM fix call |
| `PER_REQ_COST_WARN` | $2.00 | Cost warning threshold per requirement |
| `PER_REQ_COST_ESCALATE` | $5.00 | Cost escalation threshold per requirement |
| `PER_REQ_COST_HARD_CAP` | $10.00 | Hard cost cap per requirement |

---

*Generated from GSD Engine v3.0.0 source documentation, scripts, and standards prompt templates.*
*V3 scripts: gsd-full-pipeline.ps1, gsd-smoketest.ps1, gsd-codereview.ps1, gsd-existing.ps1, gsd-validation-fixer.ps1, mock-data-detector.ps1, route-role-matrix.ps1, cost-tracker.ps1, phase-orchestrator.ps1, api-client.ps1*
*V2 scripts: 42 (1 master installer + 1 pre-flight + 36 installer scripts + 4 standalone utilities)*
*Chapters: 29 + 6 Appendices | Security rules: 88+ | Compliance frameworks: 4 (HIPAA, SOC 2, PCI DSS, GDPR) | Validation gates: 14 + 9 smoke test phases*
