# GSD Script Reference

## Commands (available after install)

### gsd-assess

Scans codebase, detects interfaces, generates file map, runs Claude assessment.

Usage:

```powershell
gsd-assess              # Full assessment
gsd-assess -MapOnly     # Regenerate file map without Claude assessment
gsd-assess -DryRun      # Preview without executing
```

Output: .gsd\assessment\ folder with inventories and work classification.

### gsd-converge

Runs 5-phase convergence loop to fix existing code issues. Uses three agents: Claude (review, plan, verify), Gemini (research), and Codex (execute).

Usage:

```powershell
gsd-converge                          # Full convergence
gsd-converge -SkipResearch            # Skip Gemini/Codex research phase (saves tokens)
gsd-converge -DryRun                  # Preview without executing
gsd-converge -MaxIterations 5         # Limit iterations
gsd-converge -ThrottleSeconds 60      # 60s delay between phases
gsd-converge -AutoResolve             # Auto-fix spec conflicts via Gemini
gsd-converge -NtfyTopic "my-topic"    # Override notification topic
```

Parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| -DryRun | false | Preview mode, no agent calls or code changes |
| -SkipInit | false | Skip initial requirements check, use existing matrix |
| -SkipResearch | false | Skip Gemini/Codex research phase (saves tokens) |
| -SkipSpecCheck | false | Skip spec consistency check before starting |
| -AutoResolve | false | Auto-resolve spec conflicts via Gemini (falls back to Codex) |
| -MaxIterations | 20 | Maximum convergence iterations |
| -StallThreshold | 3 | Stop after N iterations with no improvement |
| -ThrottleSeconds | 30 | Delay between agent calls to prevent quota exhaustion |
| -NtfyTopic | (auto) | Override ntfy.sh notification topic |

### gsd-blueprint

Generates code from specifications via blueprint manifest. Uses Claude (blueprint, verify), Codex (build), and Gemini (spec-fix when -AutoResolve).

Usage:

```powershell
gsd-blueprint                         # Full pipeline
gsd-blueprint -BlueprintOnly          # Generate manifest only, no build
gsd-blueprint -BuildOnly              # Resume build from existing manifest
gsd-blueprint -VerifyOnly             # Re-score without generating
gsd-blueprint -DryRun                 # Preview
gsd-blueprint -BatchSize 10           # Build 10 items per cycle
gsd-blueprint -AutoResolve            # Auto-fix spec conflicts via Gemini
gsd-blueprint -NtfyTopic "my-topic"   # Override notification topic
```

Parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| -DryRun | false | Preview mode |
| -BlueprintOnly | false | Generate manifest only, skip build and verify |
| -BuildOnly | false | Resume building from existing manifest |
| -VerifyOnly | false | Re-verify and re-score without generating code |
| -SkipSpecCheck | false | Skip spec consistency check before starting |
| -AutoResolve | false | Auto-resolve spec conflicts via Gemini (falls back to Codex) |
| -MaxIterations | 30 | Maximum build/verify iterations |
| -StallThreshold | 3 | Stop after N iterations with no improvement |
| -BatchSize | 15 | Number of blueprint items to build per cycle |
| -ThrottleSeconds | 30 | Delay between agent calls to prevent quota exhaustion |
| -NtfyTopic | (auto) | Override ntfy.sh notification topic |

### gsd-status

Displays health dashboard for current project.

Usage:

```powershell
gsd-status
```

Shows: current health score, iteration progress, batch sizes, throttling status, convergence/blueprint progress.

### gsd-init

Initializes the .gsd\ folder structure for the current project without running any iterations.

Usage:

```powershell
gsd-init
```

This creates the .gsd\ directory with config files, health templates, and log folders. Equivalent to running gsd-converge -MaxIterations 0.

### gsd-remote

Launches Claude remote control for phone-based monitoring via QR code.

Usage:

```powershell
gsd-remote
```

Displays a QR code in the terminal. Scan it with your phone to monitor and interact with the Claude session from anywhere. Press Ctrl+C to stop the remote session.

### gsd-costs

Estimates API token costs to complete a project to 100% using the GSD pipeline. Supports auto-detection from project data or manual parameter input. Includes dynamic pricing, pipeline comparison, client quoting, and subscription cost analysis.

Installed globally as `gsd-costs` command (available after terminal restart). Also available as `token-cost-calculator.ps1` in the scripts folder.

Usage:

