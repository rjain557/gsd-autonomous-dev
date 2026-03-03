<#
.SYNOPSIS
    Final Integration Sub-Patch 5/6: Convergence Pipeline - Fully Integrated
    Fixes GAP 13: Multi-interface, Figma Make context, spec check, disk per-iter
#>
param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$ScriptDir = Join-Path $UserHome ".gsd-global\scripts"

Write-Host "[SYNC] Sub-patch 5/6: Convergence pipeline - fully integrated..." -ForegroundColor Yellow

$script = @'
<#
.SYNOPSIS
    GSD Convergence Loop - Final Integrated Edition
    Multi-interface, Figma Make aware, spec check, all gaps closed
#>
param(
    [int]$MaxIterations = 20, [int]$StallThreshold = 3, [int]$BatchSize = 8,
    [int]$ThrottleSeconds = 30,
    [string]$NtfyTopic = "",
    [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch, [switch]$SkipSpecCheck,
    [switch]$AutoResolve
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"
$GsdDir = Join-Path $RepoRoot ".gsd"

# Load ALL modules
. "$GlobalDir\lib\modules\resilience.ps1"
if (Test-Path "$GlobalDir\lib\modules\interfaces.ps1") { . "$GlobalDir\lib\modules\interfaces.ps1" }
if (Test-Path "$GlobalDir\lib\modules\interface-wrapper.ps1") { . "$GlobalDir\lib\modules\interface-wrapper.ps1" }

# Initialize push notifications
if (Get-Command Initialize-GsdNotifications -ErrorAction SilentlyContinue) {
    Initialize-GsdNotifications -GsdGlobalDir $GlobalDir -OverrideTopic $NtfyTopic
}
$repoName = Split-Path $RepoRoot -Leaf

# Ensure dirs
@($GsdDir, "$GsdDir\health", "$GsdDir\code-review", "$GsdDir\research",
  "$GsdDir\generation-queue", "$GsdDir\agent-handoff", "$GsdDir\specs", "$GsdDir\logs") | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

$HealthFile = Join-Path $GsdDir "health\health-current.json"
$MatrixFile = Join-Path $GsdDir "health\requirements-matrix.json"

if (-not (Test-Path $HealthFile)) {
    @{ health_score=0; total_requirements=0; satisfied=0; partial=0; not_started=0; iteration=0 } |
        ConvertTo-Json | Set-Content $HealthFile -Encoding UTF8
}
if (-not (Test-Path $MatrixFile)) {
    @{ meta=@{ total_requirements=0; satisfied=0; health_score=0; iteration=0 }; requirements=@() } |
        ConvertTo-Json -Depth 4 | Set-Content $MatrixFile -Encoding UTF8
}

function Get-Health {
    try { return [double](Get-Content $HealthFile -Raw | ConvertFrom-Json).health_score } catch { return 0 }
}

# -- Startup --
Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  GSD Convergence - Final Integrated Edition" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green

if (-not $DryRun) {
    $preFlight = Test-PreFlight -RepoRoot $RepoRoot -GsdDir $GsdDir
    if (-not $preFlight) { exit 1 }
    New-GsdLock -GsdDir $GsdDir -Pipeline "converge"
}

# Interface detection (GAP 13)
$InterfaceContext = ""
$Interfaces = @()
if (Get-Command Initialize-ProjectInterfaces -ErrorAction SilentlyContinue) {
    Write-Host ""
    $ifaceResult = Initialize-ProjectInterfaces -RepoRoot $RepoRoot -GsdDir $GsdDir
    $InterfaceContext = $ifaceResult.Context
    $Interfaces = $ifaceResult.Interfaces
}

# Checkpoint recovery
$checkpoint = Get-Checkpoint -GsdDir $GsdDir
$Iteration = 0; $Health = Get-Health; $CurrentBatchSize = $BatchSize
if ($checkpoint -and $checkpoint.pipeline -eq "converge") {
    $Iteration = $checkpoint.iteration; $Health = $checkpoint.health
    $CurrentBatchSize = if ($checkpoint.batch_size -gt 0) { $checkpoint.batch_size } else { $BatchSize }
    Write-Host "  [SYNC] Resuming: Iter $Iteration, Health: ${Health}%" -ForegroundColor Yellow
}

Write-Host "  Health: ${Health}% -> 100% | Batch: $CurrentBatchSize | Interfaces: $($Interfaces.Count)" -ForegroundColor White
if ($ThrottleSeconds -gt 0) { Write-Host "  Throttle: ${ThrottleSeconds}s between agent calls (prevents quota exhaustion)" -ForegroundColor DarkGray }
if ($script:NTFY_TOPIC) { Write-Host "  Notify:   ntfy.sh/$($script:NTFY_TOPIC)" -ForegroundColor DarkGray }
Write-Host ""

Send-GsdNotification -Title "GSD Converge Started" `
    -Message "$repoName | Health: ${Health}% | Batch: $CurrentBatchSize | Throttle: ${ThrottleSeconds}s" `
    -Tags "rocket" -Priority "low"

# Prompt resolver with interface context
function Local-ResolvePrompt($templatePath, $iter, $health) {
    $text = Get-Content $templatePath -Raw
    $resolved = $text.Replace("{{ITERATION}}", "$iter").Replace("{{HEALTH}}", "$health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{BATCH_SIZE}}", "$CurrentBatchSize").Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext).Replace("{{FIGMA_PATH}}", "(see interface context)").Replace("{{FIGMA_VERSION}}", "(multi-interface)")
    $fileMapPath = Join-Path $GsdDir "file-map.json"
    $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
    if (Test-Path $fileTreePath) {
        $resolved += "`n`n## Repository File Map`nA live file map is maintained at:`n- JSON: $fileMapPath`n- Tree: $fileTreePath`nRead the tree file to understand the current repo structure. This map is updated after every iteration.`n"
    }
    return $resolved
}

# Spec consistency check (GAP 5) with optional auto-resolution
if (-not $SkipSpecCheck -and -not $SkipInit) {
    if (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {
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
                Write-Host "  [BLOCK] Spec conflicts detected. Use -AutoResolve to auto-fix." -ForegroundColor Red
                Remove-GsdLock -GsdDir $GsdDir; exit 1
            }
        }
    }
    Write-Host ""
}

