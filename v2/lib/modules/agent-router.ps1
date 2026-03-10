# ===============================================================
# GSD v2.0 Agent Router - Round-robin assignment + alternation tracking
# Ensures no agent is used in consecutive steps; distributes load
# ===============================================================

# -- State --
$script:AgentLastUsedStep = @{}          # agent -> last step number used
$script:AgentCallCount = @{}             # agent -> total calls this session
$script:AgentQuotaExhausted = @{}        # agent -> $true if quota hit
$script:RoundRobinIndex = @{}            # pool_key -> next index

# -- Agent Pools --
$script:TIER1_AGENTS = @("claude", "codex", "gemini")
$script:TIER2_AGENTS = @("kimi", "deepseek", "glm5", "minimax")
$script:ALL_AGENTS   = @("claude", "codex", "gemini", "kimi", "deepseek", "glm5", "minimax")

function Initialize-AgentRouter {
    <#
    .SYNOPSIS
        Reset router state for a new pipeline run.
    #>
    $script:AgentLastUsedStep = @{}
    $script:AgentCallCount = @{}
    $script:AgentQuotaExhausted = @{}
    $script:RoundRobinIndex = @{}
    foreach ($a in $script:ALL_AGENTS) {
        $script:AgentCallCount[$a] = 0
        $script:AgentQuotaExhausted[$a] = $false
    }
    Write-Host "  Agent router initialized (7 agents across 2 tiers)" -ForegroundColor DarkGray
}

function Get-StepAgent {
    <#
    .SYNOPSIS
        Returns the assigned agent for a sequential (single-agent) step.
        Reads from agent-map.json step_assignments.
    .PARAMETER StepId
        Step identifier, e.g. "01-spec-quality-gate"
    .PARAMETER AgentMap
        Parsed agent-map.json object
    #>
    param(
        [string]$StepId,
        [PSObject]$AgentMap
    )

    $assignment = $AgentMap.step_assignments.$StepId
    if (-not $assignment) {
        Write-Host "    [WARN] No assignment for step $StepId, defaulting to claude" -ForegroundColor DarkYellow
        return "claude"
    }

    # Single-agent step
    if ($assignment.agent) {
        $agent = $assignment.agent
        # Check if quota exhausted, try fallback within same tier
        if ($script:AgentQuotaExhausted[$agent]) {
            $fallback = Get-FallbackAgent -Agent $agent -AgentMap $AgentMap
            if ($fallback) {
                Write-Host "    [ROTATE] $agent quota exhausted -> $fallback" -ForegroundColor Yellow
                return $fallback
            }
        }
        return $agent
    }

    # Multi-agent step (shouldn't use this function)
    Write-Host "    [WARN] Step $StepId is multi-agent, use Get-WaveAgents instead" -ForegroundColor DarkYellow
    return $assignment.agents[0]
}

function Get-WaveAgents {
    <#
    .SYNOPSIS
        Returns ordered list of agents for a wave-parallel step.
        Distributes requirements round-robin across the agent pool.
    .PARAMETER StepId
        Step identifier, e.g. "07a-research"
    .PARAMETER RequirementCount
        Number of requirements to distribute in this wave
    .PARAMETER AgentMap
        Parsed agent-map.json object
    #>
    param(
        [string]$StepId,
        [int]$RequirementCount,
        [PSObject]$AgentMap
    )

    $assignment = $AgentMap.step_assignments.$StepId
    if (-not $assignment -or -not $assignment.agents) {
        Write-Host "    [WARN] No wave assignment for $StepId, using all agents" -ForegroundColor DarkYellow
        $pool = $script:ALL_AGENTS
    } else {
        $pool = @($assignment.agents)
    }

    # Filter out quota-exhausted agents
    $available = $pool | Where-Object { -not $script:AgentQuotaExhausted[$_] }
    if ($available.Count -eq 0) {
        Write-Host "    [WARN] All agents in pool exhausted, using full pool anyway" -ForegroundColor DarkYellow
        $available = $pool
    }

    # Round-robin assignment
    $assignments = @()
    $poolKey = $StepId
    if (-not $script:RoundRobinIndex.ContainsKey($poolKey)) {
        $script:RoundRobinIndex[$poolKey] = 0
    }

    for ($i = 0; $i -lt $RequirementCount; $i++) {
        $idx = $script:RoundRobinIndex[$poolKey] % $available.Count
        $assignments += $available[$idx]
        $script:RoundRobinIndex[$poolKey]++
    }

    return $assignments
}

