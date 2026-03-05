# GSD Installation Guide

## Prerequisites

### Required Software

| Tool | Version | Install Command |
|------|---------|----------------|
| PowerShell | 5.1+ (Windows) or 7+ (cross-platform) | Pre-installed on Windows |
| Node.js | 18+ | `winget install OpenJS.NodeJS.LTS` |
| npm | 9+ | Included with Node.js |
| .NET SDK | 8.x | `winget install Microsoft.DotNet.SDK.8` |
| Git | 2.x+ | `winget install Git.Git` |
| Claude Code CLI | Latest | `npm install -g @anthropic-ai/claude-code` |
| Codex CLI | Latest | `npm install -g @openai/codex` |

### Optional Software

| Tool | Purpose | Install Command |
|------|---------|----------------|
| Gemini CLI | Three-model optimization (research, spec-fix) | `npm install -g @google/gemini-cli` |
| sqlcmd | SQL syntax validation | `winget install Microsoft.SqlServer.SqlCmd` |
| ntfy app | Mobile push notifications | iOS App Store / Google Play |

### CLI Authentication

Each CLI must be authenticated before first use. There are two methods:

**Method 1: Interactive Login (default)**

```powershell
# Claude Code
claude    # Follow interactive auth flow

# Codex
codex     # Follow interactive auth flow

# Gemini (optional -- uses Google OAuth, opens browser)
gemini    # Follow interactive OAuth flow
```

**Method 2: API Keys (recommended for autonomous pipelines)**

API keys bypass interactive rate limits and allow higher throughput. The installer prompts for API keys during setup (Step 0), or you can configure them separately:

```powershell
# Interactive setup (prompts for each key)
powershell -ExecutionPolicy Bypass -File scripts/setup-gsd-api-keys.ps1

# Check current key status
powershell -ExecutionPolicy Bypass -File scripts/setup-gsd-api-keys.ps1 -Show
```

API keys are stored as persistent User-level environment variables (never committed to git):

| Environment Variable | CLI | Get Key From |
|---------------------|-----|-------------|
| ANTHROPIC_API_KEY | Claude Code | https://console.anthropic.com/settings/keys |
| OPENAI_API_KEY | Codex | https://platform.openai.com/api-keys |
| GOOGLE_API_KEY | Gemini | https://aistudio.google.com/apikey |

You can use either method (or both). API keys take priority when set. See the setup-gsd-api-keys.ps1 section in the Script Reference for full details.

### REST Agent API Keys (Optional)

The engine supports 4 additional REST API agents that expand the rotation pool from 3 to 7. These are optional — agents without keys are silently excluded from rotation.

| Environment Variable | Provider | Model | Key Source |
|---------------------|----------|-------|-----------|
| KIMI_API_KEY | Moonshot AI | Kimi K2.5 | https://platform.moonshot.ai |
| DEEPSEEK_API_KEY | DeepSeek | DeepSeek V3 | https://platform.deepseek.com |
| GLM_API_KEY | Zhipu AI | GLM-5 | https://z.ai |
| MINIMAX_API_KEY | MiniMax | MiniMax M2.5 | https://platform.minimaxi.com |

Set keys as persistent User-level environment variables:

```powershell
[System.Environment]::SetEnvironmentVariable("KIMI_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("DEEPSEEK_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("GLM_API_KEY", "your-key-here", "User")
[System.Environment]::SetEnvironmentVariable("MINIMAX_API_KEY", "your-key-here", "User")
```

No terminal restart is needed — the engine auto-loads User-level keys during preflight. You can verify detection by running any pipeline and checking the preflight output:

```
  [OK] KIMI_API_KEY set (REST agent: kimi)
  [OK] DEEPSEEK_API_KEY set (REST agent: deepseek)
  [OK] GLM_API_KEY set (REST agent: glm5)
  [OK] MINIMAX_API_KEY set (REST agent: minimax)
  4 REST agent(s) available for rotation
```

Benefits of adding REST agents:
- **Immediate rotation**: When any CLI agent hits quota, the engine rotates to the next available agent instantly (no 5-minute sleep)
- **7 independent quota pools**: Virtually eliminates quota-induced stalls during long autonomous runs
- **Cost-effective**: REST API pricing is competitive (DeepSeek: $0.28/$0.42 per million input/output tokens)