```powershell
# Auto-detect from current project
gsd-costs

# Auto-detect from specific project
gsd-costs -ProjectPath "C:\repos\my-app"

# Manual estimate
gsd-costs -TotalItems 120 -CompletedItems 30

# Pipeline comparison (blueprint vs convergence)
gsd-costs -TotalItems 200 -ShowComparison

# Convergence with Opus pricing
gsd-costs -TotalItems 200 -Pipeline convergence -ClaudeModel opus

# Per-iteration cost breakdown
gsd-costs -TotalItems 150 -Detailed

# Force-update cached pricing
gsd-costs -UpdatePricing

# Client quote with 8x markup
gsd-costs -TotalItems 300 -ClientQuote -Markup 8 -ClientName "Acme Corp"
```

Parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| -ProjectPath | string | (current dir) | Path to project root with .gsd\blueprint\ |
| -TotalItems | int | 0 | Manual override: total blueprint items |
| -CompletedItems | int | 0 | Manual override: completed items |
| -PartialItems | int | 0 | Partial items (counted as 0.5 remaining) |
| -BatchSize | int | 15 | Items per build iteration |
| -Pipeline | string | "blueprint" | Pipeline type: "blueprint" or "convergence" |
| -BatchEfficiency | double | 0.70 | Success rate per batch (0.0-1.0) |
| -RetryRate | double | 0.15 | Fraction of iterations triggering retry |
| -ShowComparison | switch | false | Side-by-side blueprint vs convergence comparison |
| -ClaudeModel | string | "sonnet" | Claude model: "sonnet", "opus", or "haiku" |
| -Detailed | switch | false | Per-iteration cost breakdown (first 10) |
| -UpdatePricing | switch | false | Force-fetch latest pricing from LiteLLM |
| -ClientQuote | switch | false | Generate client-facing cost estimate |
| -Markup | double | 7.0 | Markup multiplier (used with -ClientQuote) |
| -ClientName | string | "Client Project" | Client name for quote header |

Output sections:

1. **Project Summary** -- pipeline, items, health, batch/efficiency, iterations
2. **Model Pricing** -- per-1M token costs with source and cache age
3. **Phase-by-Phase Breakdown** -- agent, iterations, input/output tokens, cost
4. **Cost by Agent** -- with visual bar chart
5. **Key Metrics** -- total tokens, cost per 1% health, cost per item, cost per iteration
6. **Historical Progression** -- adjusted estimate from actual health-history.jsonl data
7. **Subscription Comparison** -- API cost vs subscription cost at ~3 iterations/day
8. **Pipeline Comparison** -- side-by-side (with -ShowComparison)
9. **Per-Iteration Detail** -- first 10 iterations (with -Detailed)
10. **Client Quote** -- three-tier pricing, timeline, inclusions, margin analysis (with -ClientQuote)

Pricing source: LiteLLM open-source database, cached at %USERPROFILE%\.gsd-global\pricing-cache.json (auto-refreshed every 14 days).

## Push Notifications

### Automatic Topic Detection

When you run gsd-converge or gsd-blueprint, the engine auto-generates a unique ntfy.sh topic:

```
gsd-{username}-{reponame}
```

The topic prints at startup:

```
  ntfy topic (auto): gsd-rjain-patient-portal
```

Subscribe to this topic in the ntfy app on your phone to receive real-time pipeline notifications.

### Per-Project Isolation

Each project gets its own topic, so running multiple projects simultaneously sends notifications to separate channels:

```
Project A: gsd-rjain-patient-portal
Project B: gsd-rjain-billing-api
Project C: gsd-rjain-admin-dashboard
```

### Topic Override

Override the auto-detected topic using any of these methods:

1. **Per-run**: `gsd-converge -NtfyTopic "my-custom-topic"`
2. **Global config**: Set ntfy_topic in %USERPROFILE%\.gsd-global\config\global-config.json to a specific topic string
3. **Auto (default)**: Set ntfy_topic to "auto" or leave it unset

### Topic Sanitization

Special characters in usernames and repo names are automatically handled:
- Dots, underscores, spaces become hyphens
- All characters lowercased
- Consecutive hyphens collapsed
- Leading/trailing hyphens removed

Examples: `my.project.v2` becomes `my-project-v2`, `My_App` becomes `my-app`

## Installation Scripts

### install-gsd-all.ps1

Master installer. Runs all 13 scripts in dependency order. Idempotent (safe to re-run for updates).

Usage:

```powershell
powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1
```

Creates %USERPROFILE%\.gsd-global\ with all engine files and adds gsd-* commands to PowerShell profile.

### install-gsd-prerequisites.ps1

Checks all required tools and installs missing ones via winget/npm.

Usage:

```powershell
powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1
powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1 -VerifyOnly
```

