<#
.SYNOPSIS
    Blueprint Pipeline - Final Integrated Edition
    All gaps closed: multi-interface, Figma Make prompts, spec check, disk per-iter, storyboard verify
#>
param(
    [int]$MaxIterations = 30, [int]$StallThreshold = 3, [int]$BatchSize = 15,
    [int]$ThrottleSeconds = 30,
    [string]$NtfyTopic = "",
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
$PipelineName = "blueprint"
$GsdGlobalDir = $GlobalDir

# -- Load ALL modules --
. "$GlobalDir\lib\modules\resilience.ps1"
if (Test-Path "$GlobalDir\lib\modules\interfaces.ps1") {
    . "$GlobalDir\lib\modules\interfaces.ps1"
}
if (Test-Path "$GlobalDir\lib\modules\interface-wrapper.ps1") {
    . "$GlobalDir\lib\modules\interface-wrapper.ps1"
}
if (Test-Path "$GlobalDir\lib\modules\supervisor.ps1") {
    . "$GlobalDir\lib\modules\supervisor.ps1"
}

# Initialize push notifications
if (Get-Command Initialize-GsdNotifications -ErrorAction SilentlyContinue) {
    Initialize-GsdNotifications -GsdGlobalDir $GlobalDir -OverrideTopic $NtfyTopic
}
$repoName = Split-Path $RepoRoot -Leaf

# -- Ensure dirs --
@($GsdDir, $BpDir, "$GsdDir\logs", "$GsdDir\supervisor", "$GsdDir\costs") | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# Initialize cost tracking
if (Get-Command Initialize-CostTracking -ErrorAction SilentlyContinue) {
    Initialize-CostTracking -GsdDir $GsdDir -Pipeline "blueprint"
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

function Get-GitRuntimeConfig {
    $defaults = @{
        enabled = $true
        commit_on_iteration = $true
        push_on_iteration = $false
        push_on_terminal = $true
        tag_on_terminal = $true
        commit_developer_handoff = $true
    }

    $cfgPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $cfgPath) {
        try {
            $gitCfg = (Get-Content $cfgPath -Raw | ConvertFrom-Json).git
            if ($gitCfg) {
                foreach ($prop in $gitCfg.PSObject.Properties.Name) {
                    $defaults[$prop] = $gitCfg.$prop
                }
            }
        } catch {}
    }

    return $defaults
}

function Invoke-GitCommitFromText {
    param(
        [string]$Subject,
        [string]$Body = "",
        [string[]]$Paths = @(),
        [switch]$Terminal
    )

    if ($DryRun -or -not $script:GIT_RUNTIME.enabled) { return $false }
    if (-not $Terminal -and -not $script:GIT_RUNTIME.commit_on_iteration) { return $false }

    if ($Paths.Count -gt 0) {
        git add -- @Paths 2>$null | Out-Null
    } else {
        git add -A 2>$null | Out-Null
    }

    git diff --cached --quiet 2>$null
    if ($LASTEXITCODE -eq 0) { return $false }
    if ($LASTEXITCODE -gt 1) { return $false }

    if ($Body) {
        $commitMsgFile = Join-Path $GsdDir ".commit-msg.tmp"
        "$Subject`n`n$Body" | Set-Content $commitMsgFile -Encoding UTF8
        git commit -F $commitMsgFile --no-verify 2>$null | Out-Null
        Remove-Item $commitMsgFile -ErrorAction SilentlyContinue
    } else {
        git commit -m $Subject --no-verify 2>$null | Out-Null
    }

    return ($LASTEXITCODE -eq 0)
}

function Invoke-GitPushIfAllowed {
    param(
        [switch]$Terminal,
        [switch]$IncludeTags
    )

    if ($DryRun -or -not $script:GIT_RUNTIME.enabled) { return }

    $shouldPush = if ($Terminal) {
        [bool]$script:GIT_RUNTIME.push_on_terminal
    } else {
        [bool]$script:GIT_RUNTIME.push_on_iteration
    }

    if (-not $shouldPush) { return }

    if ($IncludeTags) {
        git push --tags 2>$null | Out-Null
    } else {
        git push 2>$null | Out-Null
    }
}

function Add-SupervisorContextSection {
    param(
        [string]$Heading,
        [string[]]$Lines
    )

    if (-not $Lines -or $Lines.Count -eq 0) { return }

    $ctxPath = Join-Path $GsdDir "supervisor\error-context.md"
    $existing = if (Test-Path $ctxPath) { Get-Content $ctxPath -Raw } else { "" }
    $section = "## $Heading`n" + (($Lines | Where-Object { $_ }) -join "`n")
    $content = if ($existing.Trim()) { "$existing`n`n$section" } else { $section }
    $content | Set-Content $ctxPath -Encoding UTF8
}

$script:GIT_RUNTIME = Get-GitRuntimeConfig

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

# Engine status: starting
if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
    Update-EngineStatus -GsdDir $GsdDir -State "starting" -Iteration 0 -HealthScore (Get-Health) -BatchSize $BatchSize
}

