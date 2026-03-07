<#
.SYNOPSIS
    Maintenance Mode - Post-launch feature updates, bug fixes, and scoped convergence.
    Run AFTER patch-gsd-loc-tracking.ps1.

.DESCRIPTION
    Adds three capabilities for post-launch project maintenance:

    1. Incremental Create-Phases (--Incremental flag):
       - New prompt template create-phases-incremental.md
       - Preserves existing satisfied requirements in the matrix
       - Adds new requirements from updated specs (v02+)
       - Triggered when matrix is non-empty and --Incremental is passed
       - Avoids manual editing of requirements-matrix.json

    2. Scoped Convergence (--Scope parameter):
       - Filter plan phase to only select matching requirements
       - Scope by source: "source:v02_spec", "source:bug_report"
       - Scope by ID: "id:BUG-001,BUG-002"
       - Code-review still sees everything (regression detection)
       - Plan/execute only work on scoped items

    3. gsd-fix Helper Command:
       - Shortcut for bug fixes: gsd-fix "description" "description2" ...
       - From file: gsd-fix -File bugs.md
       - From directory with artifacts: gsd-fix -BugDir ./bugs/login-issue/
         (directory can contain bug.md + screenshots, logs, repro files)
       - Auto-creates matrix entries with source=bug_report
       - Copies artifacts to .gsd/supervisor/bug-artifacts/BUG-xxx/
       - Writes error-context.md with bug details + inlined log snippets
       - Calls gsd-converge with small MaxIterations/BatchSize

    Config: maintenance_mode block in global-config.json

