<#
.SYNOPSIS
    Final Integration Sub-Patch 4/6: Blueprint Pipeline - Fully Integrated
    Fixes GAP 9: Per-iteration disk checks in main loop
    Fixes GAP 11: Loads interface-wrapper.ps1, calls Initialize-ProjectInterfaces
    Fixes GAP 12: Selects Figma Make prompts when _analysis/ exists
#>
param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$BpScriptDir = Join-Path $UserHome ".gsd-global\blueprint\scripts"

Write-Host "[SYNC] Sub-patch 4/6: Blueprint pipeline - fully integrated..." -ForegroundColor Yellow

$script = @'
<#
.SYNOPSIS
    Blueprint Pipeline - Final Integrated Edition
    All gaps closed: multi-interface, Figma Make prompts, spec check, disk per-iter, storyboard verify
#>
param(
    [int]$MaxIterations = 30, [int]$StallThreshold = 3, [int]$BatchSize = 15,
    [int]$ThrottleSeconds = 30,
    [switch]$DryRun, [switch]$BlueprintOnly, [switch]$BuildOnly, [switch]$VerifyOnly,
    [switch]$SkipSpecCheck, [switch]$AutoResolve
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"
$BpGlobalDir = Join-Path $GlobalDir "blueprint"
$GsdDir = Join-Path $RepoRoot ".gsd"
$BpDir = Join-Path $GsdDir "blueprint"

# -- Load ALL modules --
. "$GlobalDir\lib\modules\resilience.ps1"
if (Test-Path "$GlobalDir\lib\modules\interfaces.ps1") {
    . "$GlobalDir\lib\modules\interfaces.ps1"
}
if (Test-Path "$GlobalDir\lib\modules\interface-wrapper.ps1") {
    . "$GlobalDir\lib\modules\interface-wrapper.ps1"
}

# -- Ensure dirs --
@($GsdDir, $BpDir, "$GsdDir\logs") | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# -- State files --
$BlueprintFile = Join-Path $BpDir "blueprint.json"
$HealthFile = Join-Path $BpDir "health.json"
$HealthLog = Join-Path $BpDir "health-history.jsonl"

if (-not (Test-Path $HealthFile)) {
    @{ total=0; completed=0; partial=0; not_started=0; health=0; current_tier=0; current_tier_name="none"; iteration=0; status="not_started" } |
        ConvertTo-Json | Set-Content $HealthFile -Encoding UTF8
}

function Get-Health {
    try { return [double](Get-Content $HealthFile -Raw | ConvertFrom-Json).health } catch { return 0 }
}
function Has-Blueprint {
    if (-not (Test-Path $BlueprintFile)) { return $false }
    try { return (Get-Content $BlueprintFile -Raw | ConvertFrom-Json).tiers.Count -gt 0 } catch { return $false }
}

# ========================================
# STARTUP
# ========================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Blue
Write-Host "  * Blueprint Pipeline - Final Integrated Edition" -ForegroundColor Blue
Write-Host "=========================================================" -ForegroundColor Blue

# Pre-flight
if (-not $DryRun) {
    $preFlight = Test-PreFlight -RepoRoot $RepoRoot -GsdDir $GsdDir
    if (-not $preFlight) { Write-Host "  [XX] Pre-flight failed." -ForegroundColor Red; exit 1 }
    New-GsdLock -GsdDir $GsdDir -Pipeline "blueprint"
}

# Interface detection (GAP 11)
$InterfaceContext = ""
$UseFigmaMake = $false
$hasStoryboards = $false

if (Get-Command Initialize-ProjectInterfaces -ErrorAction SilentlyContinue) {
    Write-Host ""
    $ifaceResult = Initialize-ProjectInterfaces -RepoRoot $RepoRoot -GsdDir $GsdDir
    $InterfaceContext = $ifaceResult.Context
    $UseFigmaMake = $ifaceResult.UseFigmaMakePrompts

    $hasStoryboards = ($ifaceResult.Interfaces | Where-Object {
        $_.HasAnalysis -and $_.AnalysisFiles.ContainsKey("storyboards") -and $_.AnalysisFiles["storyboards"].Exists
    }).Count -gt 0
} else {
    Write-Host "  [!!]  Interface module not loaded - using standard prompts" -ForegroundColor DarkYellow
}

# Select correct prompts (GAP 12)
$BlueprintPromptPath = if ($UseFigmaMake -and (Test-Path "$BpGlobalDir\prompts\claude\blueprint-figmamake.md")) {
    "$BpGlobalDir\prompts\claude\blueprint-figmamake.md"
} else { "$BpGlobalDir\prompts\claude\blueprint.md" }

$BuildPromptPath = if ($UseFigmaMake -and (Test-Path "$BpGlobalDir\prompts\codex\build-figmamake.md")) {
    "$BpGlobalDir\prompts\codex\build-figmamake.md"
} else { "$BpGlobalDir\prompts\codex\build.md" }

$VerifyPromptPath = if ($hasStoryboards -and (Test-Path "$BpGlobalDir\prompts\claude\verify-storyboard.md")) {
    "$BpGlobalDir\prompts\claude\verify-storyboard.md"
} else { "$BpGlobalDir\prompts\claude\verify.md" }

Write-Host "  Prompts:   $(if ($UseFigmaMake) {'Figma Make'} else {'Standard'})$(if ($hasStoryboards) {' + storyboard verify'})" -ForegroundColor White

# Checkpoint recovery
$checkpoint = Get-Checkpoint -GsdDir $GsdDir
$Iteration = 0; $Health = Get-Health; $CurrentBatchSize = $BatchSize
if ($checkpoint -and $checkpoint.pipeline -eq "blueprint" -and -not $BlueprintOnly) {
    Write-Host "  [SYNC] Resuming: Iter $($checkpoint.iteration)" -ForegroundColor Yellow
    $Iteration = $checkpoint.iteration; $Health = $checkpoint.health
    $CurrentBatchSize = if ($checkpoint.batch_size -gt 0) { $checkpoint.batch_size } else { $BatchSize }
}

Write-Host "  Health:    ${Health}% -> 100% | Batch: $CurrentBatchSize (adaptive)" -ForegroundColor White
if ($ThrottleSeconds -gt 0) { Write-Host "  Throttle:  ${ThrottleSeconds}s between agent calls (prevents quota exhaustion)" -ForegroundColor DarkGray }
if ($DryRun) { Write-Host "  MODE:      DRY RUN" -ForegroundColor Yellow }
Write-Host ""

# Helper to resolve prompts with interface context
function Local-ResolvePrompt($templatePath, $iter, $health) {
    $text = Get-Content $templatePath -Raw
    $resolved = $text.Replace("{{ITERATION}}", "$iter").Replace("{{HEALTH}}", "$health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{BATCH_SIZE}}", "$CurrentBatchSize").Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext).Replace("{{FIGMA_PATH}}", "(see interface context)").Replace("{{FIGMA_VERSION}}", "(multi-interface)")
    # Inject file map reference so agents always know repo structure
    $fileMapPath = Join-Path $GsdDir "file-map.json"
    $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
    if (Test-Path $fileTreePath) {
        $resolved += "`n`n## Repository File Map`nA live file map is maintained at:`n- JSON: $fileMapPath`n- Tree: $fileTreePath`nRead the tree file to understand the current repo structure. This map is updated after every iteration.`n"
    }
    return $resolved
}