# Interface detection (GAP 11)
$InterfaceContext = ""
$Interfaces = @()
$UseFigmaMake = $false
$hasStoryboards = $false

if (Get-Command Initialize-ProjectInterfaces -ErrorAction SilentlyContinue) {
    Write-Host ""
    $ifaceResult = Initialize-ProjectInterfaces -RepoRoot $RepoRoot -GsdDir $GsdDir
    $InterfaceContext = $ifaceResult.Context
    $Interfaces = $ifaceResult.Interfaces
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
if ($script:NTFY_TOPIC) { Write-Host "  Notify:    ntfy.sh/$($script:NTFY_TOPIC)" -ForegroundColor DarkGray }
if ($DryRun) { Write-Host "  MODE:      DRY RUN" -ForegroundColor Yellow }
Write-Host ""

Send-GsdNotification -Title "GSD Blueprint Started" `
    -Message "$repoName | Health: ${Health}% | Batch: $CurrentBatchSize" `
    -Tags "rocket" -Priority "default"

# Save LOC baseline for cumulative metrics at pipeline exit.
if (Get-Command Save-LocBaseline -ErrorAction SilentlyContinue) {
    Save-LocBaseline -GsdDir $GsdDir
}

# Start background heartbeat (sends progress every 10 min even during long agent calls)
Start-BackgroundHeartbeat -GsdDir $GsdDir -NtfyTopic $script:NTFY_TOPIC `
    -Pipeline "blueprint" -RepoName $repoName -IntervalMinutes 10

# Start background command listener (responds to "progress" commands via ntfy)
Start-CommandListener -GsdDir $GsdDir -NtfyTopic $script:NTFY_TOPIC `
    -Pipeline "blueprint" -RepoName $repoName -PollIntervalSeconds 15

# Start engine-status.json heartbeat (60s freshness signal)
if (Get-Command Start-EngineStatusHeartbeat -ErrorAction SilentlyContinue) {
    Start-EngineStatusHeartbeat -GsdDir $GsdDir
}

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

# Spec consistency check (GAP 5+15) with optional auto-resolution
if (-not $SkipSpecCheck -and -not $BuildOnly -and -not $VerifyOnly) {
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
    Send-HeartbeatIfDue -Phase "blueprint-gen" -Iteration 0 -Health 0 -RepoName $repoName
    Write-Host "* PHASE 1: BLUEPRINT (Claude Code)" -ForegroundColor Blue
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration 0 -Phase "blueprint" -Health 0 -BatchSize $CurrentBatchSize
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "blueprint" -Agent "claude" -Iteration 0 -HealthScore 0 -BatchSize $CurrentBatchSize
    }
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

    # â”€â”€ POST-BLUEPRINT COUNCIL (validate blueprint before building) â”€â”€
    if (-not $DryRun -and (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue)) {
        Write-Host "  [SCALES] Post-blueprint council review..." -ForegroundColor Cyan
        $bpCouncil = Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration 0 -Health 0 -Pipeline "blueprint" -CouncilType "post-blueprint"
        if (-not $bpCouncil.Approved) {
            Write-Host "  [SCALES] Blueprint concerns: $($bpCouncil.Findings.concerns.Count) issue(s)" -ForegroundColor Yellow
            foreach ($c in $bpCouncil.Findings.concerns) { Write-Host "    - $c" -ForegroundColor DarkYellow }
            Write-Host "  [SCALES] Regenerating blueprint to address concerns..." -ForegroundColor Cyan
            # Write council feedback for blueprint regeneration
            $feedbackPath = Join-Path $GsdDir "supervisor\council-feedback.md"
            $feedback = "## Blueprint Council Feedback`n`n"
            foreach ($c in $bpCouncil.Findings.concerns) { $feedback += "- $c`n" }
            $feedback += "`nAddress these concerns in the regenerated blueprint."
            $feedback | Set-Content $feedbackPath -Encoding UTF8
            # Re-run blueprint with feedback injected
            $prompt = Local-ResolvePrompt $BlueprintPromptPath 0 0
            Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "blueprint" `
                -LogFile "$GsdDir\logs\phase1-blueprint-regen.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
            Remove-Item $feedbackPath -ErrorAction SilentlyContinue
        } else {
            Write-Host "  [SCALES] Blueprint APPROVED (confidence: $($bpCouncil.Findings.confidence)%)" -ForegroundColor Green
        }
    }

    if ($BlueprintOnly) { Clear-Checkpoint -GsdDir $GsdDir; Remove-GsdLock -GsdDir $GsdDir; return }
}

# -- MAIN LOOP --
$StallCount = 0; $TargetHealth = 100; $Health = Get-Health
$ValidationAttempts = 0; $MaxValidationAttempts = 3; $validationResult = $null

do {

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

    $errorsThisIter = 0

    # VERIFY (storyboard-aware if available)
    Send-HeartbeatIfDue -Phase "verify" -Iteration $Iteration -Health $Health -RepoName $repoName
    Write-Host "  [SEARCH] CLAUDE -> verify$(if ($hasStoryboards) {' + storyboard'})" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration $Iteration -Phase "verify" -Health $Health -BatchSize $CurrentBatchSize
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "verify" -Agent "claude" -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize -ErrorsThisIteration 0
    }
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
            $errorsThisIter++
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -ErrorsThisIteration $errorsThisIter -LastError "Regression: ${Health}% from ${PrevHealth}%"
            }
            Send-GsdNotification -Title "Iter ${Iteration}: Regression Reverted" `
                -Message "$repoName | ${Health}% dropped from ${PrevHealth}% - reverted | Stall $($StallCount+1)/$StallThreshold" `
                -Tags "warning" -Priority "high"
            $script:LAST_NOTIFY_TIME = Get-Date
            $Health = $PrevHealth; $StallCount++; continue
        }
    }

    if ($VerifyOnly) { break }

    # Throttle between phases
    if ($ThrottleSeconds -gt 0 -and -not $DryRun) {
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -Phase "throttle" -SleepReason "throttle" -SleepUntil ((Get-Date).ToUniversalTime().AddSeconds($ThrottleSeconds))
        }
        Write-Host "  [THROTTLE] ${ThrottleSeconds}s pacing..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $ThrottleSeconds
        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "running" }
    }

    # BUILD (Figma Make aware, or supervisor-overridden agent)
    Send-HeartbeatIfDue -Phase "build" -Iteration $Iteration -Health $Health -RepoName $repoName
    $buildAgent = "codex"
    $overridePath = Join-Path $GsdDir "supervisor\agent-override.json"
    if (Test-Path $overridePath) {
        try { $ov = Get-Content $overridePath -Raw | ConvertFrom-Json
              if ($ov.build) { $buildAgent = $ov.build; Write-Host "  [SUPERVISOR] Agent override: build -> $buildAgent" -ForegroundColor Yellow } } catch {}
    }
    Write-Host "  [WRENCH] $($buildAgent.ToUpper()) -> build (batch: $CurrentBatchSize)" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration $Iteration -Phase "build" -Health $Health -BatchSize $CurrentBatchSize
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "build" -Agent $buildAgent -Iteration $Iteration -HealthScore $Health -BatchSize $CurrentBatchSize
    }
    $prompt = Local-ResolvePrompt $BuildPromptPath $Iteration $Health
    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent $buildAgent -Prompt $prompt -Phase "build" `
            -LogFile "$GsdDir\logs\iter${Iteration}-2-build.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if ($result.Success) {
            $CurrentBatchSize = $result.FinalBatchSize
            # Build commit message from verify/health findings for GitHub traceability
            $bpHealthContent = if (Test-Path $HealthFile) { (Get-Content $HealthFile -Raw).Trim() } else { "" }
            $driftPath = Join-Path $GsdDir "health\drift-report.md"
            $commitSubject = "blueprint: iter $Iteration (health: ${Health}%)"
            $commitBody = ""
            if (Test-Path $driftPath) {
                $commitBody = (Get-Content $driftPath -Raw).Trim()
            } elseif ($bpHealthContent) {
                $commitBody = "Verify results:`n$bpHealthContent"
            }
            if ($commitBody) {
                if ($commitBody.Length -gt 4000) { $commitBody = $commitBody.Substring(0, 4000) + "`n... (truncated)" }
                $null = Invoke-GitCommitFromText -Subject $commitSubject -Body $commitBody
            } else {
                $null = Invoke-GitCommitFromText -Subject $commitSubject
            }
            # Update file map after each iteration so agents see current structure
            if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                $null = Update-FileMap -Root $RepoRoot -GsdPath $GsdDir
            }
            Invoke-GitPushIfAllowed
            Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix | Out-Null
        } else {
            $CurrentBatchSize = $result.FinalBatchSize; $StallCount++; $errorsThisIter++
            if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                Update-EngineStatus -GsdDir $GsdDir -State "running" -ErrorsThisIteration $errorsThisIter -LastError "Build failed: $($result.Error)"
            }
            Send-GsdNotification -Title "Iter ${Iteration}: Build Failed" `
                -Message "$repoName | Health: ${Health}% | Batch reduced -> $CurrentBatchSize | Stall $StallCount/$StallThreshold" `
                -Tags "warning" -Priority "default"
            $script:LAST_NOTIFY_TIME = Get-Date
            continue
        }
    }

    # Stall detection
    $NewHealth = Get-Health
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
            $diagFiles = ".gsd\blueprint\*, .gsd\logs\errors.jsonl"
            if ($hasStoryboards) { $diagFiles += ", storyboard-issues.md" }
            if (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue) {
                Write-Host "  [SCALES] Multi-agent stall diagnosis..." -ForegroundColor DarkCyan
                Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -Health $NewHealth -Pipeline "blueprint" -CouncilType "stall-diagnosis" | Out-Null
            } else {
                Invoke-WithRetry -Agent "claude" -Prompt "Stalled at ${NewHealth}%. Read $diagFiles. Diagnose. Write .gsd\blueprint\stall-diagnosis.md." `
                    -Phase "stall" -LogFile "$GsdDir\logs\stall-$Iteration.log" -CurrentBatchSize 1 -GsdDir $GsdDir | Out-Null
            }
            break
        }
    } else {
        $StallCount = 0
        if ($CurrentBatchSize -lt $BatchSize) { $CurrentBatchSize = [math]::Min($BatchSize, $CurrentBatchSize + 2) }
    }

    $Health = $NewHealth
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "done"
    $bpIterCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir } else { "" }
    $bpIterMsg = "$repoName | Health: ${Health}% (+$([math]::Round($Health - $PrevHealth, 1))%) | Batch: $CurrentBatchSize"
    if ($bpIterCostLine) { $bpIterMsg += "`n$bpIterCostLine" }
    if (Get-Command Update-LocMetrics -ErrorAction SilentlyContinue) {
        Update-LocMetrics -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GsdGlobalDir -Iteration $Iteration -Pipeline $PipelineName
    }
    $bpLocLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir } else { "" }
    if ($bpLocLine) { $bpIterMsg += "`n$bpLocLine" }
    Send-GsdNotification -Title "Blueprint Iter $Iteration" -Message $bpIterMsg -Tags "chart_with_upwards_trend"
    $script:LAST_NOTIFY_TIME = Get-Date
    Write-Host ""; Start-Sleep -Seconds 2
}

    $FinalHealth = Get-Health

    # Quality gate checks before final validation
    if ($FinalHealth -ge $TargetHealth -and -not $DryRun) {
        if (Get-Command Test-DatabaseCompleteness -ErrorAction SilentlyContinue) {
            $dbResult = Test-DatabaseCompleteness -RepoRoot $RepoRoot -GsdDir $GsdDir
            if (-not $dbResult.Passed -and -not $dbResult.Skipped) {
                Add-SupervisorContextSection -Heading "Database Completeness Issues" -Lines ($dbResult.Issues | ForEach-Object { "- $_" })
            }
        }
        if (Get-Command Test-SecurityCompliance -ErrorAction SilentlyContinue) {
            $secResult = Test-SecurityCompliance -RepoRoot $RepoRoot -GsdDir $GsdDir -Detailed
            if (-not $secResult.Passed -and -not $secResult.Skipped) {
                Add-SupervisorContextSection -Heading "Security Compliance Issues" -Lines @("- $($secResult.Criticals) critical, $($secResult.Highs) high violations")
            }
        }
    }
    # Final validation gate - runs when health reaches 100%
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
                # Write failures to error-context so verify picks them up next iteration
                $failText = ($validationResult.HardFailures | ForEach-Object { "- $_" }) -join "`n"
                "## Final Validation Failures`n$failText" | Set-Content (Join-Path $GsdDir "supervisor\error-context.md") -Encoding UTF8
                # Reset health to 99 so while loop re-enters (blueprint uses .health not .health_score)
                $healthObj = Get-Content $HealthFile -Raw | ConvertFrom-Json
                $healthObj.health = 99
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

