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
gsd-converge -ForceCodeReview         # Force code review even at 100% health
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
| -ForceCodeReview | false | Force one code-review iteration even when health is already 100% |
| -BatchSize | 8 | Items per execute cycle (adaptive: shrinks on failure, grows on success) |
| -MaxIterations | 20 | Maximum convergence iterations |
| -StallThreshold | 3 | Stop after N iterations with no improvement |
| -ThrottleSeconds | 30 | Delay between agent calls to prevent quota exhaustion |
| -NtfyTopic | (auto) | Override ntfy.sh notification topic |
| -SupervisorAttempts | 5 | Max recovery attempts by supervisor before escalation |
| -NoSupervisor | false | Bypass supervisor wrapper (run pipeline directly) |

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
| -SupervisorAttempts | 5 | Max recovery attempts by supervisor before escalation |
| -NoSupervisor | false | Bypass supervisor wrapper (run pipeline directly) |

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
| -ShowActual | switch | false | Display actual tracked costs and estimated vs actual comparison |

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

11. **Actual Cost Tracking** -- actual costs by agent, phase, run history, estimated vs actual comparison (with -ShowActual)

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

Master installer. Runs install-gsd-prerequisites.ps1 (pre-flight check) then all 21 scripts in dependency order. Idempotent (safe to re-run for updates). The repository contains 27 scripts total (1 master installer + 1 pre-flight + 21 run by installer + 4 standalone utilities).

Usage:

```powershell
powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1
```

Creates %USERPROFILE%\.gsd-global\ with all engine files and adds gsd-* commands to PowerShell profile.

### install-gsd-prerequisites.ps1

Checks all required tools and installs missing ones via winget/npm. Auto-upgrades outdated packages. Refreshes PATH after installs so newly installed tools are immediately usable.

Usage:

```powershell
powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1
powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1 -VerifyOnly
powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1 -Force
```

Parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| -VerifyOnly | false | Check everything, install nothing |
| -SkipOptional | false | Skip optional tools (sqlcmd) |
| -Force | false | Reinstall even if already present |
| -SkipAuth | false | Skip API key configuration section |
| -AnthropicKey | "" | Set Anthropic API key directly (non-interactive) |
| -OpenAIKey | "" | Set OpenAI API key directly (non-interactive) |
| -GoogleKey | "" | Set Google API key directly (non-interactive) |

Required tools: Node.js 18+, npm 8+, Git 2+, .NET SDK 8+, Claude Code CLI, Codex CLI. Optional: Gemini CLI (three-model optimization), sqlcmd (SQL validation).

Reports a final summary with counts: Passed, Failed, Installed, Skipped, Warnings.

### install-gsd-keybindings.ps1

Adds VS Code keyboard shortcuts (Ctrl+Shift+G chords).

## Core Scripts (executed by installer)

The master installer (`install-gsd-all.ps1`) runs these 21 scripts in order. Each is idempotent and safe to re-run.

### install-gsd-global.ps1 (Script 1)

**Step 0 -- API Key Setup**: Before creating the directory structure, prompts the user to enter API keys for all three providers (Anthropic, OpenAI, Google). If all keys are already configured as User-level environment variables, this step is automatically skipped with a green status display. Only missing keys are prompted. Keys are stored as persistent User-level environment variables (ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY) and are immediately available in the current session.

