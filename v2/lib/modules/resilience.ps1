# ===============================================================
# GSD v2.0 Resilience Library - Extends v1.5 resilience with v2 features
# Loads v1.5 resilience first (checkpoint, lock, preflight, file-map)
# then adds per-requirement retry, token tracking, and v2 checkpoint schema
# ===============================================================

# -- Load v1.5 base resilience --
$v15ResiliencePath = Join-Path $env:USERPROFILE ".gsd-global\lib\modules\resilience.ps1"
if (Test-Path $v15ResiliencePath) {
    . $v15ResiliencePath
    Write-Host "  v1.5 resilience loaded (checkpoint, lock, preflight, file-map)" -ForegroundColor DarkGray
}

# -- v2 Configuration --
$script:V2_RETRY_MAX = 3
$script:V2_RETRY_DELAY_SECONDS = 10
$script:V2_REQUIREMENT_TIMEOUT_MINUTES = 45
$script:V2_TOKEN_FEEDBACK_THRESHOLD = 1.5   # Log if actual > 1.5x forecast

# ===========================================
# PER-REQUIREMENT RETRY
# ===========================================

function Invoke-RequirementWithRetry {
    <#
    .SYNOPSIS
        Execute a single requirement with retry logic.
        On failure, tries fallback agents from the router.
    #>
    param(
        [string]$ReqId,
        [string]$Agent,
        [string]$Prompt,
        [string]$StepId,
        [string]$GsdDir,
        [string]$RepoRoot,
        [int]$MaxAttempts = $script:V2_RETRY_MAX,
        [int]$TimeoutMinutes = $script:V2_REQUIREMENT_TIMEOUT_MINUTES,
        [PSObject]$AgentMap = $null
    )

    $result = @{
        Success = $false
        ReqId = $ReqId
        Attempts = 0
        FinalAgent = $Agent
        Error = $null
        Output = $null
        TokenData = $null
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result.Attempts = $attempt

        Write-Host "    [$Agent] $ReqId (attempt $attempt/$MaxAttempts)..." -ForegroundColor DarkGray -NoNewline

        $agentResult = Invoke-Agent -Agent $Agent -Prompt $Prompt -StepId $StepId `
            -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes $TimeoutMinutes

        if ($agentResult.Success) {
            Write-Host " OK ($($agentResult.DurationSeconds)s)" -ForegroundColor Green
            $result.Success = $true
            $result.FinalAgent = $Agent
            $result.Output = $agentResult.Output
            $result.TokenData = $agentResult.TokenData
            return $result
        }

        Write-Host " FAIL ($($agentResult.Error))" -ForegroundColor Red
        $result.Error = $agentResult.Error

        # Don't retry auth errors
        if ($agentResult.Error -eq "auth_error") { break }

        # Try fallback agent
        if ($attempt -lt $MaxAttempts -and $AgentMap) {
            $fallback = Get-FallbackAgent -Agent $Agent -AgentMap $AgentMap
            if ($fallback -and $fallback -ne $Agent) {
                Write-Host "    [ROTATE] $Agent -> $fallback" -ForegroundColor Yellow
                $Agent = $fallback
            }
        }

        # Wait before retry
        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $script:V2_RETRY_DELAY_SECONDS
        }
    }

    # Log failure
    $errorEntry = @{
        type = "requirement_failed"
        req_id = $ReqId
        step = $StepId
        agent = $Agent
        attempts = $result.Attempts
        error = $result.Error
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json -Compress

    $errorsPath = Join-Path $GsdDir "logs\errors.jsonl"
    $logsDir = Split-Path $errorsPath -Parent
    if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
    Add-Content -Path $errorsPath -Value $errorEntry -Encoding UTF8

    return $result
}

# ===========================================
# TOKEN USAGE TRACKING (v2)
# ===========================================

function Save-TokenUsage {
    <#
    .SYNOPSIS
        Log a single agent call's token usage to the append-only JSONL.
    #>
    param(
        [string]$StepId,
        [string]$ReqId,
        [string]$Agent,
        [PSObject]$TokenData,
        [bool]$Success,
        [int]$DurationSeconds
    )

    if (-not $TokenData) { return }

    $entry = @{
        timestamp = (Get-Date -Format "o")
        step = $StepId
        req_id = $ReqId
        agent = $Agent
        success = $Success
        tokens = @{
            input = if ($TokenData.Tokens) { $TokenData.Tokens.input } else { 0 }
            output = if ($TokenData.Tokens) { $TokenData.Tokens.output } else { 0 }
        }
        duration_seconds = $DurationSeconds
    } | ConvertTo-Json -Compress

    $usagePath = Join-Path $GsdDir "costs\token-usage.jsonl"
    $costsDir = Split-Path $usagePath -Parent
    if (-not (Test-Path $costsDir)) { New-Item -ItemType Directory -Path $costsDir -Force | Out-Null }
    Add-Content -Path $usagePath -Value $entry -Encoding UTF8
}

function Log-TokenFeedback {
    <#
    .SYNOPSIS
        Log actual vs forecast token usage for calibration feedback loop.
    #>
    param(
        [string]$ReqId,
        [string]$Phase,
        [int]$ActualInput,
        [int]$ActualOutput,
        [int]$ForecastInput,
        [int]$ForecastOutput,
        [string]$GsdDir
    )

    $inputRatio = if ($ForecastInput -gt 0) { $ActualInput / $ForecastInput } else { 0 }
    $outputRatio = if ($ForecastOutput -gt 0) { $ActualOutput / $ForecastOutput } else { 0 }

    # Only log if significantly over forecast
    if ($inputRatio -gt $script:V2_TOKEN_FEEDBACK_THRESHOLD -or
        $outputRatio -gt $script:V2_TOKEN_FEEDBACK_THRESHOLD) {

        $entry = @{
            req_id = $ReqId
            phase = $Phase
            actual = @{ input = $ActualInput; output = $ActualOutput }
            forecast = @{ input = $ForecastInput; output = $ForecastOutput }
            ratio = @{ input = [math]::Round($inputRatio, 2); output = [math]::Round($outputRatio, 2) }
            timestamp = (Get-Date -Format "o")
        } | ConvertTo-Json -Compress

        $feedbackPath = Join-Path $GsdDir "requirements\token-feedback.jsonl"
        Add-Content -Path $feedbackPath -Value $entry -Encoding UTF8
    }
}

# ===========================================
# V2 CHECKPOINT (extends v1.5)
# ===========================================

function Save-V2Checkpoint {
    <#
    .SYNOPSIS
        Save v2-specific checkpoint with step tracking.
    #>
    param(
        [string]$GsdDir,
        [string]$StepId,
        [int]$Iteration = 0,
        [double]$Health = 0,
        [array]$CompletedSteps = @(),
        [string]$Status = "in_progress"
    )

    $checkpointFile = Join-Path $GsdDir ".gsd-checkpoint.json"
    @{
        pipeline = "v2"
        step = $StepId
        iteration = $Iteration
        health = $Health
        completed_steps = $CompletedSteps
        status = $Status
        timestamp = (Get-Date -Format "o")
        pid = $PID
    } | ConvertTo-Json | Set-Content $checkpointFile -Encoding UTF8
}

# ===========================================
# JSON SAFETY (reuse v1.5 Test-JsonFile if available)
# ===========================================

if (-not (Get-Command Test-JsonFile -ErrorAction SilentlyContinue)) {
    function Test-JsonFile {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return $false }
        try {
            $null = Get-Content $Path -Raw | ConvertFrom-Json
            return $true
        }
        catch { return $false }
    }
}

Write-Host "  v2.0 resilience loaded (per-requirement retry, token tracking)" -ForegroundColor DarkGray