# Spec consistency check (GAP 5+15) with optional auto-resolution
if (-not $SkipSpecCheck -and -not $BuildOnly -and -not $VerifyOnly) {
    if (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {
        $Interfaces = if ($ifaceResult) { $ifaceResult.Interfaces } else { @() }
        $specResult = Invoke-SpecConsistencyCheck -RepoRoot $RepoRoot -GsdDir $GsdDir -Interfaces $Interfaces -DryRun:$DryRun
        if (-not $specResult.Passed) {
            if ($AutoResolve -and (Get-Command Invoke-SpecConflictResolution -ErrorAction SilentlyContinue)) {
                $resolution = Invoke-SpecConflictResolution -RepoRoot $RepoRoot -GsdDir $GsdDir `
                    -Interfaces $Interfaces -Conflicts $specResult.Conflicts `
                    -Warnings $specResult.Warnings -DryRun:$DryRun
                if (-not $resolution.Resolved) {
                    Write-Host "  [BLOCK] Auto-resolution failed. Fix spec conflicts manually." -ForegroundColor Red
                    Write-Host "  See: .gsd\spec-conflicts\conflicts-to-resolve.json" -ForegroundColor Yellow
                    Remove-GsdLock -GsdDir $GsdDir; exit 1
                }
            } else {
                Write-Host "  [BLOCK] Fix spec conflicts first. Use -AutoResolve to attempt auto-fix." -ForegroundColor Red
                Remove-GsdLock -GsdDir $GsdDir; exit 1
            }
        }
    }
    Write-Host ""
}

trap { Remove-GsdLock -GsdDir $GsdDir }

try {

# -- PHASE 1: BLUEPRINT --
$needsBlueprint = (-not (Has-Blueprint)) -and (-not $BuildOnly) -and (-not $VerifyOnly)

if ($needsBlueprint) {
    Write-Host "* PHASE 1: BLUEPRINT (Claude Code)" -ForegroundColor Blue
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration 0 -Phase "blueprint" -Health 0 -BatchSize $CurrentBatchSize
    $prompt = Local-ResolvePrompt $BlueprintPromptPath 0 0

    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "blueprint" `
            -LogFile "$GsdDir\logs\phase1-blueprint.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if (-not $result.Success) { Write-Host "  [XX] Blueprint failed." -ForegroundColor Red; return }
        if (Has-Blueprint) {
            $bp = Get-Content $BlueprintFile -Raw | ConvertFrom-Json
            $total = 0; $bp.tiers | ForEach-Object { $total += $_.items.Count }
            Write-Host "  [OK] Blueprint: $total items, $($bp.tiers.Count) tiers" -ForegroundColor Green
        }
    } else { Write-Host "  [DRY RUN] claude -> blueprint" -ForegroundColor DarkYellow }

    if ($BlueprintOnly) { Clear-Checkpoint -GsdDir $GsdDir; Remove-GsdLock -GsdDir $GsdDir; return }
}

# -- MAIN LOOP --
$StallCount = 0; $TargetHealth = 100; $Health = Get-Health

while ($Health -lt $TargetHealth -and $Iteration -lt $MaxIterations -and $StallCount -lt $StallThreshold) {
    $Iteration++; $PrevHealth = $Health

    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "starting"

    # Per-iteration disk check (GAP 9)
    if (-not $DryRun) {
        if (-not (Test-DiskSpace -RepoRoot $RepoRoot -GsdDir $GsdDir)) {
            Write-Host "  [XX] Disk space critical. Stopping." -ForegroundColor Red; break
        }
        New-GitSnapshot -RepoRoot $RepoRoot -Iteration $Iteration -Pipeline "blueprint"
    }

    # VERIFY (storyboard-aware if available)
    Write-Host "  [SEARCH] CLAUDE -> verify$(if ($hasStoryboards) {' + storyboard'})" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration $Iteration -Phase "verify" -Health $Health -BatchSize $CurrentBatchSize
    $prompt = Local-ResolvePrompt $VerifyPromptPath $Iteration $Health
    if (-not $DryRun) {
        Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "verify" `
            -LogFile "$GsdDir\logs\iter${Iteration}-1-verify.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
    }
    $Health = Get-Health
    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }

    # Health regression
    if (-not $DryRun -and $Iteration -gt 1) {
        if (Test-HealthRegression -PreviousHealth $PrevHealth -CurrentHealth $Health -RepoRoot $RepoRoot -Iteration $Iteration) {
            $Health = $PrevHealth; $StallCount++; continue
        }
    }

    if ($VerifyOnly) { break }

    # Throttle between phases
    if ($ThrottleSeconds -gt 0 -and -not $DryRun) {
        Write-Host "  [THROTTLE] ${ThrottleSeconds}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $ThrottleSeconds
    }

    # BUILD (Figma Make aware)
    Write-Host "  [WRENCH] CODEX -> build (batch: $CurrentBatchSize)" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration $Iteration -Phase "build" -Health $Health -BatchSize $CurrentBatchSize
    $prompt = Local-ResolvePrompt $BuildPromptPath $Iteration $Health
    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "build" `
            -LogFile "$GsdDir\logs\iter${Iteration}-2-build.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if ($result.Success) {
            $CurrentBatchSize = $result.FinalBatchSize
            git add -A; git commit -m "blueprint: iter $Iteration (health: ${Health}%)" --no-verify 2>$null
            # Update file map after each iteration so agents see current structure
            if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
            }
            Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix | Out-Null
        } else { $CurrentBatchSize = $result.FinalBatchSize; $StallCount++; continue }
    }

    # Stall detection
    $NewHealth = Get-Health
    if ($NewHealth -le $PrevHealth -and $Iteration -gt 1) {
        $StallCount++
        $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * 0.75))
        Write-Host "  [!!]  Stall $StallCount/$StallThreshold | Batch -> $CurrentBatchSize" -ForegroundColor DarkYellow
        if ($StallCount -ge $StallThreshold -and -not $DryRun) {
            $diagFiles = ".gsd\blueprint\*, .gsd\logs\errors.jsonl"
            if ($hasStoryboards) { $diagFiles += ", storyboard-issues.md" }
            Invoke-WithRetry -Agent "claude" -Prompt "Stalled at ${NewHealth}%. Read $diagFiles. Diagnose. Write .gsd\blueprint\stall-diagnosis.md." `
                -Phase "stall" -LogFile "$GsdDir\logs\stall-$Iteration.log" -CurrentBatchSize 1 -GsdDir $GsdDir | Out-Null
            break
        }
    } else {
        $StallCount = 0
        if ($CurrentBatchSize -lt $BatchSize) { $CurrentBatchSize = [math]::Min($BatchSize, $CurrentBatchSize + 2) }
    }

    $Health = $NewHealth
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "done"
    Write-Host ""; Start-Sleep -Seconds 2
}