**Step 1+**: Creates the global `%USERPROFILE%\.gsd-global\` directory structure with: convergence engine (convergence-loop.ps1), token cost calculator (token-cost-calculator.ps1), bin/ CLI wrappers (gsd-converge.cmd, gsd-blueprint.cmd, gsd-status.cmd, gsd-remote.cmd, gsd-costs.cmd), VS Code tasks.json, PATH entries, global-config.json with notification settings, prompt templates for Claude/Codex/Gemini, and PowerShell profile functions (gsd-converge, gsd-costs, gsd-status, gsd-assess, gsd-remote).

### install-gsd-blueprint.ps1 (Script 2)

Installs the blueprint pipeline (blueprint-pipeline.ps1), assessment script (assess.ps1), blueprint prompt templates, agent configurations, and profile functions (gsd-blueprint, gsd-init). Creates the blueprint/ subdirectory structure within .gsd-global.

### patch-gsd-partial-repo.ps1 (Script 3)

Installs gsd-assess command, assessment prompts, file map generation, -MapOnly flag.

### patch-gsd-resilience.ps1 (Script 4)

Installs resilience.ps1 module: Invoke-WithRetry (with watchdog timeout), Save-Checkpoint, Restore-Checkpoint, New-Lock, Remove-Lock, Save-GsdSnapshot, Invoke-AdaptiveBatch, Get-FailureDiagnosis, Invoke-AgentFallback. Agent calls run in isolated child processes with a 30-minute watchdog that kills hung agents and retries. Note: Get-FailureDiagnosis is extended by `patch-gsd-multi-model.ps1` (steps 13B/13C) to handle REST agent HTTP errors.

### patch-gsd-hardening.ps1 (Script 5)

Appends hardening to resilience.ps1: Wait-ForQuotaReset, Test-NetworkAvailability, Backup-JsonState, Set-AgentBoundary, Update-FileMap, Get-GsdNtfyTopic, Send-GsdNotification, Send-HeartbeatIfDue, Start-BackgroundHeartbeat, Stop-BackgroundHeartbeat, Start-CommandListener, Stop-CommandListener, Initialize-GsdNotifications, Test-HealthRegression, Write-GsdError, Update-EngineStatus, Start-EngineStatusHeartbeat, Stop-EngineStatusHeartbeat, Initialize-CostTracking, Get-TokenPrice, Extract-TokensFromOutput, Save-TokenUsage, Update-CostSummary, Rebuild-CostSummary, Complete-CostTrackingRun.

### patch-gsd-final-validation.ps1 (Script 6)

Adds final validation gate and developer handoff report to resilience.ps1. Installs `Invoke-FinalValidation` (7-check quality gate at 100% health) and `New-DeveloperHandoff` (10-section developer handoff markdown generator). Hard failures reset health to 99% so the loop auto-fixes; warnings are included in the handoff report. Generates `developer-handoff.md` at pipeline exit with build commands, database setup, requirements status, cost summary, and known issues.

### patch-gsd-council.ps1 (Script 7)

Adds `Invoke-LlmCouncil`, `Build-RequirementChunks`, and `Build-ChunkContext` to resilience.ps1 and creates 20 council prompt templates (6 types x 3 agent templates + 2 synthesis variants). Multi-stage LLM Council system providing cross-validation at 6 points across both pipelines. Codex and Gemini review; Claude synthesizes only.

| Council Type | Pipeline | Reviewers | Behavior |
|-------------|----------|-----------|----------|
| convergence | Both | Codex + Gemini | Blocking: resets health to 99% if blocked |
| post-research | Convergence | Codex + Gemini | Non-blocking: injects feedback into plan phase |
| pre-execute | Convergence | Codex + Gemini | Non-blocking: injects feedback into execute phase |
| post-blueprint | Blueprint | Codex + Gemini | Blocking: regenerates manifest if blocked |
| stall-diagnosis | Both | Codex + Gemini | Diagnostic: replaces single-agent stall analysis |
| post-spec-fix | Both | Codex + Gemini | Blocking: retries spec resolution if blocked |

For projects with 30+ requirements, the convergence council auto-chunks requirements into groups of 25 (configurable in `agent-map.json` under `council.chunking`). The "auto" strategy discovers the best grouping field from the data -- no hardcoded domain maps.

Max 2 convergence council attempts per run. Outputs: `.gsd/health/council-review.json`, `.gsd/code-review/council-findings.md`. Council findings are included in the developer handoff report.

### patch-gsd-figma-make.ps1 (Script 8)

Installs interfaces.ps1 module: Find-ProjectInterfaces, Initialize-ProjectInterfaces, Show-InterfaceSummary, Get-InterfaceContext. Recursive design folder discovery, _analysis/_stubs auto-discovery, folder inventory.

### final-patch-1-spec-check.ps1 (Script 9)

Adds Invoke-SpecConsistencyCheck to resilience.ps1. Pre-checks specs for conflicts before pipeline runs. Detects: data_type, api_contract, navigation, business_rule, design_system, database, missing_ref conflicts.

### final-patch-2-sql-cli.ps1 (Script 10)

Adds Test-SqlSyntaxWithSqlcmd, Test-SqlFiles, and Test-CliVersions to resilience.ps1. SQL pattern validation and CLI version compatibility checks.

### final-patch-3-storyboard-verify.ps1 (Script 11)

Installs storyboard-aware verification prompt for Claude. Traces data paths end-to-end through all layers.

### final-patch-4-blueprint-pipeline.ps1 (Script 12)

Final blueprint pipeline with file map updates, prompt injection (via Local-ResolvePrompt), background heartbeat, push notifications, throttling, spec check integration, adaptive batch sizing, final validation gate, developer handoff generation, and git commit traceability (review text in commit messages with auto-push).

### final-patch-5-convergence-pipeline.ps1 (Script 13)

Final convergence loop with file map updates, prompt injection (via Local-ResolvePrompt), background heartbeat, push notifications, throttling, spec check integration, adaptive batch sizing, parallel sub-task execution (when enabled), final validation gate, developer handoff generation, and git commit traceability (code review text in commit messages with auto-push).

### final-patch-6-assess-limitations.ps1 (Script 14)

Installs final assess.ps1 with Show-InterfaceSummary, Update-FileMap, -MapOnly, known limitations documentation.

### final-patch-7-spec-resolve.ps1 (Script 15)

Adds spec conflict auto-resolution via Gemini agent (`--yolo`). Installs Invoke-SpecConflictResolution function and wires -AutoResolve flag into both pipelines. Falls back to Codex if Gemini CLI is not available.

### patch-gsd-supervisor.ps1 (Script 16)

Installs the self-healing supervisor system: supervisor.ps1 module, supervisor-converge.ps1 and supervisor-blueprint.ps1 wrappers, profile function updates (adds -SupervisorAttempts and -NoSupervisor params to gsd-converge and gsd-blueprint). Creates `~/.gsd-global/supervisor/` for cross-project pattern memory.

### patch-false-converge-fix.ps1 (Script 17)

One-time bug fix: fixes false "converged" exit when StallCount/TargetHealth/Iteration variables are null in the finally block (moves initialization before try block), and removes orphaned profile code statements outside function bodies. Idempotent.

### patch-gsd-parallel-execute.ps1 (Script 18)

Installs parallel sub-task execution for the execute phase. Adds `execute_parallel` config to agent-map.json, creates `execute-subtask.md` prompt template, adds `Invoke-ParallelExecute` function to resilience.ps1, and updates convergence-loop.ps1 with parallel-aware dispatch. Splits the batch into independent sub-tasks dispatched round-robin across codex/claude/gemini in concurrent waves. Partial success commits completed work; total failure falls back to monolithic single-agent call. Disable by setting `execute_parallel.enabled` to `false` in agent-map.json.

### patch-gsd-resilience-hardening.ps1 (Script 19)

Resilience hardening patch fixing four gaps: (P1) tracks token costs on ALL attempts (success, failure, quota probes) with cost estimation when agents return error text instead of JSON; (P2) fixes auth regex that misclassified Gemini 403 rate limits as auth failures, routing them to proper quota backoff; (P3) adds 2-hour cumulative quota wait cap to prevent 14+ hour sleep loops; (P4) adds automatic agent rotation after 3 consecutive quota failures on the same agent (e.g., codex exhausted -> switch to claude). New functions: `New-EstimatedTokenData`, `Get-NextAvailableAgent`, `Set-AgentCooldown`. New constants: `QUOTA_CUMULATIVE_MAX_MINUTES` (120), `QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE` (3). Creates `.gsd/supervisor/agent-cooldowns.json` at runtime.

### patch-gsd-quality-gates.ps1 (Script 20)

Quality gates patch adding three verification layers: (1) `Test-DatabaseCompleteness` -- zero-token-cost static analysis verifying the full chain API Endpoint -> Stored Procedure -> Tables -> Seed Data by scanning `11-api-to-sp-map.md` and source files; (2) `Test-SecurityCompliance` -- zero-token-cost regex scan catching OWASP Top 10 violations (SQL injection, XSS, eval(), hardcoded secrets, missing [Authorize], BinaryFormatter, localStorage secrets); (3) `Invoke-SpecQualityGate` -- enhanced spec validation combining existing consistency check with AI-powered clarity scoring (spec-kit inspired) and cross-artifact consistency checking. Creates 5 prompt templates in `prompts/shared/` and `prompts/claude/` (security-standards.md, coding-conventions.md, database-completeness-review.md, spec-clarity-check.md, cross-artifact-consistency.md). Adds security checklist to council review prompts. Adds `quality_gates` config block to global-config.json. Integrates into both pipelines before final validation.

### patch-gsd-multi-model.ps1 (Script 21)

Multi-model LLM integration patch adding four OpenAI-compatible REST API agents (Kimi K2.5, DeepSeek V3, GLM-5, MiniMax M2.5) to expand the agent pool from 3 to 7. Creates `model-registry.json` (central metadata for all agents: CLI vs REST type, endpoints, API key env vars, pricing, model IDs). Adds `Invoke-OpenAICompatibleAgent` and `Test-IsOpenAICompatAgent` functions to resilience.ps1. Patches `Invoke-WithRetry` (both original and enhanced versions) to dispatch REST agents via the generic adapter. Patches `Extract-TokensFromOutput` for `openai-compat-result` JSON parsing. Patches `Get-TokenPrice` with pricing for 4 new models. Patches `Get-NextAvailableAgent` to read rotation pool from model-registry.json (with API key validation for REST agents). Reduces `QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE` from 3 to 1 for immediate rotation. Patches `Wait-ForQuotaReset` with REST agent probe support. Patches both `Get-FailureDiagnosis` functions (original and enhanced) to handle REST agent HTTP errors (429→rate limit, 402→quota exhausted, 401→auth failure, 5xx→server error, timeout) with fallback to claude for read-only phases (steps 13B/13C). Expands council reviewers pool dynamically from agent-map.json. Adds REST agent API key checks to `Test-PreFlight` (warnings only). Patches supervisor diagnosis for cooldown-aware routing. Updates token-cost-calculator.ps1 with new model pricing and LiteLLM lookups. Creates `openai-compat-review.md` council prompt template.

New functions:

| Function | Description |
|----------|-------------|
| `Invoke-OpenAICompatibleAgent` | Generic REST adapter for OpenAI-compatible chat completions API. Reads config from model-registry.json, resolves API key, builds request, calls Invoke-RestMethod, returns synthetic JSON envelope with usage tokens. Maps HTTP errors to GSD error taxonomy (rate_limit, unauthorized, server_error). |
| `Test-IsOpenAICompatAgent` | Checks model-registry.json to determine if a given agent name is an openai-compat REST agent. |

New/modified constants:

| Constant | Old Value | New Value | Description |
|----------|-----------|-----------|-------------|
| QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE | 3 | 1 | Rotate immediately on first quota hit (7 agents available) |

### Optional standalone scripts

These are NOT run by the installer but can be run manually:

- **setup-gsd-api-keys.ps1** -- Manages API key environment variables for all three CLI providers. See below for full usage.
- **setup-gsd-convergence.ps1** -- Per-project convergence config setup. Detects latest Figma design version, references SDLC specs (Phase A-E), creates per-project .gsd/ folder structure. Legacy script superseded by the global install approach.
- **install-gsd-keybindings.ps1** -- Adds VS Code keyboard shortcuts (Ctrl+Shift+G chord prefix).
- **token-cost-calculator.ps1** -- Token cost estimator script (also installed globally as `gsd-costs` by install-gsd-global.ps1).

### setup-gsd-api-keys.ps1

Manages API key environment variables for the three CLI agents used by the GSD engine. REST agent API keys (KIMI_API_KEY, DEEPSEEK_API_KEY, GLM_API_KEY, MINIMAX_API_KEY) are set separately via `[System.Environment]::SetEnvironmentVariable()` -- see the Installation Guide for details. All keys are stored as persistent User-level environment variables (Windows registry), never committed to git.

Usage:

```powershell
# Interactive mode -- prompts for each key
.\scripts\setup-gsd-api-keys.ps1

