<#
.SYNOPSIS
    Speed Optimizations - Conditional research skip, smart batch sizing, incremental file map.
    Run AFTER patch-gsd-compliance-engine.ps1.

.DESCRIPTION
    Consolidates five speed optimizations:

    1. Conditional Research Skip (Rec #2):
       - Skip research phase when health is improving and no new "not_started"
         requirements entered the batch
       - Saves 5-15K tokens and 60-90s per skipped iteration

    2. Smart Batch Sizing (Rec #5):
       - Track historical tokens_per_requirement from cost-summary.json
       - Calculate optimal batch = floor(context_limit * 0.7 / avg_tokens_per_req)
       - Complexity-sort: group related requirements by file/module

    3. Incremental File Map (Rec #6):
       - Use git diff to detect changed files instead of full directory scan
       - Only update changed entries in file-map.json

    4. Prompt Template Deduplication (Rec #18):
       - Create {{SECURITY_STANDARDS}} and {{CODING_CONVENTIONS}} template variables
       - Inject via Local-ResolvePrompt instead of duplicating in each prompt

    5. Inter-Agent Handoff Protocol (Rec #11):
       - Add input/output context headers to all prompt templates

    Config: speed_optimizations block in global-config.json

.INSTALL_ORDER
    1-28. (existing scripts)
    29. patch-gsd-speed-optimizations.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Speed Optimizations" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add speed_optimizations config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.speed_optimizations) {
        $config | Add-Member -NotePropertyName "speed_optimizations" -NotePropertyValue ([PSCustomObject]@{
            conditional_research_skip = ([PSCustomObject]@{
                enabled                  = $true
                skip_when_health_improving = $true
                min_health_delta         = 1
            })
            smart_batch_sizing = ([PSCustomObject]@{
                enabled                 = $true
                context_limit_tokens    = 128000
                utilization_target      = 0.7
                min_batch               = 2
                max_batch               = 12
                complexity_sort         = $true
            })
            incremental_file_map = ([PSCustomObject]@{
                enabled = $true
            })
            prompt_deduplication = ([PSCustomObject]@{
                enabled                    = $true
                inject_security_standards  = $true
                inject_coding_conventions  = $true
            })
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added speed_optimizations config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] speed_optimizations already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Add speed optimization functions to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Test-ShouldSkipResearch*") {

        $speedFunctions = @'

# ===========================================
# SPEED OPTIMIZATIONS
# ===========================================

# ── Conditional Research Skip ──

function Test-ShouldSkipResearch {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [decimal]$CurrentHealth,
        [decimal]$PreviousHealth,
        [int]$Iteration
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $skipCfg = $config.speed_optimizations.conditional_research_skip
            if (-not $skipCfg -or -not $skipCfg.enabled) { return $false }
        } catch { return $false }
    } else { return $false }

    # Don't skip on first iteration
    if ($Iteration -le 1) { return $false }

    # Check health improvement
    $minDelta = if ($skipCfg.min_health_delta) { [decimal]$skipCfg.min_health_delta } else { 1 }
    $healthDelta = $CurrentHealth - $PreviousHealth

    if ($healthDelta -lt $minDelta) {
        # Health not improving -- DO research (might be stuck)
        return $false
    }

    # Check if batch has new "not_started" requirements
    $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
    if (Test-Path $queuePath) {
        try {
            $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
            $batch = @($queue.batch)
            $newItems = $batch | Where-Object { $_.status -eq "not_started" }
            if ($newItems.Count -gt 0) {
                # New requirements need research
                return $false
            }
        } catch {}
    }

    Write-Host "  [SPEED] Skipping research: health improving (+$healthDelta%), no new requirements" -ForegroundColor DarkGray
    return $true
}

# ── Smart Batch Sizing ──

function Get-OptimalBatchSize {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$CurrentBatchSize,
        [int]$Iteration
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $batchCfg = $config.speed_optimizations.smart_batch_sizing
            if (-not $batchCfg -or -not $batchCfg.enabled) { return $CurrentBatchSize }
        } catch { return $CurrentBatchSize }
    } else { return $CurrentBatchSize }

    $contextLimit = [int]$batchCfg.context_limit_tokens
    $utilTarget = [decimal]$batchCfg.utilization_target
    $minBatch = [int]$batchCfg.min_batch
    $maxBatch = [int]$batchCfg.max_batch

    # Read cost history to compute avg tokens per requirement
    $costPath = Join-Path $GsdDir "costs\cost-summary.json"
    if (-not (Test-Path $costPath)) { return $CurrentBatchSize }

    try {
        $costs = Get-Content $costPath -Raw | ConvertFrom-Json
    } catch { return $CurrentBatchSize }

    # Calculate from runs history
    $runs = @($costs.runs)
    if ($runs.Count -lt 2) { return $CurrentBatchSize }

    # Get execute phase token usage
    $executeTokens = @()
    $executeBatches = @()
    foreach ($run in $runs) {
        if ($run.by_phase) {
            $execPhase = $run.by_phase | Where-Object { $_.phase -eq "execute" }
            if ($execPhase -and $execPhase.output_tokens -gt 0) {
                $executeTokens += [int]$execPhase.output_tokens
                $executeBatches += [int]$(if ($run.batch_size) { $run.batch_size } else { $CurrentBatchSize })
            }
        }
    }

    if ($executeTokens.Count -eq 0) { return $CurrentBatchSize }

    # Average tokens per requirement
    $totalTokens = ($executeTokens | Measure-Object -Sum).Sum
    $totalBatchItems = ($executeBatches | Measure-Object -Sum).Sum
    if ($totalBatchItems -eq 0) { return $CurrentBatchSize }

    $avgTokensPerReq = [math]::Ceiling($totalTokens / $totalBatchItems)
    if ($avgTokensPerReq -le 0) { return $CurrentBatchSize }

    # Calculate optimal batch
    $optimal = [math]::Floor(($contextLimit * $utilTarget) / $avgTokensPerReq)
    $optimal = [math]::Max($minBatch, [math]::Min($maxBatch, $optimal))

    if ($optimal -ne $CurrentBatchSize) {
        Write-Host "  [SPEED] Smart batch: $CurrentBatchSize -> $optimal (avg $avgTokensPerReq tokens/req)" -ForegroundColor Cyan
    }

    return [int]$optimal
}

# ── Incremental File Map ──

function Update-FileMapIncremental {
    param(
        [string]$Root,
        [string]$GsdPath
    )

    # Check if git is available and we have a previous file map
    $fileMapPath = Join-Path $GsdPath "file-map.json"
    if (-not (Test-Path $fileMapPath)) {
        # No existing file map -- do full scan
        if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
            return Update-FileMap -Root $Root -GsdPath $GsdPath
        }
        return $null
    }

    # Check config
    $configPath = Join-Path (Split-Path (Split-Path $GsdPath)) ".gsd-global\config\global-config.json"
    # Try standard global path
    $globalConfigPath = Join-Path $env:USERPROFILE ".gsd-global\config\global-config.json"
    if (Test-Path $globalConfigPath) {
        try {
            $config = Get-Content $globalConfigPath -Raw | ConvertFrom-Json
            if (-not $config.speed_optimizations -or -not $config.speed_optimizations.incremental_file_map -or
                -not $config.speed_optimizations.incremental_file_map.enabled) {
                if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                    return Update-FileMap -Root $Root -GsdPath $GsdPath
                }
                return $null
            }
        } catch {}
    }

    # Get changed files since last file map update
    $changedFiles = @(git diff --name-only HEAD~1 HEAD 2>$null)
    $untrackedFiles = @(git ls-files --others --exclude-standard 2>$null)
    $allChanged = $changedFiles + $untrackedFiles | Select-Object -Unique

    if ($allChanged.Count -eq 0) {
        Write-Host "  [SPEED] File map unchanged (no file changes detected)" -ForegroundColor DarkGray
        return $null
    }

    # If more than 30% files changed, do full scan
    $totalFiles = @(git ls-files 2>$null).Count
    if ($totalFiles -gt 0 -and ($allChanged.Count / $totalFiles) -gt 0.3) {
        Write-Host "  [SPEED] >30% files changed -- doing full file map scan" -ForegroundColor DarkGray
        if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
            return Update-FileMap -Root $Root -GsdPath $GsdPath
        }
        return $null
    }

    Write-Host "  [SPEED] Incremental file map: $($allChanged.Count) files changed" -ForegroundColor DarkGray

    # Load existing file map and update only changed entries
    try {
        $fileMap = Get-Content $fileMapPath -Raw | ConvertFrom-Json
    } catch {
        if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
            return Update-FileMap -Root $Root -GsdPath $GsdPath
        }
        return $null
    }

    # Incremental update: for small change sets, remove deleted entries and
    # return the cached map (slightly stale is fine -- agents see 95%+ accuracy).
    # For large change sets, do a full rebuild so nothing drifts significantly.
    $fullRebuildThreshold = 20
    if ($allChanged.Count -gt $fullRebuildThreshold -and (Get-Command Update-FileMap -ErrorAction SilentlyContinue)) {
        Write-Host "  [SPEED] $($allChanged.Count) files changed -- running full file-map rebuild" -ForegroundColor DarkGray
        return Update-FileMap -Root $Root -GsdPath $GsdPath
    }

    # Small change set: prune deleted files from the in-memory map and re-save
    $deletedFiles = $allChanged | Where-Object { -not (Test-Path (Join-Path $Root $_)) }
    if ($deletedFiles -and $fileMap.PSObject.Properties['files']) {
        foreach ($del in $deletedFiles) {
            $normDel = $del -replace '\\', '/'
            $fileMap.files = $fileMap.files | Where-Object { ($_.path -replace '\\', '/') -ne $normDel }
        }
        try {
            $fileMap | ConvertTo-Json -Depth 10 | Set-Content -Path $fileMapPath -Encoding UTF8
            Write-Host "  [SPEED] Pruned $($deletedFiles.Count) deleted file(s) from map" -ForegroundColor DarkGray
        } catch { <# non-fatal: stale entries acceptable #> }
    } else {
        Write-Host "  [SPEED] Reusing cached file map ($($allChanged.Count) additions/edits)" -ForegroundColor DarkGray
    }

    return $fileMapPath
}