# FINAL
Write-Host ""; Write-Host "=========================================================" -ForegroundColor Blue
$FinalHealth = Get-Health
if ($FinalHealth -ge $TargetHealth) {
    Write-Host "  [PARTY] COMPLETE - ${FinalHealth}% in $Iteration iterations" -ForegroundColor Green
    if (-not $DryRun) {
        $bpHealthContent = if (Test-Path $HealthFile) { (Get-Content $HealthFile -Raw).Trim() } else { "" }
        $commitSubject = "blueprint: COMPLETE at ${FinalHealth}% in $Iteration iterations"
        if ($bpHealthContent) {
            $null = Invoke-GitCommitFromText -Subject $commitSubject -Body "Final health:`n$bpHealthContent" -Terminal
        } else {
            $null = Invoke-GitCommitFromText -Subject $commitSubject -Terminal
        }
        if ($script:GIT_RUNTIME.tag_on_terminal) {
            git tag "blueprint-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null | Out-Null
        }
        Invoke-GitPushIfAllowed -Terminal -IncludeTags:$script:GIT_RUNTIME.tag_on_terminal
    }
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "converged" -HealthScore $FinalHealth -Iteration $Iteration }
    $bpFinalCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $bpCompleteMsg = "$repoName | 100% in $Iteration iterations"
    $bpLocCostSummary = if (Get-Command Get-LocCostSummaryText -ErrorAction SilentlyContinue) { Get-LocCostSummaryText -GsdDir $GsdDir } else { "" }
    if ($bpLocCostSummary) { $bpCompleteMsg += "`n$bpLocCostSummary" }
    $bpLocFinalLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($bpLocFinalLine) { $bpCompleteMsg += "`n$bpLocFinalLine" }
    if ($bpFinalCostLine) { $bpCompleteMsg += "`n$bpFinalCostLine" }
    Send-GsdNotification -Title "BLUEPRINT COMPLETE!" -Message $bpCompleteMsg -Tags "tada,white_check_mark" -Priority "high"
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "  [STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "stalled" -HealthScore $FinalHealth -Iteration $Iteration }
    $bpStalledCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $bpStalledMsg = "$repoName | Stuck at ${FinalHealth}% after $Iteration iterations"
    $bpLocStalledLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($bpLocStalledLine) { $bpStalledMsg += "`n$bpLocStalledLine" }
    if ($bpStalledCostLine) { $bpStalledMsg += "`n$bpStalledCostLine" }
    Send-GsdNotification -Title "BLUEPRINT STALLED" -Message $bpStalledMsg -Tags "warning" -Priority "high"
} else {
    Write-Host "  [!!]  $(if ($VerifyOnly){'VERIFY DONE'}else{'MAX ITERATIONS'}) at ${FinalHealth}%" -ForegroundColor Yellow
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) { Update-EngineStatus -GsdDir $GsdDir -State "completed" -HealthScore $FinalHealth -Iteration $Iteration }
    $bpMaxCostLine = if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) { Get-CostNotificationText -GsdDir $GsdDir -Detailed } else { "" }
    $bpMaxMsg = "$repoName | ${FinalHealth}% after $Iteration iterations"
    $bpLocMaxLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
    if ($bpLocMaxLine) { $bpMaxMsg += "`n$bpLocMaxLine" }
    if ($bpMaxCostLine) { $bpMaxMsg += "`n$bpMaxCostLine" }
    Send-GsdNotification -Title "Blueprint Max Iterations" -Message $bpMaxMsg -Tags "warning" -Priority "high"
}

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

} finally {
    # Stop background heartbeat, command listener, and engine status heartbeat
    Stop-BackgroundHeartbeat
    Stop-CommandListener
    if (Get-Command Stop-EngineStatusHeartbeat -ErrorAction SilentlyContinue) { Stop-EngineStatusHeartbeat }
    if (Get-Command Complete-CostTrackingRun -ErrorAction SilentlyContinue) { Complete-CostTrackingRun -GsdDir $GsdDir }
    if (Get-Command Complete-LocTracking -ErrorAction SilentlyContinue) {
        Complete-LocTracking -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GsdGlobalDir -Pipeline $PipelineName
    }

    # Supervisor: save terminal summary so supervisor can read exit state
    $FinalHealth = Get-Health
    if (Get-Command Save-TerminalSummary -ErrorAction SilentlyContinue) {
        $exitReason = if ($FinalHealth -ge $TargetHealth) { "converged" }
                      elseif ($StallCount -ge $StallThreshold) { "stalled" }
                      else { "max_iterations" }
        Save-TerminalSummary -GsdDir $GsdDir -Pipeline "blueprint" -ExitReason $exitReason `
            -Health $FinalHealth -Iteration $Iteration -StallCount $StallCount -BatchSize $CurrentBatchSize
    }

    # Generate developer handoff report (always, regardless of exit reason)
    if (Get-Command New-DeveloperHandoff -ErrorAction SilentlyContinue) {
        Write-Host "  [DOC] Generating developer handoff..." -ForegroundColor Cyan
        $handoffPath = New-DeveloperHandoff -RepoRoot $RepoRoot -GsdDir $GsdDir `
            -Pipeline "blueprint" -ExitReason $exitReason `
            -FinalHealth $FinalHealth -Iteration $Iteration -ValidationResult $validationResult
        if ($script:GIT_RUNTIME.commit_developer_handoff -and $handoffPath -and (Test-Path $handoffPath)) {
            $null = Invoke-GitCommitFromText -Subject "blueprint: developer handoff report" -Paths @($handoffPath) -Terminal
        }
    }

    Invoke-GitPushIfAllowed -Terminal

    Clear-Checkpoint -GsdDir $GsdDir; Remove-GsdLock -GsdDir $GsdDir
}


