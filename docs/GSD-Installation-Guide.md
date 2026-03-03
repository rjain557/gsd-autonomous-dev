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

This runs all 14 install/patch scripts in dependency order. The installer also runs `install-gsd-prerequisites.ps1` first as a pre-flight check. On first run, `install-gsd-global.ps1` (Step 0) prompts for API keys if they are not already configured.

| Order | Script | What It Installs |
|-------|--------|-----------------|
| 1 | install-gsd-global.ps1 | API key setup (Step 0), global directory, engine, config, profile, gsd-costs |
| 2 | install-gsd-blueprint.ps1 | Blueprint pipeline, assess script, prompts |
| 3 | patch-gsd-partial-repo.ps1 | gsd-assess command, file map generation |
| 4 | patch-gsd-resilience.ps1 | Resilience module (retry, checkpoint, lock, watchdog timeout) |
| 5 | patch-gsd-hardening.ps1 | Hardening (quota, network, boundary, notifications, heartbeat) |
| 6 | patch-gsd-figma-make.ps1 | Interface detection, _analysis/_stubs discovery |
| 7 | final-patch-1-spec-check.ps1 | Spec consistency checker |
| 8 | final-patch-2-sql-cli.ps1 | SQL validation, CLI version checks |
| 9 | final-patch-3-storyboard-verify.ps1 | Storyboard-aware verification prompts |
| 10 | final-patch-4-blueprint-pipeline.ps1 | Final blueprint pipeline with all features |
| 11 | final-patch-5-convergence-pipeline.ps1 | Final convergence loop with all features |
| 12 | final-patch-6-assess-limitations.ps1 | Final assess script with known limitations |
| 13 | final-patch-7-spec-resolve.ps1 | Spec conflict auto-resolution via Gemini |
| 14 | patch-gsd-supervisor.ps1 | Self-healing supervisor (recovery, error context, pattern memory) |

Optional standalone scripts (not run by installer):
- **setup-gsd-api-keys.ps1** -- manage API key environment variables (set, show, clear)
- **setup-gsd-convergence.ps1** -- per-project convergence config (run manually if needed)
- **install-gsd-keybindings.ps1** -- VS Code keyboard shortcuts (Ctrl+Shift+G chords)
- **token-cost-calculator.ps1** -- token cost estimator (also installed globally as `gsd-costs` by install-gsd-global.ps1)

The repository contains 20 scripts total: 1 master installer, 1 pre-flight check, 14 core install/patch scripts, and 4 standalone utilities.

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
    agent-map.json              # Agent-to-phase assignments
  lib\modules\
    resilience.ps1              # Retry, checkpoint, lock, rollback, adaptive batch, hardening
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