## Quick Start

### Step 1: Clone the Repository

```powershell
git clone <your-gsd-repo-url>
cd gsd-autonomous-dev
```

### Step 2: Run the Master Installer

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-all.ps1
```

This runs all 35 install/patch scripts in dependency order. The installer also runs `install-gsd-prerequisites.ps1` first as a pre-flight check. On first run, `install-gsd-global.ps1` (Step 0) prompts for CLI agent API keys if they are not already configured.

| Order | Script | What It Installs |
|-------|--------|-----------------|
| 1 | install-gsd-global.ps1 | API key setup (Step 0), global directory, engine, config, profile, gsd-costs |
| 2 | install-gsd-blueprint.ps1 | Blueprint pipeline, assess script, prompts |
| 3 | patch-gsd-partial-repo.ps1 | gsd-assess command, file map generation |
| 4 | patch-gsd-resilience.ps1 | Resilience module (retry, checkpoint, lock, watchdog timeout) |
| 5 | patch-gsd-hardening.ps1 | Hardening (quota, network, boundary, notifications, heartbeat) |
| 6 | patch-gsd-final-validation.ps1 | Final validation gate + developer handoff report |
| 7 | patch-gsd-figma-make.ps1 | Interface detection, _analysis/_stubs discovery |
| 8 | final-patch-1-spec-check.ps1 | Spec consistency checker |
| 9 | final-patch-2-sql-cli.ps1 | SQL validation, CLI version checks |
| 10 | final-patch-3-storyboard-verify.ps1 | Storyboard-aware verification prompts |
| 11 | final-patch-4-blueprint-pipeline.ps1 | Final blueprint pipeline with all features |
| 12 | final-patch-5-convergence-pipeline.ps1 | Final convergence loop with all features |
| 13 | final-patch-6-assess-limitations.ps1 | Final assess script with known limitations |
| 14 | final-patch-7-spec-resolve.ps1 | Spec conflict auto-resolution via Gemini |
| 15 | patch-gsd-supervisor.ps1 | Self-healing supervisor (recovery, error context, pattern memory) |
| 16 | patch-false-converge-fix.ps1 | Fix false convergence exit + orphaned profile code |
| 17 | patch-gsd-council.ps1 | LLM Council (multi-agent review gate at 100% health) |
| 18 | patch-gsd-parallel-execute.ps1 | Parallel sub-task execution (split batch, round-robin agents) |
| 19 | patch-gsd-resilience-hardening.ps1 | Resilience hardening (token tracking, auth fix, quota cap, agent rotation) |
| 20 | patch-gsd-quality-gates.ps1 | Quality gates (DB completeness, security compliance, spec validation) |
| 21 | patch-gsd-multi-model.ps1 | Multi-model LLM integration (Kimi, DeepSeek, GLM-5, MiniMax REST agents) |
| 22 | patch-gsd-differential-review.ps1 | Differential code review (review only changed files, cache state) |
| 23 | patch-gsd-pre-execute-gate.ps1 | Pre-execute compile gate (build validation before commit) |
| 24 | patch-gsd-acceptance-tests.ps1 | Per-requirement acceptance tests (auto-generate + run per req) |
| 25 | patch-gsd-api-contract-validation.ps1 | Contract-first API validation (controller vs OpenAPI spec) |
| 26 | patch-gsd-visual-validation.ps1 | Visual validation (Figma screenshot diff via Playwright) |
| 27 | patch-gsd-design-token-enforcement.ps1 | Design token enforcement (CSS/style hardcoded value scan) |
| 28 | patch-gsd-compliance-engine.ps1 | Compliance engine (per-iteration audit, DB migration, PII tracking) |
| 29 | patch-gsd-speed-optimizations.ps1 | Speed optimizations (research skip, smart batch, prompt dedup) |
| 30 | patch-gsd-agent-intelligence.ps1 | Agent intelligence (performance scoring, warm-start patterns) |
| 31 | patch-gsd-loc-tracking.ps1 | LOC tracking (lines of code metrics, cost-per-line, ntfy) |
| 32 | patch-gsd-runtime-smoke-test.ps1 | Runtime smoke test (DI validation, API 500 check, FK seed order) |
| 33 | patch-gsd-partitioned-code-review.ps1 | Partitioned code review (3-way parallel, agent rotation) |
| 34 | patch-gsd-loc-cost-integration.ps1 | LOC-Cost integration (cost-per-line, review LOC awareness, ntfy) |
| 35 | patch-gsd-maintenance-mode.ps1 | Maintenance mode (gsd-fix, gsd-update, --Scope, --Incremental) |

Optional standalone scripts (not run by installer):
- **setup-gsd-api-keys.ps1** -- manage CLI agent API key environment variables (set, show, clear)
- **setup-gsd-convergence.ps1** -- per-project convergence config (run manually if needed)
- **install-gsd-keybindings.ps1** -- VS Code keyboard shortcuts (Ctrl+Shift+G chords)
- **token-cost-calculator.ps1** -- token cost estimator (also installed globally as `gsd-costs` by install-gsd-global.ps1)

The repository contains 41 scripts total: 1 master installer, 1 pre-flight check, 35 scripts run by installer (31 core patches + 1 bug fix + 1 resilience hardening + 1 maintenance mode + 1 LOC-cost integration), and 4 standalone utilities.

### Step 3: Restart Terminal

Close and reopen your terminal (or run `. $PROFILE`) to load the gsd-* commands.

### Step 4: Verify Installation

```powershell
# Verify commands are available
gsd-status