# FINAL
Write-Host ""; Write-Host "=========================================================" -ForegroundColor Blue
$FinalHealth = Get-Health
if ($FinalHealth -ge $TargetHealth) {
    Write-Host "  [PARTY] COMPLETE - ${FinalHealth}% in $Iteration iterations" -ForegroundColor Green
    if (-not $DryRun) { git add -A; git commit -m "blueprint: COMPLETE" --no-verify 2>$null; git tag "blueprint-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null }
} elseif ($StallCount -ge $StallThreshold) { Write-Host "  [STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
} else { Write-Host "  [!!]  $(if ($VerifyOnly){'VERIFY DONE'}else{'MAX ITERATIONS'}) at ${FinalHealth}%" -ForegroundColor Yellow }

if (Test-Path $HealthLog) {
    $entries = Get-Content $HealthLog -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }
    if ($entries.Count -gt 0) {
        Write-Host ""; Write-Host "  Progression:" -ForegroundColor DarkGray
        foreach ($e in $entries) {
            $bar = "#" * [math]::Floor($e.health / 5) + "." * (20 - [math]::Floor($e.health / 5))
            Write-Host "    Iter $($e.iteration): [$bar] $($e.health)%" -ForegroundColor DarkGray
        }
    }
}
Write-Host "=========================================================" -ForegroundColor Blue

} finally { Clear-Checkpoint -GsdDir $GsdDir; Remove-GsdLock -GsdDir $GsdDir }
'@

Set-Content -Path "$BpScriptDir\blueprint-pipeline.ps1" -Value $script -Encoding UTF8
Write-Host "   [OK] blueprint-pipeline.ps1 (final)" -ForegroundColor DarkGreen
