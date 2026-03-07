<#
.SYNOPSIS
    GSD Supervisor - Autonomous Self-Healing Pipeline Recovery
    Analyzes failures, root-causes issues via Claude, modifies prompts/queue/matrix
    to fix the underlying problem, and restarts the pipeline in a new terminal.

.DESCRIPTION
    Adds a supervisor wrapper around both gsd-converge and gsd-blueprint that:
    1. Runs the pipeline normally (transparent if it converges)
    2. On failure: parses errors.jsonl for statistical patterns (free, no AI)
    3. Invokes Claude to read logs and root-cause the actual problem
    4. Claude modifies prompts/queue/matrix/specs to fix the root cause
    5. Restarts pipeline in a new terminal with the fix applied
    6. Learns from successful fixes (cross-project pattern memory)
    7. Escalates to user with full report after 5 failed attempts

.INSTALL_ORDER
    Run after final-patch-7-spec-resolve.ps1 (script #15 in install-gsd-all.ps1)
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

if (-not (Test-Path $GsdGlobalDir)) {
    Write-Host "[XX] GSD not installed. Run installers first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Supervisor - Autonomous Self-Healing Recovery" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# Ensure directories
$dirs = @(
    "$GsdGlobalDir\lib\modules",
    "$GsdGlobalDir\scripts",
    "$GsdGlobalDir\blueprint\scripts",
    "$GsdGlobalDir\supervisor"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ========================================================
# MODULE: Supervisor Library
# ========================================================

Write-Host "[ROBOT] Creating supervisor library..." -ForegroundColor Yellow

$supervisorLib = @'
# ===============================================================
# GSD Supervisor Library - Self-Healing Pipeline Recovery
# Dot-source: . "$env:USERPROFILE\.gsd-global\lib\modules\supervisor.ps1"
# ===============================================================

# -- Configuration --
$script:SUPERVISOR_MAX_ATTEMPTS = 5
$script:SUPERVISOR_TIMEOUT_HOURS = 24
$script:SUPERVISOR_DIAGNOSIS_TIMEOUT_MIN = 10
$script:SUPERVISOR_FIX_TIMEOUT_MIN = 15

# ===========================================
# STATE MANAGEMENT
# ===========================================

function Save-TerminalSummary {
    param(
        [string]$GsdDir,
        [string]$Pipeline,
        [string]$ExitReason,     # "converged", "stalled", "max_iterations", "error"
        [double]$Health,
        [int]$Iteration,
        [int]$StallCount,
        [int]$BatchSize
    )
    $summaryDir = Join-Path $GsdDir "supervisor"
    if (-not (Test-Path $summaryDir)) { New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null }
    @{
        exit_reason = $ExitReason
        final_health = $Health
        final_iteration = $Iteration
        stall_count = $StallCount
        pipeline = $Pipeline
        batch_size = $BatchSize
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json | Set-Content (Join-Path $summaryDir "last-run-summary.json") -Encoding UTF8
}

function Save-SupervisorState {
    param([string]$GsdDir, [hashtable]$State)
    $path = Join-Path $GsdDir "supervisor\supervisor-state.json"
    $State | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8
}

function Get-SupervisorState {
    param([string]$GsdDir)
    $path = Join-Path $GsdDir "supervisor\supervisor-state.json"
    if (Test-Path $path) {
        try { return Get-Content $path -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Get-PipelineExitReason {
    param([string]$GsdDir)
    $path = Join-Path $GsdDir "supervisor\last-run-summary.json"
    $result = $null
    if (Test-Path $path) {
        try { $result = Get-Content $path -Raw | ConvertFrom-Json } catch {}
    }
    # Enrich with engine-status.json if available
    $enginePath = Join-Path $GsdDir "health\engine-status.json"
    if (Test-Path $enginePath) {
        try {
            $engine = Get-Content $enginePath -Raw | ConvertFrom-Json
            if ($result) {
                $result | Add-Member -NotePropertyName "engine_state" -NotePropertyValue $engine.state -Force
                $result | Add-Member -NotePropertyName "engine_last_error" -NotePropertyValue $engine.last_error -Force
                $result | Add-Member -NotePropertyName "engine_last_heartbeat" -NotePropertyValue $engine.last_heartbeat -Force
            } else {
                # No summary but engine status exists - build result from engine state
                $result = @{
                    exit_reason = $engine.state
                    final_health = $engine.health_score
                    final_iteration = $engine.iteration
                    stall_count = 0
                    batch_size = $engine.batch_size
                    engine_state = $engine.state
                    engine_last_error = $engine.last_error
                    engine_last_heartbeat = $engine.last_heartbeat
                }
            }
        } catch {}
    }
    return $result
}

# ===========================================
# ANALYSIS - LAYER 1: Pattern Matching (free)
# ===========================================

function Get-ErrorStatistics {
    param([string]$GsdDir)
    $errFile = Join-Path $GsdDir "logs\errors.jsonl"
    $stats = @{
        ErrorCounts = @{}
        PhaseFailures = @{}
        AgentFailures = @{}
        RecentErrors = @()
        TotalErrors = 0
    }
    if (-not (Test-Path $errFile)) { return $stats }

    $errors = Get-Content $errFile -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch {}
    }
    $stats.TotalErrors = ($errors | Measure-Object).Count

    foreach ($e in $errors) {
        $type = if ($e.type) { $e.type } elseif ($e.category) { $e.category } else { "unknown" }
        if (-not $stats.ErrorCounts[$type]) { $stats.ErrorCounts[$type] = 0 }
        $stats.ErrorCounts[$type]++

        if ($e.phase) {
            if (-not $stats.PhaseFailures[$e.phase]) { $stats.PhaseFailures[$e.phase] = 0 }
            $stats.PhaseFailures[$e.phase]++
        }
        if ($e.agent) {
            if (-not $stats.AgentFailures[$e.agent]) { $stats.AgentFailures[$e.agent] = 0 }
            $stats.AgentFailures[$e.agent]++
        }
    }

    # Last 10 errors for diagnosis context
    $stats.RecentErrors = $errors | Select-Object -Last 10
    return $stats
}

function Get-StuckRequirements {
    param([string]$GsdDir)
    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) { return @() }
    try {
        $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
        $stuck = $matrix.requirements | Where-Object { $_.status -eq "partial" -or $_.status -eq "not_started" }
        return @($stuck)
    } catch { return @() }
}

function Get-HealthTrajectory {
    param([string]$GsdDir)
    # Check both convergence and blueprint health history locations
    $histPaths = @(
        (Join-Path $GsdDir "health\health-history.jsonl"),
        (Join-Path $GsdDir "blueprint\health-history.jsonl")
    )
    $entries = @()
    foreach ($p in $histPaths) {
        if (Test-Path $p) {
            $entries += Get-Content $p -ErrorAction SilentlyContinue | ForEach-Object {
                try { $_ | ConvertFrom-Json } catch {}
            }
        }
    }
    if ($entries.Count -lt 2) { return @{ Trend = "insufficient_data"; Entries = $entries } }

    $last5 = $entries | Select-Object -Last 5
    $healthValues = $last5 | ForEach-Object { [double]$_.health_score }
    $avgDelta = 0
    for ($i = 1; $i -lt $healthValues.Count; $i++) {
        $avgDelta += ($healthValues[$i] - $healthValues[$i-1])
    }
    $avgDelta = $avgDelta / [math]::Max(1, $healthValues.Count - 1)

    $trend = if ($avgDelta -gt 1) { "improving" }
             elseif ($avgDelta -lt -1) { "regressing" }
             elseif ([math]::Abs($avgDelta) -le 1) { "flat" }
             else { "unknown" }

    return @{ Trend = $trend; AvgDelta = [math]::Round($avgDelta, 2); Entries = $entries; Last5 = $last5 }
}

function Invoke-Layer1Classification {
    param([hashtable]$Stats, [hashtable]$Trajectory, [array]$StuckReqs, [hashtable]$Summary)

    $category = "unknown"
    $confidence = "low"

    $timeoutCount = if ($Stats.ErrorCounts["watchdog_timeout"]) { $Stats.ErrorCounts["watchdog_timeout"] } else { 0 }
    $retryCount = if ($Stats.ErrorCounts["retry"]) { $Stats.ErrorCounts["retry"] } else { 0 }
    $quotaCount = if ($Stats.ErrorCounts["quota"]) { $Stats.ErrorCounts["quota"] } else { 0 }
    $buildFailCount = if ($Stats.ErrorCounts["build_fail"]) { $Stats.ErrorCounts["build_fail"] } else { 0 }
    $regressionCount = if ($Stats.ErrorCounts["regression"]) { $Stats.ErrorCounts["regression"] } else { 0 }

    # Classify based on dominant error pattern
    if ($quotaCount -ge 3) {
        $category = "quota_exhaustion"; $confidence = "high"
    } elseif ($timeoutCount -ge 3) {
        $category = "phase_timeout"; $confidence = "high"
    } elseif ($regressionCount -ge 2 -and $Trajectory.Trend -eq "regressing") {
        $category = "regression_loop"; $confidence = "high"
    } elseif ($buildFailCount -ge 3) {
        $category = "build_loop"; $confidence = "high"
    } elseif ($retryCount -ge 5 -and $Stats.AgentFailures.Count -gt 0) {
        # Find dominant failing agent
        $worstAgent = ($Stats.AgentFailures.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
        $category = "agent_failures"; $confidence = "medium"
    } elseif ($StuckReqs.Count -gt 0 -and $Trajectory.Trend -eq "flat" -and $Stats.TotalErrors -lt 5) {
        $category = "stuck_requirements"; $confidence = "medium"
    } elseif ($Trajectory.Trend -eq "flat" -and $Summary.final_health -gt 70) {
        $category = "spec_ambiguity"; $confidence = "low"
    }

    return @{ Category = $category; Confidence = $confidence }
}

# ===========================================
# ROOT-CAUSE DIAGNOSIS - LAYER 2 (AI-assisted)
# ===========================================

function Invoke-SupervisorDiagnosis {
    param(
        [string]$GsdDir,
        [string]$Pipeline,
        [hashtable]$Summary,
        [hashtable]$Stats,
        [string]$Layer1Category,
        [int]$AttemptNumber
    )

    $repoRoot = (Get-Location).Path
    $repoName = Split-Path $repoRoot -Leaf

    # Gather diagnostic files
    $diagContext = "# Supervisor Diagnosis Request (Attempt $AttemptNumber)`n`n"
    $diagContext += "## Pipeline Exit Summary`n"
    $diagContext += "- Pipeline: $Pipeline`n- Exit reason: $($Summary.exit_reason)`n"
    $diagContext += "- Final health: $($Summary.final_health)%`n- Iteration: $($Summary.final_iteration)`n"
    $diagContext += "- Stall count: $($Summary.stall_count)`n- Batch size: $($Summary.batch_size)`n`n"

    $diagContext += "## Error Statistics (Layer 1)`n"
    $diagContext += "- Total errors: $($Stats.TotalErrors)`n"
    $diagContext += "- Layer 1 classification: $Layer1Category`n"
    $diagContext += "- Error counts by type: $(($Stats.ErrorCounts.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', ')`n"
    $diagContext += "- Phase failures: $(($Stats.PhaseFailures.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', ')`n"
    $diagContext += "- Agent failures: $(($Stats.AgentFailures.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', ')`n`n"

    # Read stall diagnosis if exists
    $stallDiagPaths = @(
        (Join-Path $GsdDir "health\stall-diagnosis.md"),
        (Join-Path $GsdDir "blueprint\stall-diagnosis.md")
    )
    foreach ($p in $stallDiagPaths) {
        if (Test-Path $p) {
            $diagContext += "## Existing Stall Diagnosis`n$(Get-Content $p -Raw)`n`n"
        }
    }

    # Read last 3 iteration logs
    $logDir = Join-Path $GsdDir "logs"
    if (Test-Path $logDir) {
        $recentLogs = Get-ChildItem $logDir -Filter "iter*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3
        foreach ($log in $recentLogs) {
            $content = Get-Content $log.FullName -Raw -ErrorAction SilentlyContinue
            if ($content) {
                # Truncate to last 200 lines to keep prompt reasonable
                $lines = $content -split "`n" | Select-Object -Last 200
                $diagContext += "## Log: $($log.Name) (last 200 lines)`n$($lines -join "`n")`n`n"
            }
        }
    }

    # Read recent errors.jsonl entries
    $errFile = Join-Path $GsdDir "logs\errors.jsonl"
    if (Test-Path $errFile) {
        $recentErrs = Get-Content $errFile -ErrorAction SilentlyContinue | Select-Object -Last 20
        $diagContext += "## Recent Errors (errors.jsonl)`n$($recentErrs -join "`n")`n`n"
    }

    $prompt = @"
You are a GSD pipeline failure analyst. Read the diagnostic data below and produce a root-cause analysis.

$diagContext

## Your Task
1. Read ALL the data above carefully
2. Identify the ROOT CAUSE - not just symptoms, but WHY the pipeline failed
3. Determine what specific files/prompts/configs need to change to fix it
4. Output your analysis in this EXACT format (the JSON block MUST be valid JSON):

## Root Cause Analysis
[Your 2-3 sentence explanation of the actual root cause]

## Specific Fix Required
[Describe exactly what needs to change - which files, what content, why]

``json
{
  "root_cause": "one-line summary",
  "category": "$Layer1Category",
  "failing_phase": "phase name or null",
  "failing_agent": "agent name or null",
  "stuck_requirements": [],
  "fix_type": "error_context|decompose_requirements|reorder_queue|clarify_specs|reassign_agent|modify_prompt_hints|escalate",
  "fix_description": "what to change and why",
  "fix_details": {
    "target_files": ["list of files to modify"],
    "error_context_summary": "what agents need to know about previous failures",
    "prompt_hints": "additional instructions for agents",
    "requirements_to_decompose": [],
    "agent_override": null
  }
}
``

Write your analysis to: $GsdDir\supervisor\diagnosis-$AttemptNumber.md
"@

    $diagLogFile = Join-Path $GsdDir "logs\supervisor-diagnosis-$AttemptNumber.log"

    Write-Host "  [MAG] Supervisor: Claude analyzing root cause..." -ForegroundColor Cyan

    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        Send-GsdNotification -Title "Supervisor: Diagnosing" `
            -Message "$repoName | Analyzing failure: $Layer1Category" `
            -Tags "mag" -Priority "default"
    }

    # Use Invoke-WithRetry if available, otherwise direct call
    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "supervisor-diagnosis" `
            -LogFile $diagLogFile -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2 `
            -AllowedTools "Read,Write,Bash"
    } else {
        $output = claude -p $prompt --allowedTools "Read,Write,Bash" 2>&1
        $output | Out-File -FilePath $diagLogFile -Encoding UTF8
        $result = @{ Success = ($LASTEXITCODE -eq 0) }
    }

    # Parse the diagnosis file Claude wrote
    $diagFile = Join-Path $GsdDir "supervisor\diagnosis-$AttemptNumber.md"
    $diagnosis = @{
        RootCause = "Unknown"
        Category = $Layer1Category
        FailingPhase = $null
        FailingAgent = $null
        StuckRequirements = @()
        FixType = "error_context"
        FixDescription = ""
        FixDetails = @{}
    }

    if (Test-Path $diagFile) {
        $diagContent = Get-Content $diagFile -Raw -ErrorAction SilentlyContinue
        # Try to extract JSON block from Claude's output
        if ($diagContent -match '(?s)\{[^{}]*"root_cause"[^{}]*\}') {
            try {
                $parsed = $Matches[0] | ConvertFrom-Json
                $diagnosis.RootCause = $parsed.root_cause
                $diagnosis.Category = if ($parsed.category) { $parsed.category } else { $Layer1Category }
                $diagnosis.FailingPhase = $parsed.failing_phase
                $diagnosis.FailingAgent = $parsed.failing_agent
                $diagnosis.StuckRequirements = if ($parsed.stuck_requirements) { @($parsed.stuck_requirements) } else { @() }
                $diagnosis.FixType = if ($parsed.fix_type) { $parsed.fix_type } else { "error_context" }
                $diagnosis.FixDescription = if ($parsed.fix_description) { $parsed.fix_description } else { "" }
                $diagnosis.FixDetails = if ($parsed.fix_details) { $parsed.fix_details } else { @{} }
            } catch {
                Write-Host "    [!!] Could not parse diagnosis JSON, using Layer 1 classification" -ForegroundColor DarkYellow
            }
        }
    }

    Write-Host "  [OK] Diagnosis: $($diagnosis.RootCause)" -ForegroundColor Green
    return $diagnosis
}

# ===========================================
# FIX APPLICATION - LAYER 3 (AI-assisted)
# ===========================================

function Write-ErrorContextFile {
    param([string]$GsdDir, [hashtable]$Diagnosis, [hashtable]$Stats)
    $ctxPath = Join-Path $GsdDir "supervisor\error-context.md"
    $content = "## CRITICAL: Previous Pipeline Run Failed`n`n"
    $content += "**Root Cause:** $($Diagnosis.RootCause)`n"
    $content += "**Category:** $($Diagnosis.Category)`n`n"

    if ($Diagnosis.FixDescription) {
        $content += "## Fix Applied by Supervisor`n$($Diagnosis.FixDescription)`n`n"
    }

    if ($Diagnosis.StuckRequirements.Count -gt 0) {
        $content += "## Stuck Requirements`nThese requirements have been stuck and need focused attention:`n"
        foreach ($r in $Diagnosis.StuckRequirements) { $content += "- $r`n" }
        $content += "`n"
    }

    # Add recent error details
    if ($Stats.RecentErrors.Count -gt 0) {
        $content += "## Recent Errors (DO NOT repeat these mistakes)`n"
        foreach ($e in $Stats.RecentErrors) {
            $msg = if ($e.message) { $e.message } elseif ($e.reason) { $e.reason } else { $e.type }
            $content += "- [$($e.phase)] $msg`n"
        }
        $content += "`n"
    }

    if ($Diagnosis.FixDetails.prompt_hints) {
        $content += "## Supervisor Instructions`n$($Diagnosis.FixDetails.prompt_hints)`n"
    }

    Set-Content -Path $ctxPath -Value $content -Encoding UTF8
    Write-Host "    [OK] error-context.md written (injected into next prompts)" -ForegroundColor DarkGreen
}

function Update-PromptHints {
    param([string]$GsdDir, [hashtable]$Diagnosis)
    if (-not $Diagnosis.FixDetails.prompt_hints) { return }
    $hintPath = Join-Path $GsdDir "supervisor\prompt-hints.md"
    Set-Content -Path $hintPath -Value $Diagnosis.FixDetails.prompt_hints -Encoding UTF8
    Write-Host "    [OK] prompt-hints.md written" -ForegroundColor DarkGreen
}

function Update-AgentAssignment {
    param([string]$GsdDir, [hashtable]$Diagnosis)
    if (-not $Diagnosis.FixDetails.agent_override) { return }
    $overridePath = Join-Path $GsdDir "supervisor\agent-override.json"
    $override = $Diagnosis.FixDetails.agent_override
    if ($override -is [string]) {
        # Simple format: just an agent name for execute phase
        @{ execute = $override; reason = $Diagnosis.RootCause } | ConvertTo-Json |
            Set-Content $overridePath -Encoding UTF8
    } else {
        $override | ConvertTo-Json | Set-Content $overridePath -Encoding UTF8
    }
    Write-Host "    [OK] agent-override.json written" -ForegroundColor DarkGreen
}

function Invoke-SupervisorFix {
    param(
        [string]$GsdDir,
        [string]$Pipeline,
        [hashtable]$Diagnosis,
        [hashtable]$Stats,
        [int]$AttemptNumber
    )

    $repoRoot = (Get-Location).Path
    $repoName = Split-Path $repoRoot -Leaf
    $fixType = $Diagnosis.FixType

    Write-Host "  [WRENCH] Supervisor: Applying fix ($fixType)..." -ForegroundColor Yellow

    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        Send-GsdNotification -Title "Supervisor: Fixing" `
            -Message "$repoName | $fixType - $($Diagnosis.FixDescription)" `
            -Tags "wrench" -Priority "default"
    }

    # Always write error context (agents should know what failed)
    $supervisorDir = Join-Path $GsdDir "supervisor"
    if (-not (Test-Path $supervisorDir)) { New-Item -ItemType Directory -Path $supervisorDir -Force | Out-Null }
    Write-ErrorContextFile -GsdDir $GsdDir -Diagnosis $Diagnosis -Stats $Stats

    switch ($fixType) {
        "error_context" {
            # Error context file already written above - that's the fix
            Write-Host "    [OK] Error context injected for next run" -ForegroundColor DarkGreen
        }
        "modify_prompt_hints" {
            Update-PromptHints -GsdDir $GsdDir -Diagnosis $Diagnosis
        }
        "reassign_agent" {
            Update-AgentAssignment -GsdDir $GsdDir -Diagnosis $Diagnosis
        }
        "decompose_requirements" {
            # Use Claude to break stuck requirements into smaller pieces
            $stuckList = ($Diagnosis.StuckRequirements | ForEach-Object { "- $_" }) -join "`n"
            $decompPrompt = @"
Read $GsdDir\health\requirements-matrix.json.
These requirements are stuck and need to be decomposed into smaller sub-requirements:
$stuckList

Root cause: $($Diagnosis.RootCause)

For each stuck requirement:
1. Break it into 2-3 smaller, independently completable sub-requirements
2. Update the requirements array in requirements-matrix.json with the new sub-requirements
3. Set the original requirement status to "decomposed" and add a "decomposed_into" field
4. Each sub-requirement should have a unique id (append -a, -b, -c to parent id)

Also write a summary to $GsdDir\supervisor\decomposition-$AttemptNumber.md
"@
            $logFile = Join-Path $GsdDir "logs\supervisor-decompose-$AttemptNumber.log"
            if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
                Invoke-WithRetry -Agent "claude" -Prompt $decompPrompt -Phase "supervisor-decompose" `
                    -LogFile $logFile -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2 `
                    -AllowedTools "Read,Write,Bash" | Out-Null
            } else {
                claude -p $decompPrompt --allowedTools "Read,Write,Bash" 2>&1 |
                    Out-File -FilePath $logFile -Encoding UTF8
            }
            Write-Host "    [OK] Requirements decomposed" -ForegroundColor DarkGreen
        }
        "reorder_queue" {
            # Write hints that the plan phase will pick up
            Update-PromptHints -GsdDir $GsdDir -Diagnosis $Diagnosis
            # Clear the current queue so plan phase regenerates it
            $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
            if (Test-Path $queuePath) { Remove-Item $queuePath -Force }
            Write-Host "    [OK] Queue cleared, will regenerate with hints" -ForegroundColor DarkGreen
        }
        "clarify_specs" {
            # Use Claude to write spec clarification notes
            $clarifyPrompt = @"
Read the following files:
- $GsdDir\health\requirements-matrix.json
- $GsdDir\supervisor\diagnosis-$AttemptNumber.md
- All files in docs\ directory

Root cause: $($Diagnosis.RootCause)

The specifications have ambiguities or contradictions causing the pipeline to stall.
Write a clarification document to $GsdDir\supervisor\spec-clarifications.md that:
1. Lists each ambiguity or contradiction found
2. Provides a definitive resolution for each
3. References the authoritative spec document for each resolution

Then update $GsdDir\supervisor\prompt-hints.md with clear instructions for agents
to follow the clarifications.
"@
            $logFile = Join-Path $GsdDir "logs\supervisor-clarify-$AttemptNumber.log"
            if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
                Invoke-WithRetry -Agent "claude" -Prompt $clarifyPrompt -Phase "supervisor-clarify" `
                    -LogFile $logFile -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2 `
                    -AllowedTools "Read,Write,Bash" | Out-Null
            } else {
                claude -p $clarifyPrompt --allowedTools "Read,Write,Bash" 2>&1 |
                    Out-File -FilePath $logFile -Encoding UTF8
            }
            Write-Host "    [OK] Spec clarifications written" -ForegroundColor DarkGreen
        }
        "escalate" {
            # Don't apply a fix - just escalate
            Write-Host "    [!!] No automated fix available - escalating to user" -ForegroundColor DarkYellow
            return $false
        }
        default {
            # Generic fix: write error context + prompt hints
            Update-PromptHints -GsdDir $GsdDir -Diagnosis $Diagnosis
        }
    }

    # Git commit the fix
    try {
        $fixMsg = "gsd-supervisor: fix attempt $AttemptNumber - $($Diagnosis.FixType): $($Diagnosis.FixDescription)"
        if ($fixMsg.Length -gt 200) { $fixMsg = $fixMsg.Substring(0, 200) }
        git add -A 2>$null
        git commit -m $fixMsg --no-verify 2>$null
    } catch {}

    return $true
}

# ===========================================
# PATTERN MEMORY (cross-project learning)
# ===========================================

function Save-FailurePattern {
    param(
        [string]$Category,
        [string]$RootCause,
        [string]$FixType,
        [string]$FixDescription,
        [bool]$Success,
        [string]$Project
    )
    $memoryDir = Join-Path $env:USERPROFILE ".gsd-global\supervisor"
    if (-not (Test-Path $memoryDir)) { New-Item -ItemType Directory -Path $memoryDir -Force | Out-Null }
    # Write to per-project file to avoid cross-project pattern pollution
    $projectSlug = if ($Project) { $Project -replace '[^a-zA-Z0-9_-]', '_' } else { "global" }
    $memoryFile = Join-Path $memoryDir "pattern-memory-$projectSlug.jsonl"

    $entry = @{
        category = $Category
        root_cause = $RootCause
        fix_type = $FixType
        fix_description = $FixDescription
        success = $Success
        project = $Project
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json -Compress

    Add-Content -Path $memoryFile -Value $entry -Encoding UTF8
}

function Find-KnownFix {
    param([string]$Category, [string]$RootCause)
    $memoryFile = Join-Path $env:USERPROFILE ".gsd-global\supervisor\pattern-memory.jsonl"
    if (-not (Test-Path $memoryFile)) { return $null }

    $patterns = Get-Content $memoryFile -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch {}
    }

    # Find successful fixes for this category
    $matches = $patterns | Where-Object { $_.success -eq $true -and $_.category -eq $Category }
    if ($matches) {
        # Return most recent successful fix for this category
        return $matches | Select-Object -Last 1
    }
    return $null
}

# ===========================================
# ESCALATION
# ===========================================

function New-EscalationReport {
    param(
        [string]$GsdDir,
        [string]$Pipeline,
        [hashtable]$SupervisorState
    )

    $reportPath = Join-Path $GsdDir "supervisor\escalation-report.md"
    $report = "# GSD Supervisor Escalation Report`n`n"
    $report += "**Pipeline:** $Pipeline`n"
    $report += "**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
    $report += "**Total Attempts:** $($SupervisorState.attempt_count)`n`n"

    $report += "## Summary`nAll automated recovery strategies have been exhausted. Human intervention required.`n`n"

    $report += "## Attempts`n"
    if ($SupervisorState.attempts) {
        foreach ($a in $SupervisorState.attempts) {
            $report += "### Attempt $($a.attempt_number): $($a.fix_type)`n"
            $report += "- **Root Cause:** $($a.root_cause)`n"
            $report += "- **Fix Applied:** $($a.fix_description)`n"
            $report += "- **Result:** exit_reason=$($a.exit_reason), health=$($a.exit_health)%`n`n"
        }
    }

    $report += "## Recommended Manual Actions`n"
    $report += "1. Review the diagnosis files in .gsd\supervisor\diagnosis-*.md`n"
    $report += "2. Check .gsd\logs\errors.jsonl for recurring error patterns`n"
    $report += "3. Review .gsd\health\requirements-matrix.json for stuck requirements`n"
    $report += "4. Check if specs in docs\ have contradictions or ambiguities`n"
    $report += "5. Consider running gsd-converge -NoSupervisor with manual adjustments`n"

    Set-Content -Path $reportPath -Value $report -Encoding UTF8
    Write-Host "  [SOS] Escalation report: $reportPath" -ForegroundColor Red
}

# ===========================================
# PIPELINE CONTROL
# ===========================================

function Start-PipelineInNewTerminal {
    param(
        [string]$Pipeline,
        [hashtable]$Params,
        [string]$RepoRoot
    )

    $paramParts = @()
    foreach ($kv in $Params.GetEnumerator()) {
        if ($kv.Value -is [bool] -and $kv.Value) { $paramParts += "-$($kv.Key)" }
        elseif ($kv.Value -is [bool] -and -not $kv.Value) { continue }
        elseif ($null -ne $kv.Value -and $kv.Value -ne "") { $paramParts += "-$($kv.Key) $($kv.Value)" }
    }
    $paramString = $paramParts -join ' '

    $cmd = if ($Pipeline -eq "converge") { "gsd-converge" } else { "gsd-blueprint" }
    $fullCmd = "cd '$RepoRoot'; $cmd $paramString -NoSupervisor"

    Write-Host "  [ROCKET] Launching in new terminal: $cmd $paramString -NoSupervisor" -ForegroundColor Green

    # Launch in a new PowerShell window
    Start-Process powershell -ArgumentList "-NoExit -Command `"$fullCmd`""
}

function Wait-ForPipelineCompletion {
    param(
        [string]$GsdDir,
        [int]$TimeoutMinutes = 0     # 0 = no timeout (rely on pipeline's own limits)
    )

    $summaryPath = Join-Path $GsdDir "supervisor\last-run-summary.json"
    # Remove old summary so we detect fresh completion
    if (Test-Path $summaryPath) { Remove-Item $summaryPath -Force }

    $startTime = Get-Date
    $pollSeconds = 30

    Write-Host "  [HOURGLASS] Waiting for pipeline completion (polling every ${pollSeconds}s)..." -ForegroundColor DarkGray

    while ($true) {
        Start-Sleep -Seconds $pollSeconds

        if (Test-Path $summaryPath) {
            try {
                $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
                if ($summary.exit_reason) {
                    Write-Host "  [OK] Pipeline exited: $($summary.exit_reason) at $($summary.final_health)%" -ForegroundColor Green
                    return $summary
                }
            } catch {}
        }

        # Check timeout
        if ($TimeoutMinutes -gt 0) {
            $elapsed = (Get-Date) - $startTime
            if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
                Write-Host "  [!!] Supervisor timeout after ${TimeoutMinutes}m" -ForegroundColor Red
                return @{ exit_reason = "supervisor_timeout"; final_health = 0; final_iteration = 0 }
            }
        }

        # Send heartbeat
        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalMinutes % 10 -lt ($pollSeconds / 60)) {
            $mins = [math]::Floor($elapsed.TotalMinutes)
            Write-Host "    Still waiting... (${mins}m elapsed)" -ForegroundColor DarkGray
        }
    }
}

# ===========================================
# MAIN SUPERVISOR LOOP
# ===========================================

function Invoke-SupervisorLoop {
    param(
        [string]$Pipeline,          # "converge" or "blueprint"
        [hashtable]$OriginalParams, # all params passed to gsd-converge/gsd-blueprint
        [int]$MaxAttempts = $script:SUPERVISOR_MAX_ATTEMPTS,
        [int]$TimeoutHours = $script:SUPERVISOR_TIMEOUT_HOURS
    )

    $repoRoot = (Get-Location).Path
    $repoName = Split-Path $repoRoot -Leaf
    $GsdDir = Join-Path $repoRoot ".gsd"
    $GlobalDir = Join-Path $env:USERPROFILE ".gsd-global"
    $supervisorDir = Join-Path $GsdDir "supervisor"

    # Ensure supervisor directory exists
    if (-not (Test-Path $supervisorDir)) { New-Item -ItemType Directory -Path $supervisorDir -Force | Out-Null }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Magenta
    Write-Host "  GSD Supervisor - Autonomous Self-Healing" -ForegroundColor Magenta
    Write-Host "=========================================================" -ForegroundColor Magenta
    Write-Host "  Pipeline: $Pipeline | Max attempts: $MaxAttempts" -ForegroundColor White
    Write-Host ""

    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        Send-GsdNotification -Title "Supervisor Active" `
            -Message "$repoName | $Pipeline | Max $MaxAttempts attempts" `
            -Tags "robot_face" -Priority "low"
    }

    # Load or initialize supervisor state
    $state = Get-SupervisorState -GsdDir $GsdDir
    if (-not $state -or $state.pipeline -ne $Pipeline) {
        $state = @{
            pipeline = $Pipeline
            original_params = $OriginalParams
            supervisor_budget = $MaxAttempts
            attempt_count = 0
            attempts = @()
            strategies_tried = @()
            escalated = $false
            started = (Get-Date -Format "o")
        }
    }

    $supervisorStart = Get-Date
    $lastHealth = 0

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $state.attempt_count = $attempt
        Write-Host "  --- Supervisor Attempt $attempt/$MaxAttempts ---" -ForegroundColor Magenta

        # Time budget check
        $elapsedHours = ((Get-Date) - $supervisorStart).TotalHours
        if ($elapsedHours -ge $TimeoutHours) {
            Write-Host "  [!!] Supervisor time budget exhausted (${TimeoutHours}h)" -ForegroundColor Red
            break
        }

        # Run pipeline (attempt 1 = normal, subsequent = after fix)
        if ($attempt -eq 1) {
            # First attempt: run pipeline directly in this process
            Write-Host "  [ROCKET] Running $Pipeline pipeline..." -ForegroundColor Cyan
            $pipelineScript = if ($Pipeline -eq "converge") {
                Join-Path $GlobalDir "scripts\convergence-loop.ps1"
            } else {
                Join-Path $GlobalDir "blueprint\scripts\blueprint-pipeline.ps1"
            }

            # Build params for the pipeline
            $pipelineParams = @{}
            foreach ($kv in $OriginalParams.GetEnumerator()) {
                $pipelineParams[$kv.Key] = $kv.Value
            }

            try {
                & $pipelineScript @pipelineParams
            } catch {
                Write-Host "  [!!] Pipeline threw exception: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            # Clear stale engine-status.json before restart
            $engineStatusPath = Join-Path $GsdDir "health\engine-status.json"
            if (Test-Path $engineStatusPath) { Remove-Item $engineStatusPath -Force -ErrorAction SilentlyContinue }

            # Subsequent attempts: launch in new terminal and wait
            Start-PipelineInNewTerminal -Pipeline $Pipeline -Params $OriginalParams -RepoRoot $repoRoot

            # Wait for pipeline to finish (monitor last-run-summary.json)
            $pipelineTimeout = if ($OriginalParams.MaxIterations) {
                $OriginalParams.MaxIterations * 15  # ~15 min per iteration max
            } else { 300 }  # 5 hours default
            Wait-ForPipelineCompletion -GsdDir $GsdDir -TimeoutMinutes $pipelineTimeout | Out-Null
        }

        # Read exit state
        $summary = Get-PipelineExitReason -GsdDir $GsdDir
        if (-not $summary) {
            $summary = @{ exit_reason = "unknown"; final_health = 0; final_iteration = 0; stall_count = 0; batch_size = 8 }
        }

        Write-Host "  Pipeline result: $($summary.exit_reason) at $($summary.final_health)%" -ForegroundColor White

        # SUCCESS: Pipeline converged!
        if ($summary.exit_reason -eq "converged") {
            Write-Host "  [PARTY] Pipeline CONVERGED!" -ForegroundColor Green

            # Save successful pattern if this was a recovery (attempt > 1)
            if ($attempt -gt 1 -and $state.attempts.Count -gt 0) {
                $lastAttemptInfo = $state.attempts[-1]
                Save-FailurePattern -Category $lastAttemptInfo.category `
                    -RootCause $lastAttemptInfo.root_cause `
                    -FixType $lastAttemptInfo.fix_type `
                    -FixDescription $lastAttemptInfo.fix_description `
                    -Success $true -Project $repoName

                if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
                    Send-GsdNotification -Title "Supervisor: RECOVERED!" `
                        -Message "$repoName | Converged at $($summary.final_health)% after $attempt attempts" `
                        -Tags "white_check_mark,robot_face" -Priority "high"
                }
            }

            # Clean up supervisor state on success
            Save-SupervisorState -GsdDir $GsdDir -State $state
            return
        }

        # Health monotonicity check (after 3+ attempts, health should be going up)
        if ($attempt -ge 2 -and $summary.final_health -lt $lastHealth -and $lastHealth -gt 0) {
            Write-Host "  [!!] Health declining across supervisor attempts ($lastHealth% -> $($summary.final_health)%). Escalating." -ForegroundColor Red
            break
        }
        $lastHealth = [double]$summary.final_health

        # ANALYZE: Parse errors and classify
        Write-Host "  [MAG] Analyzing failure..." -ForegroundColor Cyan
        $stats = Get-ErrorStatistics -GsdDir $GsdDir
        $trajectory = Get-HealthTrajectory -GsdDir $GsdDir
        $stuckReqs = Get-StuckRequirements -GsdDir $GsdDir
        $layer1 = Invoke-Layer1Classification -Stats $stats -Trajectory $trajectory `
            -StuckReqs $stuckReqs -Summary $summary

        Write-Host "    Layer 1: $($layer1.Category) (confidence: $($layer1.Confidence))" -ForegroundColor DarkGray

        # Check pattern memory for known fix
        $knownFix = Find-KnownFix -Category $layer1.Category -RootCause ""
        if ($knownFix -and $knownFix.fix_type -notin $state.strategies_tried) {
            Write-Host "    [BRAIN] Known fix found from pattern memory: $($knownFix.fix_type)" -ForegroundColor Cyan
            $diagnosis = @{
                RootCause = $knownFix.root_cause
                Category = $knownFix.category
                FixType = $knownFix.fix_type
                FixDescription = $knownFix.fix_description
                FixDetails = @{ prompt_hints = $knownFix.fix_description }
                StuckRequirements = @()
                FailingPhase = $null
                FailingAgent = $null
            }
        } else {
            # ROOT-CAUSE: AI-assisted deep diagnosis
            $diagnosis = Invoke-SupervisorDiagnosis -GsdDir $GsdDir -Pipeline $Pipeline `
                -Summary $summary -Stats $stats -Layer1Category $layer1.Category -AttemptNumber $attempt
        }

        # Check if this fix type was already tried
        if ($diagnosis.FixType -in $state.strategies_tried) {
            # Escalate the fix type to something more aggressive
            $escalationChain = @("error_context", "modify_prompt_hints", "decompose_requirements",
                                 "reorder_queue", "reassign_agent", "clarify_specs", "escalate")
            $nextFix = $escalationChain | Where-Object { $_ -notin $state.strategies_tried } | Select-Object -First 1
            if ($nextFix) {
                Write-Host "    Fix '$($diagnosis.FixType)' already tried, escalating to '$nextFix'" -ForegroundColor DarkYellow
                $diagnosis.FixType = $nextFix
            } else {
                Write-Host "    All strategies exhausted" -ForegroundColor Red
                $diagnosis.FixType = "escalate"
            }
        }

        # Record attempt
        $attemptRecord = @{
            attempt_number = $attempt
            root_cause = $diagnosis.RootCause
            category = $diagnosis.Category
            fix_type = $diagnosis.FixType
            fix_description = $diagnosis.FixDescription
            exit_reason = $summary.exit_reason
            exit_health = $summary.final_health
            exit_iteration = $summary.final_iteration
            timestamp = (Get-Date -Format "o")
        }
        $state.attempts += $attemptRecord
        $state.strategies_tried += $diagnosis.FixType

        # ESCALATE check
        if ($diagnosis.FixType -eq "escalate") {
            Write-Host "  [SOS] Escalating to user" -ForegroundColor Red
            $state.escalated = $true
            Save-SupervisorState -GsdDir $GsdDir -State $state
            New-EscalationReport -GsdDir $GsdDir -Pipeline $Pipeline -SupervisorState $state

            if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
                Send-GsdNotification -Title "Supervisor: NEEDS HUMAN" `
                    -Message "$repoName | All $attempt strategies failed. See escalation-report.md" `
                    -Tags "sos" -Priority "urgent"
            }
            return
        }

        # APPLY FIX
        $fixSuccess = Invoke-SupervisorFix -GsdDir $GsdDir -Pipeline $Pipeline `
            -Diagnosis $diagnosis -Stats $stats -AttemptNumber $attempt

        if (-not $fixSuccess) {
            Write-Host "  [!!] Fix application failed, escalating" -ForegroundColor Red
            break
        }

        # Save state before restart
        Save-SupervisorState -GsdDir $GsdDir -State $state

        # Clear errors.jsonl for fresh tracking in next run
        $errFile = Join-Path $GsdDir "logs\errors.jsonl"
        if (Test-Path $errFile) {
            $backupFile = Join-Path $GsdDir "logs\errors-attempt-$attempt.jsonl"
            Copy-Item $errFile $backupFile -Force
            Set-Content $errFile "" -Encoding UTF8
        }

        Write-Host ""
        Write-Host "  [RECYCLE] Restarting pipeline with fix applied..." -ForegroundColor Yellow
        Write-Host ""
    }

    # All attempts exhausted
    if (-not $state.escalated) {
        $state.escalated = $true
        Save-SupervisorState -GsdDir $GsdDir -State $state
        New-EscalationReport -GsdDir $GsdDir -Pipeline $Pipeline -SupervisorState $state

        if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
            Send-GsdNotification -Title "Supervisor: NEEDS HUMAN" `
                -Message "$repoName | All $MaxAttempts attempts exhausted. See escalation-report.md" `
                -Tags "sos" -Priority "urgent"
        }
    }
}
'@

Set-Content -Path "$GsdGlobalDir\lib\modules\supervisor.ps1" -Value $supervisorLib -Encoding UTF8
Write-Host "   [OK] lib\modules\supervisor.ps1" -ForegroundColor DarkGreen

# ========================================================
# SUPERVISOR WRAPPER: Convergence
# ========================================================

Write-Host "[SYNC] Creating supervisor wrappers..." -ForegroundColor Yellow

$supervisorConverge = @'
<#
.SYNOPSIS
    GSD Supervisor Wrapper for Convergence Pipeline
    Wraps convergence-loop.ps1 with autonomous self-healing recovery.
#>
param(
    [int]$MaxIterations = 20, [int]$StallThreshold = 3, [int]$BatchSize = 8,
    [int]$ThrottleSeconds = 30,
    [string]$NtfyTopic = "",
    [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch, [switch]$SkipSpecCheck,
    [switch]$AutoResolve, [switch]$ForceCodeReview,
    [int]$SupervisorAttempts = 5,
    [switch]$NoSupervisor
)

$GlobalDir = Join-Path $env:USERPROFILE ".gsd-global"

# Load modules
. "$GlobalDir\lib\modules\resilience.ps1"
if (Test-Path "$GlobalDir\lib\modules\supervisor.ps1") {
    . "$GlobalDir\lib\modules\supervisor.ps1"
}

if ($NoSupervisor -or -not (Get-Command Invoke-SupervisorLoop -ErrorAction SilentlyContinue)) {
    # Direct pipeline invocation (backward compatible)
    & "$GlobalDir\scripts\convergence-loop.ps1" -MaxIterations $MaxIterations `
        -StallThreshold $StallThreshold -BatchSize $BatchSize `
        -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic `
        -DryRun:$DryRun -SkipInit:$SkipInit -SkipResearch:$SkipResearch `
        -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve -ForceCodeReview:$ForceCodeReview
    return
}

$originalParams = @{
    MaxIterations = $MaxIterations
    StallThreshold = $StallThreshold
    BatchSize = $BatchSize
    ThrottleSeconds = $ThrottleSeconds
    NtfyTopic = $NtfyTopic
    DryRun = $DryRun.IsPresent
    SkipInit = $SkipInit.IsPresent
    SkipResearch = $SkipResearch.IsPresent
    SkipSpecCheck = $SkipSpecCheck.IsPresent
    AutoResolve = $AutoResolve.IsPresent
    ForceCodeReview = $ForceCodeReview.IsPresent
}

Invoke-SupervisorLoop -Pipeline "converge" -OriginalParams $originalParams `
    -MaxAttempts $SupervisorAttempts
'@

Set-Content -Path "$GsdGlobalDir\scripts\supervisor-converge.ps1" -Value $supervisorConverge -Encoding UTF8
Write-Host "   [OK] scripts\supervisor-converge.ps1" -ForegroundColor DarkGreen

# ========================================================
# SUPERVISOR WRAPPER: Blueprint
# ========================================================

$supervisorBlueprint = @'
<#
.SYNOPSIS
    GSD Supervisor Wrapper for Blueprint Pipeline
    Wraps blueprint-pipeline.ps1 with autonomous self-healing recovery.
#>
param(
    [int]$MaxIterations = 30, [int]$StallThreshold = 3, [int]$BatchSize = 15,
    [int]$ThrottleSeconds = 30,
    [string]$NtfyTopic = "",
    [switch]$DryRun, [switch]$BlueprintOnly, [switch]$BuildOnly, [switch]$VerifyOnly,
    [switch]$SkipSpecCheck, [switch]$AutoResolve,
    [int]$SupervisorAttempts = 5,
    [switch]$NoSupervisor
)

$GlobalDir = Join-Path $env:USERPROFILE ".gsd-global"

# Load modules
. "$GlobalDir\lib\modules\resilience.ps1"
if (Test-Path "$GlobalDir\lib\modules\supervisor.ps1") {
    . "$GlobalDir\lib\modules\supervisor.ps1"
}

if ($NoSupervisor -or -not (Get-Command Invoke-SupervisorLoop -ErrorAction SilentlyContinue)) {
    & "$GlobalDir\blueprint\scripts\blueprint-pipeline.ps1" -MaxIterations $MaxIterations `
        -StallThreshold $StallThreshold -BatchSize $BatchSize `
        -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic `
        -DryRun:$DryRun -BlueprintOnly:$BlueprintOnly -BuildOnly:$BuildOnly `
        -VerifyOnly:$VerifyOnly -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve
    return
}

$originalParams = @{
    MaxIterations = $MaxIterations
    StallThreshold = $StallThreshold
    BatchSize = $BatchSize
    ThrottleSeconds = $ThrottleSeconds
    NtfyTopic = $NtfyTopic
    DryRun = $DryRun.IsPresent
    BlueprintOnly = $BlueprintOnly.IsPresent
    BuildOnly = $BuildOnly.IsPresent
    VerifyOnly = $VerifyOnly.IsPresent
    SkipSpecCheck = $SkipSpecCheck.IsPresent
    AutoResolve = $AutoResolve.IsPresent
}

Invoke-SupervisorLoop -Pipeline "blueprint" -OriginalParams $originalParams `
    -MaxAttempts $SupervisorAttempts
'@

Set-Content -Path "$GsdGlobalDir\blueprint\scripts\supervisor-blueprint.ps1" -Value $supervisorBlueprint -Encoding UTF8
Write-Host "   [OK] blueprint\scripts\supervisor-blueprint.ps1" -ForegroundColor DarkGreen

# ========================================================
# UPDATE PROFILE FUNCTIONS
# ========================================================

Write-Host "[GEAR] Updating profile functions for supervisor..." -ForegroundColor Yellow

$profileFunctionsPath = "$GsdGlobalDir\scripts\gsd-profile-functions.ps1"
$profileContent = ""
if (Test-Path $profileFunctionsPath) {
    $profileContent = Get-Content $profileFunctionsPath -Raw
}

# Add -SupervisorAttempts and -NoSupervisor to gsd-converge
if ($profileContent -notmatch "SupervisorAttempts") {
    # Replace gsd-converge function to point to supervisor wrapper
    $oldConvergePattern = '(?s)function gsd-converge\s*\{.+?\n\}'
    $newConverge = @'
function gsd-converge {
    param(
        [int]$MaxIterations = 20, [int]$StallThreshold = 3, [int]$BatchSize = 8,
        [int]$ThrottleSeconds = 30, [string]$NtfyTopic = "",
        [switch]$DryRun, [switch]$SkipInit, [switch]$SkipResearch,
        [switch]$SkipSpecCheck, [switch]$AutoResolve, [switch]$ForceCodeReview,
        [int]$SupervisorAttempts = 5, [switch]$NoSupervisor
    )
    $script = "$env:USERPROFILE\.gsd-global\scripts\supervisor-converge.ps1"
    if (-not (Test-Path $script)) { $script = "$env:USERPROFILE\.gsd-global\scripts\convergence-loop.ps1" }
    $gsdArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script,
        "-MaxIterations", $MaxIterations, "-StallThreshold", $StallThreshold, "-BatchSize", $BatchSize,
        "-ThrottleSeconds", $ThrottleSeconds, "-SupervisorAttempts", $SupervisorAttempts)
    if ($NtfyTopic)    { $gsdArgs += "-NtfyTopic"; $gsdArgs += $NtfyTopic }
    if ($DryRun)       { $gsdArgs += "-DryRun" }
    if ($SkipInit)     { $gsdArgs += "-SkipInit" }
    if ($SkipResearch) { $gsdArgs += "-SkipResearch" }
    if ($SkipSpecCheck){ $gsdArgs += "-SkipSpecCheck" }
    if ($AutoResolve)  { $gsdArgs += "-AutoResolve" }
    if ($ForceCodeReview) { $gsdArgs += "-ForceCodeReview" }
    if ($NoSupervisor) { $gsdArgs += "-NoSupervisor" }
    # Use pwsh (PS7) if available, otherwise fall back to current session
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { & pwsh @gsdArgs } else { & $script -MaxIterations $MaxIterations -StallThreshold $StallThreshold -BatchSize $BatchSize -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic -DryRun:$DryRun -SkipInit:$SkipInit -SkipResearch:$SkipResearch -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve -ForceCodeReview:$ForceCodeReview -SupervisorAttempts $SupervisorAttempts -NoSupervisor:$NoSupervisor }
}
'@

    $oldBlueprintPattern = '(?s)function gsd-blueprint\s*\{.+?\n\}'
    $newBlueprint = @'
function gsd-blueprint {
    param(
        [int]$MaxIterations = 30, [int]$StallThreshold = 3, [int]$BatchSize = 15,
        [int]$ThrottleSeconds = 30, [string]$NtfyTopic = "",
        [switch]$DryRun, [switch]$BlueprintOnly, [switch]$BuildOnly,
        [switch]$VerifyOnly, [switch]$SkipSpecCheck, [switch]$AutoResolve,
        [int]$SupervisorAttempts = 5, [switch]$NoSupervisor
    )
    $script = "$env:USERPROFILE\.gsd-global\blueprint\scripts\supervisor-blueprint.ps1"
    if (-not (Test-Path $script)) { $script = "$env:USERPROFILE\.gsd-global\blueprint\scripts\blueprint-pipeline.ps1" }
    $gsdArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script,
        "-MaxIterations", $MaxIterations, "-StallThreshold", $StallThreshold, "-BatchSize", $BatchSize,
        "-ThrottleSeconds", $ThrottleSeconds, "-SupervisorAttempts", $SupervisorAttempts)
    if ($NtfyTopic)    { $gsdArgs += "-NtfyTopic"; $gsdArgs += $NtfyTopic }
    if ($DryRun)       { $gsdArgs += "-DryRun" }
    if ($BlueprintOnly){ $gsdArgs += "-BlueprintOnly" }
    if ($BuildOnly)    { $gsdArgs += "-BuildOnly" }
    if ($VerifyOnly)   { $gsdArgs += "-VerifyOnly" }
    if ($SkipSpecCheck){ $gsdArgs += "-SkipSpecCheck" }
    if ($AutoResolve)  { $gsdArgs += "-AutoResolve" }
    if ($NoSupervisor) { $gsdArgs += "-NoSupervisor" }
    # Use pwsh (PS7) if available, otherwise fall back to current session
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { & pwsh @gsdArgs } else { & $script -MaxIterations $MaxIterations -StallThreshold $StallThreshold -BatchSize $BatchSize -ThrottleSeconds $ThrottleSeconds -NtfyTopic $NtfyTopic -DryRun:$DryRun -BlueprintOnly:$BlueprintOnly -BuildOnly:$BuildOnly -VerifyOnly:$VerifyOnly -SkipSpecCheck:$SkipSpecCheck -AutoResolve:$AutoResolve -SupervisorAttempts $SupervisorAttempts -NoSupervisor:$NoSupervisor }
}
'@

    # Overwrite the profile functions file with updated versions
    if ($profileContent -match 'function gsd-converge') {
        $profileContent = $profileContent -replace '(?s)function gsd-converge\s*\{.+?\n\}', $newConverge
    } else {
        $profileContent += "`n$newConverge`n"
    }
    if ($profileContent -match 'function gsd-blueprint') {
        $profileContent = $profileContent -replace '(?s)function gsd-blueprint\s*\{.+?\n\}', $newBlueprint
    } else {
        $profileContent += "`n$newBlueprint`n"
    }

    Set-Content -Path $profileFunctionsPath -Value $profileContent -Encoding UTF8
    Write-Host "   [OK] Profile functions updated (gsd-converge, gsd-blueprint -> supervisor)" -ForegroundColor DarkGreen

    # Re-register in all profile files
    $profilePaths = @(
        [System.IO.Path]::Combine($env:USERPROFILE, "Documents", "PowerShell", "Microsoft.PowerShell_profile.ps1"),
        [System.IO.Path]::Combine($env:USERPROFILE, "Documents", "WindowsPowerShell", "Microsoft.PowerShell_profile.ps1")
    )
    foreach ($pp in $profilePaths) {
        $ppDir = Split-Path $pp -Parent
        if (-not (Test-Path $ppDir)) { New-Item -ItemType Directory -Path $ppDir -Force | Out-Null }
        $dotSource = ". `"$profileFunctionsPath`""
        if ((Test-Path $pp) -and (Get-Content $pp -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($profileFunctionsPath)) {
            continue  # Already sourced
        }
        Add-Content -Path $pp -Value "`n$dotSource" -Encoding UTF8
    }
    Write-Host "   [OK] GSD functions registered in all PowerShell profiles" -ForegroundColor DarkGreen
} else {
    Write-Host "   [OK] Profile functions already have supervisor params" -ForegroundColor DarkGreen
}

# ========================================================
# SUMMARY
# ========================================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] GSD Supervisor - Installed!" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  SELF-HEALING FEATURES:" -ForegroundColor White
Write-Host ""
Write-Host "  [MAG] Log Analysis       Parse errors.jsonl, classify failure patterns" -ForegroundColor White
Write-Host "  [BRAIN] Root-Cause        Claude reads full logs, diagnoses actual cause" -ForegroundColor White
Write-Host "  [WRENCH] Auto-Fix          Modifies prompts/queue/matrix/specs to fix issue" -ForegroundColor White
Write-Host "  [ROCKET] New Terminal      Kills stuck script, launches fresh in new window" -ForegroundColor White
Write-Host "  [RECYCLE] Error Injection   Feeds failure context into next iteration prompts" -ForegroundColor White
Write-Host "  [BRAIN] Pattern Memory    Learns fixes across projects (saves in .gsd-global)" -ForegroundColor White
Write-Host "  [SOS] Escalation       Full report when all strategies exhausted" -ForegroundColor White
Write-Host ""
Write-Host "  NEW PARAMETERS:" -ForegroundColor White
Write-Host "    gsd-converge -SupervisorAttempts 5   # max recovery attempts (default 5)" -ForegroundColor Gray
Write-Host "    gsd-converge -NoSupervisor           # bypass supervisor (direct pipeline)" -ForegroundColor Gray
Write-Host ""
