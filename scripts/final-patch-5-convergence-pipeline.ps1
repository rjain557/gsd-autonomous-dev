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
if (Test-Path "$GlobalDir\lib\modules\supervisor.ps1") { . "$GlobalDir\lib\modules\supervisor.ps1" }

# Initialize push notifications
if (Get-Command Initialize-GsdNotifications -ErrorAction SilentlyContinue) {
    Initialize-GsdNotifications -GsdGlobalDir $GlobalDir -OverrideTopic $NtfyTopic
}
$repoName = Split-Path $RepoRoot -Leaf

# Ensure dirs
@($GsdDir, "$GsdDir\health", "$GsdDir\code-review", "$GsdDir\research",
  "$GsdDir\generation-queue", "$GsdDir\agent-handoff", "$GsdDir\specs", "$GsdDir\logs", "$GsdDir\supervisor", "$GsdDir\costs") | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# Initialize cost tracking
if (Get-Command Initialize-CostTracking -ErrorAction SilentlyContinue) {
    Initialize-CostTracking -GsdDir $GsdDir -Pipeline "converge"
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

# Engine status: starting
if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
    Update-EngineStatus -GsdDir $GsdDir -State "starting" -Iteration 0 -HealthScore (Get-Health) -BatchSize $BatchSize
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
    -Tags "rocket" -Priority "default"

# Start background heartbeat (sends progress every 10 min even during long agent calls)
Start-BackgroundHeartbeat -GsdDir $GsdDir -NtfyTopic $script:NTFY_TOPIC `
    -Pipeline "converge" -RepoName $repoName -IntervalMinutes 10

# Start background command listener (responds to "progress" commands via ntfy)
Start-CommandListener -GsdDir $GsdDir -NtfyTopic $script:NTFY_TOPIC `
    -Pipeline "converge" -RepoName $repoName -PollIntervalSeconds 15

# Start engine-status.json heartbeat (60s freshness signal)
if (Get-Command Start-EngineStatusHeartbeat -ErrorAction SilentlyContinue) {
    Start-EngineStatusHeartbeat -GsdDir $GsdDir
}

# Prompt resolver with interface context
function Local-ResolvePrompt($templatePath, $iter, $health) {
    $text = Get-Content $templatePath -Raw
    $resolved = $text.Replace("{{ITERATION}}", "$iter").Replace("{{HEALTH}}", "$health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{BATCH_SIZE}}", "$CurrentBatchSize").Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext).Replace("{{FIGMA_PATH}}", "(see interface context)").Replace("{{FIGMA_VERSION}}", "(multi-interface)")
    $fileMapPath = Join-Path $GsdDir "file-map.json"
    $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
    if (Test-Path $fileTreePath) {
        $resolved += "`n`n## Repository File Map`nA live file map is maintained at:`n- JSON: $fileMapPath`n- Tree: $fileTreePath`nRead the tree file to understand the current repo structure. This map is updated after every iteration.`n"
    }
    # Supervisor: inject error context and prompt hints from previous iteration
    $errorCtxPath = Join-Path $GsdDir "supervisor\error-context.md"
    $hintPath = Join-Path $GsdDir "supervisor\prompt-hints.md"
    if (Test-Path $errorCtxPath) {
        $resolved += "`n`n## Previous Iteration Errors`n" + (Get-Content $errorCtxPath -Raw)
    }
    if (Test-Path $hintPath) {
        $resolved += "`n`n## Supervisor Instructions`n" + (Get-Content $hintPath -Raw)
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
$ValidationAttempts = 0; $MaxValidationAttempts = 3; $validationResult = $null

do {

while ($Health -lt $TargetHealth -and $Iteration -lt $MaxIterations -and $StallCount -lt $StallThreshold) {
    $Iteration++; $PrevHealth = $Health
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "starting"

    # Per-iteration disk check (GAP 9)
    if (-not $DryRun) {
        if (-not (Test-DiskSpace -RepoRoot $RepoRoot -GsdDir $GsdDir)) { break }
        New-GitSnapshot -RepoRoot $RepoRoot -Iteration $Iteration -Pipeline "converge"
    }

    $errorsThisIter = 0

    # 1. CODE REVIEW (Claude)
    Send-HeartbeatIfDue -Phase "code-review" -Iteration $Iteration -Health $Health -RepoName $repoName
    Write-Host "  [SEARCH] CLAUDE -> code-review" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "code-review" -Health $Health -BatchSize $CurrentBatchSize
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "code-review" -Agent "claude" -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize -Attempt "1/$($script:RETRY_MAX)" -ErrorsThisIteration 0
    }
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
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -Phase "throttle" -SleepReason "throttle" -SleepUntil ((Get-Date).ToUniversalTime().AddSeconds($ThrottleSeconds))
        }
        Write-Host "  [THROTTLE] ${ThrottleSeconds}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $ThrottleSeconds
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "running" }
    }

    # 2. RESEARCH (Gemini plan mode, read-only - saves Claude/Codex quota)
    if (-not $SkipResearch) {
        Send-HeartbeatIfDue -Phase "research" -Iteration $Iteration -Health $Health -RepoName $repoName
        Write-Host "  GEMINI -> research (read-only)" -ForegroundColor Magenta
        if (-not (Test-Path "$GsdDir\research")) { New-Item -ItemType Directory -Path "$GsdDir\research" -Force | Out-Null }
        # Try Gemini first; fall back to Codex if gemini CLI not available
        $useGemini = $null -ne (Get-Command gemini -ErrorAction SilentlyContinue)
        if ($useGemini) {
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "research" -Agent "gemini" -Iteration $Iteration -HealthScore $Health
            }
            $prompt = Local-ResolvePrompt "$GlobalDir\prompts\gemini\research.md" $Iteration $Health
            if (-not $DryRun) {
                Invoke-WithRetry -Agent "gemini" -Prompt $prompt -Phase "research" `
                    -LogFile "$GsdDir\logs\iter${Iteration}-2.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
                    -GeminiMode "--approval-mode plan" | Out-Null
            }
        } else {
            Write-Host "    (gemini not found, falling back to codex)" -ForegroundColor DarkYellow
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "research" -Agent "codex" -Iteration $Iteration -HealthScore $Health
            }
            $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\research.md" $Iteration $Health
            if (-not $DryRun) {
                Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "research" `
                    -LogFile "$GsdDir\logs\iter${Iteration}-2.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
            }
        }
    }

    # Throttle between phases
    if ($ThrottleSeconds -gt 0 -and -not $DryRun) {
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -Phase "throttle" -SleepReason "throttle" -SleepUntil ((Get-Date).ToUniversalTime().AddSeconds($ThrottleSeconds))
        }
        Write-Host "  [THROTTLE] ${ThrottleSeconds}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $ThrottleSeconds
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "running" }
    }

    # 3. PLAN (Claude)
    Send-HeartbeatIfDue -Phase "plan" -Iteration $Iteration -Health $Health -RepoName $repoName
    Write-Host "  CLAUDE -> plan" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "plan" -Health $Health -BatchSize $CurrentBatchSize
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "plan" -Agent "claude" -Iteration $Iteration -HealthScore $Health
    }
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\plan.md" $Iteration $Health
    if (-not $DryRun) {
        Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "plan" `
            -LogFile "$GsdDir\logs\iter${Iteration}-3.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash" | Out-Null
    }

    # Throttle between phases
    if ($ThrottleSeconds -gt 0 -and -not $DryRun) {
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -Phase "throttle" -SleepReason "throttle" -SleepUntil ((Get-Date).ToUniversalTime().AddSeconds($ThrottleSeconds))
        }
        Write-Host "  [THROTTLE] ${ThrottleSeconds}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $ThrottleSeconds
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "running" }
    }

    # 4. EXECUTE (Codex, or supervisor-overridden agent)
    Send-HeartbeatIfDue -Phase "execute" -Iteration $Iteration -Health $Health -RepoName $repoName
    $executeAgent = "codex"
    $overridePath = Join-Path $GsdDir "supervisor\agent-override.json"
    if (Test-Path $overridePath) {
        try { $ov = Get-Content $overridePath -Raw | ConvertFrom-Json
              if ($ov.execute) { $executeAgent = $ov.execute; Write-Host "  [SUPERVISOR] Agent override: execute -> $executeAgent" -ForegroundColor Yellow } } catch {}
    }
    Write-Host "  [WRENCH] $($executeAgent.ToUpper()) -> execute (batch: $CurrentBatchSize)" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "execute" -Health $Health -BatchSize $CurrentBatchSize
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "execute" -Agent $executeAgent -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize
    }
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health
    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent $executeAgent -Prompt $prompt -Phase "execute" `
            -LogFile "$GsdDir\logs\iter${Iteration}-4.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if ($result.Success) {
            $CurrentBatchSize = $result.FinalBatchSize
            # Build commit message from code review findings for GitHub traceability
            $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
            $commitSubject = "gsd: iter $Iteration (health: ${Health}%)"
            if (Test-Path $reviewPath) {
                $reviewText = (Get-Content $reviewPath -Raw).Trim()
                if ($reviewText.Length -gt 4000) { $reviewText = $reviewText.Substring(0, 4000) + "`n... (truncated)" }
                $commitMsgFile = Join-Path $GsdDir ".commit-msg.tmp"
                "$commitSubject`n`n$reviewText" | Set-Content $commitMsgFile -Encoding UTF8
                git add -A; git commit -F $commitMsgFile --no-verify 2>$null
                Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
            } else {
                git add -A; git commit -m $commitSubject --no-verify 2>$null
            }
            git push 2>$null
            # Update file map after each iteration
            if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
            }
            Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix | Out-Null
        } else {
            $CurrentBatchSize = $result.FinalBatchSize; $StallCount++; $errorsThisIter++
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -ErrorsThisIteration $errorsThisIter -LastError "Execute failed: $($result.Error)"
            }
            Send-GsdNotification -Title "Iter ${Iteration}: Execute Failed" `
                -Message "$repoName | Health: ${Health}% | Batch reduced -> $CurrentBatchSize | Stall $StallCount/$StallThreshold" `
                -Tags "warning" -Priority "default"
            $script:LAST_NOTIFY_TIME = Get-Date
            continue
        }
    }

    # Regression + stall
    $NewHealth = Get-Health
    if (-not $DryRun -and $Iteration -gt 1 -and (Test-HealthRegression -PreviousHealth $PrevHealth -CurrentHealth $NewHealth -RepoRoot $RepoRoot -Iteration $Iteration)) {
        $errorsThisIter++
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -ErrorsThisIteration $errorsThisIter -LastError "Regression: ${NewHealth}% from ${PrevHealth}%"
        }
        Send-GsdNotification -Title "Iter ${Iteration}: Regression Reverted" `
            -Message "$repoName | ${NewHealth}% dropped from ${PrevHealth}% - reverted | Stall $($StallCount+1)/$StallThreshold" `
            -Tags "warning" -Priority "high"
        $script:LAST_NOTIFY_TIME = Get-Date
        $Health = $PrevHealth; $StallCount++; continue
    }
    if ($NewHealth -le $PrevHealth -and $Iteration -gt 1) {
        $StallCount++
        $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * 0.75))
        Write-Host "  [!!]  Stall $StallCount/$StallThreshold | Batch -> $CurrentBatchSize" -ForegroundColor DarkYellow
        Send-GsdNotification -Title "Iter ${Iteration}: No Progress" `
            -Message "$repoName | Health: ${NewHealth}% (unchanged) | Batch -> $CurrentBatchSize | Stall $StallCount/$StallThreshold" `
            -Tags "hourglass" -Priority "default"
        $script:LAST_NOTIFY_TIME = Get-Date
        if ($StallCount -ge $StallThreshold -and -not $DryRun) {
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "stalled" -HealthScore $NewHealth -LastError "Stalled: $StallCount consecutive iterations with no progress"
            }
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
    $script:LAST_NOTIFY_TIME = Get-Date
    Write-Host ""; Start-Sleep -Seconds 2
}

    # Final validation gate - runs when health reaches 100%
    $FinalHealth = Get-Health
    $validationFailed = $false
    if ($FinalHealth -ge $TargetHealth -and -not $DryRun -and $ValidationAttempts -lt $MaxValidationAttempts) {
        if (Get-Command Invoke-FinalValidation -ErrorAction SilentlyContinue) {
            $ValidationAttempts++
            Write-Host ""
            Write-Host "  [SHIELD] Final validation (attempt $ValidationAttempts/$MaxValidationAttempts)..." -ForegroundColor Cyan
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "final-validation" -Agent "local" -Iteration $Iteration -HealthScore $FinalHealth
            }
            $validationResult = Invoke-FinalValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration
            if (-not $validationResult.Passed) {
                $validationFailed = $true
                foreach ($f in $validationResult.HardFailures) { Write-Host "    FAIL: $f" -ForegroundColor Red }
                foreach ($w in $validationResult.Warnings) { Write-Host "    WARN: $w" -ForegroundColor DarkYellow }
                # Write failures to error-context so code-review picks them up next iteration
                $failText = ($validationResult.HardFailures | ForEach-Object { "- $_" }) -join "`n"
                "## Final Validation Failures`n$failText" | Set-Content (Join-Path $GsdDir "supervisor\error-context.md") -Encoding UTF8
                # Reset health to 99 so while loop re-enters
                $healthObj = Get-Content $HealthFile -Raw | ConvertFrom-Json
                $healthObj.health_score = 99
                $healthObj | ConvertTo-Json | Set-Content $HealthFile -Encoding UTF8
                $Health = 99; $FinalHealth = 99
                Send-GsdNotification -Title "Validation Failed ($ValidationAttempts/$MaxValidationAttempts)" `
                    -Message "$repoName | $($validationResult.HardFailures.Count) issues - loop continues" `
                    -Tags "warning" -Priority "high"
                $script:LAST_NOTIFY_TIME = Get-Date
            } else {
                if ($validationResult.Warnings.Count -gt 0) {
                    Write-Host "  [OK] Validation passed with $($validationResult.Warnings.Count) warning(s)" -ForegroundColor Yellow
                    foreach ($w in $validationResult.Warnings) { Write-Host "    WARN: $w" -ForegroundColor DarkYellow }
                } else {
                    Write-Host "  [OK] All validation checks passed" -ForegroundColor Green
                }
            }
        }
    }

} while ($validationFailed -and $ValidationAttempts -lt $MaxValidationAttempts)

