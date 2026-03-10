# ===============================================================
# GSD v2.0 Wave Executor - Parallel orchestration for wave-based steps
# Handles: 7a (research), 7b (plan), 9a (execute) wave-parallel dispatch
# ===============================================================

function Invoke-WaveParallel {
    <#
    .SYNOPSIS
        Executes a set of requirements in dependency-ordered waves.
        Within each wave, distributes requirements across agents round-robin in parallel.
    .PARAMETER Requirements
        Array of requirement objects to process
    .PARAMETER Waves
        Parsed waves.json — array of wave groups (each wave is an array of REQ-IDs)
    .PARAMETER StepId
        Step identifier for agent routing (e.g., "07a-research")
    .PARAMETER PromptBuilder
        ScriptBlock that takes (requirement, context) and returns the prompt string
    .PARAMETER AgentMap
        Parsed agent-map.json
    .PARAMETER GsdDir
        .gsd directory path
    .PARAMETER RepoRoot
        Project root path
    .PARAMETER MaxConcurrent
        Max parallel jobs within a wave (default from agent-map or 5)
    .PARAMETER CooldownSeconds
        Seconds between waves (default: 10)
    .PARAMETER OnComplete
        Optional ScriptBlock called after each requirement completes: (reqId, result)
    #>
    param(
        [array]$Requirements,
        [array]$Waves,
        [string]$StepId,
        [scriptblock]$PromptBuilder,
        [PSObject]$AgentMap,
        [string]$GsdDir,
        [string]$RepoRoot,
        [int]$MaxConcurrent = 5,
        [int]$CooldownSeconds = 10,
        [scriptblock]$OnComplete = $null
    )

    $totalReqs = ($Waves | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
    $completedReqs = 0
    $failedReqs = @()
    $results = @{}
    $tokenFeedback = @()

    Write-Host "`n  Wave Executor: $StepId" -ForegroundColor Cyan
    Write-Host "  $($Waves.Count) waves, $totalReqs total requirements, max $MaxConcurrent concurrent" -ForegroundColor DarkGray

    for ($waveIdx = 0; $waveIdx -lt $Waves.Count; $waveIdx++) {
        $wave = $Waves[$waveIdx]
        $waveNum = $waveIdx + 1
        Write-Host "`n  --- Wave $waveNum/$($Waves.Count) ($($wave.Count) requirements) ---" -ForegroundColor Cyan

        # Get agent assignments for this wave
        $agents = Get-WaveAgents -StepId $StepId -RequirementCount $wave.Count -AgentMap $AgentMap

        # Build jobs array
        $jobs = @()
        for ($i = 0; $i -lt $wave.Count; $i++) {
            $reqId = $wave[$i]
            $req = $Requirements | Where-Object { $_.id -eq $reqId }
            if (-not $req) {
                Write-Host "    [WARN] Requirement $reqId not found, skipping" -ForegroundColor DarkYellow
                continue
            }
            $agent = $agents[$i]

            # Build context for prompt builder
            $context = @{
                WaveNumber = $waveNum
                TotalWaves = $Waves.Count
                GsdDir = $GsdDir
                RepoRoot = $RepoRoot
                PriorWaveResults = $results
            }

            $prompt = & $PromptBuilder $req $context

            $jobs += @{
                ReqId = $reqId
                Agent = $agent
                Prompt = $prompt
                Index = $i
            }
        }

        # Execute jobs in batches of MaxConcurrent
        $jobBatches = Split-IntoBatches -Items $jobs -BatchSize $MaxConcurrent

        foreach ($batch in $jobBatches) {
            $runningJobs = @()

            # Launch parallel jobs
            foreach ($job in $batch) {
                Write-Host "    [$($job.Agent)] $($job.ReqId)..." -ForegroundColor DarkGray -NoNewline

                # Launch as PowerShell background job
                $scriptBlock = {
                    param($AgentName, $Prompt, $StepId, $GsdDir, $RepoRoot)

                    # Dot-source required modules
                    $modulePath = Join-Path (Split-Path $GsdDir -Parent) "v2\lib\modules"
                    if (Test-Path (Join-Path $modulePath "api-agents.ps1")) {
                        . (Join-Path $modulePath "api-agents.ps1")
                    }

                    # For API agents, call directly
                    if ($AgentName -in @("kimi", "deepseek", "glm5", "minimax")) {
                        $result = Invoke-ApiAgent -Agent $AgentName -Prompt $Prompt -TimeoutSec 1800
                        return $result
                    }

                    # For CLI agents, use wrapper process
                    $promptTempFile = [System.IO.Path]::GetTempFileName()
                    $outputTempFile = [System.IO.Path]::GetTempFileName()
                    Set-Content -Path $promptTempFile -Value $Prompt -Encoding UTF8

                    try {
                        if ($AgentName -eq "claude") {
                            $cmd = "Set-Location '$RepoRoot'; `$p = Get-Content '$promptTempFile' -Raw; `$o = claude -p `$p --allowedTools Read,Write,Bash 2>&1; `$o | Out-File '$outputTempFile' -Encoding UTF8; exit `$LASTEXITCODE"
                        } elseif ($AgentName -eq "codex") {
                            $cmd = "Set-Location '$RepoRoot'; `$p = Get-Content '$promptTempFile' -Raw; `$o = `$p | codex exec --full-auto - 2>&1; `$o | Out-File '$outputTempFile' -Encoding UTF8; exit `$LASTEXITCODE"
                        } elseif ($AgentName -eq "gemini") {
                            $cmd = "Set-Location '$RepoRoot'; `$p = Get-Content '$promptTempFile' -Raw; `$o = `$p | gemini --approval-mode plan 2>&1; `$o | Out-File '$outputTempFile' -Encoding UTF8; exit `$LASTEXITCODE"
                        }

                        $proc = Start-Process -FilePath "powershell.exe" `
                            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`"" `
                            -NoNewWindow -PassThru

                        $completed = $proc.WaitForExit(1800000)  # 30 min timeout

                        if (-not $completed) {
                            try { $proc.Kill() } catch {}
                            return @{ Success = $false; Error = "timeout"; Output = $null; RawOutput = $null }
                        }

                        $output = if (Test-Path $outputTempFile) { Get-Content $outputTempFile -Raw } else { "" }
                        return @{
                            Success = ($proc.ExitCode -eq 0 -and $output -and $output.Trim().Length -gt 0)
                            Output = $output -split "`n"
                            RawOutput = $output
                            Error = if ($proc.ExitCode -ne 0) { "exit_$($proc.ExitCode)" } else { $null }
                        }
                    }
                    finally {
                        Remove-Item $promptTempFile -Force -ErrorAction SilentlyContinue
                        Remove-Item $outputTempFile -Force -ErrorAction SilentlyContinue
                    }
                }

                $psJob = Start-Job -ScriptBlock $scriptBlock `
                    -ArgumentList $job.Agent, $job.Prompt, $StepId, $GsdDir, $RepoRoot

                $runningJobs += @{
                    Job = $psJob
                    ReqId = $job.ReqId
                    Agent = $job.Agent
                    StartTime = Get-Date
                }
            }

            # Wait for all jobs in this batch
            $timeout = 45 * 60  # 45 minute max per batch
            $runningJobs | ForEach-Object {
                $jobResult = $null
                try {
                    $jobResult = Receive-Job -Job $_.Job -Wait -Timeout $timeout -ErrorAction Stop
                } catch {
                    $jobResult = @{ Success = $false; Error = "job_error: $($_.Exception.Message)"; Output = $null }
                } finally {
                    Remove-Job -Job $_.Job -Force -ErrorAction SilentlyContinue
                }

                $reqId = $_.ReqId
                $agent = $_.Agent
                $duration = [int]((Get-Date) - $_.StartTime).TotalSeconds

                if ($jobResult -and $jobResult.Success) {
                    Write-Host " OK (${duration}s)" -ForegroundColor Green
                    $results[$reqId] = $jobResult
                    $completedReqs++

                    # Call OnComplete handler
                    if ($OnComplete) {
                        & $OnComplete $reqId $jobResult
                    }
                }
                else {
                    $errMsg = if ($jobResult) { $jobResult.Error } else { "no_result" }
                    Write-Host " FAIL ($errMsg, ${duration}s)" -ForegroundColor Red
                    $failedReqs += @{ ReqId = $reqId; Agent = $agent; Error = $errMsg; Duration = $duration }

                    # Mark agent as exhausted if quota error
                    if ($errMsg -match "rate_limit|quota") {
                        Set-AgentQuotaExhausted -Agent $agent
                    }
                }
            }

            # Brief cooldown between batches within a wave
            if ($batch -ne $jobBatches[-1]) {
                Start-Sleep -Seconds 2
            }
        }

        # Wave summary
        Write-Host "  Wave $waveNum complete: $completedReqs/$totalReqs done, $($failedReqs.Count) failed" -ForegroundColor DarkGray

        # Cooldown between waves
        if ($waveIdx -lt ($Waves.Count - 1)) {
            Write-Host "  Cooldown ${CooldownSeconds}s before wave $($waveNum + 1)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $CooldownSeconds
        }
    }

    # Final summary
    Write-Host "`n  Wave Executor complete: $completedReqs/$totalReqs succeeded" -ForegroundColor $(if ($failedReqs.Count -eq 0) { "Green" } else { "Yellow" })

    return @{
        TotalRequirements = $totalReqs
        Completed = $completedReqs
        Failed = $failedReqs
        Results = $results
        TokenFeedback = $tokenFeedback
    }
}

function Split-IntoBatches {
    <#
    .SYNOPSIS
        Splits an array into batches of a given size.
    #>
    param(
        [array]$Items,
        [int]$BatchSize
    )

    $batches = @()
    for ($i = 0; $i -lt $Items.Count; $i += $BatchSize) {
        $end = [math]::Min($i + $BatchSize, $Items.Count)
        $batches += , ($Items[$i..($end - 1)])
    }
    return $batches
}

function Invoke-IterationExecute {
    <#
    .SYNOPSIS
        Executes a single iteration from the iteration plan.
        Handles parallel_group (round-robin across Tier2+Codex) and sequential_group (Codex only).
    .PARAMETER Iteration
        The iteration object from iteration-plan.json
    .PARAMETER Plans
        Hashtable of REQ-ID -> plan object
    .PARAMETER Research
        Hashtable of REQ-ID -> research object
    .PARAMETER AgentMap
        Parsed agent-map.json
    .PARAMETER GsdDir
        .gsd directory
    .PARAMETER RepoRoot
        Project root
    .PARAMETER PromptBuilder
        ScriptBlock: (reqId, plan, research, context) -> prompt string
    #>
    param(
        [PSObject]$Iteration,
        [hashtable]$Plans,
        [hashtable]$Research,
        [PSObject]$AgentMap,
        [string]$GsdDir,
        [string]$RepoRoot,
        [scriptblock]$PromptBuilder
    )

    $iterNum = $Iteration.iteration
    $results = @{}
    $failed = @()

    Write-Host "`n  === Iteration $iterNum ===" -ForegroundColor Cyan

    # 1. Execute parallel_group concurrently
    if ($Iteration.parallel_group -and $Iteration.parallel_group.Count -gt 0) {
        Write-Host "  Parallel group: $($Iteration.parallel_group.Count) requirements" -ForegroundColor DarkGray

        $parallelAgents = Get-WaveAgents -StepId "09a-execute" `
            -RequirementCount $Iteration.parallel_group.Count -AgentMap $AgentMap

        $jobs = @()
        for ($i = 0; $i -lt $Iteration.parallel_group.Count; $i++) {
            $reqId = $Iteration.parallel_group[$i]
            $plan = $Plans[$reqId]
            $research = $Research[$reqId]
            $agent = $parallelAgents[$i]

            $context = @{
                Iteration = $iterNum
                GsdDir = $GsdDir
                RepoRoot = $RepoRoot
            }
            $prompt = & $PromptBuilder $reqId $plan $research $context

            $agentResult = Invoke-Agent -Agent $agent -Prompt $prompt -StepId "09a-execute" `
                -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 45
            # Note: For true parallelism, this should use background jobs like Invoke-WaveParallel
            # Simplified here for clarity; production should use Start-Job pattern

            if ($agentResult.Success) {
                $results[$reqId] = $agentResult
                Write-Host "    [OK] $reqId ($agent)" -ForegroundColor Green
            } else {
                $failed += @{ ReqId = $reqId; Agent = $agent; Error = $agentResult.Error }
                Write-Host "    [FAIL] $reqId ($agent): $($agentResult.Error)" -ForegroundColor Red
            }
        }
    }

    # 2. Execute sequential_group one at a time (Codex)
    if ($Iteration.sequential_group -and $Iteration.sequential_group.Count -gt 0) {
        Write-Host "  Sequential group: $($Iteration.sequential_group.Count) requirements" -ForegroundColor DarkGray

        foreach ($reqId in $Iteration.sequential_group) {
            $plan = $Plans[$reqId]
            $research = $Research[$reqId]
            $context = @{
                Iteration = $iterNum
                GsdDir = $GsdDir
                RepoRoot = $RepoRoot
                PriorResults = $results
            }
            $prompt = & $PromptBuilder $reqId $plan $research $context

            $agentResult = Invoke-Agent -Agent "codex" -Prompt $prompt -StepId "09a-execute" `
                -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 45

            if ($agentResult.Success) {
                $results[$reqId] = $agentResult
                Write-Host "    [OK] $reqId (codex, sequential)" -ForegroundColor Green
            } else {
                $failed += @{ ReqId = $reqId; Agent = "codex"; Error = $agentResult.Error }
                Write-Host "    [FAIL] $reqId (codex): $($agentResult.Error)" -ForegroundColor Red
            }
        }
    }

    return @{
        Iteration = $iterNum
        Results = $results
        Failed = $failed
        TotalExecuted = $results.Count + $failed.Count
    }
}

Write-Host "  Wave executor module loaded" -ForegroundColor DarkGray