.INSTALL_ORDER
    1-31. (existing scripts)
    32. patch-gsd-maintenance-mode.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Maintenance Mode (Post-Launch Updates)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add maintenance_mode config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.maintenance_mode) {
        $config | Add-Member -NotePropertyName "maintenance_mode" -NotePropertyValue ([PSCustomObject]@{
            enabled = $true
            fix_defaults = ([PSCustomObject]@{
                max_iterations = 5
                batch_size     = 3
                skip_research  = $true
            })
            scope_filter = ([PSCustomObject]@{
                enabled                  = $true
                review_all_on_scope      = $true
                scope_plan_and_execute   = $true
            })
            incremental_phases = ([PSCustomObject]@{
                enabled                    = $true
                preserve_satisfied         = $true
                add_spec_version_tag       = $true
            })
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added maintenance_mode config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] maintenance_mode already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Create incremental create-phases prompt ──

$promptDir = Join-Path $GsdGlobalDir "prompts\claude"
$incrementalPrompt = Join-Path $promptDir "create-phases-incremental.md"

if (-not (Test-Path $incrementalPrompt)) {
    $promptContent = @'
# GSD Incremental Create Phases - Claude Code Phase

You are the ARCHITECT. Merge new requirements from updated specs into the existing matrix.
This runs when specs have been updated (e.g., v02) and new requirements need to be added
WITHOUT losing existing satisfied requirements.

## Context
- Project: {{REPO_ROOT}}
- SDLC docs: docs\ (Phase A through Phase E)
- Project .gsd dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json (EXISTING matrix -- DO NOT discard)
2. Every file in docs\ (SDLC specification documents)
3. Design files (scan design\ directories for latest version)
4. Existing codebase structure (scan src\ or equivalent)

## Rules
1. **PRESERVE** all existing requirements in the matrix regardless of status
   - Do NOT remove or modify any requirement with status "satisfied"
   - Do NOT remove or modify any requirement with status "partial"
   - Requirements with status "not_started" may be updated if specs changed
2. **ADD** new requirements discovered in the updated specs
   - Assign status "not_started" to all new requirements
   - Set source field to indicate the spec version (e.g., "v02_spec", "v02_figma")
   - Assign unique req_ids that don't collide with existing ones
3. **UPDATE** the total count and recalculate health score
4. **TAG** new requirements with spec_version field (e.g., "v02")

## Do
1. READ the existing requirements-matrix.json completely
2. READ the latest design/ specs and docs/
3. COMPARE: identify requirements in new specs not already in the matrix
4. APPEND new requirements to the existing matrix
5. WRITE updated requirements-matrix.json (preserving all existing entries)
6. UPDATE health-current.json with new totals
7. WRITE drift-report.md noting what was added

## Output Format
Same schema as create-phases.md:
- id, source, sdlc_phase, description, status, depends_on, pattern, priority
- NEW field: spec_version (e.g., "v01", "v02")

## Token Budget
~5000 output tokens. Focus on COMPLETENESS of new requirements.
Do NOT regenerate existing requirements -- only append new ones.
'@
    Set-Content -Path $incrementalPrompt -Value $promptContent -Encoding UTF8
    Write-Host "  [OK] Created create-phases-incremental.md prompt" -ForegroundColor Green
} else {
    Write-Host "  [SKIP] create-phases-incremental.md already exists" -ForegroundColor DarkGray
}

# ── 3. Patch convergence-loop.ps1 for --Scope and --Incremental ──

$convergenceScript = Join-Path $GsdGlobalDir "scripts\convergence-loop.ps1"
if (Test-Path $convergenceScript) {
    $existing = Get-Content $convergenceScript -Raw

    # 3a. Add --Scope and --Incremental params
    if ($existing -notlike "*`[string`]`$Scope*") {
        $existing = $existing -replace '(\[switch\]\$ForceCodeReview)', '[switch]$ForceCodeReview,
    [string]$Scope = "",
    [switch]$Incremental'
        Write-Host "  [OK] Added --Scope and --Incremental params to convergence-loop.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] --Scope param already exists" -ForegroundColor DarkGray
    }

    # 3b. Add incremental Phase 0 logic
    if ($existing -notlike "*create-phases-incremental*") {
        $oldPhase0 = @'
# Phase 0: Create phases
$matrixContent = Get-Content $MatrixFile -Raw | ConvertFrom-Json
if ($matrixContent.requirements.Count -eq 0 -and -not $SkipInit) {
'@
        $newPhase0 = @'
# Phase 0: Create phases (or incremental update)
$matrixContent = Get-Content $MatrixFile -Raw | ConvertFrom-Json
if ($Incremental -and $matrixContent.requirements.Count -gt 0) {
    Write-Host "[CLIP] Phase 0: INCREMENTAL CREATE PHASES (adding new requirements)" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration 0 -Phase "create-phases-incremental" -Health $Health -BatchSize $CurrentBatchSize
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\create-phases-incremental.md" 0 $Health
    if (-not $DryRun) {
        Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "create-phases" `
            -LogFile "$GsdDir\logs\phase0-incremental.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash" | Out-Null
    }
    $Health = Get-Health
    Write-Host "  [OK] Matrix updated incrementally. Health: ${Health}%" -ForegroundColor Green
    Write-Host ""
} elseif ($matrixContent.requirements.Count -eq 0 -and -not $SkipInit) {
'@
        if ($existing -like "*$oldPhase0*") {
            $existing = $existing.Replace($oldPhase0, $newPhase0)
            Write-Host "  [OK] Added incremental Phase 0 logic" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Could not locate Phase 0 block for incremental patch" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [SKIP] Incremental Phase 0 already patched" -ForegroundColor DarkGray
    }

    # 3c. Add scope injection into plan prompt resolution
    if ($existing -notlike "*SCOPE*") {
        # Inject {{SCOPE}} replacement into Local-ResolvePrompt
        $oldResolve = '.Replace("{{FIGMA_VERSION}}", "(multi-interface)")'
        $newResolve = '.Replace("{{FIGMA_VERSION}}", "(multi-interface)").Replace("{{SCOPE}}", $Scope)'
        if ($existing -like "*$oldResolve*") {
            $existing = $existing.Replace($oldResolve, $newResolve)
            Write-Host "  [OK] Added {{SCOPE}} to Local-ResolvePrompt" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Could not locate ResolvePrompt for SCOPE injection" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [SKIP] SCOPE already in ResolvePrompt" -ForegroundColor DarkGray
    }

    Set-Content -Path $convergenceScript -Value $existing -Encoding UTF8
}

# ── 4. Patch plan.md to respect {{SCOPE}} ──

$planPrompt = Join-Path $GsdGlobalDir "prompts\claude\plan.md"
if (Test-Path $planPrompt) {
    $planContent = Get-Content $planPrompt -Raw

    if ($planContent -notlike "*SCOPE FILTER*") {
        $scopeSection = @'

## Scope Filter
{{SCOPE}}

If a scope filter is provided above (non-empty), apply it:
- `source:<value>` -- Only select requirements whose `source` field matches `<value>` (e.g., `source:v02_spec`, `source:bug_report`)
- `id:<id1>,<id2>,...` -- Only select requirements whose `req_id` is in the comma-separated list
- Empty scope -- Select from all not_started and partial requirements (default behavior)

The scope filter restricts WHICH requirements you may select for the batch.
You must still respect all other priority rules (dependencies, SDLC order, grouping).
Do NOT include requirements outside the scope even if they are not_started.
'@
        # Insert scope section before the "## Do" section
        $planContent = $planContent.Replace("## Do", "$scopeSection`n`n## Do")
        Set-Content -Path $planPrompt -Value $planContent -Encoding UTF8
        Write-Host "  [OK] Added scope filter to plan.md" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Scope filter already in plan.md" -ForegroundColor DarkGray
    }
}

# ── 5. Add gsd-fix and gsd-update commands to profile functions ──

$profileFunctions = Join-Path $GsdGlobalDir "scripts\gsd-profile-functions.ps1"
if (Test-Path $profileFunctions) {
    $pfContent = Get-Content $profileFunctions -Raw

    if ($pfContent -notlike "*function gsd-fix*") {
        $fixFunction = @'

function gsd-fix {
    <#
    .SYNOPSIS
        Quick bug fix mode. Injects bug descriptions into the requirements matrix
        and runs a short convergence cycle to fix them.
    .EXAMPLE
        gsd-fix "Login fails when email has + character"
        gsd-fix "Login fails with +" "Report totals wrong"
        gsd-fix -File bugs.md
        gsd-fix -BugDir ./bugs/login-issue/
        gsd-fix -File bugs.md -Scope "source:bug_report"
    #>
    param(
        [Parameter(ValueFromRemainingArguments=$true)]
        [string[]]$BugDescriptions,
        [string]$File = "",
        [string]$BugDir = "",
        [string]$Scope = "source:bug_report",
        [int]$MaxIterations = 5,
        [int]$BatchSize = 3,
        [string]$NtfyTopic = "",
        [switch]$DryRun,
        [int]$SupervisorAttempts = 3,
        [switch]$NoSupervisor
    )

    $repoRoot = (Get-Location).Path
    $gsdDir = Join-Path $repoRoot ".gsd"
    $matrixPath = Join-Path $gsdDir "health\requirements-matrix.json"
    $errorCtxPath = Join-Path $gsdDir "supervisor\error-context.md"

    # Ensure requirements-matrix.json exists
    if (-not (Test-Path $matrixPath)) {
        Write-Host "  [ERROR] requirements-matrix.json not found at $matrixPath" -ForegroundColor Red
        Write-Host "  Run gsd-converge first to initialize the project matrix." -ForegroundColor Yellow
        return
    }

    # Collect bug descriptions
    $bugs = @()
    $artifactSources = @{}  # Maps bug index to source directory

    # -- BugDir mode: read from a directory containing bug.md + artifacts --
    if ($BugDir -and (Test-Path $BugDir)) {
        $bugDirFull = (Resolve-Path $BugDir).Path
        $mdFiles = Get-ChildItem -Path $bugDirFull -Filter "*.md" -File
        if ($mdFiles.Count -eq 0) {
            $mdFiles = Get-ChildItem -Path $bugDirFull -Filter "*.txt" -File
        }
        if ($mdFiles.Count -gt 0) {
            foreach ($mdFile in $mdFiles) {
                $content = Get-Content $mdFile.FullName -Raw
                if ($content -match '^#\s+(.+)$') {
                    $desc = $Matches[1].Trim()
                } else {
                    $desc = ($content -split "`n")[0].Trim()
                }
                if ($desc.Length -gt 5) {
                    $bugIdx = $bugs.Count
                    $bugs += $desc
                    $artifactSources[$bugIdx] = $bugDirFull
                }
            }
        } else {
            Write-Host "  [WARN] No .md or .txt files found in $BugDir" -ForegroundColor Yellow
        }
        Write-Host "  [OK] Loaded $($bugs.Count) bug(s) from directory: $BugDir" -ForegroundColor Green
    }

    # -- File mode: one bug per line --
    if ($File -and (Test-Path $File)) {
        $fileContent = Get-Content $File -Raw
        $fileContent -split "`n" | ForEach-Object {
            $line = $_.Trim() -replace '^[-*]\s+', '' -replace '^\d+\.\s+', ''
            if ($line.Length -gt 5) { $bugs += $line }
        }
        Write-Host "  [OK] Loaded bugs from $File" -ForegroundColor Green
    }

    # -- CLI args --
    if ($BugDescriptions) {
        $bugs += $BugDescriptions
    }

    if ($bugs.Count -eq 0) {
        Write-Host "  [ERROR] No bug descriptions provided." -ForegroundColor Red
        Write-Host "  Usage:" -ForegroundColor Yellow
        Write-Host "    gsd-fix `"description`"" -ForegroundColor White
        Write-Host "    gsd-fix -File bugs.md" -ForegroundColor White
        Write-Host "    gsd-fix -BugDir ./bugs/login-issue/" -ForegroundColor White
        return
    }

    Write-Host ""
    Write-Host "  [BUG] GSD Fix Mode: $($bugs.Count) bug(s) to fix" -ForegroundColor Yellow
    Write-Host "  ================================================" -ForegroundColor DarkGray

    # Load existing matrix
    $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json

    # Find max existing req_id number
    $maxId = 0
    foreach ($req in $matrix.requirements) {
        if ($req.req_id -match '(\d+)$') {
            $num = [int]$Matches[1]
            if ($num -gt $maxId) { $maxId = $num }
        }
    }

    # Add bug requirements
    $newReqs = @()
    $errorCtx = "## Production Bugs to Fix`n`nAdded by gsd-fix at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n"
    $bugIndex = 0

    foreach ($bug in $bugs) {
        $maxId++
        $reqId = "BUG-$('{0:D3}' -f $maxId)"

        $newReq = [PSCustomObject]@{
            req_id       = $reqId
            source       = "bug_report"
            sdlc_phase   = "Phase-D-Implementation"
            description  = $bug
            status       = "not_started"
            depends_on   = @()
            priority     = "critical"
            spec_version = "fix"
        }
        $newReqs += $newReq
        $errorCtx += "- **$reqId**: $bug`n"

        # Copy artifacts if from BugDir
        if ($artifactSources.ContainsKey($bugIndex)) {
            $srcDir = $artifactSources[$bugIndex]
            $artifactDest = Join-Path $gsdDir "supervisor\bug-artifacts\$reqId"
            New-Item -ItemType Directory -Path $artifactDest -Force | Out-Null
            Get-ChildItem -Path $srcDir -File | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $artifactDest -Force
            }
            $artifactFiles = Get-ChildItem -Path $artifactDest -File
            $errorCtx += "  Artifacts ($($artifactFiles.Count) files): ``$artifactDest``"
            foreach ($af in $artifactFiles) {
                $ext = $af.Extension.ToLower()
                if ($ext -in '.png','.jpg','.jpeg','.gif','.bmp','.webp') {
                    $errorCtx += "`n  - [Screenshot] $($af.Name)"
                } elseif ($ext -in '.log','.txt') {
                    $errorCtx += "`n  - [Log] $($af.Name)"
                    $logLines = Get-Content $af.FullName -TotalCount 20
                    $errorCtx += "`n    ``````"
                    $errorCtx += "`n$($logLines -join "`n")"
                    $errorCtx += "`n    ``````"
                } else {
                    $errorCtx += "`n  - [File] $($af.Name)"
                }
            }
            $errorCtx += "`n"
            Write-Host "  [+] $reqId : $bug (+ $($artifactFiles.Count) artifact files)" -ForegroundColor Cyan
        } else {
            Write-Host "  [+] $reqId : $bug" -ForegroundColor Cyan
        }
        $bugIndex++
    }

    # If BugDir has detailed markdown, append full content to error context
    if ($BugDir -and (Test-Path $BugDir)) {
        $bugDirFull = (Resolve-Path $BugDir).Path
        $mdFiles = Get-ChildItem -Path $bugDirFull -Filter "*.md" -File
        foreach ($mdFile in $mdFiles) {
            $fullContent = Get-Content $mdFile.FullName -Raw
            $errorCtx += "`n### Detailed Bug Report: $($mdFile.Name)`n`n$fullContent`n"
        }
    }

    # Append to matrix
    $reqList = [System.Collections.ArrayList]@($matrix.requirements)
    foreach ($r in $newReqs) { $reqList.Add($r) | Out-Null }
    $matrix.requirements = $reqList.ToArray()

    # Recalculate totals
    $satisfied = ($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
    $partial = ($matrix.requirements | Where-Object { $_.status -eq "partial" }).Count
    $total = $matrix.requirements.Count
    $healthScore = if ($total -gt 0) { [math]::Round(($satisfied * 1.0 + $partial * 0.5) / $total * 100, 1) } else { 0 }

    if ($matrix.PSObject.Properties.Name -contains 'total_requirements') { $matrix.total_requirements = $total }
    if ($matrix.PSObject.Properties.Name -contains 'satisfied') { $matrix.satisfied = $satisfied }
    if ($matrix.PSObject.Properties.Name -contains 'health_score') { $matrix.health_score = $healthScore }

    # Write updated matrix
    $matrix | ConvertTo-Json -Depth 10 | Set-Content -Path $matrixPath -Encoding UTF8
    Write-Host ""
    Write-Host "  [OK] Matrix updated: $total total requirements, health: $healthScore%" -ForegroundColor Green

    # Write error context for supervisor injection
    $supervisorDir = Join-Path $gsdDir "supervisor"
    if (-not (Test-Path $supervisorDir)) { New-Item -ItemType Directory -Path $supervisorDir -Force | Out-Null }
    Set-Content -Path $errorCtxPath -Value $errorCtx -Encoding UTF8
    Write-Host "  [OK] Bug context written to error-context.md" -ForegroundColor Green

    # Also update health-current.json
    $healthPath = Join-Path $gsdDir "health\health-current.json"
    if (Test-Path $healthPath) {
        $healthObj = Get-Content $healthPath -Raw | ConvertFrom-Json
        $healthObj.health_score = $healthScore
        $healthObj.total_requirements = $total
        $healthObj.satisfied = $satisfied
        $healthObj | ConvertTo-Json | Set-Content -Path $healthPath -Encoding UTF8
    }

    Write-Host ""
    Write-Host "  [PLAY] Starting convergence with scope: $Scope" -ForegroundColor Yellow
    Write-Host ""

    # Call gsd-converge with fix-optimized settings
    gsd-converge -MaxIterations $MaxIterations -BatchSize $BatchSize `
        -Scope $Scope -SkipResearch -SkipSpecCheck `
        -NtfyTopic $NtfyTopic -DryRun:$DryRun `
        -SupervisorAttempts $SupervisorAttempts -NoSupervisor:$NoSupervisor
}

function gsd-update {
    <#
    .SYNOPSIS
        Incremental update mode. Reads new/updated specs and adds requirements
        to the existing matrix without losing satisfied items.
    .EXAMPLE
        gsd-update
        gsd-update -Scope "source:v02_spec"
        gsd-update -DryRun
    #>
    param(
        [string]$Scope = "",
        [int]$MaxIterations = 20,
        [int]$BatchSize = 8,
        [string]$NtfyTopic = "",
        [switch]$DryRun,
        [switch]$SkipSpecCheck,
        [int]$SupervisorAttempts = 5,
        [switch]$NoSupervisor
    )

    Write-Host ""
    Write-Host "  [UPDATE] GSD Incremental Update Mode" -ForegroundColor Yellow
    Write-Host "  Preserves existing satisfied requirements, adds new from updated specs" -ForegroundColor DarkGray
    Write-Host ""

    # Require existing matrix -- gsd-update is for projects already in convergence
    $repoRoot = (Get-Location).Path
    $matrixPath = Join-Path $repoRoot ".gsd\health\requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        Write-Host "  [ERROR] requirements-matrix.json not found at $matrixPath" -ForegroundColor Red
        Write-Host "  Run gsd-converge first to initialize the project, then gsd-update to add features." -ForegroundColor Yellow
        return
    }

    # Call gsd-converge with --Incremental flag
    $gsdArgs = @{
        MaxIterations      = $MaxIterations
        BatchSize          = $BatchSize
        Incremental        = $true
        SupervisorAttempts = $SupervisorAttempts
    }
    if ($Scope)        { $gsdArgs.Scope = $Scope }
    if ($NtfyTopic)    { $gsdArgs.NtfyTopic = $NtfyTopic }
    if ($DryRun)       { $gsdArgs.DryRun = $true }
    if ($SkipSpecCheck){ $gsdArgs.SkipSpecCheck = $true }
    if ($NoSupervisor) { $gsdArgs.NoSupervisor = $true }

    gsd-converge @gsdArgs
}

'@
        # Append to profile functions file
        Add-Content -Path $profileFunctions -Value $fixFunction -Encoding UTF8
        Write-Host "  [OK] Added gsd-fix and gsd-update commands" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] gsd-fix already exists" -ForegroundColor DarkGray
    }

    # 5b. Update gsd-converge to pass --Scope and --Incremental
    if ($pfContent -notlike "*`[string`]`$Scope*") {
        # Add Scope and Incremental params to gsd-converge
        $oldParams = @'
        [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch,
        [switch]$SkipSpecCheck, [switch]$AutoResolve, [switch]$ForceCodeReview,
'@
        $newParams = @'
        [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch,
        [switch]$SkipSpecCheck, [switch]$AutoResolve, [switch]$ForceCodeReview,
        [string]$Scope = "", [switch]$Incremental,
'@
        $pfContent = $pfContent.Replace($oldParams, $newParams)

        # Add Scope and Incremental to arg passing
        $oldArgPass = '    if ($ForceCodeReview) { $gsdArgs += "-ForceCodeReview" }'
        $newArgPass = @'
    if ($ForceCodeReview) { $gsdArgs += "-ForceCodeReview" }
    if ($Scope)         { $gsdArgs += "-Scope"; $gsdArgs += $Scope }
    if ($Incremental)   { $gsdArgs += "-Incremental" }
'@
        $pfContent = $pfContent.Replace($oldArgPass, $newArgPass)

        # Update the fallback else branch to include Scope and Incremental
        $oldFallback = '-ForceCodeReview:$ForceCodeReview -SupervisorAttempts $SupervisorAttempts -NoSupervisor:$NoSupervisor }'
        $newFallback = '-ForceCodeReview:$ForceCodeReview -Scope $Scope -Incremental:$Incremental -SupervisorAttempts $SupervisorAttempts -NoSupervisor:$NoSupervisor }'
        $pfContent = $pfContent.Replace($oldFallback, $newFallback)

        Set-Content -Path $profileFunctions -Value $pfContent -Encoding UTF8
        Write-Host "  [OK] Updated gsd-converge with --Scope and --Incremental" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] gsd-converge already has --Scope" -ForegroundColor DarkGray
    }

    # 5c. Update gsd-status to show maintenance commands
    if ($pfContent -notlike "*gsd-fix*") {
        $pfContent = Get-Content $profileFunctions -Raw
        $oldCommands = @'
    Write-Host "  Commands:" -ForegroundColor Yellow
    Write-Host "    gsd-blueprint              Greenfield generation" -ForegroundColor White
    Write-Host "    gsd-converge               Maintenance loop" -ForegroundColor White
    Write-Host "    gsd-status                 This screen" -ForegroundColor White
'@
        $newCommands = @'
    Write-Host "  Commands:" -ForegroundColor Yellow
    Write-Host "    gsd-blueprint              Greenfield generation" -ForegroundColor White
    Write-Host "    gsd-converge               Convergence loop" -ForegroundColor White
    Write-Host "    gsd-update                 Add new features (incremental)" -ForegroundColor White
    Write-Host "    gsd-fix `"bug desc`"          Quick bug fix mode" -ForegroundColor White
    Write-Host "    gsd-costs                  Token cost calculator" -ForegroundColor White
    Write-Host "    gsd-status                 This screen" -ForegroundColor White
'@
        $pfContent = $pfContent.Replace($oldCommands, $newCommands)
        Set-Content -Path $profileFunctions -Value $pfContent -Encoding UTF8
        Write-Host "  [OK] Updated gsd-status command list" -ForegroundColor Green
    }
}

# ── 6. Update install-gsd-all.ps1 to include this script ──

$installerPath = Join-Path $GsdGlobalDir "scripts\install-gsd-all.ps1"
if (Test-Path $installerPath) {
    $installerContent = Get-Content $installerPath -Raw
    if ($installerContent -notlike "*patch-gsd-maintenance-mode*") {
        # Find the last patch script reference and add after it
        if ($installerContent -match 'patch-gsd-loc-tracking') {
            $installerContent = $installerContent -replace '(.*patch-gsd-loc-tracking.*)', "`$1`n& `"`$ScriptDir\patch-gsd-maintenance-mode.ps1`" -UserHome `$UserHome"
            Set-Content -Path $installerPath -Value $installerContent -Encoding UTF8
            Write-Host "  [OK] Added to install-gsd-all.ps1" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Could not find loc-tracking reference in installer" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [SKIP] Already in installer" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Maintenance Mode installed!" -ForegroundColor Green
Write-Host ""
Write-Host "  New commands:" -ForegroundColor Yellow
Write-Host "    gsd-fix `"bug description`"                   Quick bug fix" -ForegroundColor White
Write-Host "    gsd-fix -File bugs.md                        Fix from file" -ForegroundColor White
Write-Host "    gsd-fix -BugDir ./bugs/login-issue/          Fix with screenshots/logs" -ForegroundColor White
Write-Host "    gsd-update                                   Add features from new specs" -ForegroundColor White
Write-Host "    gsd-converge -Scope `"source:bug_report`"      Scoped convergence" -ForegroundColor White
Write-Host "    gsd-converge -Incremental                    Add new requirements" -ForegroundColor White
Write-Host ""
Write-Host "  Config: global-config.json -> maintenance_mode" -ForegroundColor DarkGray
Write-Host ""
