---
title: "GSD Autonomous Development Engine - Developer Guide"
version: "1.1.0"
date: "2026-03-03"
classification: "Confidential - Internal Use Only"
---

# GSD Autonomous Development Engine

## Developer Guide

**Version 1.1.0** | March 2026

*Confidential - Internal Use Only*

---

### Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | February 2026 | Initial release |
| 1.1.0 | March 2026 | Codex CLI update (`codex exec --full-auto`), multi-agent cost tracking, supervisor pattern memory, false convergence fix, API key management |

---

### Table of Contents

- [Chapter 1: Introduction](#chapter-1-introduction)
- [Chapter 2: Architecture](#chapter-2-architecture)
- [Chapter 3: Installation](#chapter-3-installation)
- [Chapter 4: Usage Guide](#chapter-4-usage-guide)
- [Chapter 5: Resilience and Self-Healing](#chapter-5-resilience-and-self-healing)
- [Chapter 6: Configuration Reference](#chapter-6-configuration-reference)
- [Chapter 7: Multi-Interface Support](#chapter-7-multi-interface-support)
- [Chapter 8: Script Reference](#chapter-8-script-reference)
- [Chapter 9: Troubleshooting](#chapter-9-troubleshooting)
- [Chapter 10: Cost Management](#chapter-10-cost-management)
- [Appendix A: Complete File Inventory](#appendix-a-complete-file-inventory)
- [Appendix B: Prompt Templates](#appendix-b-prompt-templates)
- [Appendix C: Notification Events](#appendix-c-notification-events)
- [Appendix D: Error Categories](#appendix-d-error-categories)
- [Appendix E: Glossary](#appendix-e-glossary)

---

## Chapter 1: Introduction

### 1.1 Why We Built This

Traditional AI-assisted development is manual, fragile, and fundamentally stateless. The typical workflow involves a developer copying requirements into a prompt, waiting for generated code, manually reviewing the output, fixing issues, and repeating the cycle. There is no memory between sessions -- context evaporates the moment a chat window closes. There is no recovery from failures -- a single quota timeout, network glitch, or malformed response kills the entire session and forces the developer to start over. There is no way to verify completeness against specifications -- the developer must manually cross-reference every requirement, every Figma design, every acceptance criterion against what was actually produced. This approach does not scale beyond trivial projects.

The GSD Engine automates the entire develop-review-fix loop. It orchestrates three AI agents -- Claude Code for reasoning and analysis, Codex CLI for code generation, and Gemini CLI for research and spec-fixing -- assigning each to the tasks they do best, and runs autonomously until the codebase matches specifications. It handles crashes, quota limits, network failures, and agent errors without human intervention. When the engine detects a stall (health score stops improving), a self-healing supervisor diagnoses the root cause, modifies prompts, reduces batch sizes, reassigns agents, and restarts the pipeline -- up to five recovery attempts before escalating to a human with a detailed diagnosis report. The engine maintains full state across interruptions: you can Ctrl+C mid-run, transfer to a different workstation, or lose power entirely, and it resumes exactly where it left off.

The result: a developer writes specifications, runs one command, and returns to a fully built, verified, compliant codebase. What used to take weeks of manual AI-assisted development happens overnight. The engine tracks actual API token costs across every agent call, generates developer handoff reports documenting what was built and why, and sends push notifications to your phone so you can monitor progress from anywhere. When the health score reaches 100% and final validation passes, you receive a notification with a complete summary -- ready for human review and deployment.

### 1.2 Design Philosophy

- **Specification-Driven**: Code matches specs, not the other way around. A requirements matrix tracks every item from SDLC documents and Figma designs all the way to code, with statuses updated automatically each iteration.
- **Token-Optimized Agent Assignment**: Claude (expensive, excellent at judgment) handles review, plan, and verify phases. Codex (cheaper, excellent at generation) handles execute and build phases. Gemini (separate quota pool entirely) handles research and spec-fix. Each agent draws from an independent API quota, maximizing throughput.
- **Self-Healing**: The engine retries with automatic batch reduction, maintains checkpoint/resume state for crash recovery, rolls back on health regression, and employs a supervisor with cross-project pattern memory that learns from previous failures across all your projects.
- **Idempotent**: Safe to re-run at any time. Safe to interrupt with Ctrl+C and resume. Safe to transfer between workstations via git. The .gsd/ state folder travels with the repository.
- **Observable**: Health scores track progress from 0% to 100%. Push notifications via ntfy.sh deliver real-time updates. Remote monitoring via QR code lets you watch from your phone. Actual cost tracking per agent call provides full transparency into API spend.

### 1.3 What Was Built

The GSD Engine provides three core capabilities, each optimized for a different development scenario:

| Capability | Command | Best For | Pipeline |
|---|---|---|---|
| Assess | `gsd-assess` | Understanding an existing codebase | One-time scan |
| Converge | `gsd-converge` | Fixing existing code toward spec compliance | 5-phase iterative loop |
| Blueprint | `gsd-blueprint` | Building new code from specs (greenfield) | 3-phase generation pipeline |

**Assess** performs a deep inventory of your codebase -- cataloging every backend endpoint, database object, frontend component, and their relationships -- and classifies each item as skip, fix, build, or review. It produces a work classification that feeds directly into the convergence loop or blueprint pipeline.

**Converge** is the iterative engine for existing codebases. It reviews code against specifications, plans the next batch of fixes, executes them, and loops until health reaches 100%. Each iteration commits to git with the current health score, providing a full audit trail.

**Blueprint** is the generation engine for greenfield projects. It reads all specifications and Figma designs, produces a complete project manifest (every file that needs to exist), then generates and verifies in batches until the entire manifest is built.

Supporting tools complement the core pipelines:

- `gsd-status` -- Health dashboard showing current score, phase, iteration count, and recent history
- `gsd-costs` -- Cost estimation before a run and actual cost tracking during/after
- `gsd-init` -- Initialize the .gsd/ folder for a new project
- `gsd-remote` -- Launch remote monitoring with a QR code for phone access

### 1.4 Three-Model Strategy

| Agent | Role | Phases | Token Budget |
|---|---|---|---|
| Claude Code | Reasoning, analysis, architectural judgment | Review, Plan, Verify, Blueprint, Assess | ~11K tokens/iteration |
| Codex CLI | Fast code generation, bulk operations | Execute, Build, Research (fallback) | Unlimited |
| Gemini CLI | Research, spec-fix (optional, separate quota) | Research, Spec-fix | Unlimited |

Each agent draws from an independent API quota pool -- exhausting your OpenAI quota does not affect Claude operations, and vice versa. Gemini is optional; if unavailable, the engine falls back to Codex for research and spec-fix phases. This three-model strategy maximizes throughput while keeping Claude costs under control: Claude performs only the high-judgment work (review, plan, verify) where its reasoning capabilities justify the cost, while Codex handles the high-volume code generation where raw output speed matters most.

---

## Chapter 2: Architecture

### 2.1 System Overview

The GSD Engine runs entirely on your local developer workstation. It reads specifications (SDLC documents, Figma analysis files, and stub definitions), orchestrates AI agents through a PowerShell-based engine, and writes all state to the per-project .gsd/ folder. There is no server component, no cloud infrastructure, and no data leaves your machine except the API calls to the AI providers themselves. Push notifications are sent via ntfy.sh (a lightweight pub/sub service) so you can monitor from your phone, but this is optional and carries no sensitive data.

```
┌─────────────────────────────────────────────────────────────────┐
│                     DEVELOPER WORKSTATION                        │
│                                                                  │
│   Specifications          GSD Engine              AI Agents      │
│   ┌──────────┐      ┌──────────────────┐    ┌────────────────┐  │
│   │ SDLC     │─────>│ PowerShell       │───>│ Claude Code    │  │
│   │ Phase A-E│      │ Orchestrator     │    │ (Review, Plan) │  │
│   ├──────────┤      │                  │    ├────────────────┤  │
│   │ Figma    │─────>│ Convergence Loop │───>│ Codex CLI      │  │
│   │ _analysis│      │ Blueprint Pipe   │    │ (Execute,Build)│  │
│   ├──────────┤      │ Supervisor       │    ├────────────────┤  │
│   │ Stubs    │─────>│ Resilience Module│───>│ Gemini CLI     │  │
│   │ _stubs/  │      └──────────────────┘    │ (Research)     │  │
│   └──────────┘             │                └────────────────┘  │
│                            │                                     │
│                     ┌──────▼──────┐     ┌──────────────┐        │
│                     │ .gsd/ State │     │ ntfy.sh      │        │
│                     │ Health,Logs │     │ Push Notify  │        │
│                     │ Checkpoint  │     │ Phone Monitor│        │
│                     └─────────────┘     └──────────────┘        │
└─────────────────────────────────────────────────────────────────┘
```

The orchestrator manages the full lifecycle: reading specs, selecting the appropriate agent for each phase, building context-rich prompts via the interface wrapper, invoking agents, parsing their output, updating state, handling errors, and committing results to git. The resilience module provides retry logic, checkpoint/resume, file locking, batch reduction, cost tracking, and push notifications. The supervisor wraps the entire pipeline and provides self-healing recovery when the engine stalls.

### 2.2 Agent Assignment

Each phase of the engine is assigned to the agent best suited for the task. The assignment is configurable via `agent-map.json`, and the supervisor can dynamically reassign phases during recovery.

**Phase-to-Agent Mapping:**

| Phase | Agent | Why | Output Tokens |
|---|---|---|---|
| Code Review | Claude Code | Superior architectural analysis and spec compliance judgment | ~3,000 |
| Create Phases | Claude Code | One-time requirement extraction demanding precise interpretation | ~5,000 |
| Research | Gemini (fallback: Codex) | Thorough analysis benefits from separate quota pool | ~10,000+ |
| Plan | Claude Code | Strategic planning and dependency ordering require strong reasoning | ~3,000 |
| Execute | Codex (fallback: Claude) | Fast bulk code generation at lower cost per token | ~50,000+ |
| Blueprint | Claude Code | Spec-to-manifest generation requires comprehensive understanding | ~5,000 |
| Build | Codex (fallback: Claude) | High-volume code generation from blueprint items | ~80,000+ |
| Verify | Claude Code | Spec compliance checking demands precise judgment | ~3,000 |
| Spec-Fix | Gemini (fallback: Codex) | Auto-resolving spec contradictions on a separate quota | ~2,000 |

**Agent Boundary Enforcement:**

| Domain | Claude Code | Codex | Gemini |
|---|---|---|---|
| Source code | READ only | READ + WRITE | READ only |
| .gsd/health/ | READ + WRITE | READ only | READ only |
| .gsd/research/ | READ only | READ + WRITE | READ + WRITE |
| .gsd/agent-handoff/ | WRITE assignment | APPEND log | -- |
| docs/ | READ only | READ only | READ only |

These boundaries are enforced through prompt instructions and the interface wrapper. Claude never modifies source code directly -- it writes analysis and instructions that Codex then executes. This separation ensures that the expensive reasoning agent is never wasted on bulk file operations, and the fast generation agent never makes unsupervised architectural decisions.

### 2.3 Convergence Loop (5-Phase)

The convergence loop is the core engine for iteratively improving an existing codebase toward full specification compliance. Each iteration runs all five phases in sequence, commits the results to git, and loops until the health score reaches 100%, a stall is detected, or the maximum iteration count is reached.

```
┌─────────────────────────────────────────────────┐
│            GSD CONVERGENCE LOOP                  │
│                                                  │
│  1. CODE REVIEW    ──> Claude Code (~3K tokens)  │
│     Scan repo vs requirements matrix             │
│     Score health, update statuses                │
│          │                                       │
│  2. CREATE PHASES  ──> Claude Code (~5K tokens)  │
│     One-time: Extract requirements from specs    │
│     (skipped after iteration 1)                  │
│          │                                       │
│  3. RESEARCH       ──> Gemini/Codex (~10K+ tok)  │
│     Deep-read specs, Figma, codebase             │
│     Build dependency maps, patterns              │
│          │                                       │
│  4. PLAN           ──> Claude Code (~3K tokens)  │
│     Select next 3-8 requirements                 │
│     Write execution instructions                 │
│          │                                       │
│  5. EXECUTE        ──> Codex (~50K+ tokens)      │
│     Generate code for the batch                  │
│     Build validation + auto-fix                  │
│          │                                       │
│     git commit ──> Loop back to 1                │
│                                                  │
│  Exit when: health=100% + validation passes      │
│         or: stall threshold reached              │
│         or: max iterations reached               │
└─────────────────────────────────────────────────┘
```

**Phase 1: Code Review** (Claude Code)
Scans every requirement in the requirements matrix against the current codebase. Updates each requirement's status to one of: `satisfied`, `partial`, or `not_started`. Calculates the health score as `satisfied / total * 100`. Writes three output files: `health-current.json` (machine-readable score and breakdown), `drift-report.md` (human-readable gaps between specs and code, max 50 lines), and `review-current.md` (detailed findings, max 100 lines). If the health score reaches 100%, the engine triggers the final validation gate.

**Phase 2: Create Phases** (Claude Code)
One-time extraction of all requirements from SDLC documents and Figma designs into `requirements-matrix.json`. This phase runs on the first iteration or when specifications change, and is skipped on subsequent iterations. It maps every requirement to a structured record containing: id, source document, description, current status, dependencies on other requirements, and priority level.

**Phase 3: Research** (Gemini, fallback: Codex)
Deep analysis of the codebase, specifications, Figma designs, and dependency relationships. The research agent reads broadly -- examining code patterns, identifying architectural conventions, mapping data flows, and noting spec ambiguities. Output is written to `.gsd/research/` and is consumed by the Plan phase. This phase can be skipped with the `-SkipResearch` flag.

**Phase 4: Plan** (Claude Code)
Selects the next batch of 3-8 requirements to implement or fix. Priority ordering follows these rules: resolve dependencies first, follow SDLC phase order (A through E), build backend before frontend, and group related items together to minimize context switching. Output is `queue-current.json` (machine-readable batch) and `current-assignment.md` (detailed instructions for the execute agent).

**Phase 5: Execute** (Codex, fallback: Claude)
Generates all code for the planned batch. Produces full, production-ready files following the project's established patterns. After code generation, build validation runs automatically (`dotnet build` for backend, `npm run build` for frontend). If the build fails, the agent attempts auto-fix (up to 3 attempts). On success, the engine commits to git with a message containing the current health score and iteration number.

### 2.4 Blueprint Pipeline (3-Phase)

The blueprint pipeline is optimized for greenfield projects where most or all code needs to be generated from scratch. Instead of iteratively reviewing and fixing, it generates a complete project manifest upfront and then builds and verifies in batches.

```
┌─────────────────────────────────────────────────┐
│           GSD BLUEPRINT PIPELINE                 │
│                                                  │
│  1. BLUEPRINT      ──> Claude Code (~5K tokens)  │
│     Read all specs + Figma                       │
│     Generate blueprint.json manifest             │
│          │                                       │
│  2. BUILD          ──> Codex (~80K+ tokens)      │
│     Generate code for batch of items             │
│     Build validation + auto-fix                  │
│          │                                       │
│  3. VERIFY         ──> Claude Code (~3K tokens)  │
│     Check each item against specs                │
│     Update statuses, score health                │
│          │                                       │
│     Loop 2-3 until 100% or stalled               │
└─────────────────────────────────────────────────┘
```

**Phase 1: Blueprint** (Claude Code) -- Runs once. Reads all SDLC specifications and Figma analysis files and produces `blueprint.json`: a complete manifest of every file the project needs, with acceptance criteria for each. This phase must be exhaustive -- any item omitted from the blueprint will not be built. Output is approximately 5K tokens.

**Phase 2: Build** (Codex) -- Generates code for a batch of blueprint items. Each item includes the target file path, description, acceptance criteria, and dependencies. Build validation runs after generation. The batch size starts at the configured maximum and automatically reduces if builds fail repeatedly.

**Phase 3: Verify** (Claude Code) -- Binary check: does each file exist and does it meet its acceptance criteria? Updates item statuses in the blueprint, calculates the health score, and writes `next-batch.json` for the next Build phase. Output is approximately 2K tokens with no prose -- just status updates.

The Build-Verify loop repeats until all blueprint items reach `satisfied` status or the engine detects a stall. Blueprint is best for greenfield projects; convergence is best for existing codebases. The two pipelines are interchangeable -- they share the same `.gsd/` state directory, and you can switch between them at any time.

### 2.5 Data Flow Diagrams

**gsd-assess Flow:**

```
┌────────────┐    ┌────────────────┐    ┌──────────────────────┐
│ Repository │───>│ Update-FileMap │───>│ file-map.json        │
│ (all files)│    │                │    │ file-map-tree.md     │
└────────────┘    └────────────────┘    └──────────────────────┘
                         │
                         ▼
              ┌─────────────────────┐    ┌──────────────────────┐
              │ Claude Code         │───>│ assessment-summary.md│
              │ (assess prompt)     │    │ work-classification  │
              │                     │    │ backend-inventory    │
              │ Reads: specs,       │    │ database-inventory   │
              │   Figma, code       │    │ frontend-inventory   │
              └─────────────────────┘    └──────────────────────┘
```

**gsd-converge Per-Iteration Flow:**

```
┌────────────────────────────────────────────────────────────────┐
│                     ITERATION N                                 │
│                                                                 │
│  ┌─────────┐   ┌──────────┐   ┌──────┐   ┌─────────┐         │
│  │ REVIEW  │──>│ RESEARCH │──>│ PLAN │──>│ EXECUTE │──> git   │
│  │ Claude  │   │ Gemini   │   │Claude│   │ Codex   │   commit │
│  └────┬────┘   └──────────┘   └──┬───┘   └────┬────┘         │
│       │                          │             │               │
│       ▼                          ▼             ▼               │
│  health-current    queue-current.json    source code           │
│  drift-report      assignment.md         build validation      │
│  review-current                          auto-fix if needed    │
│       │                                                        │
│       ▼                                                        │
│  health >= 100%? ──YES──> Final Validation ──> Handoff Report  │
│       │                                                        │
│       NO ──> stalled? ──YES──> Supervisor Recovery             │
│       │                                                        │
│       NO ──> max iterations? ──YES──> Handoff Report           │
│       │                                                        │
│       NO ──> Next Iteration                                    │
└────────────────────────────────────────────────────────────────┘
```

**gsd-blueprint Per-Iteration Flow:**

```
┌────────────────────────────────────────────────────────────────┐
│                     BLUEPRINT PIPELINE                          │
│                                                                 │
│  ┌───────────┐   ┌─────────────┐   ┌──────────┐              │
│  │ BLUEPRINT │──>│ BUILD       │──>│ VERIFY   │──> git commit │
│  │ Claude    │   │ Codex       │   │ Claude   │               │
│  │ (once)    │   │ (per batch) │   │(per iter)│               │
│  └─────┬─────┘   └──────┬──────┘   └────┬─────┘              │
│        │                │               │                      │
│        ▼                ▼               ▼                      │
│  blueprint.json   source code     next-batch.json              │
│  (full manifest)  build validate  status updates               │
│                                                                │
│  Loop BUILD-VERIFY until 100% or stalled                       │
└────────────────────────────────────────────────────────────────┘
```

### 2.6 Installed Directory Structure

The global engine installs to `%USERPROFILE%\.gsd-global\` and is shared across all projects on the workstation.

```
%USERPROFILE%\.gsd-global\
├── bin\                              CLI wrappers (added to PATH)
│   ├── gsd-converge.cmd              Convergence loop launcher
│   ├── gsd-blueprint.cmd             Blueprint pipeline launcher
│   ├── gsd-status.cmd                Health status dashboard
│   ├── gsd-remote.cmd                Remote monitoring launcher
│   └── gsd-costs.cmd                 Token cost calculator
├── config\
│   ├── global-config.json            Notifications, patterns, phase order
│   └── agent-map.json                Agent-to-phase assignments
├── lib\modules\
│   ├── resilience.ps1                Core: retry, checkpoint, lock, batch, costs, notifications
│   ├── supervisor.ps1                Self-healing: diagnosis, fix, pattern memory
│   ├── interfaces.ps1                Multi-interface detection + auto-discovery
│   └── interface-wrapper.ps1         Context builder for agent prompts
├── prompts\
│   ├── claude\                       Claude prompt templates (review, plan, verify, assess)
│   ├── codex\                        Codex prompt templates (execute, build)
│   └── gemini\                       Gemini prompt templates (research, spec-fix)
├── blueprint\
│   └── scripts\
│       ├── blueprint-pipeline.ps1    Blueprint generation + build loop
│       └── assess.ps1                Assessment script (gsd-assess)
├── scripts\
│   ├── convergence-loop.ps1          5-phase convergence engine
│   ├── supervisor-converge.ps1       Supervisor wrapper for convergence
│   ├── supervisor-blueprint.ps1      Supervisor wrapper for blueprint
│   ├── gsd-profile-functions.ps1     PowerShell profile (gsd-* commands)
│   └── token-cost-calculator.ps1     Token cost estimator
├── supervisor\
│   └── pattern-memory.jsonl          Cross-project failure patterns + fixes
├── pricing-cache.json                Cached LLM pricing (auto-updated)
├── KNOWN-LIMITATIONS.md              Full scenario matrix
└── VERSION                           Installed version stamp
```

### 2.7 Per-Project State (.gsd/ folder)

Each project maintains its own `.gsd/` folder at the repository root. This folder contains all engine state and travels with the repo via git, enabling workstation transfers and full audit history.

```
.gsd\
├── assessment\
│   ├── assessment-summary.md         Human-readable findings
│   ├── work-classification.json      Skip/fix/build/review per item
│   ├── backend-inventory.json        C# layer detail
│   ├── database-inventory.json       SQL layer detail
│   ├── frontend-inventory.json       React layer detail
│   └── file-inventory.json           Complete file catalog
├── health\
│   ├── health-current.json           Current health score + breakdown
│   ├── health-history.jsonl          Score progression over iterations
│   ├── requirements-matrix.json      Every requirement with status
│   ├── drift-report.md               Gaps between specs and code
│   ├── review-current.md             Latest review findings
│   ├── engine-status.json            Live engine state (phase, agent, heartbeat)
│   └── final-validation.json         Quality gate results at 100%
├── costs\
│   ├── token-usage.jsonl             Every agent call with tokens + cost
│   └── cost-summary.json             Rolling totals by agent, phase, run
├── supervisor\
│   ├── supervisor-state.json         Recovery attempt tracking
│   ├── last-run-summary.json         Why pipeline exited
│   ├── error-context.md              Injected into agent prompts
│   ├── prompt-hints.md               Persistent constraints for agents
│   ├── agent-override.json           Phase-to-agent reassignment
│   ├── diagnosis-{N}.md              Root cause analysis per attempt
│   └── escalation-report.md          Human intervention guide
├── generation-queue\
│   └── queue-current.json            Next batch of items to build
├── agent-handoff\
│   └── current-assignment.md         Instructions for execute/build agent
├── logs\
│   ├── errors.jsonl                  Categorized error log
│   └── iter{N}-{phase}.log          Per-iteration agent output
├── blueprint\
│   └── blueprint.json                Full project manifest
├── file-map.json                     Machine-readable repo inventory
├── file-map-tree.md                  Human-readable directory tree
├── spec-consistency-report.json      Spec conflict analysis
├── .gsd-checkpoint.json              Crash recovery state
└── .gsd-lock                         Prevents concurrent runs
```

---

## Chapter 3: Installation

### 3.1 Prerequisites

**Required Software:**

| Tool | Version | Purpose | Install Command |
|---|---|---|---|
| PowerShell | 5.1+ or 7+ | Script execution | Pre-installed on Windows |
| Node.js | 18+ | JavaScript runtime for npm | `winget install OpenJS.NodeJS.LTS` |
| npm | 9+ | Package manager | Included with Node.js |
| .NET SDK | 8+ | Backend build validation | `winget install Microsoft.DotNet.SDK.8` |
| Git | 2+ | Version control, snapshots | `winget install Git.Git` |
| Claude Code CLI | Latest | AI agent (review, plan, verify) | `npm install -g @anthropic-ai/claude-code` |
| Codex CLI | Latest | AI agent (execute, build) | `npm install -g @openai/codex` |

**Optional Software:**

| Tool | Purpose | Install Command |
|---|---|---|
| Gemini CLI | Three-model optimization (research, spec-fix) | `npm install -g @google/gemini-cli` |
| sqlcmd | SQL syntax validation | `winget install Microsoft.SqlServer.SqlCmd` |
| ntfy app | Mobile push notifications | iOS App Store / Google Play |

All required tools must be installed and available on your system PATH before running the GSD installer. The installer includes a pre-flight check (`install-gsd-prerequisites.ps1`) that verifies each dependency and can automatically install missing tools via winget.

### 3.2 API Key Configuration

API keys are recommended for autonomous pipelines because they provide higher throughput and more predictable rate limits than interactive authentication. Keys are stored as persistent User-level environment variables and are never committed to git.

| Environment Variable | CLI | Get Key From |
|---|---|---|
| ANTHROPIC_API_KEY | Claude Code | https://console.anthropic.com/settings/keys |
| OPENAI_API_KEY | Codex | https://platform.openai.com/api-keys |
| GOOGLE_API_KEY | Gemini | https://aistudio.google.com/apikey |

**Method 1: During Installation (automatic)**

The master installer prompts for API keys as Step 0. If keys are already set as environment variables, this step is automatically skipped.

**Method 2: Standalone Script**

```powershell
# Interactive (prompts for each key)
.\scripts\setup-gsd-api-keys.ps1

# Non-interactive (pass keys directly)
.\scripts\setup-gsd-api-keys.ps1 -AnthropicKey "sk-ant-..." -OpenAIKey "sk-..." -GoogleKey "AIza..."

# Check current status
.\scripts\setup-gsd-api-keys.ps1 -Show

# Remove all keys
.\scripts\setup-gsd-api-keys.ps1 -Clear
```

**Method 3: Manual**

```powershell
[System.Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", "sk-ant-...", "User")
[System.Environment]::SetEnvironmentVariable("OPENAI_API_KEY", "sk-...", "User")
[System.Environment]::SetEnvironmentVariable("GOOGLE_API_KEY", "AIza...", "User")
```

After setting keys via any method, restart your terminal for the environment variables to take effect in new processes.

### 3.3 Running the Master Installer

```powershell
git clone https://github.com/your-org/gsd-autonomous-dev.git
cd gsd-autonomous-dev\scripts
powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1
```

The installer runs `install-gsd-prerequisites.ps1` first as a pre-flight check, then executes all 16 installation scripts in order:

| Order | Script | What It Installs |
|---|---|---|
| 1 | install-gsd-global.ps1 | API keys, global directory, engine, config, profile, gsd-costs |
| 2 | install-gsd-blueprint.ps1 | Blueprint pipeline, assess script, prompts |
| 3 | patch-gsd-partial-repo.ps1 | gsd-assess command, file map generation |
| 4 | patch-gsd-resilience.ps1 | Resilience module (retry, checkpoint, lock, watchdog) |
| 5 | patch-gsd-hardening.ps1 | Hardening (quota, network, boundary, notifications, cost tracking) |
| 6 | patch-gsd-final-validation.ps1 | Final validation gate + developer handoff report |
| 7 | patch-gsd-figma-make.ps1 | Interface detection, _analysis/_stubs discovery |
| 8 | final-patch-1-spec-check.ps1 | Spec consistency checker |
| 9 | final-patch-2-sql-cli.ps1 | SQL validation, CLI version checks |
| 10 | final-patch-3-storyboard-verify.ps1 | Storyboard-aware verification prompts |
| 11 | final-patch-4-blueprint-pipeline.ps1 | Final blueprint pipeline with all integrations |
| 12 | final-patch-5-convergence-pipeline.ps1 | Final convergence loop with all integrations |
| 13 | final-patch-6-assess-limitations.ps1 | Final assess script + known limitations |
| 14 | final-patch-7-spec-resolve.ps1 | Spec conflict auto-resolution via Gemini |
| 15 | patch-gsd-supervisor.ps1 | Self-healing supervisor system |
| 16 | patch-false-converge-fix.ps1 | Bug fix: false convergence exit |

The installer is idempotent -- it is safe to re-run at any time for updates. Each script checks for existing installations and overwrites only the files it manages.

### 3.4 Post-Install Verification

After installation completes, restart your terminal to load the updated PowerShell profile, then verify:

```powershell
# Restart terminal first (required to load profile)

# Verify commands are available
gsd-status

# Verify all prerequisites
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-prerequisites.ps1 -VerifyOnly
```

The `gsd-status` command should display the health dashboard (or a message indicating no project is initialized in the current directory). The prerequisite check with `-VerifyOnly` reports the status of every required and optional tool without modifying anything.

### 3.5 VS Code Integration

**Tasks** are available via Ctrl+Shift+P > "Run Task":

- GSD: Convergence Loop
- GSD: Blueprint Pipeline

**Keyboard Shortcuts** (available after running `install-gsd-keybindings.ps1`):

| Shortcut | Action |
|---|---|
| Ctrl+Shift+G, C | Run convergence loop |
| Ctrl+Shift+G, B | Run blueprint pipeline |
| Ctrl+Shift+G, S | Show status dashboard |

### 3.6 Multi-Workstation Setup

GSD supports installation on multiple workstations with seamless work transfer via git. The entire `.gsd/` state directory -- health scores, requirements matrix, checkpoint state, logs, and all engine state -- travels with the repository.

**On the source workstation:**

```powershell
# Wait for current iteration to complete (watch for git commit line)
# Ctrl+C during a safe pause (e.g., quota sleep)
git add -A
git commit -m "gsd: pause for workstation transfer"
git push
```

**On the target workstation:**

```powershell
# One-time setup
git clone https://github.com/your-org/gsd-autonomous-dev.git
cd gsd-autonomous-dev\scripts
powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1

# Resume work
cd C:\path\to\your-project
git pull
Remove-Item .gsd/.gsd-lock -Force    # Clear stale lock if present
gsd-converge                          # Resumes from checkpoint
```

The engine detects the existing checkpoint and resumes from the exact phase and iteration where work was paused.

### 3.7 Updating and Uninstalling

**Update:**

```powershell
cd gsd-autonomous-dev
git pull
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-all.ps1
```

Pull the latest changes and re-run the master installer. The idempotent installer overwrites engine files with updated versions while preserving your configuration and per-project state.

**Uninstall:**

```powershell
# Remove global engine
Remove-Item -Recurse -Force "$env:USERPROFILE\.gsd-global"

# Remove profile entries (manual edit)
notepad $PROFILE    # Remove gsd-related lines

# Remove API keys (optional)
.\scripts\setup-gsd-api-keys.ps1 -Clear

# Remove per-project state
Remove-Item -Recurse -Force .gsd
```

---

## Chapter 4: Usage Guide

### 4.1 First Project Setup

Step-by-step from empty repo to first run:

1. **Prepare your repository** -- must be a git repo with .sln at root:

```
your-repo\
├── design\
│   └── web\v01\
│       ├── _analysis\        <- 12 Figma Make deliverables
│       └── _stubs\           <- Controller, DTO, SQL stubs
├── docs\                     <- SDLC Phase A-E specifications
├── src\                      <- Source code
├── .sln                      <- .NET solution file
└── package.json              <- Frontend (if applicable)
```

2. **Initialize**: `gsd-init` creates the .gsd/ folder
3. **Assess**: `gsd-assess` analyzes existing code, generates file map
4. **Choose pipeline**: `gsd-blueprint` for greenfield, `gsd-converge` for existing code
5. **Monitor**: Watch terminal output, subscribe to ntfy topic on phone

**Decision heuristic:**

| Scenario | Command |
|---|---|
| New project, no code | `gsd-blueprint` |
| New project, some scaffolding exists | `gsd-assess` then `gsd-blueprint` |
| Existing project needs fixes | `gsd-converge` |
| Blueprint at 60-80%, stuck | Switch to `gsd-converge` |
| Quick assessment only | `gsd-assess` |

### 4.2 Running gsd-assess

```powershell
gsd-assess              # Full assessment
gsd-assess -MapOnly     # Regenerate file map only
gsd-assess -DryRun      # Preview without executing
```

**What it produces:**
- `.gsd/assessment/assessment-summary.md` -- Human-readable findings
- `.gsd/assessment/work-classification.json` -- Skip/fix/build/review per item
- `.gsd/assessment/backend-inventory.json` -- C# controllers, services, repos, DTOs
- `.gsd/assessment/database-inventory.json` -- Tables, stored procedures, views
- `.gsd/assessment/frontend-inventory.json` -- Screens, components, hooks
- `.gsd/assessment/file-inventory.json` -- Complete file catalog
- `.gsd/file-map.json` -- Machine-readable repo inventory
- `.gsd/file-map-tree.md` -- Human-readable directory tree

### 4.3 Running gsd-converge

Full parameter reference:

| Parameter | Default | Description |
|---|---|---|
| -DryRun | false | Preview mode, no agent calls |
| -SkipInit | false | Skip initial requirements check |
| -SkipResearch | false | Skip Gemini/Codex research phase |
| -SkipSpecCheck | false | Skip spec consistency check |
| -AutoResolve | false | Auto-resolve spec conflicts via Gemini |
| -BatchSize | 8 | Items per execute cycle |
| -MaxIterations | 20 | Maximum iterations |
| -StallThreshold | 3 | Stop after N stalled iterations |
| -ThrottleSeconds | 30 | Delay between agent calls |
| -NtfyTopic | (auto) | Override ntfy notification topic |
| -SupervisorAttempts | 5 | Max supervisor recovery attempts |
| -NoSupervisor | false | Bypass supervisor wrapper |

Example usage patterns:

```powershell
gsd-converge                              # Standard run
gsd-converge -SkipResearch                # Save tokens (skip research)
gsd-converge -MaxIterations 5             # Quick 5-iteration run
gsd-converge -ThrottleSeconds 60          # Slower, less quota pressure
gsd-converge -AutoResolve                 # Auto-fix spec conflicts
gsd-converge -NoSupervisor                # Debug without supervisor
gsd-converge -BatchSize 4 -MaxIterations 10  # Conservative run
```

**What to expect during a run:**

```
  Resilience library ready.
  Hardening modules loaded.
  ntfy topic (auto): gsd-rjain-myproject

  CLAUDE -> code-review
    Attempt 1/3 (batch: 8)...
  CODEX -> research
    Attempt 1/3 (batch: 8)...
  CLAUDE -> plan
    Attempt 1/3 (batch: 8)...
  CODEX -> execute (batch: 8)
    Attempt 1/3 (batch: 8)...

  gsd: iter 1 (health: 45.2%)
```

### 4.4 Running gsd-blueprint

| Parameter | Default | Description |
|---|---|---|
| -DryRun | false | Preview mode |
| -BlueprintOnly | false | Generate manifest only |
| -BuildOnly | false | Resume build from existing manifest |
| -VerifyOnly | false | Re-verify without generating |
| -SkipSpecCheck | false | Skip spec consistency check |
| -AutoResolve | false | Auto-resolve spec conflicts |
| -MaxIterations | 30 | Maximum build/verify iterations |
| -StallThreshold | 3 | Stall detection threshold |
| -BatchSize | 15 | Items per build cycle |
| -ThrottleSeconds | 30 | Delay between calls |
| -NtfyTopic | (auto) | Notification topic override |
| -SupervisorAttempts | 5 | Max recovery attempts |
| -NoSupervisor | false | Bypass supervisor |

Typical workflow:

```powershell
gsd-blueprint                    # Full pipeline
gsd-blueprint -BlueprintOnly     # Just generate manifest, review it
gsd-blueprint -BuildOnly         # Resume building from manifest
gsd-blueprint -VerifyOnly        # Re-score after manual fixes
```

When to switch to convergence: When blueprint reaches 60-80% and stalls, switch to `gsd-converge` which handles iterative fix-and-verify better for remaining gaps.

### 4.5 Running gsd-status

```powershell
gsd-status
```

Shows: current health score, iteration count, batch sizes, convergence/blueprint progress, active/stalled state.

### 4.6 Running gsd-costs

**Pre-run estimation:**

```powershell
gsd-costs                                    # Auto-detect from current project
gsd-costs -TotalItems 150                    # Manual estimate
gsd-costs -TotalItems 200 -ShowComparison    # Blueprint vs convergence side-by-side
gsd-costs -TotalItems 300 -ClientQuote -Markup 8  # Client quote
```

**Live cost tracking:**

```powershell
gsd-costs -ShowActual    # View actual costs from pipeline runs
```

Output sections: Project Summary, Model Pricing, Phase-by-Phase Breakdown, Cost by Agent, Key Metrics, Subscription Comparison, Pipeline Comparison, Client Quote.

**Token estimates per item type:**

| Item Type | Output Tokens |
|---|---|
| sql-migration | 1,000 |
| stored-procedure | 2,000 |
| controller | 5,000 |
| service | 3,500 |
| dto | 1,500 |
| react-component | 4,000 |
| hook | 2,500 |
| test | 3,000 |

**Client quoting tiers:**

| Tier | Item Count | Suggested Markup |
|---|---|---|
| Standard | <=100 | 5x |
| Complex | <=250 | 7x |
| Enterprise | <=500 | 7-10x |
| Enterprise+ | >500 | 10x |

### 4.7 Monitoring a Running Pipeline

**Terminal Output Icons:**

| Icon | Meaning |
|---|---|
| CLAUDE -> | Claude Code phase (review, plan, verify) |
| CODEX -> | Codex phase (execute, build) |
| GEMINI -> | Gemini phase (research, spec-fix) |
| OK | Phase completed successfully |
| !! | Warning or retry |
| XX | Phase failed |
| STALLED | Pipeline stalled, no progress |

**Push Notifications (ntfy.sh):**

1. Install ntfy app on your phone (free, no account)
2. Run a pipeline -- note the topic at startup: `ntfy topic (auto): gsd-rjain-projectname`
3. Subscribe to that topic in the ntfy app
4. Receive real-time notifications: iteration complete, stalled, quota exhausted, converged, errors
5. Send "progress" to the topic to get a status response

**Remote Monitoring:**

```powershell
gsd-remote    # Displays QR code, scan with phone
```

### 4.8 Interrupting and Resuming

**Safe to Ctrl+C when:**
- Between iterations (after git commit line)
- During quota sleep ("Sleeping 60 minutes...")
- During network polling ("Polling every 30s...")

**After Ctrl+C:**

```powershell
# Check for stale lock
Remove-Item .gsd/.gsd-lock -Force    # If present
gsd-converge                          # Resumes from checkpoint
```

**Transfer to another workstation:**

```powershell
# Source machine
git add -A && git commit -m "gsd: pause" && git push

# Target machine
git pull && Remove-Item .gsd/.gsd-lock -Force && gsd-converge
```

---

## Chapter 5: Resilience and Self-Healing

### 5.1 Retry with Batch Reduction

When an agent call fails, `Invoke-WithRetry` retries up to 3 times, halving the batch size each time:

```
Attempt 1: batch 8 -> FAIL
Attempt 2: batch 4 -> FAIL
Attempt 3: batch 2 -> FAIL -> Try fallback agent
```

Minimum batch size: 2. If all retries fail, the engine tries a fallback agent (codex->claude, gemini->codex).

Configuration constants:

| Constant | Default | Description |
|---|---|---|
| RETRY_MAX | 3 | Maximum retries per agent call |
| MIN_BATCH_SIZE | 2 | Minimum batch size after reduction |
| BATCH_REDUCTION_FACTOR | 0.5 | Multiplier on failure |
| RETRY_DELAY_SECONDS | 10 | Delay between retries |

### 5.2 Checkpoint and Recovery

After each successful phase, state is saved to `.gsd/.gsd-checkpoint.json`:

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

On restart, the engine reads the checkpoint and resumes from the last completed phase. No work is repeated.

### 5.3 Lock File Management

`.gsd/.gsd-lock` prevents concurrent GSD runs on the same project. The lock includes a timestamp for stale detection -- locks older than 120 minutes are auto-cleared.

To manually clear: `Remove-Item .gsd/.gsd-lock -Force`

### 5.4 Health Regression Protection

If health drops >5% after an iteration, the engine:

1. Detects the regression via `Test-HealthRegression`
2. Auto-reverts to the pre-iteration git state via `Save-GsdSnapshot`
3. Logs a `health_regression` error
4. Increments the stall counter

### 5.5 Quota and Rate Limit Handling

`Wait-ForQuotaReset` implements adaptive backoff:

- First sleep: 5 minutes
- Each subsequent: doubles (10 -> 20 -> 40 -> 60 min cap)
- Maximum: 24 cycles (up to 24 hours)
- Sends push notification on each sleep
- Tests agent availability before resuming

### 5.6 Network Failure Handling

`Test-NetworkAvailability` polls every 30 seconds via `claude -p "PING" --max-turns 1`. Maximum wait: 1 hour. Sends push notification when connection drops and when it's restored.

### 5.7 Build Validation and Auto-Fix

After every Execute/Build phase:

1. `dotnet build` runs (if .sln exists)
2. `npm run build` runs (if package.json exists)
3. On failure -> Codex auto-fixes compilation errors
4. Re-verify after fix
5. If auto-fix succeeds -> git commit
6. If auto-fix fails -> log error, continue

### 5.8 Agent Watchdog

Each agent call runs in an isolated child process with a 30-minute watchdog timer (`AGENT_WATCHDOG_MINUTES`). If the agent hangs:

1. Watchdog kills the process tree
2. Halves the batch size
3. Sends high-priority push notification
4. Retries with smaller batch

### 5.9 The Supervisor

The supervisor wraps the entire pipeline in a recovery loop:

```
┌─────────────────────────────────────┐
│         SUPERVISOR LOOP              │
│                                      │
│  Attempt 1: Run pipeline             │
│  -> Pipeline stalls/crashes          │
│  -> Get error statistics (free)      │
│  -> AI diagnosis (1 Claude call)     │
│  -> AI fix (1 Claude call)           │
│  -> Write error-context.md           │
│  -> Write prompt-hints.md            │
│  -> Restart pipeline in new terminal │
│                                      │
│  Attempt 2: Run with hints           │
│  -> (repeat if still failing)        │
│                                      │
│  After 5 attempts:                   │
│  -> Generate escalation-report.md    │
│  -> Send urgent notification         │
│  -> "NEEDS HUMAN" alert              │
└─────────────────────────────────────┘
```

**Cross-project learning**: Successful fixes are saved to `~/.gsd-global/supervisor/pattern-memory.jsonl`. Before running AI diagnosis, the supervisor checks if a known fix exists for this failure pattern -- saving AI costs.

**Bypassing**: `gsd-converge -NoSupervisor` runs the pipeline directly without the supervisor wrapper.

### 5.10 Final Validation Gate

When health reaches 100%, `Invoke-FinalValidation` runs 7 checks:

| Check | Type | What It Does |
|---|---|---|
| dotnet build | HARD | .NET compilation check |
| npm build | HARD | Frontend build check |
| dotnet test | HARD | Unit/integration tests (if test projects exist) |
| npm test | HARD | Frontend tests (if test script exists) |
| SQL validation | WARNING | Pattern compliance (TRY/CATCH, parameterized queries) |
| NuGet audit | WARNING | Vulnerability scan |
| npm audit | WARNING | Vulnerability scan |

Hard failures reset health to 99% so the loop auto-fixes. Warnings are included in the developer handoff report. Maximum 3 validation attempts.

On pipeline exit (converged, stalled, or max iterations), `New-DeveloperHandoff` generates `developer-handoff.md` with: build commands, database setup, environment configuration, project structure, requirements status, validation results, known issues, health progression chart, and cost summary.

---

## Chapter 6: Configuration Reference

### 6.1 Global Configuration (global-config.json)

**Location:** `%USERPROFILE%\.gsd-global\config\global-config.json`

```json
{
  "notifications": {
    "ntfy_topic": "auto",
    "notify_on": [
      "iteration_complete",
      "converged",
      "stalled",
      "quota_exhausted",
      "error"
    ]
  },
  "patterns": {
    "backend": ".NET 8 with Dapper",
    "database": "SQL Server stored procedures only",
    "frontend": "React 18",
    "api": "Contract-first, API-first",
    "compliance": ["HIPAA", "SOC 2", "PCI", "GDPR"]
  },
  "phase_order": [
    "code-review",
    "create-phases",
    "research",
    "plan",
    "execute"
  ]
}
```

**notifications fields:**

| Field | Type | Default | Description |
|---|---|---|---|
| ntfy_topic | string | "auto" | "auto" for per-project detection, or fixed topic string |
| notify_on | string[] | (all events) | Which events trigger push notifications |

Notification events: `iteration_complete`, `no_progress`, `execute_failed`, `build_failed`, `regression_reverted`, `converged`, `stalled`, `quota_exhausted`, `error`, `heartbeat`, `agent_timeout`, `progress_response`, `supervisor_active`, `supervisor_diagnosis`, `supervisor_fix`, `supervisor_restart`, `supervisor_recovered`, `supervisor_escalation`, `validation_failed`, `validation_passed`

**patterns fields:**

| Field | Type | Description |
|---|---|---|
| backend | string | Backend framework and ORM |
| database | string | Database access pattern |
| frontend | string | Frontend framework |
| api | string | API design approach |
| compliance | string[] | Regulatory compliance requirements |

### 6.2 Agent Assignment (agent-map.json)

**Location:** `%USERPROFILE%\.gsd-global\config\agent-map.json`

Maps each convergence phase to a specific agent. Token budget allocation ensures Claude stays under ~11K tokens/iteration while Codex/Gemini handle bulk generation. The supervisor can dynamically reassign phases during recovery.

### 6.3 Blueprint Configuration (blueprint-config.json)

The blueprint configuration is embedded within the blueprint pipeline script and controls batch sizes, iteration limits, and stall detection for the Build-Verify loop.

### 6.4 Per-Project State Files

**health-current.json:**

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

**engine-status.json** -- live engine state updated every 60 seconds:

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
  "elapsed_minutes": 27
}
```

**token-usage.jsonl** -- append-only log of every agent call:

```json
{
  "timestamp": "2026-03-02T14:30:00Z",
  "pipeline": "converge",
  "iteration": 5,
  "phase": "code-review",
  "agent": "claude",
  "batch_size": 8,
  "success": true,
  "tokens": {
    "input": 45000,
    "output": 3200,
    "cached": 12000
  },
  "cost_usd": 0.183,
  "duration_seconds": 120
}
```

**cost-summary.json** -- rolling totals by agent, phase, and run.

**supervisor-state.json** -- tracks recovery attempts, strategies tried, and diagnoses.

**.gsd-checkpoint.json** -- crash recovery state (iteration, phase, health, batch_size).

**requirements-matrix.json** -- every requirement with id, source, description, status, dependencies, and priority.

**spec-consistency-report.json** -- conflicts found across specification documents, categorized by type (data_type, api_contract, navigation, business_rule, database, missing_ref).

**final-validation.json** -- results of all 7 quality gate checks at 100% health.

### 6.5 Environment Variables

| Variable | Used By | Description |
|---|---|---|
| ANTHROPIC_API_KEY | Claude Code CLI | API key (sk-ant-...) |
| OPENAI_API_KEY | Codex CLI | API key (sk-...) |
| GOOGLE_API_KEY | Gemini CLI | API key (AIza...) |
| USERPROFILE | All scripts | Home directory for .gsd-global |
| USERNAME | Notifications | Auto-generates ntfy topic |
| PATH | CLI wrappers | Must include .gsd-global\bin |

### 6.6 Pricing Cache

**Location:** `%USERPROFILE%\.gsd-global\pricing-cache.json`

Auto-fetched from LiteLLM open-source database. Freshness thresholds:

| Age | Behavior |
|---|---|
| < 14 days | Fresh -- used directly |
| 14-60 days | Auto-refresh attempted silently |
| > 60 days | Stale -- warning displayed, refresh attempted |
| No cache | Fetches from web, falls back to hardcoded |

Supported models: `claude_sonnet`, `claude_opus`, `claude_haiku`, `codex`, `codex_gpt51`, `gemini`.

### 6.7 Supervisor Configuration

| Constant | Default | Description |
|---|---|---|
| SUPERVISOR_MAX_ATTEMPTS | 5 | Recovery attempts before escalation |
| SUPERVISOR_TIMEOUT_HOURS | 24 | Wall-clock time limit |
| AGENT_WATCHDOG_MINUTES | 30 | Per-agent-call timeout |
| RETRY_MAX | 3 | Retries per agent call |
| MIN_BATCH_SIZE | 2 | Minimum batch after reduction |

Default batch sizes:

| Pipeline | Default | Description |
|---|---|---|
| Blueprint | 15 | Items per build cycle |
| Convergence | 8 | Items per execute cycle |

---

## Chapter 7: Multi-Interface Support

### 7.1 Interface Types

The GSD Engine supports multi-interface projects where a single codebase serves multiple frontends:

| Interface | Folder | Example |
|---|---|---|
| Web | `design\web\v##\` | Web application (React) |
| MCP | `design\mcp\v##\` | MCP Admin Portal |
| Browser | `design\browser\v##\` | Browser Extension |
| Mobile | `design\mobile\v##\` | Mobile App (React Native) |
| Agent | `design\agent\v##\` | Remote Agent |

Detection: `Find-ProjectInterfaces` recursively scans up to 3 levels deep for any folder named `{type}` whose parent is `design`. The latest version folder (highest v## number) is used.

### 7.2 Directory Structure

```
your-repo\
├── design\
│   ├── web\v03\                  <- Web application designs
│   │   ├── _analysis\            <- 12 Figma Make deliverables
│   │   └── _stubs\               <- Controller, DTO, SQL stubs
│   ├── mcp\v02\                  <- MCP Admin Portal designs
│   │   ├── _analysis\
│   │   └── _stubs\
│   ├── browser\v01\              <- Browser Extension designs
│   ├── mobile\v01\               <- Mobile App designs
│   └── agent\v01\                <- Remote Agent designs
├── docs\                         <- SDLC Phase A-E specs
└── src\                          <- Generated code
```

### 7.3 Figma Make Integration

Each interface version folder should contain `_analysis/` with 12 expected deliverable files:

1. **UI Contract** -- screen inventory with 5-state definitions
2. **Component Hierarchy** -- parent-child component tree
3. **Design Tokens** -- colors, fonts, spacing, breakpoints
4. **Navigation Map** -- routes, transitions, guards
5. **Data Binding Map** -- component-to-API field mapping
6. **Interaction Matrix** -- user actions, triggers, responses
7. **Accessibility Spec** -- ARIA labels, keyboard nav, focus management
8. **Responsive Breakpoints** -- mobile, tablet, desktop layouts
9. **Animation Spec** -- transitions, loading states, micro-interactions
10. **Error State Inventory** -- error messages, boundaries, fallbacks
11. **Storyboard** -- end-to-end user flows with data paths
12. **API-SP Mapping** -- UI actions to API endpoints to stored procedures

The `_stubs/` folder contains generated backend stubs: controllers, DTOs, SQL scripts.

### 7.4 Auto-Discovery

`Find-ProjectInterfaces` scans the repo:

1. **Direct**: `{repo}\design\{type}\` (e.g., `design\web\`)
2. **Recursive**: searches up to 3 levels deep for any folder named `{type}` whose parent is "design"
3. Within each interface, finds the latest version folder (e.g., v03 over v02)
4. Within each version, recursively discovers `_analysis/` and `_stubs/` folders
5. Validates that expected deliverable files are present

The interface context is injected into every agent prompt so agents understand the full project scope.

---

## Chapter 8: Script Reference

### 8.1 User Commands

**gsd-assess** -- Scan codebase, detect interfaces, generate file map, run Claude assessment.

```powershell
gsd-assess              # Full assessment
gsd-assess -MapOnly     # Regenerate file map only
gsd-assess -DryRun      # Preview without executing
```

**gsd-converge** -- 5-phase convergence loop (review, research, plan, execute, verify).

```powershell
gsd-converge                          # Full convergence
gsd-converge -SkipResearch            # Skip research phase
gsd-converge -MaxIterations 5         # Limit iterations
gsd-converge -ThrottleSeconds 60      # Slower, less quota pressure
gsd-converge -AutoResolve             # Auto-fix spec conflicts
gsd-converge -NoSupervisor            # Debug without supervisor
```

**gsd-blueprint** -- 3-phase spec-to-code pipeline (blueprint, build, verify).

```powershell
gsd-blueprint                         # Full pipeline
gsd-blueprint -BlueprintOnly          # Generate manifest only
gsd-blueprint -BuildOnly              # Resume build
gsd-blueprint -VerifyOnly             # Re-score only
```

**gsd-status** -- Health dashboard for current project.

**gsd-costs** -- Token cost estimator with dynamic pricing, pipeline comparison, client quoting.

```powershell
gsd-costs                                    # Auto-detect from project
gsd-costs -TotalItems 150 -ShowComparison    # Compare pipelines
gsd-costs -ShowActual                        # View actual costs
gsd-costs -ClientQuote -Markup 8             # Client quote
```

**gsd-init** -- Initialize .gsd/ folder without running iterations.

**gsd-remote** -- Launch Claude remote session with QR code for phone monitoring.

### 8.2 Installation Scripts

The 16 scripts run by the master installer in dependency order:

1. **install-gsd-global.ps1** -- API key setup (Step 0), global directory structure, convergence engine, profile functions, gsd-costs command, VS Code tasks.

2. **install-gsd-blueprint.ps1** -- Blueprint pipeline, assess script, prompt templates, gsd-blueprint/gsd-init commands.

3. **patch-gsd-partial-repo.ps1** -- gsd-assess command, assessment prompts, file map generation, -MapOnly flag.

4. **patch-gsd-resilience.ps1** -- Resilience module: `Invoke-WithRetry` (with watchdog timeout), `Save-Checkpoint`, `Restore-Checkpoint`, lock management, adaptive batch sizing, agent fallback.

5. **patch-gsd-hardening.ps1** -- Quota handling, network polling, boundary enforcement, push notifications, background heartbeat, command listener, cost tracking functions, engine status tracking.

6. **patch-gsd-final-validation.ps1** -- 7-check quality gate at 100% health, developer handoff report generator.

7. **patch-gsd-figma-make.ps1** -- Multi-interface detection (web/mcp/browser/mobile/agent), _analysis/_stubs discovery, interface context injection.

8. **final-patch-1-spec-check.ps1** -- Spec consistency pre-check (data_type, api_contract, navigation, business_rule, database, missing_ref conflicts).

9. **final-patch-2-sql-cli.ps1** -- SQL pattern validation, CLI version compatibility checks.

10. **final-patch-3-storyboard-verify.ps1** -- Storyboard-aware verification prompt tracing data paths end-to-end.

11. **final-patch-4-blueprint-pipeline.ps1** -- Final blueprint pipeline with all integrations (file map, notifications, throttling, spec check, adaptive batch, validation, handoff, git traceability).

12. **final-patch-5-convergence-pipeline.ps1** -- Final convergence loop with all integrations.

13. **final-patch-6-assess-limitations.ps1** -- Final assess script with interface summary, known limitations documentation.

14. **final-patch-7-spec-resolve.ps1** -- Spec conflict auto-resolution via Gemini (`--yolo`), falls back to Codex.

15. **patch-gsd-supervisor.ps1** -- Self-healing supervisor: diagnosis, fix, pattern memory, escalation, supervisor wrappers for both pipelines.

16. **patch-false-converge-fix.ps1** -- Bug fix: false convergence exit when variables are null, orphaned profile code cleanup.

### 8.3 Standalone Utilities

- **setup-gsd-api-keys.ps1** -- Manage API keys (set/show/clear) for Anthropic, OpenAI, Google. Supports `-AnthropicKey`, `-OpenAIKey`, `-GoogleKey`, `-Show`, `-Clear` parameters.
- **setup-gsd-convergence.ps1** -- Per-project convergence setup (legacy, superseded by global install).
- **install-gsd-keybindings.ps1** -- VS Code keyboard shortcuts (Ctrl+Shift+G chords).
- **token-cost-calculator.ps1** -- Cost estimator (also installed globally as `gsd-costs`).

### 8.4 Key Internal Functions

**Invoke-WithRetry** -- Core agent call with retry, batch reduction, watchdog timeout, quota backoff, and fallback.
Parameters: `-Agent` ("claude"/"codex"/"gemini"), `-Prompt`, `-Phase`, `-LogFile`, `-CurrentBatchSize`, `-GsdDir`, `-GeminiMode`

**Update-FileMap** -- Generates file-map.json and file-map-tree.md. Excludes: node_modules, .git, bin, obj, dist, build, .gsd.
Parameters: `-Root`, `-GsdPath`. Returns: path to file-map.json.

**Save-Checkpoint / Restore-Checkpoint** -- Saves/restores pipeline state (iteration, phase, health, batch_size) for crash recovery.

**Wait-ForQuotaReset** -- Adaptive backoff: 5min, 10, 20, 40, 60 cap. Max 24 cycles.

**Test-NetworkAvailability** -- Polls every 30s via `claude -p "PING"`. Max wait: 1 hour.

**Save-GsdSnapshot** -- Creates git stash/commit as rollback point before destructive operations.

**Find-ProjectInterfaces** -- Recursively scans repo for `design/{type}/v##` folders, discovers _analysis/_stubs.

**Invoke-SpecConsistencyCheck** -- Scans spec documents for contradictions. Blocks critical conflicts unless `-AutoResolve`.

**Invoke-FinalValidation** -- 7-check quality gate at 100% health. Returns structured results with hard failures and warnings.

**New-DeveloperHandoff** -- Generates `developer-handoff.md` with 10 sections (build commands, DB setup, requirements, costs, etc.).

**Invoke-SupervisorDiagnosis** -- Claude reads all logs and produces structured diagnosis (root cause, category, recommended fix).

**Invoke-SupervisorFix** -- Claude modifies project files to fix diagnosed root cause (error-context, prompt-hints, agent-override, queue).

**Extract-TokensFromOutput** -- Parses CLI output (Claude JSON array, Codex JSONL, Gemini JSON) to extract token counts and cost.

**Save-TokenUsage** -- Appends JSONL record to token-usage.jsonl and updates cost-summary.json.

**Update-EngineStatus** -- Merge-on-write update to engine-status.json (state, phase, agent, heartbeat).

**Local-ResolvePrompt** -- Resolves prompt template variables and appends supervisor context/hints.

---

## Chapter 9: Troubleshooting

### 9.1 Installation Issues

| Problem | Fix |
|---|---|
| "running scripts is disabled" | `powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1` |
| "gsd-assess is not recognized" | Restart terminal, or `. $PROFILE` |
| "command claude not found" | `npm install -g @anthropic-ai/claude-code` then restart |
| "command codex not found" | `npm install -g @openai/codex` then restart |
| "command gemini not found" | Optional: `npm install -g @google/gemini-cli` |
| Install fails partway | Re-run install-gsd-all.ps1 (idempotent) |

### 9.2 Runtime Issues

| Problem | Fix |
|---|---|
| "Another GSD process is running" | `Remove-Item .gsd/.gsd-lock -Force` |
| "Quota exhausted, sleeping 60 min" | Automatic recovery. Use `-ThrottleSeconds 60` to prevent. Install Gemini for separate quota. |
| "Network unavailable, polling" | Automatic recovery. Check internet connection. |
| Codex exit code 2 | Check `codex --version`, ensure using `codex exec --full-auto`. Re-run installer. |
| Health stuck / stalling | Use `-AutoResolve` for spec conflicts. Review `drift-report.md`. |
| Health regression (score drops) | Automatic revert. Check logs for what caused the drop. |
| JSON parsing errors | Automatic restore from .last-good backup. If corrupt: delete file, re-run. |
| Agent boundary violation | Automatic revert. Review `current-assignment.md` for ambiguity. |

### 9.3 Agent-Specific Issues

**Claude Code**: If auth fails, run `claude` interactively to re-authenticate. For API keys: set `ANTHROPIC_API_KEY`. Check key validity at https://console.anthropic.com/settings/keys.

**Codex CLI**: The `--approval-mode` flag was removed in recent versions. GSD uses `codex exec --full-auto`. If you see "unexpected argument '--approval-mode'" errors, re-run the installer to update all scripts.

**Gemini CLI**: Uses Google OAuth (interactive) or `GOOGLE_API_KEY`. Exit code 44 = old sandbox issue, fixed in current version. If OAuth fails, try API key method instead.

### 9.4 Spec Consistency Conflicts

`Invoke-SpecConsistencyCheck` runs before each pipeline iteration and scans specification documents for contradictions. Results are written to `.gsd/spec-consistency-report.json`.

**Conflict types:**

| Type | Description | Example |
|---|---|---|
| data_type | Field type mismatch across specs | Phone: string in one spec, int in another |
| api_contract | Endpoint definition conflicts | GET /users vs POST /users for same operation |
| navigation | Route conflicts | Two screens claiming same URL |
| business_rule | Logic contradictions | "Require 2FA" vs "Allow password-only" |
| database | Schema conflicts | Column defined differently in two scripts |
| missing_ref | Referenced item doesn't exist | Screen references API endpoint not defined |

**Resolution:**
- Use `-AutoResolve` flag to have Gemini auto-fix conflicts
- Review `spec-consistency-report.json` for manual resolution
- Critical conflicts block the pipeline; warnings are logged

### 9.5 Reading Error Logs

All errors are logged to `.gsd/logs/errors.jsonl` in structured format:

```json
{
  "timestamp": "2026-03-02T14:30:00Z",
  "category": "agent_crash",
  "phase": "execute",
  "iteration": 3,
  "message": "codex exit code 2",
  "resolution": "Batch reduced to 4"
}
```

**Error categories:**

| Category | Description |
|---|---|
| quota | API quota exhausted (sleeping) |
| network | Network connectivity lost |
| disk | Disk space critically low |
| corrupt_json | JSON state file corrupted |
| boundary_violation | Agent wrote outside allowed scope |
| agent_crash | Agent CLI crashed (exit code != 0) |
| health_regression | Health dropped >5% after iteration |
| spec_conflict | Contradictions in specification documents |
| watchdog_timeout | Agent hung, killed by watchdog |
| build_fail | dotnet build or npm build failed |
| fallback_success | Primary agent failed, fallback succeeded |
| validation_fail | Final validation gate check failed |

### 9.6 Notification Issues

| Problem | Fix |
|---|---|
| Not receiving notifications | Verify topic name matches subscription exactly |
| Wrong topic | Check `ntfy topic (auto):` line at startup, or use `-NtfyTopic` override |
| No heartbeats | Heartbeats fire every 10 min. Short iterations skip them. |
| "progress" command no response | Pipeline must be running. Post exact word "progress". |

### 9.7 Supervisor Issues

| Problem | Fix |
|---|---|
| Supervisor retrying same fix | Check `supervisor-state.json`. Built-in dedup should prevent this. |
| "NEEDS HUMAN" notification | Read `escalation-report.md` for full diagnosis |
| Stale prompt-hints | `Remove-Item .gsd/supervisor/prompt-hints.md -Force` |
| Reset supervisor | `Remove-Item .gsd/supervisor/* -Force` |
| Bypass supervisor | `gsd-converge -NoSupervisor` |

### 9.8 Final Validation Issues

| Problem | Fix |
|---|---|
| Stuck at 99% health | Check `.gsd/logs/final-validation.log` for which checks fail |
| Build passes locally but fails in validation | Validation uses `--no-restore`. Ensure packages are restored. |
| npm test hangs | Set `CI=true` in environment, or add `--watchAll=false` to test script |
| All checks show SKIP | No .sln or package.json found. Normal for non-.NET/Node projects. |

### 9.9 Cost Tracking Issues

| Problem | Fix |
|---|---|
| Costs not being tracked | Re-run installer. Check CLI versions support JSON output. |
| cost-summary.json corrupted | `Rebuild-CostSummary -GsdDir ".gsd"` |
| -ShowActual shows no data | Run at least one pipeline iteration first |

---

## Chapter 10: Cost Management

### 10.1 Token Budget Per Iteration

**Convergence Pipeline:**

| Phase | Agent | Est. Output Tokens | Monthly @ 20 iters |
|---|---|---|---|
| code-review | Claude | 2,000-5,000 | 40K-100K |
| create-phases | Claude | 3,000-6,000 | one-time ~5K |
| research | Gemini/Codex | 5,000-15,000 | unlimited |
| plan | Claude | 1,500-4,000 | 30K-80K |
| execute | Codex | 15,000-100,000+ | unlimited |
| **Claude total** | | **~11K/iter** | **~220K/mo** |
| **Codex/Gemini total** | | **~65K+/iter** | **unlimited** |

**Blueprint Pipeline:**

| Phase | Agent | Est. Output Tokens |
|---|---|---|
| blueprint | Claude | ~5,000 (one-time) |
| build | Codex | ~80,000+ per iteration |
| verify | Claude | ~3,000 per iteration |

### 10.2 Pre-Run Estimation

```powershell
gsd-costs -TotalItems 150                    # Quick estimate
gsd-costs -TotalItems 200 -ShowComparison    # Blueprint vs convergence
gsd-costs -TotalItems 150 -Detailed          # Per-iteration breakdown
```

**Token estimates per item type:**

| Item Type | Output Tokens |
|---|---|
| sql-migration | 1,000 |
| stored-procedure | 2,000 |
| controller | 5,000 |
| service | 3,500 |
| dto | 1,500 |
| react-component | 4,000 |
| hook | 2,500 |
| middleware | 2,000 |
| config | 1,500 |
| test | 3,000 |
| compliance | 2,000 |

### 10.3 Live Cost Tracking

Costs are tracked automatically from the first pipeline run:
- **token-usage.jsonl** -- append-only, survives crashes, one line per agent call
- **cost-summary.json** -- rolling totals, can be rebuilt from JSONL

View actual costs:

```powershell
gsd-costs -ShowActual
```

Shows: actual costs by agent, by phase, run history, estimated vs actual comparison.

### 10.4 Client Quoting

```powershell
gsd-costs -TotalItems 300 -ClientQuote -Markup 8 -ClientName "Acme Corp"
```

Three-tier pricing: Best case, Expected case, Worst case.

**Complexity tiers:**

| Tier | Item Count | Suggested Markup |
|---|---|---|
| Standard | <=100 | 5x |
| Complex | <=250 | 7x |
| Enterprise | <=500 | 7-10x |
| Enterprise+ | >500 | 10x |

**Subscription cost comparison (for context):**

| Service | Monthly Cost |
|---|---|
| Claude Pro | $20 |
| Claude Max | $100-200 |
| ChatGPT Plus | $20 |
| ChatGPT Pro | $200 |
| Minimum bundle (Pro tiers) | $60/month |

---

## Appendices

### Appendix A: Complete File Inventory

**Global installation (~/.gsd-global/):**

| File | Description |
|---|---|
| bin/gsd-converge.cmd | Convergence loop CLI wrapper |
| bin/gsd-blueprint.cmd | Blueprint pipeline CLI wrapper |
| bin/gsd-status.cmd | Health dashboard CLI wrapper |
| bin/gsd-remote.cmd | Remote monitoring CLI wrapper |
| bin/gsd-costs.cmd | Token cost calculator CLI wrapper |
| config/global-config.json | Notifications, patterns, phase order |
| config/agent-map.json | Phase-to-agent assignments |
| lib/modules/resilience.ps1 | Core resilience (retry, checkpoint, lock, costs, notifications) |
| lib/modules/supervisor.ps1 | Self-healing supervisor system |
| lib/modules/interfaces.ps1 | Multi-interface detection |
| lib/modules/interface-wrapper.ps1 | Context builder for prompts |
| prompts/claude/*.md | Claude prompt templates |
| prompts/codex/*.md | Codex prompt templates |
| prompts/gemini/*.md | Gemini prompt templates |
| blueprint/scripts/blueprint-pipeline.ps1 | Blueprint pipeline |
| blueprint/scripts/assess.ps1 | Assessment script |
| scripts/convergence-loop.ps1 | Convergence engine |
| scripts/supervisor-converge.ps1 | Supervisor wrapper (convergence) |
| scripts/supervisor-blueprint.ps1 | Supervisor wrapper (blueprint) |
| scripts/gsd-profile-functions.ps1 | PowerShell profile functions |
| scripts/token-cost-calculator.ps1 | Cost estimator |
| supervisor/pattern-memory.jsonl | Cross-project failure patterns |
| pricing-cache.json | Cached LLM pricing |
| KNOWN-LIMITATIONS.md | Scenario matrix |
| VERSION | Version stamp |

**Per-project (.gsd/):**

| File | Description |
|---|---|
| assessment/assessment-summary.md | Human-readable assessment findings |
| assessment/work-classification.json | Skip/fix/build/review classification |
| assessment/backend-inventory.json | C# controllers, services, DTOs |
| assessment/database-inventory.json | Tables, stored procedures, views |
| assessment/frontend-inventory.json | React screens, components, hooks |
| assessment/file-inventory.json | Complete file catalog |
| health/health-current.json | Current health score and breakdown |
| health/health-history.jsonl | Score progression over iterations |
| health/requirements-matrix.json | Every requirement with status |
| health/drift-report.md | Gaps between specs and code |
| health/review-current.md | Latest review findings |
| health/engine-status.json | Live engine state |
| health/final-validation.json | Quality gate results |
| costs/token-usage.jsonl | Per-call token and cost log |
| costs/cost-summary.json | Rolling cost totals |
| supervisor/supervisor-state.json | Recovery attempt tracking |
| supervisor/error-context.md | Injected error context |
| supervisor/prompt-hints.md | Persistent agent constraints |
| supervisor/escalation-report.md | Human intervention guide |
| generation-queue/queue-current.json | Next batch items |
| agent-handoff/current-assignment.md | Execute/build agent instructions |
| logs/errors.jsonl | Categorized error log |
| logs/iter{N}-{phase}.log | Per-iteration agent output |
| blueprint/blueprint.json | Full project manifest |
| file-map.json | Machine-readable repo inventory |
| file-map-tree.md | Human-readable directory tree |
| spec-consistency-report.json | Spec conflict analysis |
| .gsd-checkpoint.json | Crash recovery state |
| .gsd-lock | Concurrent run prevention |

### Appendix B: Prompt Templates

| Template | Agent | Purpose | Est. Output |
|---|---|---|---|
| claude/code-review.md | Claude | Scan repo vs matrix, score health | ~3K tokens |
| claude/create-phases.md | Claude | Extract requirements from specs | ~5K tokens |
| claude/plan.md | Claude | Select and prioritize next batch | ~3K tokens |
| claude/assess.md | Claude | Analyze existing codebase | ~5K tokens |
| claude/blueprint.md | Claude | Generate blueprint manifest | ~5K tokens |
| claude/verify.md | Claude | Verify items against specs | ~3K tokens |
| claude/verify-storyboard.md | Claude | Storyboard-aware verification | ~3K tokens |
| codex/execute.md | Codex | Generate code for batch | ~50K+ tokens |
| codex/build.md | Codex | Generate code from blueprint | ~80K+ tokens |
| codex/research.md | Codex | Research codebase (fallback) | ~10K+ tokens |
| gemini/research.md | Gemini | Research specs, Figma, codebase | ~10K+ tokens |
| gemini/spec-fix.md | Gemini | Auto-resolve spec conflicts | ~2K tokens |

### Appendix C: Notification Events

| Event | Priority | When |
|---|---|---|
| iteration_complete | default | Each iteration finishes |
| converged | high | Health reaches 100% + validation passes |
| stalled | high | Stall threshold reached |
| quota_exhausted | high | Agent quota depleted |
| error | high | Unrecoverable error |
| heartbeat | low | Every 10 minutes (background) |
| agent_timeout | high | Watchdog killed hung agent |
| build_failed | default | Build validation failed |
| regression_reverted | default | Health regression auto-reverted |
| no_progress | default | Iteration with no health improvement |
| execute_failed | default | Execute/build phase failed |
| progress_response | min | Response to "progress" command |
| supervisor_active | default | Supervisor activated |
| supervisor_diagnosis | default | Diagnosis complete |
| supervisor_fix | default | Fix applied |
| supervisor_restart | default | Pipeline restarting |
| supervisor_recovered | high | Recovery successful |
| supervisor_escalation | urgent | All strategies exhausted |
| validation_failed | high | Final validation gate failed |
| validation_passed | high | Final validation gate passed |

### Appendix D: Error Categories

| Category | Description |
|---|---|
| quota | API quota exhausted, engine sleeping until reset |
| network | Network connectivity lost, polling until restored |
| disk | Disk space critically low |
| corrupt_json | JSON state file corrupted, restored from backup |
| boundary_violation | Agent wrote outside allowed scope, changes reverted |
| agent_crash | Agent CLI crashed (exit code != 0) |
| health_regression | Health dropped >5% after iteration, auto-reverted |
| spec_conflict | Contradictions found in specification documents |
| watchdog_timeout | Agent hung past timeout, process killed |
| build_fail | dotnet build or npm build failed |
| fallback_success | Primary agent failed, fallback agent succeeded |
| validation_fail | Final validation gate check failed |

### Appendix E: Glossary

| Term | Definition |
|---|---|
| **Convergence** | Iterative loop that drives code toward 100% specification compliance |
| **Blueprint** | Manifest listing every file a project needs, generated from specifications |
| **Health Score** | Percentage of requirements satisfied (0-100%) |
| **Iteration** | One complete cycle through all pipeline phases |
| **Batch Size** | Number of items processed per execute/build phase |
| **Stall Threshold** | Number of consecutive iterations with no health improvement before stopping |
| **Supervisor** | Meta-loop that diagnoses and fixes pipeline failures automatically |
| **Watchdog** | Timer that kills hung agent processes after 30 minutes |
| **Checkpoint** | Saved pipeline state enabling crash recovery and resume |
| **Drift Report** | Gap analysis between specifications and current code |
| **Pattern Memory** | Cross-project database of failure patterns and their fixes |
| **Final Validation** | 7-check quality gate triggered when health reaches 100% |
| **Developer Handoff** | Auto-generated report with everything needed to run the project |
| **ntfy** | Free push notification service used for mobile monitoring |
| **Token** | Unit of text processed by an AI model (roughly 4 characters) |
| **Agent Boundary** | Scope restrictions on what each AI agent can read and write |
| **Spec Consistency** | Pre-check for contradictions across specification documents |
| **Interface** | A distinct frontend type (web, mcp, browser, mobile, agent) |
| **Figma Make** | Design analysis tool that produces 12 deliverable files per interface |
| **Escalation** | When supervisor exhausts recovery attempts and alerts a human |
| **Idempotent** | Safe to re-run without side effects; produces same result each time |

---

*Generated from GSD Autonomous Development Engine v1.1.0 source documentation and scripts.*

*To convert to Word document:*
```
pandoc docs/GSD-Developer-Guide.md -o GSD-Developer-Guide.docx --reference-doc=template.docx --toc --toc-depth=3
```