# Final
Write-Host ""; Write-Host "=========================================================" -ForegroundColor Green
$FinalHealth = Get-Health
if ($FinalHealth -ge $TargetHealth) {
    Write-Host "  [PARTY] CONVERGED - ${FinalHealth}% in $Iteration iterations" -ForegroundColor Green
    if (-not $DryRun) {
        $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
        $commitSubject = "gsd: CONVERGED at ${FinalHealth}% in $Iteration iterations"
        if (Test-Path $reviewPath) {
            $reviewText = (Get-Content $reviewPath -Raw).Trim()
            if ($reviewText.Length -gt 4000) { $reviewText = $reviewText.Substring(0, 4000) + "`n... (truncated)" }
            $commitMsgFile = Join-Path $GsdDir ".commit-msg.tmp"
            "$commitSubject`n`n$reviewText" | Set-Content $commitMsgFile -Encoding UTF8
            git add -A; git commit -F $commitMsgFile --no-verify 2>$null
            Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
        } else {
            git add -A; git commit -m $commitSubject --no-verify 2>$null
        }
        git tag "gsd-converged-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null
        git push --tags 2>$null
    }
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "converged" -HealthScore $FinalHealth -Iteration $Iteration }
    Send-GsdNotification -Title "CONVERGED!" -Message "$repoName | 100% in $Iteration iterations" -Tags "tada,white_check_mark" -Priority "high"
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "  [STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "stalled" -HealthScore $FinalHealth -Iteration $Iteration }
    Send-GsdNotification -Title "STALLED" -Message "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations. Check stall-diagnosis.md" -Tags "warning" -Priority "high"
} else {
    Write-Host "  [!!]  MAX ITERATIONS at ${FinalHealth}%" -ForegroundColor Yellow
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "completed" -HealthScore $FinalHealth -Iteration $Iteration }
    Send-GsdNotification -Title "MAX ITERATIONS" -Message "$repoName | ${FinalHealth}% after $Iteration iterations" -Tags "warning" -Priority "high"
}
Write-Host "=========================================================" -ForegroundColor Green

} finally {
    # Stop background heartbeat, command listener, and engine status heartbeat
    Stop-BackgroundHeartbeat
    Stop-CommandListener
    if (Get-Command Stop-EngineStatusHeartbeat -ErrorAction SilentlyContinue) { Stop-EngineStatusHeartbeat }
    if (Get-Command Complete-CostTrackingRun -ErrorAction SilentlyContinue) { Complete-CostTrackingRun -GsdDir $GsdDir }

    # Supervisor: save terminal summary so supervisor can read exit state
    $FinalHealth = Get-Health
    if (Get-Command Save-TerminalSummary -ErrorAction SilentlyContinue) {
        $exitReason = if ($FinalHealth -ge $TargetHealth) { "converged" }
                      elseif ($StallCount -ge $StallThreshold) { "stalled" }
                      else { "max_iterations" }
        Save-TerminalSummary -GsdDir $GsdDir -Pipeline "converge" -ExitReason $exitReason `
            -Health $FinalHealth -Iteration $Iteration -StallCount $StallCount -BatchSize $CurrentBatchSize
    }

    # Generate developer handoff report (always, regardless of exit reason)
    if (Get-Command New-DeveloperHandoff -ErrorAction SilentlyContinue) {
        Write-Host "  [DOC] Generating developer handoff..." -ForegroundColor Cyan
        $handoffPath = New-DeveloperHandoff -RepoRoot $RepoRoot -GsdDir $GsdDir `
            -Pipeline "converge" -ExitReason $exitReason `
            -FinalHealth $FinalHealth -Iteration $Iteration -ValidationResult $validationResult
        if ($handoffPath -and (Test-Path $handoffPath)) {
            git add $handoffPath; git commit -m "gsd: developer handoff report" --no-verify 2>$null
            git push 2>$null
        }
    }

    Clear-Checkpoint -GsdDir $GsdDir; Remove-GsdLock -GsdDir $GsdDir
}
'@

Set-Content -Path "$ScriptDir\convergence-loop.ps1" -Value $script -Encoding UTF8
Write-Host "   [OK] convergence-loop.ps1 (final)" -ForegroundColor DarkGreen
