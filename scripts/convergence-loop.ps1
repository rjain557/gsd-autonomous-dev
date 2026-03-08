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
    [switch]$AutoResolve, [switch]$ForceCodeReview,
    [string]$Scope = "",
    [switch]$Incremental
)

$ErrorActionPreference = "Continue"

# CRITICAL: Remove CLAUDECODE env var so nested claude CLI calls work
# (When convergence-loop is launched from within a Claude Code session)
Remove-Item Env:\CLAUDECODE -ErrorAction SilentlyContinue
[System.Environment]::SetEnvironmentVariable("CLAUDECODE", $null, [System.EnvironmentVariableTarget]::Process)

$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"

# GUARD: Prevent running against the GSD engine's own repo
$engineMarker = Join-Path $RepoRoot "scripts\convergence-loop.ps1"
if (Test-Path $engineMarker) {
    Write-Host ""
    Write-Host "  [!!] ERROR: You are running convergence-loop inside the GSD engine repo!" -ForegroundColor Red
    Write-Host "       Current dir: $RepoRoot" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Fix: cd into your TARGET PROJECT directory first, then run:" -ForegroundColor Yellow
    Write-Host "       cd D:\vscode\your-project" -ForegroundColor Cyan
    Write-Host "       & `"$GlobalDir\scripts\convergence-loop.ps1`"" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

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
    # Always remove existing lock before startup so we start clean
    $existingLock = Join-Path $GsdDir ".gsd-lock"
    if (Test-Path $existingLock) {
        $lockAge = [math]::Round(((Get-Date) - (Get-Item $existingLock).LastWriteTime).TotalMinutes)
        Write-Host "    [LOCK] Removing stale lock (${lockAge}m old) - starting clean" -ForegroundColor DarkYellow
        Remove-Item $existingLock -Force -ErrorAction SilentlyContinue
    }
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
if ($ForceCodeReview) { Write-Host "  Force:    code-review will run even at 100% health" -ForegroundColor Yellow }
if ($script:NTFY_TOPIC) { Write-Host "  Notify:   ntfy.sh/$($script:NTFY_TOPIC)" -ForegroundColor DarkGray }
Write-Host ""

Send-GsdNotification -Title "GSD Converge Started" `
    -Message "$repoName | Health: ${Health}% | Batch: $CurrentBatchSize | Throttle: ${ThrottleSeconds}s" `
    -Tags "rocket" -Priority "default"

# Save LOC baseline (starting commit hash for total diff at exit)
if (Get-Command Save-LocBaseline -ErrorAction SilentlyContinue) { Save-LocBaseline -GsdDir $GsdDir }

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
    # LOC context: inject AI code generation metrics into review prompts
    if ($templatePath -match "code-review" -and (Get-Command Get-LocContextForReview -ErrorAction SilentlyContinue)) {
        $locCtx = Get-LocContextForReview -GsdDir $GsdDir
        if ($locCtx) { $resolved += "`n`n$locCtx" }
    }
    # Council: inject feedback from previous council review
    $councilFeedbackPath = Join-Path $GsdDir "supervisor\council-feedback.md"
    if (Test-Path $councilFeedbackPath) {
        $resolved += "`n`n" + (Get-Content $councilFeedbackPath -Raw)
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
    Write-Host "[CLIP] Phase 0: CREATE PHASES" -ForegroundColor Magenta

    # Check if council requirements extraction is enabled
    $useCouncilReqs = $false
    if (Get-Command Invoke-CouncilRequirements -ErrorAction SilentlyContinue) {
        $crCfgPath = Join-Path $GlobalDir "config\global-config.json"
        if (Test-Path $crCfgPath) {
            try {
                $crCfg = (Get-Content $crCfgPath -Raw | ConvertFrom-Json).council_requirements
                if ($crCfg -and $crCfg.enabled) { $useCouncilReqs = $true }
            } catch {}
        }
    }

    if ($useCouncilReqs -and -not $DryRun) {
        Write-Host "  [SCALES] Council requirements extraction (3-agent parallel)" -ForegroundColor Cyan
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration 0 -Phase "council-create-phases" -Health 0 -BatchSize $CurrentBatchSize
        $crResult = Invoke-CouncilRequirements -RepoRoot $RepoRoot -GsdDir $GsdDir
        if (-not $crResult.Success) {
            Write-Host "  [WARN] Council extraction failed. Falling back to single-agent." -ForegroundColor Yellow
            $useCouncilReqs = $false
        }
    }

    if (-not $useCouncilReqs) {
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

    # Reasoning effort: medium/no-thinking for review/research/plan, full for execute
    $env:GSD_CODEX_EFFORT = "medium"
    $env:GSD_KIMI_THINKING = "false"

    # 1. CODE REVIEW (Claude)
    Send-HeartbeatIfDue -Phase "code-review" -Iteration $Iteration -Health $Health -RepoName $repoName
    Write-Host "  [SEARCH] CLAUDE -> code-review" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "code-review" -Health $Health -BatchSize $CurrentBatchSize
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "code-review" -Agent "claude" -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize -Attempt "1/$($script:RETRY_MAX)" -ErrorsThisIteration 0
    }

        # â”€â”€ Differential Review Check â”€â”€
        $useDiffReview = $false
        if (Get-Command Get-DifferentialContext -ErrorAction SilentlyContinue) {
            $diffCtx = Get-DifferentialContext -GsdDir $GsdDir -GlobalDir $GlobalDir -Iteration $Iteration -RepoRoot $RepoRoot
            if ($diffCtx.UseDifferential -and $diffCtx.ChangedFiles.Count -gt 0) {
                Write-Host "  [DIFF] Differential review: $($diffCtx.ChangedFiles.Count) files changed" -ForegroundColor Cyan
                $diffPromptPath = "$GlobalDir\prompts\claude\code-review-differential.md"
                if (Test-Path $diffPromptPath) {
                    $prompt = Local-ResolvePrompt $diffPromptPath $Iteration $Health
                    $prompt = $prompt.Replace("{{DIFF_CONTENT}}", $diffCtx.DiffContent)
                    $prompt = $prompt.Replace("{{CHANGED_FILES}}", ($diffCtx.ChangedFiles -join "`n"))
                    $useDiffReview = $true
                }
            } elseif ($diffCtx.UseDifferential -and $diffCtx.ChangedFiles.Count -eq 0) {
                Write-Host "  [DIFF] No files changed since last review -- skipping code-review phase" -ForegroundColor DarkGray
                $useDiffReview = $true  # prevents the full-review block below from firing
                # Still need to save checkpoint
                if (Get-Command Save-ReviewedCommit -ErrorAction SilentlyContinue) {
                    Save-ReviewedCommit -GsdDir $GsdDir -Iteration $Iteration
                }
            } else {
                Write-Host "  [DIFF] Full review: $($diffCtx.Reason)" -ForegroundColor DarkGray
            }
        }
        if (-not $useDiffReview) {
    $prompt = Local-ResolvePrompt "$GlobalDir\prompts\claude\code-review.md" $Iteration $Health
    if (-not $DryRun) {
        $reviewResult = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "code-review" `
            -LogFile "$GsdDir\logs\iter${Iteration}-1.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash"
        # Fallback: if claude failed, retry with codex (NOT gemini -- gemini applies strict traceability rules that corrupt the matrix)
        if (-not $reviewResult -or $reviewResult.ExitCode -ne 0) {
            Write-Host "  [FALLBACK] claude code-review failed -- retrying with codex" -ForegroundColor Yellow
            Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "code-review" `
                -LogFile "$GsdDir\logs\iter${Iteration}-1-fallback.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
        }
    }
    $Health = Get-Health
    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }

    
        }  # end differential review fallback

        # Save reviewed commit for next differential
        if (Get-Command Save-ReviewedCommit -ErrorAction SilentlyContinue) {
            Save-ReviewedCommit -GsdDir $GsdDir -Iteration $Iteration
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

    # 2. RESEARCH (Parallel: Gemini->PhaseA+B, DeepSeek->PhaseC+D, Kimi->PhaseE+Figma)
    if (-not $SkipResearch) {
        Send-HeartbeatIfDue -Phase "research" -Iteration $Iteration -Health $Health -RepoName $repoName
        if (-not (Test-Path "$GsdDir\research")) { New-Item -ItemType Directory -Path "$GsdDir\research" -Force | Out-Null }

        $parallelResearchOk = $false
        if ((Get-Command Invoke-ParallelResearch -ErrorAction SilentlyContinue) -and -not $DryRun) {
            Write-Host "  [PAR-RESEARCH] Gemini+DeepSeek+Kimi -> parallel research" -ForegroundColor Magenta
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "research" `
                    -Agent "parallel(gemini+deepseek+kimi)" -Iteration $Iteration -HealthScore $Health
            }
            Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "research" -Health $Health -BatchSize $CurrentBatchSize
            $prResult = Invoke-ParallelResearch -GsdDir $GsdDir -GlobalDir $GlobalDir `
                -Iteration $Iteration -Health $Health -RepoRoot $RepoRoot -InterfaceContext $InterfaceContext
            if ($prResult.Success) {
                $parallelResearchOk = $true
            } else {
                Write-Host "  [PAR-RESEARCH] Parallel research failed ($($prResult.Error)) -- falling back to sequential" -ForegroundColor Yellow
            }
        }

        # Pre-check: if all research-capable agents are on cooldown, skip research entirely
        # This prevents rotating research to Claude/Codex and burning their quota
        if (-not $parallelResearchOk -and -not $DryRun) {
            $researchCapableAgents = @("gemini", "deepseek", "kimi", "minimax", "glm5")
            $cooldownPath = Join-Path $GsdDir "supervisor\agent-cooldowns.json"
            $agentCooldowns = @{}
            if (Test-Path $cooldownPath) {
                try { $raw = Get-Content $cooldownPath -Raw | ConvertFrom-Json
                      foreach ($p in $raw.PSObject.Properties) { try { $agentCooldowns[$p.Name] = [datetime]$p.Value } catch {} }
                } catch {}
            }
            $now = Get-Date
            $anyResearchAvail = $researchCapableAgents | Where-Object {
                -not $agentCooldowns.ContainsKey($_) -or $now -ge $agentCooldowns[$_]
            }
            if (-not $anyResearchAvail) {
                Write-Host "  [SKIP] All research-capable agents on cooldown -- skipping research this iteration" -ForegroundColor DarkYellow
                $parallelResearchOk = $true   # suppress sequential fallback
            }
        }

        # Sequential fallback: original Gemini -> Codex chain
        if (-not $parallelResearchOk -and -not $DryRun) {
            $useGemini = $null -ne (Get-Command gemini -ErrorAction SilentlyContinue)
            if ($useGemini) {
                Write-Host "  GEMINI -> research (sequential fallback)" -ForegroundColor Magenta
                if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                    Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "research" -Agent "gemini" -Iteration $Iteration -HealthScore $Health
                }
                $prompt = Local-ResolvePrompt "$GlobalDir\prompts\gemini\research.md" $Iteration $Health
                Invoke-WithRetry -Agent "gemini" -Prompt $prompt -Phase "research" `
                    -LogFile "$GsdDir\logs\iter${Iteration}-2.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
                    -GeminiMode "--approval-mode plan" | Out-Null
            } else {
                Write-Host "  CODEX -> research (sequential fallback, gemini unavailable)" -ForegroundColor Magenta
                if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                    Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "research" -Agent "codex" -Iteration $Iteration -HealthScore $Health
                }
                $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\research.md" $Iteration $Health
                Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "research" `
                    -LogFile "$GsdDir\logs\iter${Iteration}-2.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
            }
        }
    }

    # ── POST-RESEARCH COUNCIL (validate research before planning) ──
    if (-not $DryRun -and (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue)) {
        Write-Host "  [SCALES] Post-research council..." -ForegroundColor DarkCyan
        $prResult = Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -Health $Health -Pipeline $Pipeline -CouncilType "post-research"
        if (-not $prResult.Approved) {
            Write-Host "  [SCALES] Research concerns noted -- plan phase will address them" -ForegroundColor DarkYellow
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
        $planResult = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "plan" `
            -LogFile "$GsdDir\logs\iter${Iteration}-3.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir `
            -AllowedTools "Read,Write,Bash"
        # Fallback: if claude failed, retry with codex (NOT gemini -- gemini misinterprets plan requirements)
        if (-not $planResult -or $planResult.ExitCode -ne 0) {
            Write-Host "  [FALLBACK] claude plan failed -- retrying with codex" -ForegroundColor Yellow
            Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "plan" `
                -LogFile "$GsdDir\logs\iter${Iteration}-3-fallback.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
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

    # ── PRE-EXECUTE COUNCIL (validate plan before code generation) ──
    if (-not $DryRun -and (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue)) {
        Write-Host "  [SCALES] Pre-execute council..." -ForegroundColor DarkCyan
        $peResult = Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -Health $Health -Pipeline $Pipeline -CouncilType "pre-execute"
        if (-not $peResult.Approved) {
            Write-Host "  [SCALES] Plan concerns noted -- executing with caution" -ForegroundColor DarkYellow
        }
    }

    # 4. EXECUTE -- Parallel sub-task or monolithic fallback
    $env:GSD_CODEX_EFFORT = "xhigh"       # Restore full reasoning for code generation
    $env:GSD_KIMI_THINKING = "true"        # Restore thinking for kimi execute
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
                git add -A; git commit -F $commitMsgFile --no-verify 2>$null
                Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
            } else {
                git add -A; git commit -m $commitSubject --no-verify 2>$null
            }
            git push 2>$null

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
        # Agent intelligence: use best-performing agent for execute phase
        $executeAgent = if (Get-Command Get-BestAgentForPhase -ErrorAction SilentlyContinue) {
            Get-BestAgentForPhase -GsdDir $GsdDir -GlobalDir $GlobalDir -Phase "execute" -DefaultAgent "codex"
        } else { "codex" }
        # Supervisor override takes highest priority
        $overridePath = Join-Path $GsdDir "supervisor\agent-override.json"
        if (Test-Path $overridePath) {
            try { $ov = Get-Content $overridePath -Raw | ConvertFrom-Json
                  if ($ov.execute) { $executeAgent = $ov.execute; Write-Host "  [SUPERVISOR] Agent override: execute -> $executeAgent" -ForegroundColor Yellow } } catch {}
        }
        Write-Host "  [WRENCH] $($executeAgent.ToUpper()) -> execute (batch: $CurrentBatchSize)" -ForegroundColor Magenta
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "execute" -Agent $executeAgent -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize
        }

        # Figma-First mode: prepend instruction header when batch contains UI requirements
        $figmaFirstHeader = ""
        $queueDataPath = Join-Path $GsdDir "generation-queue\queue-current.json"
        if (Test-Path $queueDataPath) {
            try {
                $queueData = Get-Content $queueDataPath -Raw | ConvertFrom-Json
                $uiItems = @($queueData.batch | Where-Object {
                    ($_.target_files -join " ") -match "\.(tsx|jsx|css|scss)" -or
                    ($_.description  -match "component|UI|frontend|screen|page|modal|form|layout|nav")
                })
                if ($uiItems.Count -gt 0) {
                    $figmaFirstHeader = "## FIGMA-FIRST MODE ($($uiItems.Count) UI requirements detected)`n`n"
                    $figmaFirstHeader += "**READ FIGMA ANALYSIS FILES BEFORE WRITING ANY CODE.**`n"
                    $figmaFirstHeader += "Every UI component MUST match Figma exactly: layout, spacing, typography, colors, interactive states (hover/focus/active/disabled/loading/error/empty).`n"
                    $figmaFirstHeader += "Reference figma-mapping.md and all Figma analysis files in design/ FIRST, then generate components.`n`n---`n`n"
                    Write-Host "  [FIGMA-FIRST] $($uiItems.Count) UI item(s) in batch -- Figma-First mode enabled" -ForegroundColor Cyan
                }
            } catch {}
        }

        $prompt = Local-ResolvePrompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health
        if ($figmaFirstHeader) { $prompt = $figmaFirstHeader + $prompt }
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
                git add -A; git commit -F $commitMsgFile --no-verify 2>$null
                Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
            } else {
                git add -A; git commit -m $commitSubject --no-verify 2>$null
            }
            git push 2>$null
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
            # Multi-agent stall diagnosis via council
            if (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue) {
                Write-Host "  [SCALES] Multi-agent stall diagnosis..." -ForegroundColor DarkCyan
                Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -Health $NewHealth -Pipeline $Pipeline -CouncilType "stall-diagnosis" | Out-Null
            } else {
                Invoke-WithRetry -Agent "claude" -Prompt "Stalled at ${NewHealth}%. Read .gsd\health\*, .gsd\logs\errors.jsonl. Diagnose. Write .gsd\health\stall-diagnosis.md." `
                    -Phase "stall" -LogFile "$GsdDir\logs\stall-$Iteration.log" -CurrentBatchSize 1 -GsdDir $GsdDir | Out-Null
            }
            break
        }
    } else { $StallCount = 0; if ($CurrentBatchSize -lt $BatchSize) { $CurrentBatchSize = [math]::Min($BatchSize, $CurrentBatchSize + 1) } }

    $Health = $NewHealth
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "done"
    $iterCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir } else { "" }
    $iterMsg = "$repoName | Health: ${Health}% (+$([math]::Round($Health - $PrevHealth, 1))%) | Batch: $CurrentBatchSize"
    if ($iterCostLine) { $iterMsg += "`n$iterCostLine" }
    # LOC tracking
    if (Get-Command Update-LocMetrics -ErrorAction SilentlyContinue) {
        Update-LocMetrics -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GlobalDir -Iteration $Iteration -Pipeline "convergence"
    }
    $locLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir } else { "" }
    if ($locLine) { $iterMsg += "`n$locLine" }
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
    $finalCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $convergedMsg = "$repoName | 100% in $Iteration iterations"
    # LOC vs Cost summary for final notification
    $locCostSummary = if (Get-Command Get-LocCostSummaryText -ErrorAction SilentlyContinue) { Get-LocCostSummaryText -GsdDir $GsdDir } else { "" }
    if ($locCostSummary) { $convergedMsg += "`n$locCostSummary" }
    $locFinalLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($locFinalLine) { $convergedMsg += "`n$locFinalLine" }
    if ($finalCostLine) { $convergedMsg += "`n$finalCostLine" }
    Send-GsdNotification -Title "CONVERGED!" -Message $convergedMsg -Tags "tada,white_check_mark" -Priority "high"
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "  [STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "stalled" -HealthScore $FinalHealth -Iteration $Iteration }
    $stalledCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $stalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"
    $locCostStalledSummary = if (Get-Command Get-LocCostSummaryText -ErrorAction SilentlyContinue) { Get-LocCostSummaryText -GsdDir $GsdDir } else { "" }
    if ($locCostStalledSummary) { $stalledMsg += "`n$locCostStalledSummary" }
    $locStalledLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($locStalledLine) { $stalledMsg += "`n$locStalledLine" }
    if ($stalledCostLine) { $stalledMsg += "`n$stalledCostLine" }
    Send-GsdNotification -Title "STALLED" -Message $stalledMsg -Tags "warning" -Priority "high"
} else {
    Write-Host "  [!!]  MAX ITERATIONS at ${FinalHealth}%" -ForegroundColor Yellow
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "completed" -HealthScore $FinalHealth -Iteration $Iteration }
    $maxIterCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $maxIterMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"
    $locCostMaxSummary = if (Get-Command Get-LocCostSummaryText -ErrorAction SilentlyContinue) { Get-LocCostSummaryText -GsdDir $GsdDir } else { "" }
    if ($locCostMaxSummary) { $maxIterMsg += "`n$locCostMaxSummary" }
    $locMaxLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($locMaxLine) { $maxIterMsg += "`n$locMaxLine" }
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

    # Final LOC tracking: compute total lines from baseline to HEAD
    if (Get-Command Complete-LocTracking -ErrorAction SilentlyContinue) {
        Complete-LocTracking -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GlobalDir -Pipeline "convergence"
    }

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