function Get-FallbackAgent {
    <#
    .SYNOPSIS
        Returns the best fallback agent when the primary is unavailable.
    #>
    param(
        [string]$Agent,
        [PSObject]$AgentMap
    )

    # Try same tier first
    $tier = if ($Agent -in $script:TIER1_AGENTS) { $script:TIER1_AGENTS } else { $script:TIER2_AGENTS }
    $fallback = $tier | Where-Object { $_ -ne $Agent -and -not $script:AgentQuotaExhausted[$_] } | Select-Object -First 1

    if ($fallback) { return $fallback }

    # Try other tier
    $otherTier = if ($Agent -in $script:TIER1_AGENTS) { $script:TIER2_AGENTS } else { $script:TIER1_AGENTS }
    $fallback = $otherTier | Where-Object { -not $script:AgentQuotaExhausted[$_] } | Select-Object -First 1

    return $fallback
}

function Set-AgentQuotaExhausted {
    <#
    .SYNOPSIS
        Mark an agent as quota-exhausted. Router will skip it for future assignments.
    #>
    param([string]$Agent)
    $script:AgentQuotaExhausted[$Agent] = $true
    Write-Host "    [QUOTA] $Agent marked as exhausted" -ForegroundColor DarkYellow
}

function Reset-AgentQuota {
    <#
    .SYNOPSIS
        Reset quota status for an agent (e.g., after waiting for reset).
    #>
    param([string]$Agent)
    $script:AgentQuotaExhausted[$Agent] = $false
}

function Record-AgentUsage {
    <#
    .SYNOPSIS
        Record that an agent was used for a step. Updates tracking state.
    #>
    param(
        [string]$Agent,
        [string]$StepId
    )
    $script:AgentLastUsedStep[$Agent] = $StepId
    if (-not $script:AgentCallCount.ContainsKey($Agent)) {
        $script:AgentCallCount[$Agent] = 0
    }
    $script:AgentCallCount[$Agent]++
}

function Get-AgentStats {
    <#
    .SYNOPSIS
        Returns current agent usage statistics for monitoring/notifications.
    #>
    $stats = @()
    foreach ($a in $script:ALL_AGENTS) {
        $stats += @{
            agent = $a
            tier = if ($a -in $script:TIER1_AGENTS) { "quality" } else { "bulk" }
            calls = if ($script:AgentCallCount.ContainsKey($a)) { $script:AgentCallCount[$a] } else { 0 }
            last_step = if ($script:AgentLastUsedStep.ContainsKey($a)) { $script:AgentLastUsedStep[$a] } else { "none" }
            quota_exhausted = if ($script:AgentQuotaExhausted.ContainsKey($a)) { $script:AgentQuotaExhausted[$a] } else { $false }
        }
    }
    return $stats
}

