\# GSD Script Reference



\## Commands (available after install)



\### gsd-assess

Scans codebase, detects interfaces, generates file map, runs Claude assessment.



Usage:

&nbsp; gsd-assess              # Full assessment

&nbsp; gsd-assess -MapOnly     # Regenerate file map without Claude assessment

&nbsp; gsd-assess -DryRun      # Preview without executing



Output: .gsd\\assessment\\ folder with inventories and work classification



\### gsd-converge

Runs 5-phase convergence loop to fix existing code issues.



Usage:

&nbsp; gsd-converge                  # Full convergence

&nbsp; gsd-converge -SkipResearch    # Skip Codex research phase (saves tokens)

&nbsp; gsd-converge -DryRun          # Preview without executing

&nbsp; gsd-converge -MaxIterations 5 # Limit iterations



Parameters:

&nbsp; -SkipInit          Skip requirements check

&nbsp; -SkipResearch      Skip Codex research phase

&nbsp; -DryRun            Preview mode

&nbsp; -MaxIterations N   Max iterations (default: 20)

&nbsp; -StallThreshold N  Stop after N iterations with no improvement (default: 3)



\### gsd-blueprint

Generates code from specifications via blueprint manifest.



Usage:

&nbsp; gsd-blueprint                 # Full pipeline

&nbsp; gsd-blueprint -BlueprintOnly  # Generate manifest only, no build

&nbsp; gsd-blueprint -BuildOnly      # Resume build from existing manifest

&nbsp; gsd-blueprint -VerifyOnly     # Re-score without generating

&nbsp; gsd-blueprint -DryRun         # Preview



\### gsd-status

Displays health dashboard for current project.



Usage:

&nbsp; gsd-status



\## Installation Scripts



\### install-gsd-all.ps1

Master installer. Runs all 12 scripts in dependency order. Idempotent (safe to re-run for updates).



Usage:

&nbsp; powershell -ExecutionPolicy Bypass -File install-gsd-all.ps1



Creates %USERPROFILE%\\.gsd-global\\ with all engine files and adds gsd-\* commands to PowerShell profile.



\### install-gsd-prerequisites.ps1

Checks all required tools and installs missing ones via winget/npm.



Usage:

&nbsp; powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1

&nbsp; powershell -ExecutionPolicy Bypass -File install-gsd-prerequisites.ps1 -VerifyOnly



\### install-gsd-keybindings.ps1

Adds VS Code keyboard shortcuts (Ctrl+Shift+G chords).



\## Core Scripts (executed by installer)



\### install-gsd-global.ps1 (Script 1)

Creates global directory structure, convergence engine, VS Code tasks, PATH entries.



\### install-gsd-blueprint.ps1 (Script 2)

Installs blueprint pipeline, prompt templates, agent configurations, profile functions.



\### setup-gsd-convergence.ps1 (Script 3)

Sets up convergence loop configuration and phase definitions.



\### patch-gsd-partial-repo.ps1 (Script 4)

Installs gsd-assess command, assessment prompts, file map generation, -MapOnly flag.



\### patch-gsd-resilience.ps1 (Script 5)

Installs resilience.ps1 module: Invoke-WithRetry, Save-Checkpoint, Restore-Checkpoint, New-Lock, Remove-Lock, Save-GsdSnapshot, Invoke-AdaptiveBatch.



\### patch-gsd-hardening.ps1 (Script 6)

Appends hardening to resilience.ps1: Wait-ForQuotaReset, Test-NetworkAvailability, Backup-JsonState, Set-AgentBoundary, Update-FileMap.



\### patch-gsd-figma-make.ps1 (Script 7)

Installs interfaces.ps1 module: Find-ProjectInterfaces, Initialize-ProjectInterfaces, Show-InterfaceSummary, Get-InterfaceContext. Recursive design folder discovery, \_analysis/\_stubs auto-discovery, folder inventory.



\### final-patch-1-spec-check.ps1 (Script 8)

Adds Invoke-SpecConsistencyCheck to resilience.ps1. Pre-checks specs for conflicts before pipeline runs.



\### final-patch-2-sql-cli.ps1 (Script 9)

Adds Test-SqlSyntaxWithSqlcmd and Get-CliVersions to resilience.ps1.



\### final-patch-3-storyboard-verify.ps1 (Script 10)

Installs storyboard-aware verification prompt for Claude.



\### final-patch-4-blueprint-pipeline.ps1 (Script 11)

Wires file map updates and prompt injection into blueprint pipeline.



\### final-patch-5-convergence-pipeline.ps1 (Script 12)

Wires file map updates and prompt injection into convergence loop.



\### final-patch-6-assess-limitations.ps1 (Script 13)

Installs final assess.ps1 with Show-InterfaceSummary, Update-FileMap, -MapOnly, known limitations doc.



\## Key Functions (in resilience.ps1)



\### Invoke-WithRetry

Calls an AI agent with retry logic and batch reduction.



Parameters:

&nbsp; -Agent        "claude" or "codex"

&nbsp; -Prompt       The prompt text

&nbsp; -Phase        Phase name for logging

&nbsp; -LogFile      Path to log file

&nbsp; -CurrentBatchSize  Starting batch size

&nbsp; -GsdDir       Path to .gsd directory



\### Update-FileMap

Generates file-map.json and file-map-tree.md for the repo.



Parameters:

&nbsp; -Root     Repo root path

&nbsp; -GsdPath  Path to .gsd directory



Returns: path to file-map.json



\### Wait-ForQuotaReset

Sleeps in 60-minute increments when quota is exhausted. Max 24 cycles.



\### Test-NetworkAvailability

Tests network via claude -p "PING" --max-turns 1. Polls every 30s when offline.



\### Save-Checkpoint / Restore-Checkpoint

Saves and restores convergence state for crash recovery.



\### Save-GsdSnapshot

Creates git stash or commit as rollback point before destructive operations.