# Pass keys directly (non-interactive)
.\scripts\setup-gsd-api-keys.ps1 -AnthropicKey "sk-ant-..." -OpenAIKey "sk-..." -GoogleKey "AIza..."

# Show current key status (masked)
.\scripts\setup-gsd-api-keys.ps1 -Show

# Remove all API key environment variables
.\scripts\setup-gsd-api-keys.ps1 -Clear
```

Parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| -AnthropicKey | string | Anthropic API key for Claude Code (starts with sk-ant-) |
| -OpenAIKey | string | OpenAI API key for Codex (starts with sk-) |
| -GoogleKey | string | Google API key for Gemini (starts with AIza) |
| -Show | switch | Display current key status (masked) without changing anything |
| -Clear | switch | Remove all GSD API key environment variables |

Environment variables managed:

| Variable | CLI | Expected Prefix | Key Source |
|----------|-----|----------------|-----------|
| ANTHROPIC_API_KEY | Claude Code | sk-ant- | https://console.anthropic.com/settings/keys |
| OPENAI_API_KEY | Codex | sk- | https://platform.openai.com/api-keys |
| GOOGLE_API_KEY | Gemini | AIza | https://aistudio.google.com/apikey |

Notes:
- Keys persist across terminal sessions (stored in Windows registry at User level)
- In interactive mode, press Enter to skip a key (keeps existing value)
- Prefix validation warns but does not block (in case key format changes)
- Keys are set at both User level (persistent) and Process level (immediate availability)
- Run this script once per machine. Re-run to update keys. The installer (install-gsd-global.ps1) also includes API key setup as Step 0.

## Key Functions (in supervisor.ps1)

### Invoke-SupervisorLoop

Main entry point for the supervisor recovery loop. Wraps a pipeline (converge or blueprint), monitors for failures, and applies fixes up to N attempts.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -Pipeline | "converge" or "blueprint" |
| -GsdDir | Path to .gsd directory |
| -MaxAttempts | Maximum recovery attempts (default 5) |
| -PipelineParams | Hashtable of parameters to pass through to the pipeline |

### Save-TerminalSummary

Called by the pipeline before exit. Writes `.gsd/supervisor/last-run-summary.json` with exit reason, health, iteration, stall count, and batch size.

### Get-ErrorStatistics

Layer 1 (free): Parses errors.jsonl into counts by type, phase, and agent. No AI cost.

### Invoke-SupervisorDiagnosis

Layer 2 (1 Claude call): Claude reads all logs, matrix, stall-diagnosis, and error statistics. Outputs structured diagnosis JSON with root cause, category, failing phase, and recommended fix.

### Invoke-SupervisorFix

Layer 3 (1 Claude call): Based on diagnosis, Claude modifies actual project files to fix the root cause. May update error-context.md, prompt-hints.md, agent-override.json, queue-current.json, or requirements-matrix.json.

### Find-KnownFix

Searches pattern-memory.jsonl for a matching failure pattern. Returns the fix if found (avoids AI cost).

### Save-FailurePattern

After successful recovery, saves the failure pattern + fix to pattern-memory.jsonl for cross-project learning.

### Start-PipelineInNewTerminal

Launches the pipeline in a fresh PowerShell window with -NoSupervisor flag (prevents recursive supervisor).

### New-EscalationReport

Generates `.gsd/supervisor/escalation-report.md` with all diagnostic data when all strategies are exhausted.

## Key Functions (in resilience.ps1)

### Invoke-WithRetry

Calls an AI agent with retry logic, batch reduction, watchdog timeout, and quota-aware backoff. Each agent call runs in an isolated child process with a configurable watchdog timer (default: 30 minutes). If the agent hangs, the watchdog kills the process tree, halves the batch, sends a notification, and retries.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -Agent | "claude", "codex", "gemini", or any REST agent name from model-registry.json |
| -Prompt | The prompt text |
| -Phase | Phase name for logging |
| -LogFile | Path to log file |
| -CurrentBatchSize | Starting batch size (halves on each retry or watchdog timeout) |
| -GsdDir | Path to .gsd directory |
| -GeminiMode | "--approval-mode plan" (read-only, default) or "--yolo" (write) |

Watchdog timeout: controlled by `$script:AGENT_WATCHDOG_MINUTES` (default 30). On timeout, logs a `watchdog_timeout` entry to errors.jsonl and sends a high-priority push notification.

### Invoke-ParallelExecute

Splits the execute batch into independent sub-tasks and dispatches them in parallel using PowerShell background jobs. Each sub-task gets its own agent (round-robin), prompt (from execute-subtask.md template), and log file. Sub-tasks run in waves of `max_concurrent`, with 10-second cooldown between waves.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -GsdDir | Path to .gsd directory |
| -GlobalDir | Path to .gsd-global directory |
| -Iteration | Current iteration number |
| -Health | Current health score |
| -PromptTemplatePath | Path to execute-subtask.md template |
| -CurrentBatchSize | Current batch size (returned unchanged) |
| -LogFilePrefix | Log file prefix (e.g., ".gsd\logs\iter3-4") |
| -InterfaceContext | Multi-interface context string |
| -DryRun | If set, prints dispatch plan without executing |

Returns: `@{ Success, PartialSuccess, FinalBatchSize, Completed, Failed, Error }`

- `Success = $true` when all sub-tasks complete
- `PartialSuccess = $true` when some but not all succeed
- `Completed` and `Failed` contain arrays of req_id strings

### Update-FileMap

Generates file-map.json and file-map-tree.md for the repo.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -Root | Repo root path |
| -GsdPath | Path to .gsd directory |

Returns: path to file-map.json

### Start-BackgroundHeartbeat / Stop-BackgroundHeartbeat

Manages a background PowerShell job that sends ntfy progress notifications every 10 minutes, independent of the main pipeline execution. This ensures heartbeat notifications are sent even during long-running agent calls (which block the main thread for 15-30+ minutes). Each heartbeat includes running cost data (current run cost, total cost, total tokens) read from `.gsd/costs/cost-summary.json`.

Parameters (Start):

| Parameter | Description |
|-----------|-------------|
| -GsdDir | Path to .gsd directory (reads .gsd-checkpoint.json for current state) |
| -NtfyTopic | The ntfy.sh topic to post to |
| -Pipeline | "converge" or "blueprint" |
| -RepoName | Repository display name |
| -IntervalMinutes | Notification interval (default: 10) |

The job is started after the "Pipeline Started" notification and stopped in the `finally` block, ensuring cleanup even on crashes.

### Update-EngineStatus

Merge-on-write update to `.gsd/health/engine-status.json`. Reads the existing file to preserve fields not being updated, then merges in the provided parameters. Always updates `last_heartbeat` and `elapsed_minutes` on every call. Truncates `last_error` to 200 characters.

Parameters:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| -GsdDir | string | Yes | Path to .gsd directory |
| -State | string | Yes | Engine state (ValidateSet: starting, running, sleeping, stalled, completed, converged) |
| -Phase | string | No | Current pipeline phase (e.g., "review", "execute") |
| -Agent | string | No | Active agent ("claude", "codex", "gemini") |
| -Iteration | int | No | Current iteration number |
| -Attempt | string | No | Retry attempt in "N/M" format (e.g., "1/3") |
| -BatchSize | int | No | Current batch size |
| -HealthScore | number | No | Latest health score percentage |
| -SleepUntil | string | No | ISO 8601 timestamp when sleep ends |
| -SleepReason | string | No | Reason for sleep (e.g., "quota_backoff") |
| -LastError | string | No | Last error message (truncated to 200 chars) |
| -ErrorsThisIteration | int | No | Number of errors in the current iteration |
| -RecoveredFromError | bool | No | Whether the engine recovered from an error |

### Start-EngineStatusHeartbeat

Starts a background PowerShell job (via `Start-Job`) that updates `last_heartbeat` and `elapsed_minutes` in engine-status.json every 60 seconds. This ensures the heartbeat timestamp stays fresh even during long-running agent calls that block the main thread.

Parameters:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| -GsdDir | string | Yes | Path to .gsd directory (location of engine-status.json) |

### Stop-EngineStatusHeartbeat

Stops the background engine-status heartbeat job started by `Start-EngineStatusHeartbeat`. Called in the pipeline's `finally` block to ensure cleanup on exit (including crashes).

### Start-CommandListener / Stop-CommandListener

Manages a background PowerShell job that polls the ntfy topic every 15 seconds for user commands. When a user posts the exact word "progress" (case-insensitive), the listener reads checkpoint and health files and responds with a formatted progress report posted back to the same topic. All other messages are ignored. Responses are prefixed with `[GSD-STATUS]` to avoid feedback loops.

Parameters (Start):

| Parameter | Description |
|-----------|-------------|
| -GsdDir | Path to .gsd directory (reads .gsd-checkpoint.json and health-current.json) |
| -NtfyTopic | The ntfy.sh topic to poll and post responses to |
| -Pipeline | "converge" or "blueprint" |
| -RepoName | Repository display name |

Response format posted back to the ntfy topic:
```
[GSD-STATUS] Progress Report
{RepoName} | {pipeline} pipeline
Health: {health}% | Iter: {iteration} | Phase: {phase}
Items: {satisfied} done / {partial} partial / {not_started} todo (of {total})
Batch: {batch_size} | Elapsed: {elapsed}m
Cost: ${run_cost} run / ${total_cost} total | {tokens}K tok ({agent} ${cost}, ...)
```

The job is started alongside `Start-BackgroundHeartbeat` after the "Pipeline Started" notification and stopped in the `finally` block, ensuring cleanup even on crashes.

### Initialize-CostTracking

Creates `.gsd/costs/` directory, initializes empty `cost-summary.json` if missing, and records a new run start in the `runs` array. Called automatically when the pipeline starts.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -GsdDir | Path to .gsd directory |
| -Pipeline | "converge" or "blueprint" |

### Get-TokenPrice

Reads pricing from `~/.gsd-global/pricing-cache.json` for a given agent. Falls back to hardcoded prices if cache is missing or unreadable.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -Agent | "claude", "codex", or "gemini" |

Returns: `@{ InputPerM; OutputPerM; CacheReadPerM; ModelKey }`

### Extract-TokensFromOutput

Parses JSON output from CLI agent calls to extract token counts, cost, text output, and duration. Agent-specific parsing:
- **Claude**: Parses JSON array, finds `type="result"` entry with `total_cost_usd`, `result`, `duration_ms`, `num_turns`
- **Codex**: Parses JSONL lines, finds `turn.completed` events, sums `usage.{input_tokens, output_tokens, cached_input_tokens}`
- **Gemini**: Parses JSON, extracts `stats.{prompt_tokens, response_tokens, cached_tokens}` and `response` text

Parameters:

| Parameter | Description |
|-----------|-------------|
| -Agent | "claude", "codex", or "gemini" |
| -RawOutput | Raw string output from the CLI call |

Returns: `@{ Tokens; CostUsd; TextOutput; DurationMs; NumTurns }` or `$null` on parse failure.

### Save-TokenUsage

Appends a JSONL record to `token-usage.jsonl` and calls `Update-CostSummary`. Wrapped in try/catch -- tracking failure never blocks the pipeline.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -GsdDir | Path to .gsd directory |
| -Agent | "claude", "codex", or "gemini" |
| -Phase | Pipeline phase name |
| -Iteration | Current iteration number |
| -Pipeline | "converge" or "blueprint" |
| -BatchSize | Current batch size |
| -Success | Whether the call succeeded |
| -IsFallback | Whether this was a fallback agent call |
| -TokenData | Hashtable from Extract-TokensFromOutput |

### Update-CostSummary

Incremental merge-on-write update to `cost-summary.json`. Reads existing summary, converts it from PSCustomObject to mutable hashtables via `ConvertTo-MutableSummary`, adds new usage entry totals, writes back. This conversion is required because `ConvertFrom-Json` returns PSCustomObjects where dynamic property addition and in-place nested mutation silently fail.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -GsdDir | Path to .gsd directory |
| -UsageEntry | Hashtable with the usage data to merge |

### ConvertTo-MutableSummary

Converts a PSCustomObject (from `ConvertFrom-Json`) into nested hashtables so that dynamic property addition (`$summary.by_agent.$newKey = @{...}`) and in-place mutation of nested values work correctly. Called by `Update-CostSummary` after reading `cost-summary.json`.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -Obj | The PSCustomObject to convert |

### Rebuild-CostSummary

Full rebuild of `cost-summary.json` from `token-usage.jsonl`. Use when the summary is corrupted or out of sync. Reads every JSONL line and reconstructs all aggregates from scratch. Builds using native hashtables so no PSCustomObject conversion is needed.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -GsdDir | Path to .gsd directory |

### Complete-CostTrackingRun

Marks the current run as ended in `cost-summary.json` by setting the `ended` timestamp on the last entry in the `runs` array. Called in the pipeline's `finally` block.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -GsdDir | Path to .gsd directory |

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
| -GsdDir | (optional) | Path to .gsd directory (enables cost data in notification) |
| -HeartbeatMinutes | 10 | Minimum minutes between heartbeat notifications |

Notification format: Title "Working: {phase}", body "{repo} | Iter {n} | Health: {x}% | {m}m elapsed\nCost: ${run} run / ${total} total | {n}K tok". Uses hourglass_flowing_sand emoji tag.

### Get-CostNotificationText

Reads `.gsd/costs/cost-summary.json` and returns a compact one-line cost string for inclusion in ntfy notifications. Returns empty string if cost tracking is not initialized or total cost is $0.

Parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| -GsdDir | (required) | Path to .gsd directory |
| -Detailed | (switch) | Include per-agent cost breakdown (claude, codex, gemini) |

Summary format: `Cost: $1.24 run / $3.18 total | 412K tok`
Detailed format: `Cost: $1.24 run / $3.18 total | 412K tok (claude $1.91, codex $0.64, gemini $0.63)`

### Get-FailureDiagnosis

Analyzes agent failure output to determine root cause and recommend recovery action. Returns a diagnosis object with the failure reason, recommended action (retry, fallback, or escalate), and optional fallback agent.

Agent-specific diagnostics:
- **Gemini**: sandbox/plan-mode restriction, model unavailable, prompt too large, server error, auth failure
- **Codex**: working directory issues, prompt format errors, loop/iteration limits
- **Claude**: max turns limit, tool permission errors
- **REST agents** (kimi, deepseek, glm5, minimax): HTTP 429 rate limit, 402 quota exhausted, 401 auth failure, 5xx server error, timeout. REST agents fall back to claude for read-only phases (review, council, research, plan), retry for write phases. Added by `patch-gsd-multi-model.ps1` steps 13B/13C.

### Invoke-AgentFallback

Attempts to run the same prompt with an alternative agent when the primary agent fails. Fallback chain: codex -> claude, claude -> codex, gemini -> codex, REST agents -> claude (read-only phases). Returns success/failure and output.

### Local-ResolvePrompt

Pipeline-internal function that resolves prompt templates before sending to agents. Replaces template variables ({{ITERATION}}, {{HEALTH}}, {{GSD_DIR}}, {{REPO_ROOT}}, {{BATCH_SIZE}}, {{INTERFACE_CONTEXT}}) and appends supervisor error context, prompt hints, and council feedback when present.

### Invoke-FinalValidation

Quality gate that runs when health reaches 100%. Executes 7 checks (build, tests, SQL, vulnerability audits) and returns structured results. Hard failures block convergence; warnings are advisory.

Parameters:

| Parameter | Description |
|-----------|-------------|
| -RepoRoot | Repository root path |
| -GsdDir | Path to .gsd directory |
| -Iteration | Current iteration number |

Returns: `@{ Passed=$bool; HardFailures=@(); Warnings=@(); Details=@{}; Timestamp=string }`

Checks performed (in order):
1. Strict .NET build (`dotnet build --no-restore`) → HARD failure
2. npm build (`npm run build`) → HARD failure
3. .NET tests (`dotnet test --no-build`) → HARD failure (if test projects exist)
4. npm tests (`npm test` with CI=true) → HARD failure (if real test script exists)
5. SQL validation (`Test-SqlFiles`) → WARNING
6. .NET vulnerability audit (`dotnet list package --vulnerable`) → WARNING
7. npm vulnerability audit (`npm audit --audit-level=high`) → WARNING

Output files:
- `.gsd/health/final-validation.json` -- structured results per check
- `.gsd/logs/final-validation.log` -- human-readable log

### New-DeveloperHandoff

Generates `developer-handoff.md` in the repository root with everything a developer needs to pick up, compile, and run the project. Called automatically in the pipeline's `finally` block.

Parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| -RepoRoot | string | (required) | Repository root path |
| -GsdDir | string | (required) | Path to .gsd directory |
| -Pipeline | string | "converge" | Pipeline type: "converge" or "blueprint" |
| -ExitReason | string | "unknown" | Why the pipeline exited: "converged", "stalled", "max_iterations" |
| -FinalHealth | double | 0 | Final health percentage |
| -Iteration | int | 0 | Final iteration count |
| -ValidationResult | object | $null | Output from Invoke-FinalValidation (if validation was run) |

Returns: path to the generated `developer-handoff.md` file.

Report sections: Header, Quick Start (auto-detected build commands), Database Setup (SQL files + connection strings), Environment Configuration (appsettings + .env files), Project Structure (file tree), Requirements Status (grouped table), Validation Results, Known Issues (drift report + recent errors), Health Progression (ASCII bar chart), Cost Summary (by agent and phase).

### Invoke-LlmCouncil

Multi-agent council review with 6 council types. Codex and Gemini review independently, then Claude synthesizes a consensus verdict. For convergence reviews with 30+ requirements, automatically chunks requirements into smaller groups for focused, quota-friendly reviews.

Parameters:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| -RepoRoot | string | (required) | Repository root path |
| -GsdDir | string | (required) | Path to .gsd directory |
| -Iteration | int | 0 | Current iteration number |
| -Health | double | 0 | Current health score |
| -Pipeline | string | "converge" | Pipeline type: "converge" or "blueprint" |
| -CouncilType | string | "convergence" | Council type: "convergence", "post-research", "pre-execute", "post-blueprint", "stall-diagnosis", "post-spec-fix" |

Returns: `@{ Approved=$bool; Findings=@{approved, confidence, votes, concerns, strengths}; Report=string }`

Output files:
- `.gsd/health/council-review.json` -- structured verdict with per-agent votes
- `.gsd/code-review/council-findings.md` -- human-readable council report
- `.gsd/supervisor/council-feedback.md` -- injected into next iteration prompts (if blocked)
- `.gsd/logs/council-convergence-{agent}-chunk{N}.log` -- per-chunk review logs (chunked mode)

### Build-RequirementChunks

Groups requirements dynamically based on fields in the matrix. No hardcoded domain maps. Strategies: "auto" (discover best field), "field:X" (explicit), "id-range" (sequential blocks).

### Build-ChunkContext

Builds focused context for one chunk -- only that chunk's requirements, file hints, and drift report.

### Test-DatabaseCompleteness

Zero-token-cost static analysis verifying the full database chain. Discovers API endpoints from `11-api-to-sp-map.md` or `[Http*]` attributes, stored procedures from `CREATE PROC` in `.sql` files, tables from `CREATE TABLE`, seed data from `INSERT INTO`/`MERGE`. Cross-references the chain and writes `.gsd/assessment/db-completeness.json`. Config: `quality_gates.database_completeness` in global-config.json.

| Parameter | Type | Description |
|-----------|------|-------------|
| RepoRoot | string | Project root path |
| GsdDir | string | Project .gsd directory |
| Detailed | switch | Show per-file details |

Returns: `@{ Passed; Coverage; OverallPct; Issues; MissingStoredProcs; MissingSeedData }`

### Test-SecurityCompliance

Zero-token-cost regex scan catching OWASP violations. Scans `.cs`, `.ts`, `.tsx`, `.js`, `.jsx`, `.sql`, `.json` files for 9 vulnerability patterns plus missing `[Authorize]` and missing audit columns. Writes `.gsd/assessment/security-compliance.json`. Config: `quality_gates.security_compliance` in global-config.json.

| Pattern | Severity | Description |
|---------|----------|-------------|
| String concat + SQL | Critical | SQL injection |
| dangerouslySetInnerHTML | Critical | XSS (skips if DOMPurify present) |
| eval() / new Function() | Critical | Code injection |
| localStorage + secrets | Critical | Sensitive data in browser |
| Hardcoded secrets | Critical | Credentials in source |
| Missing [Authorize] | High | Unprotected controller |
| Missing audit columns | Medium | CREATE TABLE without CreatedAt |
| Console log + secrets | High | PII in logs |
| sp_executesql + concat | Critical | Dynamic SQL injection |

Returns: `@{ Passed; Violations; ViolationCount; Criticals; Highs; Mediums }`

### Invoke-SpecQualityGate

Enhanced spec validation combining three checks: (1) existing `Invoke-SpecConsistencyCheck` (contradiction detection), (2) AI-powered spec clarity scoring via Claude using `spec-clarity-check.md` template (scores 0-100, blocks < 70), (3) cross-artifact consistency checking via Claude using `cross-artifact-consistency.md` template (validates entity/field names, chain completeness, seed data). Config: `quality_gates.spec_quality` in global-config.json.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| RepoRoot | string | | Project root path |
| GsdDir | string | | Project .gsd directory |
| Interfaces | array | @() | Detected interfaces |
| DryRun | switch | | Skip AI calls |
| MinClarityScore | int | 70 | Minimum clarity score to pass |

Returns: `@{ Passed; ClarityScore; ConsistencyPassed; Issues; Verdict }`

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
| Ctrl+Shift+G, S | Show status dashboard |
