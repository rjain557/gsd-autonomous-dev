<#
.SYNOPSIS
    GSD Convergence Loop - Final Integrated Edition
    Multi-interface, Figma Make aware, spec check, all gaps closed
#>
param(
    [int]$MaxIterations = 20, [int]$StallThreshold = 3, [int]$BatchSize = 8,
    [int]$ThrottleSeconds = 30,
    [int]$ResearchInterval = 3,       # Run research every N iterations (0 = every iteration, old behavior)
    [int]$PushInterval = 3,           # Push to remote every N iterations (0 = every iteration)
    [string]$NtfyTopic = "",
    [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch, [switch]$SkipSpecCheck,
    [switch]$AutoResolve, [switch]$ForceCodeReview
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

# ── Adaptive Throttle (#5) ──
# Start at configured value, reduce to 10s if no quota errors in last 3 iterations, increase on quota errors
$script:AdaptiveThrottle = $ThrottleSeconds
$script:QuotaErrorHistory = @()  # Track last N iterations' quota error status

function Get-AdaptiveThrottle {
    param([string]$BetweenPhases = "")
    # No throttle between plan→execute (plan is lightweight)
    if ($BetweenPhases -eq "plan-to-execute") { return 0 }
    return $script:AdaptiveThrottle
}

function Update-AdaptiveThrottle {
    param([bool]$HadQuotaError = $false)
    $script:QuotaErrorHistory += $HadQuotaError
    # Keep only last 5 entries
    if ($script:QuotaErrorHistory.Count -gt 5) {
        $script:QuotaErrorHistory = $script:QuotaErrorHistory[-5..-1]
    }
    $recentErrors = ($script:QuotaErrorHistory | Where-Object { $_ -eq $true }).Count
    if ($recentErrors -gt 0) {
        # Had quota errors recently — increase throttle
        $script:AdaptiveThrottle = [math]::Min(60, $ThrottleSeconds + 10)
    } elseif ($script:QuotaErrorHistory.Count -ge 3) {
        # 3+ iterations without quota errors — reduce throttle
        $script:AdaptiveThrottle = [math]::Max(10, [math]::Floor($script:AdaptiveThrottle * 0.7))
    }
}

# ── Stall Detection Helpers (#9) ──
$script:HealthWindow = @()  # Track last N health values for oscillation detection

function Test-HealthOscillation {
    # Returns $true if health is oscillating (range < 3% over 4+ readings)
    if ($script:HealthWindow.Count -lt 4) { return $false }
    $recent = $script:HealthWindow[-4..-1]
    $range = ($recent | Measure-Object -Maximum -Minimum)
    return (($range.Maximum - $range.Minimum) -lt 3)
}

function Test-NearCeilingStall {
    param([double]$Health)
    # Returns $true if health > 90% and hasn't changed by > 1% in last 2 readings
    if ($Health -le 90 -or $script:HealthWindow.Count -lt 2) { return $false }
    $recent = $script:HealthWindow[-2..-1]
    $maxDelta = ($recent | ForEach-Object { [math]::Abs($_ - $Health) } | Measure-Object -Maximum).Maximum
    return ($maxDelta -le 1)
}

# ── Research Scheduling (#4) ──
function Test-ShouldRunResearch {
    param([int]$Iter, [int]$StallCnt, [double]$Health, [double]$PrevHealth)
    # Always run on iterations 1-2 (establishing patterns)
    if ($Iter -le 2) { return $true }
    # Always run if stalled
    if ($StallCnt -gt 0) { return $true }
    # Always run if regression detected
    if ($Health -lt $PrevHealth) { return $true }
    # Run at configured interval
    if ($ResearchInterval -gt 0 -and ($Iter % $ResearchInterval) -eq 0) { return $true }
    # Skip otherwise
    return $false
}

# ── Council Scheduling (#6) ──
function Test-ShouldRunNonBlockingCouncil {
    param([string]$CouncilType, [int]$StallCnt, [double]$Health, [double]$PrevHealth)
    # Always run if stalled
    if ($StallCnt -gt 0) { return $true }
    # Always run if regression
    if ($Health -lt $PrevHealth) { return $true }
    # Always run near convergence (quality matters most)
    if ($Health -ge 80) { return $true }
    # Skip non-blocking councils otherwise to save time
    return $false
}

# ── Conflict Detection for Parallel Execute (#10) ──
function Find-FileConflicts {
    param([array]$BatchItems)
    # Detect file overlaps between batch items targeting the same files
    $fileMap = @{}
    $conflicts = @()
    foreach ($item in $BatchItems) {
        $files = @()
        if ($item.target_files) { $files = $item.target_files }
        foreach ($f in $files) {
            $normFile = $f.Replace("/", "\").ToLower()
            if ($fileMap.ContainsKey($normFile)) {
                $conflicts += @{ File = $f; Req1 = $fileMap[$normFile]; Req2 = $item.req_id }
            } else {
                $fileMap[$normFile] = $item.req_id
            }
        }
    }
    return $conflicts
}

# ── Git Push Scheduling (#7) ──
$script:LastPushIteration = 0
$script:PendingPush = $false

function Test-ShouldPush {
    param([int]$Iter, [double]$Health, [double]$PrevHealth)
    # Always push if health improved by > 5%
    if (($Health - $PrevHealth) -gt 5) { return $true }
    # Push at configured interval
    if ($PushInterval -le 0) { return $true }  # 0 = every iteration (old behavior)
    if (($Iter - $script:LastPushIteration) -ge $PushInterval) { return $true }
    $script:PendingPush = $true
    return $false
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
if ($ThrottleSeconds -gt 0) { Write-Host "  Throttle: ${ThrottleSeconds}s initial (adaptive — will auto-tune)" -ForegroundColor DarkGray }
if ($ResearchInterval -gt 0) { Write-Host "  Research: every $ResearchInterval iterations (+ on stall/regression)" -ForegroundColor DarkGray }
if ($PushInterval -gt 0) { Write-Host "  Push:     every $PushInterval iterations (+ on convergence/significant progress)" -ForegroundColor DarkGray }
if ($ForceCodeReview) { Write-Host "  Force:    code-review will run even at 100% health" -ForegroundColor Yellow }
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
    # CAP injected context (#11) — limit each context source to prevent unbounded growth
    $errorCtxPath = Join-Path $GsdDir "supervisor\error-context.md"
    $hintPath = Join-Path $GsdDir "supervisor\prompt-hints.md"
    if (Test-Path $errorCtxPath) {
        $errorCtx = (Get-Content $errorCtxPath -Raw)
        # Cap error context to 2000 chars (keep most recent content)
        if ($errorCtx.Length -gt 2000) {
            $errorCtx = "... (truncated — showing last 2000 chars)`n" + $errorCtx.Substring($errorCtx.Length - 2000)
        }
        $resolved += "`n`n## Previous Iteration Errors`n" + $errorCtx
    }
    if (Test-Path $hintPath) {
        $hintCtx = (Get-Content $hintPath -Raw)
        # Cap hints to 1000 chars
        if ($hintCtx.Length -gt 1000) {
            $hintCtx = $hintCtx.Substring($hintCtx.Length - 1000)
        }
        $resolved += "`n`n## Supervisor Instructions`n" + $hintCtx
    }
    # Council: inject ONLY the most recent council feedback, capped
    $councilFeedbackPath = Join-Path $GsdDir "supervisor\council-feedback.md"
    if (Test-Path $councilFeedbackPath) {
        $councilCtx = (Get-Content $councilFeedbackPath -Raw)
        # Cap council feedback to 1500 chars
        if ($councilCtx.Length -gt 1500) {
            $councilCtx = $councilCtx.Substring($councilCtx.Length - 1500)
        }
        $resolved += "`n`n" + $councilCtx
    }
    return $resolved
}

# Spec consistency check (GAP 5) with optional auto-resolution
if (-not $SkipSpecCheck -and -not $SkipInit) {
    if (Get-Command Invoke-SpecQualityGate -ErrorAction SilentlyContinue) {
        Write-Host "  [SEARCH] Spec quality gate (consistency + clarity + cross-artifact)..." -ForegroundColor Cyan
        $specResult = Invoke-SpecQualityGate -RepoRoot $RepoRoot -GsdDir $GsdDir -Interfaces $Interfaces -DryRun:$DryRun
        if (-not $specResult.Passed -and $specResult.Verdict -eq "BLOCK") {
            Write-Host "  [BLOCK] Spec quality gate BLOCKED. See .gsd\assessment\spec-quality-gate.json" -ForegroundColor Red
            Remove-GsdLock -GsdDir $GsdDir; exit 1
        } elseif (-not $specResult.Passed) {
            Write-Host "  [!!]  Spec quality gate WARN: $($specResult.Issues -join '; ')" -ForegroundColor DarkYellow
        }
    } elseif (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {
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

$StallCount = 0; $TargetHealth = 100

# Initialize BEFORE try so finally block always has valid values
$StallCount = 0; $TargetHealth = 100; $Iteration = 0

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
$ValidationAttempts = 0; $MaxValidationAttempts = 3; $validationResult = $null
$CouncilAttempts = 0; $MaxCouncilAttempts = 2; $councilResult = $null

do {

# -ForceCodeReview: temporarily drop health so code-review runs once
if ($ForceCodeReview -and $Health -ge $TargetHealth) {
    Write-Host "  [FORCE] ForceCodeReview: dropping health to 99% for one review iteration" -ForegroundColor Yellow
    $healthObj = Get-Content $HealthFile -Raw | ConvertFrom-Json
    $healthObj.health_score = 99
    $healthObj | ConvertTo-Json | Set-Content $HealthFile -Encoding UTF8
    $Health = 99
    $ForceCodeReview = $false  # Only force once
}

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

    # Adaptive throttle between phases (#5)
    $currentThrottle = Get-AdaptiveThrottle -BetweenPhases "review-to-research"
    if ($currentThrottle -gt 0 -and -not $DryRun) {
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -Phase "throttle" -SleepReason "throttle" -SleepUntil ((Get-Date).ToUniversalTime().AddSeconds($currentThrottle))
        }
        Write-Host "  [THROTTLE] ${currentThrottle}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $currentThrottle
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "running" }
    }

    # 2. RESEARCH (Gemini plan mode, read-only - saves Claude/Codex quota)
    # Conditional research (#4): skip when patterns are established and no issues
    $runResearch = Test-ShouldRunResearch -Iter $Iteration -StallCnt $StallCount -Health $Health -PrevHealth $PrevHealth
    if (-not $SkipResearch -and $runResearch) {
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
    } elseif (-not $SkipResearch -and -not $runResearch) {
        Write-Host "  [SKIP] Research skipped (interval: every $ResearchInterval iters, no stall/regression)" -ForegroundColor DarkGray
    }

    # ── POST-RESEARCH COUNCIL (validate research before planning) ──
    # Conditional non-blocking council (#6): only run when stalled, regression, or near convergence
    $runPostResearchCouncil = Test-ShouldRunNonBlockingCouncil -CouncilType "post-research" -StallCnt $StallCount -Health $Health -PrevHealth $PrevHealth
    if (-not $DryRun -and $runPostResearchCouncil -and (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue)) {
        Write-Host "  [SCALES] Post-research council..." -ForegroundColor DarkCyan
        $prResult = Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -Health $Health -Pipeline $Pipeline -CouncilType "post-research"
        if (-not $prResult.Approved) {
            Write-Host "  [SCALES] Research concerns noted -- plan phase will address them" -ForegroundColor DarkYellow
        }
    } elseif (-not $runPostResearchCouncil) {
        Write-Host "  [SKIP] Post-research council skipped (no stall/regression, health < 80%)" -ForegroundColor DarkGray
    }

    # Adaptive throttle between phases (#5)
    $currentThrottle = Get-AdaptiveThrottle -BetweenPhases "research-to-plan"
    if ($currentThrottle -gt 0 -and -not $DryRun) {
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -Phase "throttle" -SleepReason "throttle" -SleepUntil ((Get-Date).ToUniversalTime().AddSeconds($currentThrottle))
        }
        Write-Host "  [THROTTLE] ${currentThrottle}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $currentThrottle
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

    # No throttle between plan→execute (#5) — plan is lightweight, skip the wait
    # Adaptive throttle returns 0 for plan-to-execute
    $currentThrottle = Get-AdaptiveThrottle -BetweenPhases "plan-to-execute"
    if ($currentThrottle -gt 0 -and -not $DryRun) {
        Write-Host "  [THROTTLE] ${currentThrottle}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $currentThrottle
    }

    # ── PRE-EXECUTE COUNCIL (validate plan before code generation) ──
    # Conditional non-blocking council (#6): only run when stalled, regression, or near convergence
    $runPreExecuteCouncil = Test-ShouldRunNonBlockingCouncil -CouncilType "pre-execute" -StallCnt $StallCount -Health $Health -PrevHealth $PrevHealth
    if (-not $DryRun -and $runPreExecuteCouncil -and (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue)) {
        Write-Host "  [SCALES] Pre-execute council..." -ForegroundColor DarkCyan
        $peResult = Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -Health $Health -Pipeline $Pipeline -CouncilType "pre-execute"
        if (-not $peResult.Approved) {
            Write-Host "  [SCALES] Plan concerns noted -- executing with caution" -ForegroundColor DarkYellow
        }
    } elseif (-not $runPreExecuteCouncil) {
        Write-Host "  [SKIP] Pre-execute council skipped (no stall/regression, health < 80%)" -ForegroundColor DarkGray
    }

    # 4. EXECUTE -- Parallel sub-task or monolithic fallback
    Send-HeartbeatIfDue -Phase "execute" -Iteration $Iteration -Health $Health -RepoName $repoName
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "execute" -Health $Health -BatchSize $CurrentBatchSize

    # Check if parallel execution is enabled
    $useParallel = $false
    $fallback = $false
    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    if (Test-Path $agentMapPath) {
        try {
            $agentMapCfg = Get-Content $agentMapPath -Raw | ConvertFrom-Json
            if ($agentMapCfg.execute_parallel -and $agentMapCfg.execute_parallel.enabled) {
                $useParallel = $true
            }
        } catch {}
    }

    if ($useParallel -and (Get-Command Invoke-ParallelExecute -ErrorAction SilentlyContinue)) {
        # ── PARALLEL PATH ──
        $subtaskTemplate = Join-Path $GlobalDir "prompts\codex\execute-subtask.md"
        if (-not (Test-Path $subtaskTemplate)) {
            Write-Host "  [WARN] execute-subtask.md not found, falling back to monolithic" -ForegroundColor Yellow
            $useParallel = $false
        }
    }

    if ($useParallel -and -not $DryRun) {
        # Conflict detection for parallel execute (#10)
        $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
        if (Test-Path $queuePath) {
            try {
                $queueData = Get-Content $queuePath -Raw | ConvertFrom-Json
                if ($queueData.batch) {
                    $fileConflicts = Find-FileConflicts -BatchItems $queueData.batch
                    if ($fileConflicts.Count -gt 0) {
                        Write-Host "  [WARN] File conflicts detected in parallel batch — $($fileConflicts.Count) overlap(s):" -ForegroundColor Yellow
                        foreach ($c in $fileConflicts) {
                            Write-Host "    $($c.File): $($c.Req1) vs $($c.Req2)" -ForegroundColor DarkYellow
                        }
                        # Group conflicting requirements into the same sub-task by writing a conflict map
                        $conflictMapPath = Join-Path $GsdDir "generation-queue\conflict-map.json"
                        $fileConflicts | ConvertTo-Json -Depth 3 | Set-Content $conflictMapPath -Encoding UTF8
                        Write-Host "  [INFO] Conflict map written — parallel executor should group conflicting reqs" -ForegroundColor DarkGray
                    }
                }
            } catch {
                Write-Host "  [WARN] Could not check for file conflicts: $_" -ForegroundColor DarkYellow
            }
        }
        Write-Host "  [WRENCH] PARALLEL EXECUTE (batch: $CurrentBatchSize)" -ForegroundColor Magenta
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "execute" -Agent "parallel" -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize
        }

        $result = Invoke-ParallelExecute -GsdDir $GsdDir -GlobalDir $GlobalDir `
            -Iteration $Iteration -Health $Health `
            -PromptTemplatePath $subtaskTemplate `
            -CurrentBatchSize $CurrentBatchSize `
            -LogFilePrefix "$GsdDir\logs\iter${Iteration}-4" `
            -InterfaceContext $InterfaceContext

        if ($result.Success -or $result.PartialSuccess) {
            $CurrentBatchSize = $result.FinalBatchSize

            # Commit completed work
            $commitSubject = "gsd: iter $Iteration (health: ${Health}%)"
            if ($result.PartialSuccess) {
                $commitSubject += " [partial: $($result.Completed.Count)/$($result.Completed.Count + $result.Failed.Count)]"
            }
            $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
            if (Test-Path $reviewPath) {
                $reviewText = (Get-Content $reviewPath -Raw).Trim()
                if ($reviewText.Length -gt 4000) { $reviewText = $reviewText.Substring(0, 4000) + "`n... (truncated)" }
                $commitMsgFile = Join-Path $GsdDir ".commit-msg.tmp"
                "$commitSubject`n`nCompleted: $($result.Completed -join ', ')`nFailed: $($result.Failed -join ', ')`n`n$reviewText" | Set-Content $commitMsgFile -Encoding UTF8
                # Stage source code + .gsd tracked files, exclude temp artifacts (#7)
                git add src/ docs/ *.sln *.csproj *.json *.sql *.tsx *.ts *.cs 2>$null
                git add .gsd/health/ .gsd/agent-handoff/ .gsd/code-review/ .gsd/specs/ 2>$null
                git diff --cached --quiet 2>$null; if ($LASTEXITCODE -ne 0) { git commit -F $commitMsgFile --no-verify 2>$null }
                Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
            } else {
                git add src/ docs/ *.sln *.csproj *.json *.sql *.tsx *.ts *.cs 2>$null
                git add .gsd/health/ .gsd/agent-handoff/ .gsd/code-review/ .gsd/specs/ 2>$null
                git diff --cached --quiet 2>$null; if ($LASTEXITCODE -ne 0) { git commit -m $commitSubject --no-verify 2>$null }
            }
            # Batch push: only push at intervals or on significant progress (#7)
            if (Test-ShouldPush -Iter $Iteration -Health $Health -PrevHealth $PrevHealth) {
                git push 2>$null; $script:LastPushIteration = $Iteration; $script:PendingPush = $false
            }

            if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
            }
            Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix | Out-Null

            # If partial success, log failed sub-tasks for next iteration
            if ($result.PartialSuccess) {
                Write-Host "  [PARTIAL] $($result.Failed.Count) sub-tasks need retry next iteration" -ForegroundColor Yellow
                Send-GsdNotification -Title "Iter ${Iteration}: Partial Execute" `
                    -Message "$repoName | OK: $($result.Completed -join ',') | FAIL: $($result.Failed -join ',')" `
                    -Tags "warning" -Priority "default"
                $script:LAST_NOTIFY_TIME = Get-Date
            }
        } else {
            # All sub-tasks failed -- try monolithic fallback if configured
            if ($agentMapCfg.execute_parallel.fallback_to_sequential) {
                Write-Host "  [FALLBACK] All parallel sub-tasks failed. Trying monolithic execute..." -ForegroundColor Yellow
                $fallback = $true
            }

            if (-not $fallback) {
                $CurrentBatchSize = $result.FinalBatchSize; $StallCount++; $errorsThisIter++
                if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                    Update-EngineStatus -GsdDir $GsdDir -State "running" -ErrorsThisIteration $errorsThisIter -LastError "Parallel execute failed: $($result.Error)"
                }
                Send-GsdNotification -Title "Iter ${Iteration}: Execute Failed" `
                    -Message "$repoName | Health: ${Health}% | All sub-tasks failed" `
                    -Tags "warning" -Priority "default"
                $script:LAST_NOTIFY_TIME = Get-Date
                continue
            }
            # $fallback = $true falls through to monolithic path below
        }
    }

    # ── MONOLITHIC PATH (original behavior, also used as fallback) ──
    if ((-not $useParallel -or $fallback) -and -not $DryRun) {
        $executeAgent = "codex"
        $overridePath = Join-Path $GsdDir "supervisor\agent-override.json"
        if (Test-Path $overridePath) {
            try { $ov = Get-Content $overridePath -Raw | ConvertFrom-Json
                  if ($ov.execute) { $executeAgent = $ov.execute; Write-Host "  [SUPERVISOR] Agent override: execute -> $executeAgent" -ForegroundColor Yellow } } catch {}
        }
        Write-Host "  [WRENCH] $($executeAgent.ToUpper()) -> execute (batch: $CurrentBatchSize)" -ForegroundColor Magenta
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "execute" -Agent $executeAgent -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize
        }
        $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health
        $result = Invoke-WithRetry -Agent $executeAgent -Prompt $prompt -Phase "execute" `
            -LogFile "$GsdDir\logs\iter${Iteration}-4.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if ($result.Success) {
            $CurrentBatchSize = $result.FinalBatchSize
            $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
            $commitSubject = "gsd: iter $Iteration (health: ${Health}%)"
            if (Test-Path $reviewPath) {
                $reviewText = (Get-Content $reviewPath -Raw).Trim()
                if ($reviewText.Length -gt 4000) { $reviewText = $reviewText.Substring(0, 4000) + "`n... (truncated)" }
                $commitMsgFile = Join-Path $GsdDir ".commit-msg.tmp"
                "$commitSubject`n`n$reviewText" | Set-Content $commitMsgFile -Encoding UTF8
                # Stage source code + .gsd tracked files, exclude temp artifacts (#7)
                git add src/ docs/ *.sln *.csproj *.json *.sql *.tsx *.ts *.cs 2>$null
                git add .gsd/health/ .gsd/agent-handoff/ .gsd/code-review/ .gsd/specs/ 2>$null
                git diff --cached --quiet 2>$null; if ($LASTEXITCODE -ne 0) { git commit -F $commitMsgFile --no-verify 2>$null }
                Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
            } else {
                git add src/ docs/ *.sln *.csproj *.json *.sql *.tsx *.ts *.cs 2>$null
                git add .gsd/health/ .gsd/agent-handoff/ .gsd/code-review/ .gsd/specs/ 2>$null
                git diff --cached --quiet 2>$null; if ($LASTEXITCODE -ne 0) { git commit -m $commitSubject --no-verify 2>$null }
            }
            # Batch push: only push at intervals or on significant progress (#7)
            if (Test-ShouldPush -Iter $Iteration -Health $Health -PrevHealth $PrevHealth) {
                git push 2>$null; $script:LastPushIteration = $Iteration; $script:PendingPush = $false
            }
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

    # Regression + stall detection (#9: smarter stall detection with oscillation and near-ceiling)
    $NewHealth = Get-Health
    $script:HealthWindow += $NewHealth  # Track for oscillation detection
    if ($script:HealthWindow.Count -gt 10) { $script:HealthWindow = $script:HealthWindow[-10..-1] }

    # Update adaptive throttle based on whether this iteration had quota errors
    $hadQuotaErr = ($errorsThisIter -gt 0)  # Rough proxy — could be refined
    Update-AdaptiveThrottle -HadQuotaError $hadQuotaErr

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

    # Smart stall detection (#9): oscillation, near-ceiling, and standard stall
    $isOscillating = Test-HealthOscillation
    $isNearCeilingStall = Test-NearCeilingStall -Health $NewHealth
    $isStandardStall = ($NewHealth -le $PrevHealth -and $Iteration -gt 1)

    if ($isOscillating) {
        $StallCount += 2  # Oscillation is worse than a single stall — accelerate diagnosis
        Write-Host "  [!!]  OSCILLATION detected (health bouncing within 3% range) | Stall -> $StallCount/$StallThreshold" -ForegroundColor Red
        Send-GsdNotification -Title "Iter ${Iteration}: Oscillation" `
            -Message "$repoName | Health oscillating near ${NewHealth}% | Stall $StallCount/$StallThreshold" `
            -Tags "warning" -Priority "high"
        $script:LAST_NOTIFY_TIME = Get-Date
    } elseif ($isNearCeilingStall) {
        $StallCount++
        Write-Host "  [!!]  Near-ceiling stall (${NewHealth}% > 90%, delta < 1%) | Stall $StallCount/$StallThreshold" -ForegroundColor DarkYellow
        # For near-ceiling stalls, don't reduce batch — instead, the plan prompt's precision mode will handle it
        Send-GsdNotification -Title "Iter ${Iteration}: Near-Ceiling Stall" `
            -Message "$repoName | Health: ${NewHealth}% — stuck near convergence | Stall $StallCount/$StallThreshold" `
            -Tags "hourglass" -Priority "default"
        $script:LAST_NOTIFY_TIME = Get-Date
    } elseif ($isStandardStall) {
        $StallCount++
        $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * 0.75))
        Write-Host "  [!!]  Stall $StallCount/$StallThreshold | Batch -> $CurrentBatchSize" -ForegroundColor DarkYellow
        Send-GsdNotification -Title "Iter ${Iteration}: No Progress" `
            -Message "$repoName | Health: ${NewHealth}% (unchanged) | Batch -> $CurrentBatchSize | Stall $StallCount/$StallThreshold" `
            -Tags "hourglass" -Priority "default"
        $script:LAST_NOTIFY_TIME = Get-Date
    }

    if (($isOscillating -or $isNearCeilingStall -or $isStandardStall) -and $StallCount -ge $StallThreshold -and -not $DryRun) {
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            $stallReason = if ($isOscillating) { "Oscillation" } elseif ($isNearCeilingStall) { "Near-ceiling stall at ${NewHealth}%" } else { "No progress for $StallCount iterations" }
            Update-EngineStatus -GsdDir $GsdDir -State "stalled" -HealthScore $NewHealth -LastError "Stalled: $stallReason"
        }
        # Multi-agent stall diagnosis via council
        if (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue) {
            Write-Host "  [SCALES] Multi-agent stall diagnosis..." -ForegroundColor DarkCyan
            Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -Health $NewHealth -Pipeline $Pipeline -CouncilType "stall-diagnosis" | Out-Null
        } else {
            $stallDiagPrompt = "Stalled at ${NewHealth}%. Stall type: $stallReason. Read .gsd\health\*, .gsd\logs\errors.jsonl, .gsd\agent-handoff\handoff-log.jsonl. Diagnose root cause. If near-ceiling, identify the specific remaining requirements. Write .gsd\health\stall-diagnosis.md."
            Invoke-WithRetry -Agent "claude" -Prompt $stallDiagPrompt `
                -Phase "stall" -LogFile "$GsdDir\logs\stall-$Iteration.log" -CurrentBatchSize 1 -GsdDir $GsdDir | Out-Null
        }
        break
    } elseif (-not $isOscillating -and -not $isNearCeilingStall -and -not $isStandardStall) {
        # Health improved — reset stall count and potentially grow batch
        $StallCount = 0
        if ($CurrentBatchSize -lt $BatchSize) { $CurrentBatchSize = [math]::Min($BatchSize, $CurrentBatchSize + 1) }
        # Clear stale error context after successful iteration (#11)
        $errorCtxPath = Join-Path $GsdDir "supervisor\error-context.md"
        if (Test-Path $errorCtxPath) { Remove-Item $errorCtxPath -ErrorAction SilentlyContinue }
    }

    $Health = $NewHealth
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "done"
    $iterCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir } else { "" }
    $iterDiffLine = if (Get-Command Get-GitDiffStats -ErrorAction SilentlyContinue) { Get-GitDiffStats -RepoRoot $RepoRoot } else { "" }
    $iterMsg = "$repoName | Health: ${Health}% (+$([math]::Round($Health - $PrevHealth, 1))%) | Batch: $CurrentBatchSize"
    if ($iterDiffLine) { $iterMsg += "`n$iterDiffLine" }
    if ($iterCostLine) { $iterMsg += "`n$iterCostLine" }
    Send-GsdNotification -Title "Iter $Iteration Complete" -Message $iterMsg -Tags "chart_with_upwards_trend"
    $script:LAST_NOTIFY_TIME = Get-Date
    Write-Host ""; Start-Sleep -Seconds 2
}

    # ── LLM COUNCIL GATE -- runs when health reaches 100%, before validation ──
    $FinalHealth = Get-Health
    $validationFailed = $false
    if ($FinalHealth -ge $TargetHealth -and -not $DryRun -and $CouncilAttempts -lt $MaxCouncilAttempts) {
        if (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue) {
            $CouncilAttempts++
            Write-Host ""
            Write-Host "  [SCALES] LLM Council review (attempt $CouncilAttempts/$MaxCouncilAttempts)..." -ForegroundColor Cyan
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "council-review" -Agent "council" -Iteration $Iteration -HealthScore $FinalHealth
            }
            $councilResult = Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -Health $FinalHealth -Pipeline $Pipeline
            if (-not $councilResult.Approved) {
                Write-Host "  [SCALES] Council BLOCKED -- $($councilResult.Findings.concerns.Count) concern(s)" -ForegroundColor Yellow
                foreach ($c in $councilResult.Findings.concerns) { Write-Host "    - $c" -ForegroundColor DarkYellow }
                # Reset health to 99% so loop re-enters
                $healthObj = Get-Content $HealthFile -Raw | ConvertFrom-Json
                $healthObj.health_score = 99
                $healthObj | ConvertTo-Json | Set-Content $HealthFile -Encoding UTF8
                $Health = 99; $FinalHealth = 99
                $validationFailed = $true
                Send-GsdNotification -Title "Council Blocked (attempt $CouncilAttempts/$MaxCouncilAttempts)" `
                    -Message "$repoName | $($councilResult.Findings.concerns.Count) concerns to address" `
                    -Tags "warning" -Priority "high"
                $script:LAST_NOTIFY_TIME = Get-Date
                continue  # Re-enter do-while loop
            } else {
                Write-Host "  [SCALES] Council APPROVED (confidence: $($councilResult.Findings.confidence)%)" -ForegroundColor Green
                Send-GsdNotification -Title "Council Approved" `
                    -Message "$repoName | Confidence: $($councilResult.Findings.confidence)% -- proceeding to validation" `
                    -Tags "white_check_mark"
                $script:LAST_NOTIFY_TIME = Get-Date
            }
        }
    }

        # Quality gate checks before final validation
    if ($FinalHealth -ge $TargetHealth -and -not $DryRun) {
        if (Get-Command Test-DatabaseCompleteness -ErrorAction SilentlyContinue) {
            $dbResult = Test-DatabaseCompleteness -RepoRoot $RepoRoot -GsdDir $GsdDir
            if (-not $dbResult.Passed -and -not $dbResult.Skipped) {
                $ctxPath = Join-Path $GsdDir "supervisor\error-context.md"
                $existingCtx = ""; if (Test-Path $ctxPath) { $existingCtx = Get-Content $ctxPath -Raw }
                "$existingCtx`n## Database Completeness Issues`n$(($dbResult.Issues | ForEach-Object { "- $_" }) -join "`n")" | Set-Content $ctxPath -Encoding UTF8
            }
        }
        if (Get-Command Test-SecurityCompliance -ErrorAction SilentlyContinue) {
            $secResult = Test-SecurityCompliance -RepoRoot $RepoRoot -GsdDir $GsdDir -Detailed
            if (-not $secResult.Passed -and -not $secResult.Skipped) {
                $ctxPath = Join-Path $GsdDir "supervisor\error-context.md"
                $existingCtx = ""; if (Test-Path $ctxPath) { $existingCtx = Get-Content $ctxPath -Raw }
                "$existingCtx`n## Security Compliance Issues`n- $($secResult.Criticals) critical, $($secResult.Highs) high violations" | Set-Content $ctxPath -Encoding UTF8
            }
        }
    }
    # Final validation gate - runs when health reaches 100%
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
        # Final commit uses git add -A since this is the convergence commit — everything should be clean
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
        # Always push on convergence (flush any pending pushes too)
        git push --tags 2>$null
    }
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "converged" -HealthScore $FinalHealth -Iteration $Iteration }
    $finalCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $finalDiffLine = if (Get-Command Get-GitCumulativeStats -ErrorAction SilentlyContinue) { Get-GitCumulativeStats -RepoRoot $RepoRoot -Iterations $Iteration } else { "" }
    $convergedMsg = "$repoName | 100% in $Iteration iterations"
    if ($finalDiffLine) { $convergedMsg += "`n$finalDiffLine" }
    if ($finalCostLine) { $convergedMsg += "`n$finalCostLine" }
    Send-GsdNotification -Title "CONVERGED!" -Message $convergedMsg -Tags "tada,white_check_mark" -Priority "high"
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "  [STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "stalled" -HealthScore $FinalHealth -Iteration $Iteration }
    $stalledCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $stalledDiffLine = if (Get-Command Get-GitCumulativeStats -ErrorAction SilentlyContinue) { Get-GitCumulativeStats -RepoRoot $RepoRoot -Iterations $Iteration } else { "" }
    $stalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"
    if ($stalledDiffLine) { $stalledMsg += "`n$stalledDiffLine" }
    if ($stalledCostLine) { $stalledMsg += "`n$stalledCostLine" }
    Send-GsdNotification -Title "STALLED" -Message $stalledMsg -Tags "warning" -Priority "high"
} else {
    Write-Host "  [!!]  MAX ITERATIONS at ${FinalHealth}%" -ForegroundColor Yellow
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "completed" -HealthScore $FinalHealth -Iteration $Iteration }
    $maxIterCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $maxIterDiffLine = if (Get-Command Get-GitCumulativeStats -ErrorAction SilentlyContinue) { Get-GitCumulativeStats -RepoRoot $RepoRoot -Iterations $Iteration } else { "" }
    $maxIterMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"
    if ($maxIterDiffLine) { $maxIterMsg += "`n$maxIterDiffLine" }
    if ($maxIterCostLine) { $maxIterMsg += "`n$maxIterCostLine" }
    Send-GsdNotification -Title "MAX ITERATIONS" -Message $maxIterMsg -Tags "warning" -Priority "high"
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
        }
    }

    # Final push: flush any pending pushes from batched push strategy (#7)
    if ($script:PendingPush -or $true) {
        git push 2>$null
    }

    Clear-Checkpoint -GsdDir $GsdDir; Remove-GsdLock -GsdDir $GsdDir
}