function Invoke-Agent {
    <#
    .SYNOPSIS
        Universal agent invocation. Routes to CLI or REST API based on agent type.
    .PARAMETER Agent
        Agent name: claude, codex, gemini, kimi, deepseek, glm5, minimax
    .PARAMETER Prompt
        The prompt text
    .PARAMETER StepId
        Current step for tracking
    .PARAMETER GsdDir
        .gsd directory for logging
    .PARAMETER RepoRoot
        Project root (for CLI agents working directory)
    .PARAMETER AllowedTools
        Claude-specific: allowed tools list
    .PARAMETER GeminiMode
        Gemini-specific: --approval-mode plan or --yolo
    .PARAMETER TimeoutMinutes
        Watchdog timeout (default: 30)
    #>
    param(
        [string]$Agent,
        [string]$Prompt,
        [string]$StepId,
        [string]$GsdDir,
        [string]$RepoRoot,
        [string]$AllowedTools = "Read,Write,Bash",
        [string]$GeminiMode = "--approval-mode plan",
        [int]$TimeoutMinutes = 30
    )

    $result = @{
        Success = $false
        Output = $null
        RawOutput = $null
        Error = $null
        TokenData = $null
        Agent = $Agent
        StepId = $StepId
        DurationSeconds = 0
    }

    $callStart = Get-Date

    # Route to appropriate invocation method
    if ($Agent -in $script:TIER2_AGENTS) {
        # REST API agents
        $apiResult = Invoke-ApiAgent -Agent $Agent -Prompt $Prompt -TimeoutSec ($TimeoutMinutes * 60)
        $result.Success = $apiResult.Success
        $result.Output = $apiResult.Output
        $result.RawOutput = $apiResult.RawOutput
        $result.Error = $apiResult.Error
        $result.TokenData = $apiResult.TokenData
    }
    else {
        # CLI agents - use watchdog-wrapped process
        $logFile = Join-Path $GsdDir "logs\agent-$StepId-$Agent.log"
        $watchdogMs = $TimeoutMinutes * 60 * 1000

        $promptTempFile = [System.IO.Path]::GetTempFileName()
        $outputTempFile = [System.IO.Path]::GetTempFileName()
        $wrapperScript = [System.IO.Path]::GetTempFileName() + ".ps1"
        Set-Content -Path $promptTempFile -Value $Prompt -Encoding UTF8

        try {
            # Build wrapper script per agent type
            if ($Agent -eq "claude") {
                $wrapperContent = @"
Set-Location '$($RepoRoot -replace "'","''")'
`$prompt = Get-Content '$($promptTempFile -replace "'","''")' -Raw -Encoding UTF8
`$output = claude -p `$prompt --allowedTools $AllowedTools 2>&1
`$output | Out-File -FilePath '$($outputTempFile -replace "'","''")' -Encoding UTF8
exit `$LASTEXITCODE
"@
            } elseif ($Agent -eq "codex") {
                $wrapperContent = @"
Set-Location '$($RepoRoot -replace "'","''")'
`$prompt = Get-Content '$($promptTempFile -replace "'","''")' -Raw -Encoding UTF8
`$output = `$prompt | codex exec --full-auto - 2>&1
`$output | Out-File -FilePath '$($outputTempFile -replace "'","''")' -Encoding UTF8
exit `$LASTEXITCODE
"@
            } elseif ($Agent -eq "gemini") {
                $geminiArgs = $GeminiMode.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) -join ' '
                $wrapperContent = @"
Set-Location '$($RepoRoot -replace "'","''")'
`$prompt = Get-Content '$($promptTempFile -replace "'","''")' -Raw -Encoding UTF8
`$output = `$prompt | gemini $geminiArgs 2>&1
`$output | Out-File -FilePath '$($outputTempFile -replace "'","''")' -Encoding UTF8
exit `$LASTEXITCODE
"@
            }

            Set-Content -Path $wrapperScript -Value $wrapperContent -Encoding UTF8

            $proc = Start-Process -FilePath "powershell.exe" `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$wrapperScript`"" `
                -NoNewWindow -PassThru

            $completed = $proc.WaitForExit($watchdogMs)

            if (-not $completed) {
                # Kill hung process
                try {
                    Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $proc.Id } | ForEach-Object {
                        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
                try { $proc.Kill() } catch {}

                $result.Error = "watchdog_timeout"
                Write-Host "    [TIMEOUT] $Agent hung after ${TimeoutMinutes}m" -ForegroundColor Red
            }
            else {
                $exitCode = $proc.ExitCode
                if (Test-Path $outputTempFile) {
                    $rawOutput = Get-Content $outputTempFile -Raw -ErrorAction SilentlyContinue
                    if ($rawOutput) {
                        $result.Output = $rawOutput -split "`n"
                        $result.RawOutput = $rawOutput
                    }
                }

                # Check for errors
                $outputText = if ($result.RawOutput) { $result.RawOutput } else { "" }
                if ($outputText -match "(unauthorized|auth.*fail|invalid.*key|401)" -and
                    $outputText -notmatch "(rate|quota|resource.exhausted|too.many)") {
                    $result.Error = "auth_error"
                }
                elseif ($outputText -match "(token limit|rate limit|context.*(window|length)|too long|exceeded.*limit|max.*tokens)") {
                    $result.Error = "token_limit"
                }
                elseif ($outputText -match "(429|rate.limit|too.many|quota|resource.exhausted)") {
                    $result.Error = "rate_limit"
                    Set-AgentQuotaExhausted -Agent $Agent
                }
                elseif ($exitCode -ne 0 -or -not $rawOutput -or $rawOutput.Trim().Length -eq 0) {
                    $result.Error = "agent_error_$exitCode"
                }
                else {
                    $result.Success = $true
                }
            }

            # Save log
            if ($result.RawOutput -and $logFile) {
                $logsDir = Split-Path $logFile -Parent
                if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
                $result.RawOutput | Out-File -FilePath $logFile -Encoding UTF8 -Append
            }
        }
        finally {
            Remove-Item $promptTempFile -Force -ErrorAction SilentlyContinue
            Remove-Item $outputTempFile -Force -ErrorAction SilentlyContinue
            Remove-Item $wrapperScript -Force -ErrorAction SilentlyContinue
        }
    }

    $result.DurationSeconds = [int]((Get-Date) - $callStart).TotalSeconds
    Record-AgentUsage -Agent $Agent -StepId $StepId

    return $result
}

Write-Host "  Agent router module loaded (7 agents, 2 tiers)" -ForegroundColor DarkGray