Required CLIs: claude, codex, dotnet, node, npm. Optional: gemini (for three-model optimization), sqlcmd (for SQL validation).

### install-gsd-keybindings.ps1

Adds VS Code keyboard shortcuts (Ctrl+Shift+G chords).

## Core Scripts (executed by installer)

### install-gsd-global.ps1 (Script 1)

Creates the global %USERPROFILE%\.gsd-global\ directory structure with: convergence engine (convergence-loop.ps1), token cost calculator (token-cost-calculator.ps1), bin/ CLI wrappers (gsd-converge.cmd, gsd-remote.cmd, gsd-costs.cmd), VS Code tasks.json, PATH entries, global-config.json with notification settings, prompt templates for Claude/Codex/Gemini, and PowerShell profile functions (gsd-converge, gsd-costs, gsd-status, gsd-assess, gsd-remote).

### install-gsd-blueprint.ps1 (Script 2)

Installs the blueprint pipeline (blueprint-pipeline.ps1), assessment script (assess.ps1), blueprint prompt templates, agent configurations, and profile functions (gsd-blueprint, gsd-init). Creates the blueprint/ subdirectory structure within .gsd-global.

### setup-gsd-convergence.ps1 (Script 3)

Sets up convergence loop configuration and phase definitions. Creates the .gsd/ folder structure for autonomous convergence, detects the latest Figma design version from design\figma\v##, references SDLC spec docs (Phase A through Phase E), creates the convergence-loop.ps1 orchestrator, config templates, and agent prompt files.

### patch-gsd-partial-repo.ps1 (Script 4)

Installs gsd-assess command, assessment prompts, file map generation, -MapOnly flag.

### patch-gsd-resilience.ps1 (Script 5)

Installs resilience.ps1 module: Invoke-WithRetry (with watchdog timeout), Save-Checkpoint, Restore-Checkpoint, New-Lock, Remove-Lock, Save-GsdSnapshot, Invoke-AdaptiveBatch. Agent calls run in isolated child processes with a 30-minute watchdog that kills hung agents and retries.

### patch-gsd-hardening.ps1 (Script 6)

Appends hardening to resilience.ps1: Wait-ForQuotaReset, Test-NetworkAvailability, Backup-JsonState, Set-AgentBoundary, Update-FileMap, Get-GsdNtfyTopic, Send-GsdNotification, Send-HeartbeatIfDue, Initialize-GsdNotifications, Test-HealthRegression, Write-GsdError.

### patch-gsd-figma-make.ps1 (Script 7)

Installs interfaces.ps1 module: Find-ProjectInterfaces, Initialize-ProjectInterfaces, Show-InterfaceSummary, Get-InterfaceContext. Recursive design folder discovery, _analysis/_stubs auto-discovery, folder inventory.

### final-patch-1-spec-check.ps1 (Script 8)

Adds Invoke-SpecConsistencyCheck to resilience.ps1. Pre-checks specs for conflicts before pipeline runs. Detects: data_type, api_contract, navigation, business_rule, design_system, database, missing_ref conflicts.

### final-patch-2-sql-cli.ps1 (Script 9)

Adds Test-SqlSyntaxWithSqlcmd, Test-SqlFiles, and Test-CliVersions to resilience.ps1. SQL pattern validation and CLI version compatibility checks.

### final-patch-3-storyboard-verify.ps1 (Script 10)

Installs storyboard-aware verification prompt for Claude. Traces data paths end-to-end through all layers.

### final-patch-4-blueprint-pipeline.ps1 (Script 11)

Final blueprint pipeline with file map updates, prompt injection, push notifications, throttling, spec check integration.

### final-patch-5-convergence-pipeline.ps1 (Script 12)

Final convergence loop with file map updates, prompt injection, push notifications, throttling, spec check integration.

### final-patch-6-assess-limitations.ps1 (Script 13)

Installs final assess.ps1 with Show-InterfaceSummary, Update-FileMap, -MapOnly, known limitations documentation.

### final-patch-7-spec-resolve.ps1 (Script 14)

Adds spec conflict auto-resolution via Gemini agent (`--yolo`). Installs Invoke-SpecConflictResolution function and wires -AutoResolve flag into both pipelines. Falls back to Codex if Gemini CLI is not available.

## Key Functions (in resilience.ps1)

### Invoke-WithRetry