# Verify prerequisites
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-prerequisites.ps1 -VerifyOnly
```

## Installed Directory Structure

After installation, the engine creates:

```
%USERPROFILE%\.gsd-global\
  bin\                          # CLI wrappers (added to PATH)
    gsd-converge.cmd            # Convergence loop launcher
    gsd-blueprint.cmd           # Blueprint pipeline launcher
    gsd-status.cmd              # Health status dashboard
    gsd-remote.cmd              # Remote monitoring launcher
    gsd-costs.cmd               # Token cost calculator
  config\
    global-config.json          # Global settings (notifications, patterns, phases)
    agent-map.json              # Agent-to-phase assignments, parallel config, council reviewers
    model-registry.json         # Multi-model registry (CLI + REST agent metadata, rotation pool)
  lib\modules\
    resilience.ps1              # Retry, checkpoint, lock, rollback, adaptive batch, hardening, final validation
    supervisor.ps1              # Self-healing supervisor (diagnosis, fix, pattern memory)
    interfaces.ps1              # Multi-interface detection + auto-discovery
    interface-wrapper.ps1       # Context builder for agent prompts
  prompts\
    claude\                     # Claude Code prompt templates (review, plan, verify, assess)
    codex\                      # Codex prompt templates (execute, research fallback)
    gemini\                     # Gemini prompt templates (research, spec-fix)
  blueprint\
    scripts\
      blueprint-pipeline.ps1    # Blueprint generation + build loop
      supervisor-blueprint.ps1  # Supervisor wrapper for blueprint
      assess.ps1                # Assessment script (gsd-assess)
  scripts\
    convergence-loop.ps1        # 5-phase convergence engine
    supervisor-converge.ps1     # Supervisor wrapper for convergence
    gsd-profile-functions.ps1   # PowerShell profile functions
    token-cost-calculator.ps1   # Token cost estimator (gsd-costs)
  supervisor\
    pattern-memory.jsonl        # Cross-project failure patterns + fixes
  pricing-cache.json            # Cached LLM pricing data (auto-updated)
  KNOWN-LIMITATIONS.md          # Full scenario matrix
  VERSION                       # Installed version stamp