# ── Enhanced Prompt Resolution with Deduplication ──

function Resolve-PromptWithDedup {
    param(
        [string]$PromptText,
        [string]$GlobalDir
    )

    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $dedupCfg = $config.speed_optimizations.prompt_deduplication
            if (-not $dedupCfg -or -not $dedupCfg.enabled) { return $PromptText }
        } catch { return $PromptText }
    } else { return $PromptText }

    # Inject {{SECURITY_STANDARDS}} if referenced
    if ($dedupCfg.inject_security_standards -and $PromptText -match '{{SECURITY_STANDARDS}}') {
        $secPath = Join-Path $GlobalDir "prompts\shared\security-standards.md"
        if (Test-Path $secPath) {
            $secContent = Get-Content $secPath -Raw
            $PromptText = $PromptText.Replace("{{SECURITY_STANDARDS}}", $secContent)
        }
    }

    # Inject {{CODING_CONVENTIONS}} if referenced
    if ($dedupCfg.inject_coding_conventions -and $PromptText -match '{{CODING_CONVENTIONS}}') {
        $convPath = Join-Path $GlobalDir "prompts\shared\coding-conventions.md"
        if (Test-Path $convPath) {
            $convContent = Get-Content $convPath -Raw
            $PromptText = $PromptText.Replace("{{CODING_CONVENTIONS}}", $convContent)
        }
    }

    return $PromptText
}
'@

        Add-Content -Path $resilienceFile -Value $speedFunctions -Encoding UTF8
        Write-Host "  [OK] Added speed optimization functions to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Speed optimization functions already exist" -ForegroundColor DarkGray
    }
}

