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

Each CLI must be authenticated before first use:

```powershell
# Claude Code
claude    # Follow interactive auth flow

# Codex
codex     # Follow interactive auth flow

# Gemini (optional)
gemini    # Follow interactive auth flow
```

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

This runs all 14 install/patch scripts in dependency order:

| Order | Script | What It Installs |
|-------|--------|-----------------|
| 1 | install-gsd-prerequisites.ps1 | Verifies all required CLIs |
| 2 | install-gsd-global.ps1 | Global directory, engine, config, profile |
| 3 | install-gsd-blueprint.ps1 | Blueprint pipeline, assess script, prompts |
| 4 | setup-gsd-convergence.ps1 | Convergence loop config, phase definitions |
| 5 | install-gsd-keybindings.ps1 | VS Code keyboard shortcuts |
| 6 | patch-gsd-partial-repo.ps1 | gsd-assess command, file map generation |
| 7 | patch-gsd-resilience.ps1 | Resilience module (retry, checkpoint, lock, watchdog timeout) |
| 8 | patch-gsd-hardening.ps1 | Hardening (quota, network, boundary, notifications, heartbeat) |
| 9 | patch-gsd-figma-make.ps1 | Interface detection, _analysis/_stubs discovery |
| 10 | final-patch-1-spec-check.ps1 | Spec consistency checker |
| 11 | final-patch-2-sql-cli.ps1 | SQL validation, CLI version checks |
| 12 | final-patch-3-storyboard-verify.ps1 | Storyboard-aware verification prompts |
| 13 | final-patch-4-blueprint-pipeline.ps1 | Final blueprint pipeline with all features |
| 14 | final-patch-5-convergence-pipeline.ps1 | Final convergence loop with all features |
| 15 | final-patch-6-assess-limitations.ps1 | Final assess script with known limitations |
| 16 | final-patch-7-spec-resolve.ps1 | Spec conflict auto-resolution via Gemini |

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
  bin\                          # CLI wrappers
    gsd-converge.cmd            # Convergence loop launcher
    gsd-remote.cmd              # Remote monitoring launcher
  config\
    global-config.json          # Global settings (notifications, patterns, phases)
  lib\modules\
    resilience.ps1              # Retry, checkpoint, lock, rollback, adaptive batch
    interfaces.ps1              # Multi-interface detection + auto-discovery
    interface-wrapper.ps1       # Context builder for agent prompts
  prompts\
    claude\                     # Claude Code prompt templates
    codex\                      # Codex prompt templates
    gemini\                     # Gemini prompt templates
  blueprint\
    scripts\
      blueprint-pipeline.ps1    # Blueprint generation + build loop
      assess.ps1                # Assessment script
  scripts\
    convergence-loop.ps1        # 5-phase convergence engine
    gsd-profile-functions.ps1   # PowerShell profile functions
    token-cost-calculator.ps1   # Token cost estimator
  pricing-cache.json            # Cached LLM pricing data
  VERSION                       # Installed version stamp
```

## First Project Setup

### Using Blueprint Pipeline (new projects)

Best for building a project from specifications (greenfield development).

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

Best for fixing and improving existing codebases against specifications.

```powershell
cd C:\path\to\your\repo

# Initialize and assess
gsd-init
gsd-assess

# Run convergence loop
gsd-converge
```

### Estimating Costs Before Starting

```powershell
# Quick estimate from blueprint
gsd-costs -ProjectPath "C:\repos\my-app"

# Manual estimate for a new project
gsd-costs -TotalItems 150 -Pipeline blueprint

# Full comparison of both pipelines
gsd-costs -TotalItems 150 -ShowComparison
```

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
```

Per-project data is stored in each repo's .gsd/ folder. Delete it to remove project state:

```powershell
Remove-Item -Recurse -Force .gsd
```