Calls an AI agent with retry logic, batch reduction, watchdog timeout, and quota-aware backoff. Each agent call runs in an isolated child process with a configurable watchdog timer (default: 30 minutes). If the agent hangs, the watchdog kills the process tree, halves the batch, sends a notification, and retries.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -Agent | "claude", "codex", or "gemini" |
| -Prompt | The prompt text |
| -Phase | Phase name for logging |
| -LogFile | Path to log file |
| -CurrentBatchSize | Starting batch size (halves on each retry or watchdog timeout) |
| -GsdDir | Path to .gsd directory |
| -GeminiMode | "--sandbox" (read-only, default) or "--yolo" (write) |

Watchdog timeout: controlled by `$script:AGENT_WATCHDOG_MINUTES` (default 30). On timeout, logs a `watchdog_timeout` entry to errors.jsonl and sends a high-priority push notification.

### Update-FileMap

Generates file-map.json and file-map-tree.md for the repo.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -Root | Repo root path |
| -GsdPath | Path to .gsd directory |

Returns: path to file-map.json

### Wait-ForQuotaReset

Sleeps with adaptive backoff when quota is exhausted. Starts at 5 minutes, doubles each cycle up to 60-minute cap. Max 24 cycles (24 hours).

### Test-NetworkAvailability

Tests network via claude -p "PING" --max-turns 1. Polls every 30s when offline. Max wait: 1 hour.

### Save-Checkpoint / Restore-Checkpoint

Saves and restores pipeline state (iteration, phase, health, batch_size) for crash recovery.

### Save-GsdSnapshot

Creates git stash or commit as rollback point before destructive operations.

### Test-HealthRegression

Detects health drops >5% after an iteration. Auto-reverts to pre-iteration state.

### Test-AgentBoundaries

Validates that agent output stays within allowed write scope. Auto-reverts boundary violations.

### Test-JsonFile

Validates JSON file integrity. Auto-restores from .last-good backup on corruption.

### Test-DiskSpace

Checks for minimum 0.5 GB free space. Auto-cleans caches when low.

### Test-CliVersions

Validates claude, codex, gemini, dotnet, node, npm, sqlcmd versions and compatibility.

### Test-SqlFiles / Test-SqlSyntaxWithSqlcmd

SQL pattern validation (no string concat, TRY/CATCH required, audit columns) and sqlcmd syntax checking.

### Write-GsdError

Structured error logging to errors.jsonl with category, phase, iteration, message, and resolution.

### Get-GsdNtfyTopic

Auto-generates ntfy topic from $env:USERNAME + git repo name. Sanitizes to lowercase alphanumeric with hyphens.

### Send-GsdNotification

Sends push notification via ntfy.sh. Silent fail if not configured.

Parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| -Title | (required) | Notification title |
| -Message | (required) | Notification body |
| -Priority | "default" | min, low, default, high, urgent |
| -Tags | "" | Emoji shortcodes (e.g., "rocket", "warning", "tada") |
| -Topic | (auto) | Override topic for this notification |

### Initialize-GsdNotifications

Sets up ntfy topic at pipeline startup. Resolves topic from: override parameter > global config > auto-detection. Also initializes the heartbeat timer (`$script:LAST_NOTIFY_TIME`).

### Send-HeartbeatIfDue

Sends a low-priority heartbeat notification if 10+ minutes have elapsed since the last notification. Called before each agent phase to let users know the pipeline is still working.

Parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| -Phase | (required) | Current phase name (e.g., "code-review", "build") |
| -Iteration | (required) | Current iteration number |
| -Health | (required) | Current health score |
| -RepoName | (required) | Repository name for notification body |
| -HeartbeatMinutes | 10 | Minimum minutes between heartbeat notifications |

Notification format: Title "Working: {phase}", body "{repo} | Iter {n} | Health: {x}% | {m}m elapsed". Uses hourglass_flowing_sand emoji tag.

### Invoke-SpecConsistencyCheck

Scans specification documents for contradictions. Blocks critical conflicts unless -AutoResolve is set.

### Invoke-SpecConflictResolution

Uses Gemini (--yolo) to auto-resolve spec contradictions based on authoritative source priority. Falls back to Codex if Gemini is unavailable. Max 2 attempts per conflict.

## VS Code Integration

After installation, two tasks are available via Ctrl+Shift+P -> "Run Task":

- **GSD: Convergence Loop** - runs gsd-converge
- **GSD: Blueprint Pipeline** - runs gsd-blueprint

Keyboard shortcuts (if install-gsd-keybindings.ps1 was run):

| Shortcut | Action |
|----------|--------|
| Ctrl+Shift+G, C | Run convergence loop |
| Ctrl+Shift+G, B | Run blueprint pipeline |
| Ctrl+Shift+G, A | Run assessment |
| Ctrl+Shift+G, S | Show status dashboard |