trap { Remove-GsdLock -GsdDir $GsdDir }

try {

# Phase 0: Create phases
$matrixContent = Get-Content $MatrixFile -Raw | ConvertFrom-Json
if ($matrixContent.requirements.Count -eq 0 -and -not $SkipInit) {
    Write-Host "[CLIP] Phase 0: CREATE PHASES" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration 0 -Phase "create-phases" -Health 0 -BatchSize $CurrentBatchSize
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\create-phases.md" 0 0
    if (-not $DryRun) {
        Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "create-phases" `
            -LogFile "$GsdDir\logs\phase0.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash" | Out-Null
    }
    $Health = Get-Health
    Write-Host "  [OK] Matrix built. Health: ${Health}%" -ForegroundColor Green
    Write-Host ""
}

# Main loop
$StallCount = 0; $TargetHealth = 100

while ($Health -lt $TargetHealth -and $Iteration -lt $MaxIterations -and $StallCount -lt $StallThreshold) {
    $Iteration++; $PrevHealth = $Health
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "starting"

    # Per-iteration disk check (GAP 9)
    if (-not $DryRun) {
        if (-not (Test-DiskSpace -RepoRoot $RepoRoot -GsdDir $GsdDir)) { break }
        New-GitSnapshot -RepoRoot $RepoRoot -Iteration $Iteration -Pipeline "converge"
    }

    # 1. CODE REVIEW (Claude)
    Write-Host "  [SEARCH] CLAUDE -> code-review" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "code-review" -Health $Health -BatchSize $CurrentBatchSize
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\code-review.md" $Iteration $Health
    if (-not $DryRun) {
        Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "code-review" `
            -LogFile "$GsdDir\logs\iter${Iteration}-1.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash" | Out-Null
    }
    $Health = Get-Health
    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }

    # Throttle between phases
    if ($ThrottleSeconds -gt 0 -and -not $DryRun) {
        Write-Host "  [THROTTLE] ${ThrottleSeconds}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $ThrottleSeconds
    }

    # 2. RESEARCH (Gemini --sandbox, read-only - saves Claude/Codex quota)
    if (-not $SkipResearch) {
        Write-Host "  GEMINI -> research (sandbox)" -ForegroundColor Magenta
        if (-not (Test-Path "$GsdDir\research")) { New-Item -ItemType Directory -Path "$GsdDir\research" -Force | Out-Null }
        # Try Gemini first; fall back to Codex if gemini CLI not available
        $useGemini = $null -ne (Get-Command gemini -ErrorAction SilentlyContinue)
        if ($useGemini) {
            $prompt = Local-ResolvePrompt "$GlobalDir\prompts\gemini\research.md" $Iteration $Health
            if (-not $DryRun) {
                Invoke-WithRetry -Agent "gemini" -Prompt $prompt -Phase "research" `
                    -LogFile "$GsdDir\logs\iter${Iteration}-2.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
                    -GeminiMode "--sandbox" | Out-Null
            }
        } else {
            Write-Host "    (gemini not found, falling back to codex)" -ForegroundColor DarkYellow
            $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\research.md" $Iteration $Health
            if (-not $DryRun) {
                Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "research" `
                    -LogFile "$GsdDir\logs\iter${Iteration}-2.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
            }
        }
    }

    # Throttle between phases
    if ($ThrottleSeconds -gt 0 -and -not $DryRun) {
        Write-Host "  [THROTTLE] ${ThrottleSeconds}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $ThrottleSeconds
    }

    # 3. PLAN (Claude)
    Write-Host "  CLAUDE -> plan" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "plan" -Health $Health -BatchSize $CurrentBatchSize
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\plan.md" $Iteration $Health
    if (-not $DryRun) {
        Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "plan" `
            -LogFile "$GsdDir\logs\iter${Iteration}-3.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash" | Out-Null
    }

    # Throttle between phases
    if ($ThrottleSeconds -gt 0 -and -not $DryRun) {
        Write-Host "  [THROTTLE] ${ThrottleSeconds}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $ThrottleSeconds
    }

    # 4. EXECUTE (Codex)
    Write-Host "  [WRENCH] CODEX -> execute (batch: $CurrentBatchSize)" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "execute" -Health $Health -BatchSize $CurrentBatchSize
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health
    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "execute" `
            -LogFile "$GsdDir\logs\iter${Iteration}-4.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if ($result.Success) {
            $CurrentBatchSize = $result.FinalBatchSize
            git add -A; git commit -m "gsd: iter $Iteration (health: ${Health}%)" --no-verify 2>$null
            # Update file map after each iteration
            if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
            }
            Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix | Out-Null
        } else { $CurrentBatchSize = $result.FinalBatchSize; $StallCount++; continue }
    }

    # Regression + stall
    $NewHealth = Get-Health
    if (-not $DryRun -and $Iteration -gt 1 -and (Test-HealthRegression -PreviousHealth $PrevHealth -CurrentHealth $NewHealth -RepoRoot $RepoRoot -Iteration $Iteration)) {
        $Health = $PrevHealth; $StallCount++; continue
    }
    if ($NewHealth -le $PrevHealth -and $Iteration -gt 1) {
        $StallCount++
        $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * 0.75))
        Write-Host "  [!!]  Stall $StallCount/$StallThreshold | Batch -> $CurrentBatchSize" -ForegroundColor DarkYellow
        if ($StallCount -ge $StallThreshold -and -not $DryRun) {
            Invoke-WithRetry -Agent "claude" -Prompt "Stalled at ${NewHealth}%. Read .gsd\health\*, .gsd\logs\errors.jsonl. Diagnose. Write .gsd\health\stall-diagnosis.md." `
                -Phase "stall" -LogFile "$GsdDir\logs\stall-$Iteration.log" -CurrentBatchSize 1 -GsdDir $GsdDir | Out-Null
            break
        }
    } else { $StallCount = 0; if ($CurrentBatchSize -lt $BatchSize) { $CurrentBatchSize = [math]::Min($BatchSize, $CurrentBatchSize + 1) } }

    $Health = $NewHealth
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "done"
    Send-GsdNotification -Title "Iter $Iteration Complete" `
        -Message "$repoName | Health: ${Health}% (+$([math]::Round($Health - $PrevHealth, 1))%) | Batch: $CurrentBatchSize" `
        -Tags "chart_with_upwards_trend"
    Write-Host ""; Start-Sleep -Seconds 2
}

# Final
Write-Host ""; Write-Host "=========================================================" -ForegroundColor Green
$FinalHealth = Get-Health
if ($FinalHealth -ge $TargetHealth) {
    Write-Host "  [PARTY] CONVERGED - ${FinalHealth}% in $Iteration iterations" -ForegroundColor Green
    if (-not $DryRun) { git add -A; git commit -m "gsd: CONVERGED" --no-verify 2>$null; git tag "gsd-converged-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null }
    Send-GsdNotification -Title "CONVERGED!" -Message "$repoName | 100% in $Iteration iterations" -Tags "tada,white_check_mark" -Priority "high"
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "  [STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
    Send-GsdNotification -Title "STALLED" -Message "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations. Check stall-diagnosis.md" -Tags "warning" -Priority "high"
} else {
    Write-Host "  [!!]  MAX ITERATIONS at ${FinalHealth}%" -ForegroundColor Yellow
    Send-GsdNotification -Title "MAX ITERATIONS" -Message "$repoName | ${FinalHealth}% after $Iteration iterations" -Tags "warning" -Priority "high"
}
Write-Host "=========================================================" -ForegroundColor Green

} finally { Clear-Checkpoint -GsdDir $GsdDir; Remove-GsdLock -GsdDir $GsdDir }
'@

Set-Content -Path "$ScriptDir\convergence-loop.ps1" -Value $script -Encoding UTF8
Write-Host "   [OK] convergence-loop.ps1 (final)" -ForegroundColor DarkGreen