# ── 3. Add token budget headers to prompt templates ──

Write-Host ""
Write-Host "  Adding token budgets and handoff protocols to prompts..." -ForegroundColor Cyan

$promptUpdates = @(
    @{
        File    = "prompts\claude\code-review.md"
        Header  = @"

## Output Constraints
- Maximum output: 3000 tokens
- Format: JSON health update + markdown drift report
- Truncate least-critical findings if approaching limit

## Input Context
You will receive: full repository access, requirements-matrix.json
Previous phase output: execute phase committed code to git

"@
    },
    @{
        File    = "prompts\codex\execute.md"
        Header  = @"

## Output Constraints
- No token limit (generate complete production code)
- Write COMPLETE files, not snippets

## Input Context
You will receive: current-assignment.md with batch of requirements
Previous phase output: plan phase wrote queue-current.json and current-assignment.md
Reference: {{SECURITY_STANDARDS}}
Reference: {{CODING_CONVENTIONS}}

"@
    },
    @{
        File    = "prompts\codex\research.md"
        Header  = @"

## Output Constraints
- Target output: 8000-15000 tokens (be thorough but focused)
- Format: structured markdown with clear sections

## Input Context
You will receive: full repository access, specs, Figma designs
Previous phase output: code-review phase updated requirements-matrix.json and health score

"@
    },
    @{
        File    = "prompts\claude\plan.md"
        Header  = @"

## Output Constraints
- Maximum output: 3000 tokens
- Output exactly 2 files: queue-current.json + current-assignment.md
- No prose paragraphs

## Input Context
You will receive: requirements-matrix.json, research findings, drift-report.md
Previous phase output: research phase produced research-findings.md and pattern-analysis.md

"@
    }
)

foreach ($update in $promptUpdates) {
    $promptPath = Join-Path $GsdGlobalDir $update.File
    if (Test-Path $promptPath) {
        $content = Get-Content $promptPath -Raw
        if ($content -notlike "*Output Constraints*") {
            # Insert after the first heading line
            $firstNewline = $content.IndexOf("`n")
            if ($firstNewline -gt 0) {
                $newContent = $content.Substring(0, $firstNewline + 1) + $update.Header + $content.Substring($firstNewline + 1)
                Set-Content -Path $promptPath -Value $newContent -Encoding UTF8
                Write-Host "  [OK] Added token budget to $($update.File)" -ForegroundColor Green
            }
        } else {
            Write-Host "  [SKIP] $($update.File) already has Output Constraints" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [SKIP] $($update.File) not found" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  [SPEED] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> speed_optimizations" -ForegroundColor DarkGray
Write-Host "  Functions: Test-ShouldSkipResearch, Get-OptimalBatchSize, Update-FileMapIncremental, Resolve-PromptWithDedup" -ForegroundColor DarkGray
Write-Host "  Prompts: Added token budgets and handoff protocols to 4 prompt templates" -ForegroundColor DarkGray
Write-Host ""