```

## First Project Setup

### Blueprint vs Convergence: Which Pipeline to Use

| Scenario | Recommended Pipeline | Why |
|----------|---------------------|-----|
| New project, no existing code | `gsd-blueprint` | Generates code from specs via blueprint manifest |
| New project, partial code exists (scaffolding, some screens) | `gsd-assess` then `gsd-blueprint -BuildOnly` | Assessment classifies existing code; blueprint fills gaps |
| Existing project, needs fixes/improvements | `gsd-converge` | Reviews code against specs, fixes issues iteratively |
| Blueprint reached 60-80%, stuck on last mile | Switch to `gsd-converge` | Convergence handles iterative fix-and-verify better for remaining gaps |
| Quick assessment only, no code changes | `gsd-assess` | Produces work classification and inventories without modifying code |

**Decision heuristic**: If you have specification documents and need to build from scratch, start with `gsd-blueprint`. If you have an existing codebase that needs to match specs, use `gsd-converge`. You can switch between them at any point -- they share the same `.gsd/` state.

### What Happens at 100% Health

When the engine reaches 100% health (all requirements matched), it runs a **final validation gate** before declaring success:

1. **Compilation check**: Runs `dotnet build` and/or `npm run build` -- must pass
2. **Test execution**: Runs `dotnet test` and/or `npm test` -- must pass (if tests exist)
3. **SQL validation**: Checks SQL patterns -- advisory only
4. **Vulnerability audit**: Checks NuGet and npm dependencies -- advisory only
5. **Runtime smoke test**: Starts the application, hits API endpoints, checks for 500 errors, DI container errors, and FK constraint violations -- must pass

If compilation, tests, or runtime smoke tests fail, health is set to 99% and the engine automatically loops to fix the issues (up to 3 validation attempts).

When the pipeline exits (converged, stalled, or max iterations), it generates `developer-handoff.md` in the repository root with build commands, database setup, environment configuration, requirements status, validation results, known issues, and cost summary.

### Using Blueprint Pipeline (new projects)

Best for building a project from specifications (greenfield development). Actual API token costs are automatically tracked in `.gsd/costs/` from the first run.

```powershell
cd C:\path\to\your\repo

# Ensure your specs are in place:
#   design\{type}\v##\_analysis\   (12 Figma Make deliverables)
#   design\{type}\v##\_stubs\      (backend stubs)
#   docs\                          (SDLC Phase A-E specs)

# Initialize and assess
gsd-init
gsd-assess

# Run blueprint pipeline
gsd-blueprint
```

### Using Convergence Pipeline (existing projects)

Best for fixing and improving existing codebases against specifications. Actual API token costs are automatically tracked in `.gsd/costs/` from the first run.

```powershell
cd C:\path\to\your\repo

# Initialize and assess
gsd-init
gsd-assess

# Run convergence loop
gsd-converge
```

### Estimating and Tracking Costs

```powershell
# Quick estimate from blueprint
gsd-costs -ProjectPath "C:\repos\my-app"

# Manual estimate for a new project
gsd-costs -TotalItems 150 -Pipeline blueprint

# Full comparison of both pipelines
gsd-costs -TotalItems 150 -ShowComparison

# After running a pipeline, view actual costs vs estimates
gsd-costs -ShowActual
```

Actual costs are tracked automatically from the first pipeline run. Use `-ShowActual` at any time to see actual costs, breakdown by agent and phase, run history, and an estimated vs actual comparison table.

## Mobile Monitoring Setup

### Push Notifications (ntfy.sh)

1. Install the ntfy app on your phone (free, no account required)
2. Run any pipeline once -- note the topic at startup: `ntfy topic (auto): gsd-rjain-patient-portal`
3. Subscribe to that topic in the ntfy app
4. Repeat for each project you monitor

### Remote Control (QR Code)

```powershell
gsd-remote    # Displays QR code -- scan with phone
```

## Re-Installing / Updating

The installer is idempotent. Re-run to pick up updates:

```powershell
cd gsd-autonomous-dev
git pull
powershell -ExecutionPolicy Bypass -File scripts/install-gsd-all.ps1
```

Existing configurations and project data (.gsd/ folders) are preserved.

## Uninstalling

To remove the global engine:

```powershell
# Remove global engine
Remove-Item -Recurse -Force "$env:USERPROFILE\.gsd-global"

# Remove profile entries (manual -- edit $PROFILE and remove gsd-related lines)
notepad $PROFILE

# Remove API key environment variables (optional)
powershell -ExecutionPolicy Bypass -File scripts/setup-gsd-api-keys.ps1 -Clear
```

Per-project data is stored in each repo's .gsd/ folder. Delete it to remove project state:

```powershell
Remove-Item -Recurse -Force .gsd
```
