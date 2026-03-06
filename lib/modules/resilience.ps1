# ===============================================================
# GSD Resilience Library - dot-source this in any pipeline script
# Usage: . "$env:USERPROFILE\.gsd-global\lib\modules\resilience.ps1"
# ===============================================================

# -- Configuration --
$script:RETRY_MAX = 3
$script:RETRY_DELAY_SECONDS = 10
$script:BATCH_REDUCTION_FACTOR = 0.5
$script:MIN_BATCH_SIZE = 2
$script:BUILD_TIMEOUT_SECONDS = 300
$script:AGENT_TIMEOUT_SECONDS = 600
$script:AGENT_WATCHDOG_MINUTES = 30     # Kill hung agent after this many minutes
$script:LOCK_STALE_MINUTES = 120

# ===========================================
# PRE-FLIGHT VALIDATION
# ===========================================

function Test-PreFlight {
    param(
        [string]$RepoRoot,
        [string]$GsdDir
    )

    $errors = @()
    $warnings = @()

    Write-Host "  Pre-flight checks..." -ForegroundColor DarkGray

    # -- Required tools --
    $tools = @(
        @{ Name="claude"; Cmd="claude --version" },
        @{ Name="codex"; Cmd="codex --version" },
        @{ Name="gemini"; Cmd="gemini --version" },
        @{ Name="git"; Cmd="git --version" }
    )
    foreach ($tool in $tools) {
        try {
            $null = Invoke-Expression $tool.Cmd 2>&1
            Write-Host "    [OK] $($tool.Name) available" -ForegroundColor DarkGreen
        } catch {
            if ($tool.Name -eq "gemini") {
                $warnings += "gemini CLI not found - research/spec-fix will fall back to codex"
                Write-Host "    [!!]  $($tool.Name) not found (optional)" -ForegroundColor DarkYellow
            } else {
                $errors += "$($tool.Name) CLI not found in PATH"
                Write-Host "    [XX] $($tool.Name) not found" -ForegroundColor Red
            }
        }
    }

    # -- Project structure --
    # .sln file
    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
    if ($slnFiles.Count -gt 0) {
        Write-Host "    [OK] Solution: $($slnFiles[0].Name)" -ForegroundColor DarkGreen
    } else {
        $warnings += "No .sln file found - dotnet build validation will be limited"
        Write-Host "    [!!]  No .sln found" -ForegroundColor DarkYellow
    }

    # package.json
    $pkgJsonPaths = @(
        (Join-Path $RepoRoot "package.json"),
        (Join-Path $RepoRoot "src\Web\ClientApp\package.json"),
        (Join-Path $RepoRoot "client\package.json"),
        (Join-Path $RepoRoot "frontend\package.json")
    )
    $foundPkgJson = $pkgJsonPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($foundPkgJson) {
        Write-Host "    [OK] package.json: $($foundPkgJson.Replace($RepoRoot, '.'))" -ForegroundColor DarkGreen
        $script:PackageJsonPath = $foundPkgJson
    } else {
        $warnings += "No package.json found - npm build validation will be limited"
        Write-Host "    [!!]  No package.json found" -ForegroundColor DarkYellow
        $script:PackageJsonPath = $null
    }

    # appsettings.json
    $appSettingsPaths = @(
        (Join-Path $RepoRoot "appsettings.json"),
        (Join-Path $RepoRoot "src\Web\appsettings.json"),
        (Join-Path $RepoRoot "src\API\appsettings.json")
    )
    $foundAppSettings = $appSettingsPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($foundAppSettings) {
        Write-Host "    [OK] appsettings.json found" -ForegroundColor DarkGreen
    } else {
        $warnings += "No appsettings.json found - will be created during generation"
        Write-Host "    [!!]  No appsettings.json (will be generated)" -ForegroundColor DarkYellow
    }

    # -- Git state --
    try {
        $gitStatus = git -C $RepoRoot status --porcelain 2>&1
        $dirtyCount = ($gitStatus | Measure-Object).Count
        if ($dirtyCount -gt 0) {
            $warnings += "$dirtyCount uncommitted changes - will be included in first commit"
            Write-Host "    [!!]  $dirtyCount uncommitted changes" -ForegroundColor DarkYellow
        } else {
            Write-Host "    [OK] Git working tree clean" -ForegroundColor DarkGreen
        }
    } catch {
        $errors += "Not a git repository"
        Write-Host "    [XX] Not a git repo" -ForegroundColor Red
    }

    # -- Disk space --
    $drive = (Get-Item $RepoRoot).PSDrive
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    if ($freeGB -lt 1) {
        $errors += "Less than 1GB free disk space ($freeGB GB)"
        Write-Host "    [XX] Low disk: ${freeGB}GB free" -ForegroundColor Red
    } else {
        Write-Host "    [OK] Disk: ${freeGB}GB free" -ForegroundColor DarkGreen
    }

    # -- Lock file check --
    $lockFile = Join-Path $GsdDir ".gsd-lock"
    if (Test-Path $lockFile) {
        $lockAge = (Get-Date) - (Get-Item $lockFile).LastWriteTime
        if ($lockAge.TotalMinutes -gt $script:LOCK_STALE_MINUTES) {
            Remove-Item $lockFile -Force
            Write-Host "    Removed stale lock (${([math]::Round($lockAge.TotalMinutes))} min old)" -ForegroundColor DarkYellow
        } else {
            $errors += "Another GSD process is running (lock file age: $([math]::Round($lockAge.TotalMinutes)) min)"
            Write-Host "    Lock file active ($([math]::Round($lockAge.TotalMinutes)) min)" -ForegroundColor Red
        }
    }

    # -- REST agent API key checks (warnings only) --
    $restAgentChecks = @(
        @{ Name = "kimi";     EnvVar = "KIMI_API_KEY" }
        @{ Name = "deepseek"; EnvVar = "DEEPSEEK_API_KEY" }
        @{ Name = "glm5";     EnvVar = "GLM_API_KEY" }
        @{ Name = "minimax";  EnvVar = "MINIMAX_API_KEY" }
    )
    $restCount = 0
    foreach ($ra in $restAgentChecks) {
        $keyVal = [System.Environment]::GetEnvironmentVariable($ra.EnvVar)
        if (-not $keyVal) {
            $userVal = [System.Environment]::GetEnvironmentVariable($ra.EnvVar, 'User')
            if (-not $userVal) { $userVal = [System.Environment]::GetEnvironmentVariable($ra.EnvVar, 'Machine') }
            if ($userVal) {
                [System.Environment]::SetEnvironmentVariable($ra.EnvVar, $userVal, 'Process')
                $keyVal = $userVal
            }
        }
        if ($keyVal) {
            Write-Host "    [OK] $($ra.EnvVar) set (REST agent: $($ra.Name))" -ForegroundColor DarkGreen
            $restCount++
        } else {
            Write-Host "    [--] $($ra.EnvVar) not set ($($ra.Name) disabled)" -ForegroundColor DarkGray
        }
    }
    if ($restCount -gt 0) {
        Write-Host "    $restCount REST agent(s) available for rotation" -ForegroundColor DarkGreen
    } else {
        $warnings += "No REST agent API keys set. Set KIMI_API_KEY, DEEPSEEK_API_KEY, GLM_API_KEY, or MINIMAX_API_KEY for expanded rotation pool."
    }

    # -- Results --
    Write-Host ""
    if ($errors.Count -gt 0) {
        Write-Host "  [XX] Pre-flight FAILED:" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "     - $_" -ForegroundColor Red }
        return $false
    }
    if ($warnings.Count -gt 0) {
        Write-Host "  [!!]  Pre-flight PASSED with warnings:" -ForegroundColor DarkYellow
        $warnings | ForEach-Object { Write-Host "     - $_" -ForegroundColor DarkYellow }
    } else {
        Write-Host "  [OK] Pre-flight PASSED" -ForegroundColor Green
    }
    return $true
}

# ===========================================
# LOCK FILE MANAGEMENT
# ===========================================

function New-GsdLock {
    param([string]$GsdDir, [string]$Pipeline)
    $lockFile = Join-Path $GsdDir ".gsd-lock"
    @{
        pid = $PID
        pipeline = $Pipeline
        started = (Get-Date -Format "o")
        host = $env:COMPUTERNAME
    } | ConvertTo-Json | Set-Content $lockFile -Encoding UTF8
}

function Remove-GsdLock {
    param([string]$GsdDir)
    $lockFile = Join-Path $GsdDir ".gsd-lock"
    if (Test-Path $lockFile) { Remove-Item $lockFile -Force }
}

# ===========================================
# CHECKPOINT / RESUME
# ===========================================

function Save-Checkpoint {
    param(
        [string]$GsdDir,
        [string]$Pipeline,
        [int]$Iteration,
        [string]$Phase,
        [double]$Health,
        [int]$BatchSize,
        [string]$Status = "in_progress"
    )
    $checkpointFile = Join-Path $GsdDir ".gsd-checkpoint.json"
    @{
        pipeline = $Pipeline
        iteration = $Iteration
        phase = $Phase
        health = $Health
        batch_size = $BatchSize
        status = $Status
        timestamp = (Get-Date -Format "o")
        pid = $PID
    } | ConvertTo-Json | Set-Content $checkpointFile -Encoding UTF8
}

function Get-Checkpoint {
    param([string]$GsdDir)
    $checkpointFile = Join-Path $GsdDir ".gsd-checkpoint.json"
    if (Test-Path $checkpointFile) {
        try {
            return Get-Content $checkpointFile -Raw | ConvertFrom-Json
        } catch { return $null }
    }
    return $null
}

function Clear-Checkpoint {
    param([string]$GsdDir)
    $checkpointFile = Join-Path $GsdDir ".gsd-checkpoint.json"
    if (Test-Path $checkpointFile) { Remove-Item $checkpointFile -Force }
}

# ===========================================
# RETRY WITH ADAPTIVE BATCH REDUCTION
# ===========================================

# -- Failure diagnosis + agent fallback --

function Get-FailureDiagnosis {
    param(
        [string]$Agent,
        [int]$ExitCode,
        [string]$OutputText,
        [string]$Phase
    )

    $diagnosis = ""
    $action = "retry"
    $fallbackAgent = $null
    $fallbackMode = $null

    if ($Agent -eq "gemini") {
        if ($OutputText -match "sandbox.*restrict|plan.*mode.*restrict|not.*allow|permission.*denied|read.only") {
            $diagnosis = "Gemini plan mode blocked a write operation"
        } elseif ($OutputText -match "model.*not.*found|model.*unavail|invalid.*model") {
            $diagnosis = "Gemini model unavailable"
        } elseif ($OutputText -match "too.*large|input.*limit|prompt.*too|content.*length") {
            $diagnosis = "Prompt too large for Gemini context"
        } elseif ($OutputText -match "internal.*error|server.*error|50[0-9]") {
            $diagnosis = "Gemini server error (transient)"
        } elseif (-not $OutputText -or $OutputText.Trim().Length -eq 0) {
            $diagnosis = "Gemini produced no output (CLI crash or argument error)"
        } else {
            $diagnosis = "Gemini exit code $ExitCode"
        }
        $action = "fallback"
        $fallbackAgent = "codex"
    } elseif ($Agent -eq "codex") {
        if ($OutputText -match "loop.*detect|iteration.*limit|max.*turns") {
            $diagnosis = "Codex hit loop/iteration limit"
        } elseif (-not $OutputText -or $OutputText.Trim().Length -eq 0) {
            $diagnosis = "Codex produced no output"
        } else {
            $diagnosis = "Codex exit code $ExitCode"
        }
        if ($Phase -match "research|review|verify|plan") {
            $action = "fallback"
            $fallbackAgent = "claude"
        }
    } elseif ($Agent -eq "claude") {
        if (-not $OutputText -or $OutputText.Trim().Length -eq 0) {
            $diagnosis = "Claude produced no output"
        } else {
            $diagnosis = "Claude exit code $ExitCode"
        }
    } else {
        $diagnosis = "Unknown agent '$Agent' exit code $ExitCode"
    }

    return @{ Diagnosis = $diagnosis; Action = $action; FallbackAgent = $fallbackAgent; FallbackMode = $fallbackMode }
}

function Invoke-AgentFallback {
    param(
        [string]$FallbackAgent,
        [string]$Prompt,
        [string]$AllowedTools = "Read,Write,Bash,mcp__*",
        [string]$LogFile
    )

    $fbOutput = $null
    $fbExit = 1

    try {
        if ($FallbackAgent -eq "codex") {
            $fbOutput = $Prompt | codex exec --full-auto - 2>&1
            $fbExit = $LASTEXITCODE
        } elseif ($FallbackAgent -eq "claude") {
            $fbOutput = claude -p $Prompt --allowedTools $AllowedTools 2>&1
            $fbExit = $LASTEXITCODE
        } elseif ($FallbackAgent -eq "gemini") {
            $fbOutput = $Prompt | gemini --approval-mode plan 2>&1
            $fbExit = $LASTEXITCODE
        }
        if ($LogFile -and $fbOutput) {
            $fbOutput | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        }
    } catch { $fbExit = 1 }

    return @{ Success = ($fbExit -eq 0 -and $fbOutput -and $fbOutput.Count -gt 0); Output = $fbOutput; ExitCode = $fbExit }
}

# ===========================================
# RETRY WITH ADAPTIVE BATCH REDUCTION
# ===========================================

function Invoke-WithRetry {
    param(
        [string]$Agent,           # "claude", "codex", or "gemini"
        [string]$Prompt,
        [string]$Phase,
        [string]$LogFile,
        [int]$Attempt = 1,
        [int]$MaxAttempts = $script:RETRY_MAX,
        [int]$CurrentBatchSize = 15,
        [string]$GsdDir,
        [string]$AllowedTools = "Read,Write,Bash,mcp__*",
        [string]$GeminiMode = "--approval-mode plan"   # "--approval-mode plan" (read-only) or "--yolo" (write)
    )

    $result = @{
        Success = $false
        Attempts = 0
        FinalBatchSize = $CurrentBatchSize
        Error = $null
    }

    for ($i = $Attempt; $i -le $MaxAttempts; $i++) {
        $result.Attempts = $i

        # Inject current batch size into prompt if it has the placeholder
        $effectivePrompt = $Prompt.Replace("{{BATCH_SIZE}}", "$CurrentBatchSize")

        Write-Host "    Attempt $i/$MaxAttempts (batch: $CurrentBatchSize)..." -ForegroundColor DarkGray

        try {
            $exitCode = 0
            $wasTimedOut = $false
            $watchdogMs = $script:AGENT_WATCHDOG_MINUTES * 60 * 1000

            # Write prompt to temp file for watchdog-wrapped process execution
            $promptTempFile = [System.IO.Path]::GetTempFileName()
            $outputTempFile = [System.IO.Path]::GetTempFileName()
            $wrapperScript = [System.IO.Path]::GetTempFileName() + ".ps1"
            Set-Content -Path $promptTempFile -Value $effectivePrompt -Encoding UTF8

            try {
                # Build a wrapper script that runs the agent and captures output
                # This avoids command-line length limits and handles piping reliably
                if ($Agent -eq "claude") {
                    $wrapperContent = @"
`$prompt = Get-Content '$($promptTempFile -replace "'","''")' -Raw -Encoding UTF8
`$output = claude -p `$prompt --allowedTools $AllowedTools 2>&1
`$output | Out-File -FilePath '$($outputTempFile -replace "'","''")' -Encoding UTF8
exit `$LASTEXITCODE
"@
                } elseif ($Agent -eq "codex") {
                    $wrapperContent = @"
`$prompt = Get-Content '$($promptTempFile -replace "'","''")' -Raw -Encoding UTF8
`$output = `$prompt | codex exec --full-auto - 2>&1
`$output | Out-File -FilePath '$($outputTempFile -replace "'","''")' -Encoding UTF8
exit `$LASTEXITCODE
"@
                } elseif ($Agent -eq "gemini") {
                    $geminiArgs = $GeminiMode.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) -join ' '
                    $wrapperContent = @"
`$prompt = Get-Content '$($promptTempFile -replace "'","''")' -Raw -Encoding UTF8
`$output = `$prompt | gemini $geminiArgs 2>&1
`$output | Out-File -FilePath '$($outputTempFile -replace "'","''")' -Encoding UTF8
exit `$LASTEXITCODE
"@
                }

                Set-Content -Path $wrapperScript -Value $wrapperContent -Encoding UTF8

                # Launch as a separate process with watchdog timeout
                $proc = Start-Process -FilePath "powershell.exe" `
                    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$wrapperScript`"" `
                    -NoNewWindow -PassThru

                # Watchdog: wait with timeout
                $completed = $proc.WaitForExit($watchdogMs)

                if (-not $completed) {
                    # Agent hung - kill it and all child processes
                    $wasTimedOut = $true
                    $procId = $proc.Id
                    Write-Host "    [TIMEOUT] $Agent hung after $($script:AGENT_WATCHDOG_MINUTES)m - killing process tree..." -ForegroundColor Red

                    # Kill child processes first (the actual agent CLI), then the wrapper
                    try {
                        Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $procId } | ForEach-Object {
                            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    try { $proc.Kill() } catch {}
                    $exitCode = -1

                    # Send timeout notification
                    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
                        $repoName = Split-Path (Get-Location).Path -Leaf
                        Send-GsdNotification -Title "Agent Timeout: $Agent" `
                            -Message "$repoName | $Phase killed after $($script:AGENT_WATCHDOG_MINUTES)m | Iter $i - retrying..." `
                            -Tags "skull" -Priority "high"
                    }

                    # Log the timeout
                    $errorEntry = @{
                        type = "watchdog_timeout"
                        agent = $Agent
                        phase = $Phase
                        attempt = $i
                        timeout_minutes = $script:AGENT_WATCHDOG_MINUTES
                        timestamp = (Get-Date -Format "o")
                    } | ConvertTo-Json -Compress
                    Add-Content -Path (Join-Path $GsdDir "logs\errors.jsonl") -Value $errorEntry -Encoding UTF8
                } else {
                    $exitCode = $proc.ExitCode
                }

                # Read captured output
                if (Test-Path $outputTempFile) {
                    $output = Get-Content $outputTempFile -Raw -ErrorAction SilentlyContinue
                    if ($output) { $output = $output -split "`n" }
                }
            } finally {
                # Clean up temp files
                Remove-Item $promptTempFile -Force -ErrorAction SilentlyContinue
                Remove-Item $outputTempFile -Force -ErrorAction SilentlyContinue
                Remove-Item $wrapperScript -Force -ErrorAction SilentlyContinue
            }

            # Write log
            if ($output) { $output | Out-File -FilePath $LogFile -Encoding UTF8 -Append }

            # Check for common failure patterns in output
            $outputText = if ($output) { $output -join "`n" } else { "" }
            $isTokenError = $outputText -match "(token limit|rate limit|context.*(window|length)|too long|exceeded.*limit|max.*tokens)"
            $isTimeout = $wasTimedOut -or ($outputText -match "(timeout|timed out|ETIMEDOUT|connection.*reset)")
            $isAuthError = $outputText -match "(unauthorized|auth.*fail|invalid.*key|401)" -and
               $outputText -notmatch "(rate|quota|resource.exhausted|too.many|throttl)"
            $isCrash = ($exitCode -ne 0) -or ($null -eq $output) -or ($output.Count -eq 0)

            if ($isAuthError) {
                $result.Error = "AUTH_ERROR: Agent authentication failed"
                Write-Host "    [XX] Auth error - cannot retry. Check API keys." -ForegroundColor Red
                break
            }

            # Watchdog timeout -> reduce batch and retry (agent was likely stuck on too-large prompt)
            if ($wasTimedOut -and $i -lt $MaxAttempts) {
                $CurrentBatchSize = [math]::Max(
                    $script:MIN_BATCH_SIZE,
                    [math]::Floor($CurrentBatchSize * $script:BATCH_REDUCTION_FACTOR)
                )
                $result.FinalBatchSize = $CurrentBatchSize
                Write-Host "    [!!]  Watchdog killed $Agent after $($script:AGENT_WATCHDOG_MINUTES)m -> batch $CurrentBatchSize. Retrying..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $script:RETRY_DELAY_SECONDS
                continue
            }

            if ($isCrash -and $i -lt $MaxAttempts) {
                if ($isTokenError) {
                    # Token/context limit -> reduce batch size (smaller batch = fewer tokens)
                    $CurrentBatchSize = [math]::Max(
                        $script:MIN_BATCH_SIZE,
                        [math]::Floor($CurrentBatchSize * $script:BATCH_REDUCTION_FACTOR)
                    )
                    $result.FinalBatchSize = $CurrentBatchSize
                    $reason = "token limit"
                    Write-Host "    [!!]  $reason -> batch $CurrentBatchSize. Retry in $($script:RETRY_DELAY_SECONDS)s..." -ForegroundColor DarkYellow
                } else {
                    # Non-token failure -> diagnose root cause and attempt fallback
                    $reason = if ($isTimeout) { "timeout" } else { "exit code $exitCode" }
                    $recovery = Get-FailureDiagnosis -Agent $Agent -ExitCode $exitCode `
                        -OutputText $outputText -Phase $Phase
                    Write-Host "    [!!]  $reason - $($recovery.Diagnosis)" -ForegroundColor DarkYellow

                    # Attempt fallback to alternative agent
                    if ($recovery.Action -eq "fallback" -and $recovery.FallbackAgent) {
                        Write-Host "    [SYNC] Falling back: $Agent -> $($recovery.FallbackAgent)..." -ForegroundColor Yellow
                        $fb = Invoke-AgentFallback -FallbackAgent $recovery.FallbackAgent `
                            -Prompt $effectivePrompt -AllowedTools $AllowedTools -LogFile $LogFile

                        if ($fb.Success) {
                            Write-Host "    [OK] Fallback to $($recovery.FallbackAgent) succeeded" -ForegroundColor Green
                            $result.Success = $true
                            $result.FinalBatchSize = $CurrentBatchSize
                            return $result
                        } else {
                            Write-Host "    [!!]  Fallback to $($recovery.FallbackAgent) also failed (exit $($fb.ExitCode))" -ForegroundColor DarkYellow
                        }
                    }

                    Write-Host "    Retry $($i+1)/$MaxAttempts in $($script:RETRY_DELAY_SECONDS)s (batch unchanged: $CurrentBatchSize)..." -ForegroundColor DarkYellow
                }

                # Log the failure
                $errorEntry = @{
                    type = "retry"
                    agent = $Agent
                    phase = $Phase
                    attempt = $i
                    reason = $reason
                    new_batch_size = $CurrentBatchSize
                    timestamp = (Get-Date -Format "o")
                } | ConvertTo-Json -Compress
                Add-Content -Path (Join-Path $GsdDir "logs\errors.jsonl") -Value $errorEntry -Encoding UTF8

                Start-Sleep -Seconds $script:RETRY_DELAY_SECONDS
                continue
            }

            if (-not $isCrash) {
                $result.Success = $true
                $result.FinalBatchSize = $CurrentBatchSize
                return $result
            }
        } catch {
            $result.Error = $_.Exception.Message
            Write-Host "    [XX] Exception: $($_.Exception.Message)" -ForegroundColor Red

            # Log exception
            $errorEntry = @{
                type = "exception"
                agent = $Agent
                phase = $Phase
                attempt = $i
                message = $_.Exception.Message
                timestamp = (Get-Date -Format "o")
            } | ConvertTo-Json -Compress
            Add-Content -Path (Join-Path $GsdDir "logs\errors.jsonl") -Value $errorEntry -Encoding UTF8

            if ($i -lt $MaxAttempts) {
                # Don't reduce batch for exceptions - retry at same size
                Start-Sleep -Seconds $script:RETRY_DELAY_SECONDS
            }
        }
    }

    # All retries exhausted
    if (-not $result.Success) {
        if (-not $result.Error) { $result.Error = "All $MaxAttempts attempts failed" }
        Write-Host "    [XX] All retries exhausted for $Agent -> $Phase" -ForegroundColor Red
    }

    return $result
}

# ===========================================
# BUILD VALIDATION & AUTO-FIX
# ===========================================

function Invoke-BuildValidation {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [int]$Iteration,
        [switch]$AutoFix
    )

    Write-Host "  Build validation..." -ForegroundColor DarkGray
    $buildErrors = @()
    $fixAttempted = $false

    # -- Find .sln --
    $slnFile = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1

    # -- dotnet build --
    if ($slnFile) {
        Write-Host "    [WRENCH] dotnet build $($slnFile.Name)..." -ForegroundColor DarkGray
        try {
            $buildOutput = dotnet build $slnFile.FullName --no-restore --verbosity quiet 2>&1
            $buildExit = $LASTEXITCODE

            if ($buildExit -ne 0) {
                $errorLines = $buildOutput | Where-Object { $_ -match "(error CS|error MSB)" }
                $errorCount = ($errorLines | Measure-Object).Count
                Write-Host "    [XX] dotnet build failed: $errorCount errors" -ForegroundColor Red

                # Save build errors for auto-fix
                $buildErrorFile = Join-Path $GsdDir "logs\build-errors-iter$Iteration.log"
                $buildOutput | Out-File -FilePath $buildErrorFile -Encoding UTF8
                $buildErrors += "dotnet: $errorCount compilation errors"

                if ($AutoFix) {
                    Write-Host "    [SYNC] Auto-fix: sending build errors to Codex..." -ForegroundColor DarkYellow
                    $fixAttempted = $true

                    $fixPrompt = @"
Build errors detected. Read the build error log and fix ALL compilation errors.

Build error log: $buildErrorFile

Rules:
- Fix ONLY the compilation errors - don't refactor or change other logic
- If a file is missing an import/using statement, add it
- If a type doesn't exist, create it in the correct location
- If a method signature doesn't match, fix the caller to match the definition
- After fixing, the project must compile with: dotnet build $($slnFile.FullName)
"@
                    $fixPrompt | codex exec --full-auto - 2>&1 |
                        Out-File -FilePath (Join-Path $GsdDir "logs\autofix-dotnet-iter$Iteration.log") -Encoding UTF8

                    # Re-verify
                    $rebuildOutput = dotnet build $slnFile.FullName --no-restore --verbosity quiet 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    [OK] Auto-fix successful - dotnet build passes" -ForegroundColor Green
                        $buildErrors = $buildErrors | Where-Object { $_ -notmatch "^dotnet:" }
                        git add -A; git commit -m "gsd: auto-fix dotnet build errors (iter $Iteration)" --no-verify 2>$null
                    } else {
                        Write-Host "    [!!]  Auto-fix partial - some errors remain" -ForegroundColor DarkYellow
                    }
                }
            } else {
                Write-Host "    [OK] dotnet build passed" -ForegroundColor DarkGreen
            }
        } catch {
            Write-Host "    [!!]  dotnet build skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    # -- npm / React build --
    if ($script:PackageJsonPath) {
        $npmDir = Split-Path $script:PackageJsonPath -Parent
        Write-Host "    [WRENCH] npm run build in $($npmDir.Replace($RepoRoot, '.'))..." -ForegroundColor DarkGray

        try {
            Push-Location $npmDir

            # Install deps if node_modules missing
            if (-not (Test-Path "node_modules")) {
                Write-Host "    [PKG] Installing npm dependencies..." -ForegroundColor DarkGray
                npm install --silent 2>&1 | Out-Null
            }

            # Check if build script exists
            $pkgJson = Get-Content "package.json" -Raw | ConvertFrom-Json
            $hasBuildScript = $null -ne $pkgJson.scripts -and $null -ne $pkgJson.scripts.build

            if ($hasBuildScript) {
                $npmOutput = npm run build 2>&1
                $npmExit = $LASTEXITCODE

                if ($npmExit -ne 0) {
                    $tsErrors = $npmOutput | Where-Object { $_ -match "(TS\d{4}|SyntaxError|Module not found|Cannot find)" }
                    $tsErrorCount = ($tsErrors | Measure-Object).Count
                    Write-Host "    [XX] npm build failed: $tsErrorCount errors" -ForegroundColor Red

                    $npmErrorFile = Join-Path $GsdDir "logs\npm-errors-iter$Iteration.log"
                    $npmOutput | Out-File -FilePath $npmErrorFile -Encoding UTF8
                    $buildErrors += "npm: $tsErrorCount build errors"

                    if ($AutoFix) {
                        Write-Host "    [SYNC] Auto-fix: sending npm errors to Codex..." -ForegroundColor DarkYellow
                        $fixAttempted = $true

                        $fixPrompt = @"
React/TypeScript build errors detected. Fix ALL errors.

Error log: $npmErrorFile
Project dir: $npmDir

Rules:
- Fix ONLY the build errors - don't refactor or change other logic
- Missing imports: add the correct import statement
- Type errors: fix the type definition or usage
- Module not found: install the package or fix the import path
- After fixing, npm run build must succeed
"@
                        $fixPrompt | codex exec --full-auto - 2>&1 |
                            Out-File -FilePath (Join-Path $GsdDir "logs\autofix-npm-iter$Iteration.log") -Encoding UTF8

                        $reNpmOutput = npm run build 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "    [OK] Auto-fix successful - npm build passes" -ForegroundColor Green
                            $buildErrors = $buildErrors | Where-Object { $_ -notmatch "^npm:" }
                            git add -A; git commit -m "gsd: auto-fix npm build errors (iter $Iteration)" --no-verify 2>$null
                        } else {
                            Write-Host "    [!!]  Auto-fix partial - some npm errors remain" -ForegroundColor DarkYellow
                        }
                    }
                } else {
                    Write-Host "    [OK] npm build passed" -ForegroundColor DarkGreen
                }
            } else {
                Write-Host "    [>>]  No build script in package.json" -ForegroundColor DarkGray
            }

            Pop-Location
        } catch {
            Pop-Location
            Write-Host "    [!!]  npm build skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
    }

    # -- Summary --
    $result = @{
        Passed = ($buildErrors.Count -eq 0)
        Errors = $buildErrors
        AutoFixAttempted = $fixAttempted
    }

    if ($buildErrors.Count -eq 0) {
        Write-Host "  [OK] All builds pass" -ForegroundColor Green
    } else {
        Write-Host "  [!!]  $($buildErrors.Count) build issues remain" -ForegroundColor DarkYellow
    }

    return $result
}

# ===========================================
# HEALTH REGRESSION PROTECTION
# ===========================================

function Test-HealthRegression {
    param(
        [double]$PreviousHealth,
        [double]$CurrentHealth,
        [string]$RepoRoot,
        [int]$Iteration
    )

    if ($CurrentHealth -lt ($PreviousHealth - 5)) {
        # Health dropped by more than 5% - something went wrong
        Write-Host "  [STOP] HEALTH REGRESSION: ${PreviousHealth}% -> ${CurrentHealth}% (dropped >5%)" -ForegroundColor Red
        Write-Host "    Reverting to pre-iteration state..." -ForegroundColor Yellow

        try {
            $stash = git -C $RepoRoot stash list 2>&1 | Select-String "gsd-pre-iter-$Iteration"
            if ($stash) {
                git -C $RepoRoot stash pop 2>$null
                Write-Host "    [OK] Reverted to pre-iteration state" -ForegroundColor Green
            } else {
                # Try reverting last commit
                git -C $RepoRoot reset --hard HEAD~1 2>$null
                Write-Host "    [OK] Reverted last commit" -ForegroundColor Green
            }
        } catch {
            Write-Host "    [!!]  Could not auto-revert: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        return $true  # regression detected
    }

    return $false  # no regression
}

# ===========================================
# GIT SNAPSHOT (before each iteration)
# ===========================================

function New-GitSnapshot {
    param(
        [string]$RepoRoot,
        [int]$Iteration,
        [string]$Pipeline
    )

    try {
        git -C $RepoRoot add -A 2>$null
        git -C $RepoRoot stash push -m "gsd-pre-iter-$Iteration-$Pipeline" 2>$null
        git -C $RepoRoot stash pop 2>$null
    } catch {
        # Non-fatal - just means we can't revert this iteration if needed
    }
}

# ===========================================
# STRUCTURED ERROR LOG
# ===========================================

function Write-GsdError {
    param(
        [string]$GsdDir,
        [string]$Category,    # "agent_crash", "build_fail", "stall", "regression", "auth"
        [string]$Phase,
        [int]$Iteration,
        [string]$Message,
        [string]$Resolution = ""
    )

    $entry = @{
        category = $Category
        phase = $Phase
        iteration = $Iteration
        message = $Message
        resolution = $Resolution
        timestamp = (Get-Date -Format "o")
    } | ConvertTo-Json -Compress

    $errorLog = Join-Path $GsdDir "logs\errors.jsonl"
    Add-Content -Path $errorLog -Value $entry -Encoding UTF8
}

# ===========================================
# TIMING & PROGRESS DISPLAY
# ===========================================

function Show-ProgressBar {
    param(
        [double]$Health,
        [int]$Iteration,
        [int]$MaxIterations,
        [string]$Phase
    )

    $filled = [math]::Floor($Health / 5)
    $empty = 20 - $filled
    $bar = "#" * $filled + "." * $empty
    $pct = "{0:N1}" -f $Health
    Write-Host "  [$bar] ${pct}% | Iter $Iteration/$MaxIterations | $Phase" -ForegroundColor $(
        if ($Health -ge 90) { "Green" }
        elseif ($Health -ge 60) { "Cyan" }
        elseif ($Health -ge 30) { "Yellow" }
        else { "Red" }
    )
}

Write-Host "  Resilience library ready." -ForegroundColor DarkGray


# ===============================================================
# GSD HARDENING MODULES - appended to resilience.ps1
# ===============================================================

# -- Hardening config --
$script:QUOTA_SLEEP_INITIAL = 5         # start at 5 minutes (not 60!)
$script:QUOTA_SLEEP_MAX = 60            # cap at 60 minutes
$script:QUOTA_SLEEP_BACKOFF = 2         # double each cycle: 5, 10, 20, 40, 60, 60...
$script:QUOTA_SLEEP_MINUTES = $script:QUOTA_SLEEP_INITIAL  # compat alias
$script:QUOTA_MAX_SLEEPS = 24           # max total sleep cycles
$script:NETWORK_POLL_SECONDS = 10
$script:NETWORK_MAX_POLLS = 6          # max 60s of polling, then skip
$script:DISK_MIN_FREE_GB = 0.5
$script:JSON_BACKUP_SUFFIX = ".last-good"

# ===========================================
# 1. JSON VALIDATION + ROLLBACK
# ===========================================

function Test-JsonFile {
    <#
    .SYNOPSIS
        Validates a JSON file. If corrupt, restores from .last-good backup.
        Call this after every agent write to a JSON state file.
    #>
    param(
        [string]$Path,
        [string]$GsdDir,
        [string]$Description = "JSON file"
    )

    if (-not (Test-Path $Path)) { return $true }  # file doesn't exist yet, that's ok

    $backupPath = "$Path$($script:JSON_BACKUP_SUFFIX)"

    try {
        $content = Get-Content $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) { throw "Empty file" }

        $null = $content | ConvertFrom-Json -ErrorAction Stop

        # Valid - save as last known good
        Copy-Item -Path $Path -Destination $backupPath -Force
        return $true
    } catch {
        Write-Host "    [!!]  Corrupt $Description : $($_.Exception.Message)" -ForegroundColor DarkYellow

        # Try to restore from backup
        if (Test-Path $backupPath) {
            Copy-Item -Path $backupPath -Destination $Path -Force
            Write-Host "    [SYNC] Restored from last good backup" -ForegroundColor DarkYellow

            Write-GsdError -GsdDir $GsdDir -Category "corrupt_json" -Phase "validation" -Iteration 0 `
                -Message "Corrupt $Description at $Path - restored from backup" `
                -Resolution "Last good backup restored"
            return $true
        } else {
            Write-Host "    [XX] No backup available for $Description" -ForegroundColor Red
            Write-GsdError -GsdDir $GsdDir -Category "corrupt_json" -Phase "validation" -Iteration 0 `
                -Message "Corrupt $Description at $Path - no backup available" `
                -Resolution "File must be regenerated"
            return $false
        }
    }
}

function Invoke-ValidateAllState {
    <#
    .SYNOPSIS
        Validates all JSON state files after an agent completes a phase.
    #>
    param(
        [string]$GsdDir,
        [string]$Pipeline   # "blueprint" or "converge"
    )

    $allValid = $true

    if ($Pipeline -eq "blueprint") {
        $files = @(
            @{ Path = "$GsdDir\blueprint\blueprint.json"; Desc = "blueprint.json" },
            @{ Path = "$GsdDir\blueprint\health.json"; Desc = "health.json" },
            @{ Path = "$GsdDir\blueprint\next-batch.json"; Desc = "next-batch.json" }
        )
    } else {
        $files = @(
            @{ Path = "$GsdDir\health\health-current.json"; Desc = "health-current.json" },
            @{ Path = "$GsdDir\health\requirements-matrix.json"; Desc = "requirements-matrix.json" },
            @{ Path = "$GsdDir\generation-queue\queue-current.json"; Desc = "queue-current.json" }
        )
    }

    foreach ($f in $files) {
        if (Test-Path $f.Path) {
            $valid = Test-JsonFile -Path $f.Path -GsdDir $GsdDir -Description $f.Desc
            if (-not $valid) { $allValid = $false }
        }
    }

    return $allValid
}

# ===========================================
# 2. QUOTA / BILLING DETECTION + SLEEP
# ===========================================

function Test-IsQuotaError {
    <#
    .SYNOPSIS
        Checks if an error message indicates a billing/quota limit.
        Returns: "none", "rate_limit" (wait minutes), or "quota_exhausted" (wait hours/days)
    #>
    param([string]$ErrorOutput)

    if ($ErrorOutput -match "(billing|quota|monthly.*limit|spending.*limit|budget.*exceeded|plan.*limit)") {
        return "quota_exhausted"
    }
    if ($ErrorOutput -match "(rate.limit|too.many.requests|429|throttl|slow.down|403.*resource.exhausted)") {
        return "rate_limit"
    }
    # Catch bare 403 that looks like rate limiting (not auth)
    if ($ErrorOutput -match "403" -and $ErrorOutput -match "(resource|exhausted|limit|capacity)") {
        return "rate_limit"
    }
    return "none"
}

function Wait-ForQuotaReset {
    <#
    .SYNOPSIS
        Sleeps until quota resets, then returns. For rate limits, waits minutes.
        For quota exhaustion, waits up to 24 hours.
    #>
    param(
        [string]$QuotaType,   # "rate_limit" or "quota_exhausted"
        [string]$Agent,
        [string]$GsdDir
    )

    if ($QuotaType -eq "rate_limit") {
        $waitMinutes = 2
        Write-Host "    Rate limited on $Agent. Waiting $waitMinutes minutes..." -ForegroundColor Yellow
        Start-Sleep -Seconds ($waitMinutes * 60)
        return $true
    }

    if ($QuotaType -eq "quota_exhausted") {
        Write-Host "    Quota exhausted on $Agent." -ForegroundColor Red
        Write-Host "    Using adaptive backoff: ${script:QUOTA_SLEEP_INITIAL}min -> ${script:QUOTA_SLEEP_MAX}min" -ForegroundColor Yellow

        Write-GsdError -GsdDir $GsdDir -Category "quota" -Phase "wait" -Iteration 0 `
            -Message "$Agent quota exhausted" -Resolution "Adaptive backoff starting at $($script:QUOTA_SLEEP_INITIAL) min"

        $sleepCount = 0
        $currentSleep = $script:QUOTA_SLEEP_INITIAL
        while ($sleepCount -lt $script:QUOTA_MAX_SLEEPS) {
            $sleepCount++
            $wakeTime = (Get-Date).AddMinutes($currentSleep)
            Write-Host "    Sleep $sleepCount/$($script:QUOTA_MAX_SLEEPS) (${currentSleep}min). Wake at: $($wakeTime.ToString('HH:mm'))" -ForegroundColor DarkGray
            Start-Sleep -Seconds ($currentSleep * 60)

            # Test if quota has reset - use the SAME agent that was exhausted
            try {
                if ($Agent -eq "codex") {
                    $testOutput = "Reply with just the word READY" | codex exec --full-auto - 2>&1
                } elseif ($Agent -eq "gemini") {
                    $testOutput = "Reply with just the word READY" | gemini --approval-mode plan 2>&1
                } elseif (Test-IsOpenAICompatAgent -AgentName $Agent) {
                    $testOutput = Invoke-OpenAICompatibleAgent -AgentName $Agent -Prompt "Reply with just the word READY" -TimeoutSeconds 30
                } else {
                    $testOutput = claude -p "Reply with just the word READY" 2>&1
                }

                # Track probe token cost (small but adds up over 24 cycles)
                if ($GsdDir) {
                    try {
                        $probeData = @{
                            Tokens   = @{ input = 20; output = 5; cached = 0 }
                            CostUsd  = 0.0001
                            TextOutput = "quota probe"
                            DurationMs = 0
                            NumTurns   = 1
                            Estimated  = $true
                        }
                        $pipelineType = if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
                        Save-TokenUsage -GsdDir $GsdDir -Agent $Agent -Phase "quota-probe" `
                            -Iteration 0 -Pipeline $pipelineType -BatchSize 0 `
                            -Success $false -TokenData $probeData
                    } catch { }
                }

                if ($testOutput -match "READY") {
                    Write-Host "    [OK] $Agent quota reset after ${currentSleep}min. Resuming..." -ForegroundColor Green
                    return $true
                }
                $quotaCheck = Test-IsQuotaError ($testOutput -join "`n")
                if ($quotaCheck -eq "none") {
                    Write-Host "    [OK] $Agent quota available. Resuming..." -ForegroundColor Green
                    return $true
                }
            } catch {
                # Still limited, continue sleeping
            }
            # Exponential backoff: 5 -> 10 -> 20 -> 40 -> 60 -> 60...
            $currentSleep = [math]::Min($script:QUOTA_SLEEP_MAX, $currentSleep * $script:QUOTA_SLEEP_BACKOFF)
            Write-Host "    Still limited. Next sleep: ${currentSleep}min..." -ForegroundColor DarkYellow
        }

        Write-Host "    [XX] Quota did not reset after $($script:QUOTA_MAX_SLEEPS) sleep cycles." -ForegroundColor Red
        return $false
    }

    return $true
}

# ===========================================
# 3. NETWORK CONNECTIVITY POLLING
# ===========================================

function Wait-ForNetwork {
    <#
    .SYNOPSIS
        Polls for internet connectivity using fast HTTP check. Returns true when online, false after timeout.
        Uses lightweight HTTP HEAD to api.anthropic.com instead of claude CLI (which can hang).
    #>
    param([string]$GsdDir)

    # Fast HTTP-based connectivity check (5s timeout, no CLI dependency)
    function Test-NetworkFast {
        try {
            $null = Invoke-WebRequest -Uri "https://api.anthropic.com" -Method HEAD `
                -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            return $true
        }
        catch {
            # Any HTTP response (even 4xx) means network is reachable
            if ($_.Exception.Response) { return $true }
            return $false
        }
    }

    # Quick check first
    if (Test-NetworkFast) { return $true }

    Write-Host "    Network unavailable. Polling every $($script:NETWORK_POLL_SECONDS)s (max $($script:NETWORK_MAX_POLLS) polls)..." -ForegroundColor Yellow
    Write-GsdError -GsdDir $GsdDir -Category "network" -Phase "connectivity" -Iteration 0 `
        -Message "Network unavailable" -Resolution "Polling for connectivity"

    $polls = 0
    while ($polls -lt $script:NETWORK_MAX_POLLS) {
        $polls++
        Start-Sleep -Seconds $script:NETWORK_POLL_SECONDS

        if (Test-NetworkFast) {
            Write-Host "    [OK] Network restored after $($polls * $script:NETWORK_POLL_SECONDS)s" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "    Still offline... (poll $polls/$($script:NETWORK_MAX_POLLS))" -ForegroundColor DarkGray
        }
    }

    Write-Host "    [!!] Network did not recover after $($script:NETWORK_MAX_POLLS * $script:NETWORK_POLL_SECONDS)s - skipping" -ForegroundColor Red
    return $false
}

# ===========================================
# 4. PER-ITERATION DISK CHECK
# ===========================================

function Test-DiskSpace {
    param(
        [string]$RepoRoot,
        [string]$GsdDir
    )

    $drive = (Get-Item $RepoRoot).PSDrive
    $freeGB = [math]::Round($drive.Free / 1GB, 2)

    if ($freeGB -lt $script:DISK_MIN_FREE_GB) {
        Write-Host "    [XX] Low disk: ${freeGB}GB (need $($script:DISK_MIN_FREE_GB)GB)" -ForegroundColor Red

        # Try cleanup
        Write-Host "    Attempting cleanup..." -ForegroundColor DarkYellow
        $cleaned = $false

        # Clean node_modules/.cache
        $cacheDir = Join-Path $RepoRoot "node_modules\.cache"
        if (Test-Path $cacheDir) {
            Remove-Item $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
            $cleaned = $true
        }

        # Clean bin/obj
        Get-ChildItem -Path $RepoRoot -Include "bin","obj" -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue; $cleaned = $true }

        # Clean old logs (keep last 5)
        $logDir = Join-Path $GsdDir "logs"
        if (Test-Path $logDir) {
            Get-ChildItem $logDir -File | Sort-Object LastWriteTime -Descending |
                Select-Object -Skip 20 | Remove-Item -Force -ErrorAction SilentlyContinue
            $cleaned = $true
        }

        $newFreeGB = [math]::Round($drive.Free / 1GB, 2)
        if ($newFreeGB -ge $script:DISK_MIN_FREE_GB) {
            Write-Host "    [OK] Cleaned up. Now ${newFreeGB}GB free." -ForegroundColor Green
            return $true
        } else {
            Write-GsdError -GsdDir $GsdDir -Category "disk" -Phase "check" -Iteration 0 `
                -Message "Disk too low: ${newFreeGB}GB" -Resolution "Manual cleanup needed"
            return $false
        }
    }

    return $true
}

# ===========================================
# 5. AGENT BOUNDARY ENFORCEMENT
# ===========================================

function Test-AgentBoundaries {
    <#
    .SYNOPSIS
        After an agent runs, verify it didn't modify files outside its boundary.
        Compares against a baseline of pre-existing dirty files to avoid false positives.
    #>
    param(
        [string]$Agent,       # "claude", "codex", "gemini", "gemini-research", or "gemini-spec-fix"
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$Pipeline,
        [string[]]$BaselineDirty = @()   # Files already dirty before agent ran
    )

    # Get files modified since last commit
    $changedFiles = git -C $RepoRoot diff --name-only HEAD 2>$null
    if (-not $changedFiles) { return $true }

    # Only check files the agent actually changed (exclude pre-existing dirty files)
    $agentChanged = $changedFiles | Where-Object { $_ -notin $BaselineDirty }
    if (-not $agentChanged -or @($agentChanged).Count -eq 0) { return $true }

    $violations = @()

    if ($Agent -eq "claude") {
        # Claude should NOT modify source code
        $agentChanged | ForEach-Object {
            if ($_ -notmatch "^\.gsd" -and $_ -notmatch "^\.vscode") {
                $violations += $_
            }
        }
        if ($violations.Count -gt 0) {
            Write-Host "    [!!]  Claude modified source code (boundary violation):" -ForegroundColor DarkYellow
            $violations | Select-Object -First 5 | ForEach-Object {
                Write-Host "      - $_" -ForegroundColor DarkYellow
            }
            Write-GsdError -GsdDir $GsdDir -Category "boundary_violation" -Phase "enforcement" -Iteration 0 `
                -Message "Claude modified $($violations.Count) source files" `
                -Resolution "Reverting source changes, keeping .gsd changes"

            # Revert source changes but keep .gsd changes
            $violations | ForEach-Object {
                git -C $RepoRoot checkout HEAD -- $_ 2>$null
            }
            return $false
        }
    }

    if ($Agent -eq "codex") {
        # Codex should NOT modify .gsd/health, .gsd/code-review, .gsd/generation-queue, .gsd/blueprint (except build-log)
        $protectedPaths = @(".gsd/health", ".gsd/code-review", ".gsd/generation-queue", ".gsd/blueprint/blueprint.json", ".gsd/blueprint/health.json", ".gsd/blueprint/next-batch.json")
        $agentChanged | ForEach-Object {
            $file = $_
            foreach ($p in $protectedPaths) {
                if ($file -like "$p*" -and $file -notmatch "build-log|handoff-log") {
                    $violations += $file
                }
            }
        }
        if ($violations.Count -gt 0) {
            Write-Host "    [!!]  Codex modified protected GSD files (boundary violation):" -ForegroundColor DarkYellow
            $violations | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow }

            # Revert protected file changes
            $violations | ForEach-Object { git -C $RepoRoot checkout HEAD -- $_ 2>$null }
            return $false
        }
    }

    if ($Agent -eq "gemini-research" -or $Agent -eq "gemini") {
        # Gemini research (plan mode) should NOT modify ANY files
        if ($agentChanged -and @($agentChanged).Count -gt 0) {
            $violations = @($agentChanged)
            Write-Host "    [!!]  Gemini (research/plan) modified files (boundary violation):" -ForegroundColor DarkYellow
            $violations | Select-Object -First 5 | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow }
            $violations | ForEach-Object { git -C $RepoRoot checkout HEAD -- $_ 2>$null }
            return $false
        }
    }

    if ($Agent -eq "gemini-spec-fix") {
        # Gemini spec-fix (--yolo) may ONLY modify docs\ and .gsd\spec-conflicts\
        $agentChanged | ForEach-Object {
            if ($_ -notmatch "^docs[\\/]" -and $_ -notmatch "^\.gsd[\\/]spec-conflicts" -and $_ -notmatch "_analysis[\\/]") {
                $violations += $_
            }
        }
        if ($violations.Count -gt 0) {
            Write-Host "    [!!]  Gemini (spec-fix) modified files outside docs/spec-conflicts (boundary violation):" -ForegroundColor DarkYellow
            $violations | Select-Object -First 5 | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow }
            $violations | ForEach-Object { git -C $RepoRoot checkout HEAD -- $_ 2>$null }
            return $false
        }
    }

    return $true
}

# ===========================================
# 6. CLI VERSION VALIDATION
# ===========================================

function Test-CliVersions {
    param([string]$GsdDir)

    Write-Host "    Checking CLI versions..." -ForegroundColor DarkGray

    # Claude
    try {
        $claudeVer = claude --version 2>&1
        Write-Host "    [OK] claude: $($claudeVer | Select-Object -First 1)" -ForegroundColor DarkGreen
    } catch {
        Write-Host "    [XX] claude CLI not responding" -ForegroundColor Red
        return $false
    }

    # Codex
    try {
        $codexVer = codex --version 2>&1
        Write-Host "    [OK] codex: $($codexVer | Select-Object -First 1)" -ForegroundColor DarkGreen
    } catch {
        Write-Host "    [XX] codex CLI not responding" -ForegroundColor Red
        return $false
    }

    # Gemini (optional - used for research and spec-fix)
    try {
        $geminiVer = gemini --version 2>&1
        Write-Host "    [OK] gemini: $($geminiVer | Select-Object -First 1)" -ForegroundColor DarkGreen
    } catch {
        Write-Host "    [!!]  gemini CLI not found (research/spec-fix will fall back to codex)" -ForegroundColor DarkYellow
    }

    # dotnet (optional but recommended)
    try {
        $dotnetVer = dotnet --version 2>&1
        Write-Host "    [OK] dotnet: $dotnetVer" -ForegroundColor DarkGreen
        if ($dotnetVer -notmatch "^8\.") {
            Write-Host "    [!!]  Expected .NET 8.x, found $dotnetVer" -ForegroundColor DarkYellow
        }
    } catch {
        Write-Host "    [!!]  dotnet not found - build validation will be limited" -ForegroundColor DarkYellow
    }

    # Node/npm (optional but recommended)
    try {
        $nodeVer = node --version 2>&1
        $npmVer = npm --version 2>&1
        Write-Host "    [OK] node: $nodeVer / npm: $npmVer" -ForegroundColor DarkGreen
    } catch {
        Write-Host "    [!!]  node/npm not found - frontend build validation limited" -ForegroundColor DarkYellow
    }

    # sqlcmd (optional)
    try {
        $null = sqlcmd -? 2>&1
        Write-Host "    [OK] sqlcmd: available (SQL linting enabled)" -ForegroundColor DarkGreen
        $script:HasSqlCmd = $true
    } catch {
        Write-Host "    [>>]  sqlcmd not found (SQL linting disabled)" -ForegroundColor DarkGray
        $script:HasSqlCmd = $false
    }

    return $true
}

# ===========================================
# 7. SQL SYNTAX LINTING
# ===========================================

function Test-SqlFiles {
    <#
    .SYNOPSIS
        Basic SQL syntax validation on new/modified .sql files.
        Uses sqlcmd if available, otherwise does basic pattern checks.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [int]$Iteration
    )

    $sqlFiles = git -C $RepoRoot diff --name-only HEAD 2>$null |
        Where-Object { $_ -match "\.sql$" }

    if (-not $sqlFiles -or $sqlFiles.Count -eq 0) { return @{ Passed = $true; Errors = @() } }

    Write-Host "    [SEARCH] Checking $($sqlFiles.Count) SQL files..." -ForegroundColor DarkGray
    $sqlErrors = @()

    foreach ($sqlFile in $sqlFiles) {
        $fullPath = Join-Path $RepoRoot $sqlFile
        if (-not (Test-Path $fullPath)) { continue }

        $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Basic pattern checks (works without sqlcmd)
        # Check for inline SQL anti-patterns
        if ($content -match "string\.Format|`"\s*\+\s*.*SELECT|\$`".*SELECT") {
            $sqlErrors += "$sqlFile : Possible string concatenation in SQL (use parameterized queries)"
        }

        # Check for missing TRY/CATCH in stored procedures
        if ($content -match "CREATE\s+(OR\s+ALTER\s+)?PROC" -and $content -notmatch "TRY.*CATCH") {
            $sqlErrors += "$sqlFile : Stored procedure missing TRY/CATCH block"
        }

        # Check for missing audit columns in CREATE TABLE
        if ($content -match "CREATE\s+TABLE" -and $content -notmatch "CreatedAt") {
            $sqlErrors += "$sqlFile : CREATE TABLE missing audit columns (CreatedAt, ModifiedAt)"
        }
    }

    if ($sqlErrors.Count -gt 0) {
        Write-Host "    [!!]  SQL issues found:" -ForegroundColor DarkYellow
        $sqlErrors | Select-Object -First 5 | ForEach-Object {
            Write-Host "      - $_" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "    [OK] SQL files OK" -ForegroundColor DarkGreen
    }

    return @{ Passed = ($sqlErrors.Count -eq 0); Errors = $sqlErrors }
}

# ===========================================
# 8. FAILURE DIAGNOSIS + AGENT FALLBACK
# ===========================================

function Get-FailureDiagnosis {
    <#
    .SYNOPSIS
        Analyzes agent failure output to diagnose root cause and recommend recovery action.
        Returns: @{ Diagnosis; Action (retry|fallback|fail); FallbackAgent; FallbackMode }
    #>
    param(
        [string]$Agent,
        [int]$ExitCode,
        [string]$OutputText,
        [string]$Phase
    )

    $diagnosis = ""
    $action = "retry"
    $fallbackAgent = $null
    $fallbackMode = $null

    # -- Gemini-specific diagnostics --
    if ($Agent -eq "gemini") {
        if ($OutputText -match "sandbox.*restrict|plan.*mode.*restrict|not.*allow|permission.*denied|read.only") {
            $diagnosis = "Gemini plan mode blocked a write operation"
        } elseif ($OutputText -match "model.*not.*found|model.*unavail|invalid.*model|unsupported.*model") {
            $diagnosis = "Gemini model unavailable"
        } elseif ($OutputText -match "too.*large|input.*limit|prompt.*too|content.*length") {
            $diagnosis = "Prompt too large for Gemini context"
        } elseif ($OutputText -match "internal.*error|server.*error|50[0-9]") {
            $diagnosis = "Gemini server error (transient)"
        } elseif (-not $OutputText -or $OutputText.Trim().Length -eq 0) {
            $diagnosis = "Gemini produced no output (CLI crash or argument error)"
        } else {
            $diagnosis = "Gemini exit code $ExitCode"
        }

        # Gemini can fall back to codex for any phase
        $action = "fallback"
        $fallbackAgent = "codex"
        $fallbackMode = "exec --full-auto -"
    }

    # -- Codex-specific diagnostics --
    elseif ($Agent -eq "codex") {
        if ($OutputText -match "loop.*detect|iteration.*limit|max.*turns") {
            $diagnosis = "Codex hit loop/iteration limit"
        } elseif ($OutputText -match "internal.*error|server.*error|50[0-9]") {
            $diagnosis = "Codex server error (transient)"
        } elseif (-not $OutputText -or $OutputText.Trim().Length -eq 0) {
            $diagnosis = "Codex produced no output"
        } else {
            $diagnosis = "Codex exit code $ExitCode"
        }
        # Codex can fall back to claude for read-only phases
        if ($Phase -match "research|review|verify|plan") {
            $action = "fallback"
            $fallbackAgent = "claude"
        }
    }

    # -- Claude-specific diagnostics --
    elseif ($Agent -eq "claude") {
        if ($OutputText -match "max.*turns|turn.*limit") {
            $diagnosis = "Claude hit max turns limit"
        } elseif (-not $OutputText -or $OutputText.Trim().Length -eq 0) {
            $diagnosis = "Claude produced no output"
        } else {
            $diagnosis = "Claude exit code $ExitCode"
        }
        # Claude has no fallback - it's the most capable agent
        $action = "retry"
    }

    # -- OpenAI-compatible REST agents (kimi, deepseek, glm5, minimax) --
    elseif ((Get-Command Test-IsOpenAICompatAgent -ErrorAction SilentlyContinue) -and (Test-IsOpenAICompatAgent -AgentName $Agent)) {
        if ($OutputText -match "rate_limit|429|too.many.requests") {
            $diagnosis = "$Agent rate-limited (HTTP 429)"
        } elseif ($OutputText -match "quota_exhausted|402|payment|insufficient") {
            $diagnosis = "$Agent quota exhausted"
        } elseif ($OutputText -match "unauthorized|401|invalid.*key|auth") {
            $diagnosis = "$Agent authentication failed (check API key)"
            $action = "fail"
        } elseif ($OutputText -match "server_error|500|502|503|504") {
            $diagnosis = "$Agent server error (transient)"
        } elseif ($OutputText -match "timeout|timed.out|deadline") {
            $diagnosis = "$Agent request timed out"
        } elseif (-not $OutputText -or $OutputText.Trim().Length -eq 0) {
            $diagnosis = "$Agent produced no output"
        } else {
            $diagnosis = "$Agent exit code $ExitCode"
        }
        # REST agents fall back to claude for read-only phases, retry for write phases
        if ($Phase -match "research|review|verify|plan|council") {
            $action = "fallback"
            $fallbackAgent = "claude"
        } else {
            $action = "retry"
        }
    }

    else {
        $diagnosis = "Unknown agent '$Agent' exit code $ExitCode"
    }

    return @{
        Diagnosis = $diagnosis
        Action = $action
        FallbackAgent = $fallbackAgent
        FallbackMode = $fallbackMode
    }
}

function Invoke-AgentFallback {
    <#
    .SYNOPSIS
        Attempts to run the same prompt with a fallback agent.
        Returns: @{ Success; Output; ExitCode; TokenData }
    #>
    param(
        [string]$FallbackAgent,
        [string]$Prompt,
        [string]$AllowedTools = "Read,Write,Bash,mcp__*",
        [string]$LogFile
    )

    $fbOutput = $null
    $fbExit = 1
    $fbTokenData = $null

    try {
        if ($FallbackAgent -eq "codex") {
            $codexFbArgs = @("exec", "--full-auto", "--json", "-")
            $codexFbEffort = $env:GSD_CODEX_EFFORT
            if ($codexFbEffort) { $codexFbArgs = @("exec", "--full-auto", "--json", "-c", "model_reasoning_effort=$codexFbEffort", "-") }
            $rawOutput = $Prompt | codex @codexFbArgs 2>&1
            $fbExit = $LASTEXITCODE
            $parsed = Extract-TokensFromOutput -Agent "codex" -RawOutput ($rawOutput -join "`n")
            if ($parsed -and $parsed.TextOutput) {
                $fbOutput = $parsed.TextOutput -split "`n"
                $fbTokenData = $parsed
            } else {
                $fbOutput = $rawOutput
            }
        } elseif ($FallbackAgent -eq "claude") {
            $rawOutput = claude -p $Prompt --allowedTools $AllowedTools --output-format json 2>&1
            $fbExit = $LASTEXITCODE
            $parsed = Extract-TokensFromOutput -Agent "claude" -RawOutput ($rawOutput -join "`n")
            if ($parsed -and $parsed.TextOutput) {
                $fbOutput = $parsed.TextOutput -split "`n"
                $fbTokenData = $parsed
            } else {
                $fbOutput = $rawOutput
            }
        } elseif ($FallbackAgent -eq "gemini") {
            $rawOutput = $Prompt | gemini --approval-mode plan --output-format json 2>&1
            $fbExit = $LASTEXITCODE
            $parsed = Extract-TokensFromOutput -Agent "gemini" -RawOutput ($rawOutput -join "`n")
            if ($parsed -and $parsed.TextOutput) {
                $fbOutput = $parsed.TextOutput -split "`n"
                $fbTokenData = $parsed
            } else {
                $fbOutput = $rawOutput
            }
        } elseif (Test-IsOpenAICompatAgent -AgentName $FallbackAgent) {
            $rawOutput = Invoke-OpenAICompatibleAgent -AgentName $FallbackAgent -Prompt $Prompt
            $fbExit = if ($rawOutput -match "^(unauthorized|rate_limit|error|server_error|quota_exhausted)") { 1 } else { 0 }
            $parsed = Extract-TokensFromOutput -Agent $FallbackAgent -RawOutput $rawOutput
            if ($parsed -and $parsed.TextOutput) {
                $fbOutput = $parsed.TextOutput -split "`n"
                $fbTokenData = $parsed
            } else {
                $fbOutput = @($rawOutput)
            }
        }

        if ($LogFile -and $fbOutput) {
            $fbOutput | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        }
    } catch {
        $fbExit = 1
    }

    return @{
        Success = ($fbExit -eq 0 -and $fbOutput -and $fbOutput.Count -gt 0)
        Output = $fbOutput
        ExitCode = $fbExit
        TokenData = $fbTokenData
    }
}

# ===========================================
# 9. ENHANCED INVOKE-WITHRETRY (quota-aware + self-healing)
# ===========================================

# Override the original Invoke-WithRetry with quota + network + diagnosis awareness
$script:OriginalInvokeWithRetry = ${function:Invoke-WithRetry}

function Invoke-WithRetry {
    param(
        [string]$Agent,           # "claude", "codex", or "gemini"
        [string]$Prompt,
        [string]$Phase,
        [string]$LogFile,
        [int]$Attempt = 1,
        [int]$MaxAttempts = $script:RETRY_MAX,
        [int]$CurrentBatchSize = 15,
        [string]$GsdDir,
        [string]$AllowedTools = "Read,Write,Bash,mcp__*",
        [string]$GeminiMode = "--approval-mode plan"   # "--approval-mode plan" (read-only) or "--yolo" (write)
    )

    $result = @{ Success = $false; Attempts = 0; FinalBatchSize = $CurrentBatchSize; Error = $null }

    # Cumulative quota wait tracking (Fix P3)
    $totalQuotaWaitMinutes = 0
    $consecutiveQuotaFails = @{}  # Per-agent: @{ "codex" = 3; "gemini" = 1 }

    for ($i = $Attempt; $i -le $MaxAttempts; $i++) {
        $result.Attempts = $i

        # -- Pre-check: network --
        $networkOk = Wait-ForNetwork -GsdDir $GsdDir
        if (-not $networkOk) {
            $result.Error = "Network unavailable after max polling"
            return $result
        }

        # -- Pre-check: disk --
        $diskOk = Test-DiskSpace -RepoRoot (Get-Location).Path -GsdDir $GsdDir
        if (-not $diskOk) {
            $result.Error = "Insufficient disk space"
            return $result
        }

        $effectivePrompt = $Prompt.Replace("{{BATCH_SIZE}}", "$CurrentBatchSize")
        Write-Host "    Attempt $i/$MaxAttempts (batch: $CurrentBatchSize)..." -ForegroundColor DarkGray

        # Snapshot dirty files BEFORE agent runs (to avoid false boundary violations)
        $baselineDirty = @(git diff --name-only HEAD 2>$null)

        try {
            $exitCode = 0
            $output = $null
            $tokenData = $null
            $callStart = Get-Date

            if ($Agent -eq "claude") {
                # Use --output-format json to capture token usage + cost data
                $rawOutput = claude -p $effectivePrompt --allowedTools $AllowedTools --output-format json 2>&1
                $exitCode = $LASTEXITCODE
                $parsed = Extract-TokensFromOutput -Agent "claude" -RawOutput ($rawOutput -join "`n")
                if ($parsed -and $parsed.TextOutput) {
                    $output = $parsed.TextOutput -split "`n"
                    $tokenData = $parsed
                } else {
                    $output = $rawOutput  # Fallback: preserve current behavior
                }
            } elseif ($Agent -eq "codex") {
                # Pass prompt via stdin, use --json to capture token usage
                # GSD_CODEX_EFFORT env var overrides reasoning level per-call (e.g. "medium" for bulk tasks)
                $codexArgs = @("exec", "--full-auto", "--json", "-")
                $codexEffort = $env:GSD_CODEX_EFFORT
                if ($codexEffort) { $codexArgs = @("exec", "--full-auto", "--json", "-c", "model_reasoning_effort=$codexEffort", "-") }
                $rawOutput = $effectivePrompt | codex @codexArgs 2>&1
                $exitCode = $LASTEXITCODE
                $parsed = Extract-TokensFromOutput -Agent "codex" -RawOutput ($rawOutput -join "`n")
                if ($parsed -and $parsed.TextOutput) {
                    $output = $parsed.TextOutput -split "`n"
                    $tokenData = $parsed
                } else {
                    $output = $rawOutput
                }
            } elseif ($Agent -eq "gemini") {
                # Gemini CLI: --approval-mode plan (read-only) or --yolo (write)
                $geminiArgs = $GeminiMode.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
                $rawOutput = $effectivePrompt | gemini @geminiArgs --output-format json 2>&1
                $exitCode = $LASTEXITCODE
                $parsed = Extract-TokensFromOutput -Agent "gemini" -RawOutput ($rawOutput -join "`n")
                if ($parsed -and $parsed.TextOutput) {
                    $output = $parsed.TextOutput -split "`n"
                    $tokenData = $parsed
                } else {
                    $output = $rawOutput
                }
            } elseif (Test-IsOpenAICompatAgent -AgentName $Agent) {
                # OpenAI-compatible REST API agents (kimi, deepseek, glm5, minimax, etc.)
                $rawOutput = Invoke-OpenAICompatibleAgent -AgentName $Agent -Prompt $effectivePrompt
                $exitCode = if ($rawOutput -match "^(unauthorized|rate_limit|error|server_error|quota_exhausted)") { 1 } else { 0 }
                $parsed = Extract-TokensFromOutput -Agent $Agent -RawOutput $rawOutput
                if ($parsed -and $parsed.TextOutput) {
                    $output = $parsed.TextOutput -split "`n"
                    $tokenData = $parsed
                } else {
                    $output = @($rawOutput)
                }
            }

            # Calculate call duration from wall clock if not in JSON data
            $callDuration = [int]((Get-Date) - $callStart).TotalSeconds
            if ($tokenData -and $tokenData.DurationMs -eq 0) {
                $tokenData.DurationMs = $callDuration * 1000
            }

            if ($LogFile) { $output | Out-File -FilePath $LogFile -Encoding UTF8 -Append }

            $outputText = if ($output) { $output -join "`n" } else { "" }

            # -- Check for quota errors --
            $quotaType = Test-IsQuotaError $outputText
            if ($quotaType -ne "none") {
                # Track tokens consumed by this failed attempt
                $trackData = if ($tokenData) { $tokenData } else {
                    New-EstimatedTokenData -Agent $Agent -PromptText $effectivePrompt -ErrorType $quotaType
                }
                if ($GsdDir) {
                    try {
                        $pipelineType = if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
                        Save-TokenUsage -GsdDir $GsdDir -Agent $Agent -Phase $Phase `
                            -Iteration $i -Pipeline $pipelineType -BatchSize $CurrentBatchSize `
                            -Success $false -TokenData $trackData
                    } catch { }
                }

                # Track consecutive quota failures per agent
                if (-not $consecutiveQuotaFails.ContainsKey($Agent)) {
                    $consecutiveQuotaFails[$Agent] = 0
                }
                $consecutiveQuotaFails[$Agent]++

                Write-GsdError -GsdDir $GsdDir -Category "quota" -Phase $Phase -Iteration $i `
                    -Message "$Agent $quotaType" -Resolution "Waiting for reset"

                # Rotate to different agent after N consecutive quota hits
                if ($consecutiveQuotaFails[$Agent] -ge $script:QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE) {
                    $rotatedAgent = Get-NextAvailableAgent -CurrentAgent $Agent -GsdDir $GsdDir
                    if ($rotatedAgent) {
                        Write-Host "    [ROTATE] $Agent exhausted $($consecutiveQuotaFails[$Agent])x. Switching to $rotatedAgent" -ForegroundColor Yellow
                        Write-GsdError -GsdDir $GsdDir -Category "agent_rotate" -Phase $Phase -Iteration $i `
                            -Message "$Agent -> $rotatedAgent after $($consecutiveQuotaFails[$Agent]) consecutive quota failures" `
                            -Resolution "Rotated agent"
                        Set-AgentCooldown -Agent $Agent -GsdDir $GsdDir -CooldownMinutes 30
                        $Agent = $rotatedAgent
                        $consecutiveQuotaFails[$rotatedAgent] = 0
                        $i--
                        continue
                    }
                }

                # Check cumulative wait cap
                if ($totalQuotaWaitMinutes -ge $script:QUOTA_CUMULATIVE_MAX_MINUTES) {
                    Write-Host "    [XX] Cumulative quota wait ($totalQuotaWaitMinutes min) exceeds cap ($($script:QUOTA_CUMULATIVE_MAX_MINUTES) min). Giving up." -ForegroundColor Red
                    $result.Error = "Quota exhausted: waited $totalQuotaWaitMinutes min total across all agents"
                    return $result
                }

                # Engine status: sleeping for quota backoff
                if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                    Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -SleepReason "quota_backoff" -LastError "$Agent $quotaType"
                }

                $waitStart = Get-Date
                $quotaOk = Wait-ForQuotaReset -QuotaType $quotaType -Agent $Agent -GsdDir $GsdDir
                $waitElapsed = ((Get-Date) - $waitStart).TotalMinutes
                $totalQuotaWaitMinutes += $waitElapsed

                if ($quotaOk) {
                    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                        Update-EngineStatus -GsdDir $GsdDir -State "running" -RecoveredFromError $true
                    }
                    $consecutiveQuotaFails[$Agent] = 0
                    $i--
                    continue
                } else {
                    # Quota didn't reset -- try rotating before giving up
                    $rotatedAgent = Get-NextAvailableAgent -CurrentAgent $Agent -GsdDir $GsdDir
                    if ($rotatedAgent) {
                        Write-Host "    [ROTATE] $Agent quota didn't reset. Trying $rotatedAgent" -ForegroundColor Yellow
                        Set-AgentCooldown -Agent $Agent -GsdDir $GsdDir -CooldownMinutes 30
                        $Agent = $rotatedAgent
                        $i--
                        continue
                    }
                    $result.Error = "Quota exhausted and did not reset after $([math]::Round($totalQuotaWaitMinutes)) min"
                    return $result
                }
            }

            # -- Check for auth errors (not retryable) --
            if ($outputText -match "(unauthorized|invalid.*key|auth.*fail|401)" -and
    $outputText -notmatch "(rate|quota|resource.exhausted|too.many|throttl)") {
                # Track tokens consumed by auth-failed attempt
                $trackData = if ($tokenData) { $tokenData } else {
                    New-EstimatedTokenData -Agent $Agent -PromptText $effectivePrompt -ErrorType "auth"
                }
                if ($GsdDir) {
                    try {
                        $pipelineType = if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
                        Save-TokenUsage -GsdDir $GsdDir -Agent $Agent -Phase $Phase `
                            -Iteration $i -Pipeline $pipelineType -BatchSize $CurrentBatchSize `
                            -Success $false -TokenData $trackData
                    } catch { }
                }
                $result.Error = "AUTH_ERROR"
                Write-Host "    [XX] Auth error - cannot retry" -ForegroundColor Red
                return $result
            }

            # -- Check for other failures --
            $isTokenError = $outputText -match "(token limit|context.*(window|length)|too long|exceeded.*limit|max.*tokens)"
            $isTimeout = $outputText -match "(timeout|timed out|ETIMEDOUT|connection.*reset)"
            $isCrash = ($exitCode -ne 0) -or (-not $output) -or ($output.Count -eq 0)

            if ($isCrash -and $i -lt $MaxAttempts) {
                # Track tokens consumed by crashed attempt
                $trackData = if ($tokenData) { $tokenData } else {
                    New-EstimatedTokenData -Agent $Agent -PromptText $effectivePrompt -ErrorType "crash"
                }
                if ($GsdDir) {
                    try {
                        $pipelineType = if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
                        Save-TokenUsage -GsdDir $GsdDir -Agent $Agent -Phase $Phase `
                            -Iteration $i -Pipeline $pipelineType -BatchSize $CurrentBatchSize `
                            -Success $false -TokenData $trackData
                    } catch { }
                }

                if ($isTokenError) {
                    # Token/context limit -> reduce batch size (smaller batch = fewer tokens)
                    $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * $script:BATCH_REDUCTION_FACTOR))
                    $result.FinalBatchSize = $CurrentBatchSize
                    $reason = "token limit"
                    Write-Host "    [!!]  $reason -> batch $CurrentBatchSize. Retry in $($script:RETRY_DELAY_SECONDS)s..." -ForegroundColor DarkYellow
                    Write-GsdError -GsdDir $GsdDir -Category "agent_crash" -Phase $Phase -Iteration $i `
                        -Message "$Agent $reason" -Resolution "Batch reduced to $CurrentBatchSize"
                } else {
                    # Non-token failure -> diagnose root cause and attempt fallback
                    $reason = if ($isTimeout) { "timeout" } else { "exit code $exitCode" }
                    $recovery = Get-FailureDiagnosis -Agent $Agent -ExitCode $exitCode `
                        -OutputText $outputText -Phase $Phase
                    Write-Host "    [!!]  $reason - $($recovery.Diagnosis)" -ForegroundColor DarkYellow

                    # Attempt fallback to alternative agent
                    if ($recovery.Action -eq "fallback" -and $recovery.FallbackAgent) {
                        Write-Host "    [SYNC] Falling back: $Agent -> $($recovery.FallbackAgent)..." -ForegroundColor Yellow
                        $fb = Invoke-AgentFallback -FallbackAgent $recovery.FallbackAgent `
                            -Prompt $effectivePrompt -AllowedTools $AllowedTools -LogFile $LogFile

                        if ($fb.Success) {
                            Write-Host "    [OK] Fallback to $($recovery.FallbackAgent) succeeded" -ForegroundColor Green
                            Write-GsdError -GsdDir $GsdDir -Category "fallback_success" -Phase $Phase -Iteration $i `
                                -Message "$Agent failed ($($recovery.Diagnosis)), $($recovery.FallbackAgent) succeeded" `
                                -Resolution "Completed via fallback agent"
                            $result.Success = $true
                            $result.FinalBatchSize = $CurrentBatchSize

                            # Post-checks still apply
                            Invoke-ValidateAllState -GsdDir $GsdDir -Pipeline $(
                                if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
                            ) | Out-Null
                            Test-AgentBoundaries -Agent $recovery.FallbackAgent `
                                -RepoRoot (Get-Location).Path -GsdDir $GsdDir -Pipeline "any" `
                                -BaselineDirty $baselineDirty | Out-Null

                            # Save fallback token usage
                            if ($fb.TokenData -and $GsdDir) {
                                try {
                                    $pipelineType = if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
                                    Save-TokenUsage -GsdDir $GsdDir -Agent $recovery.FallbackAgent -Phase $Phase `
                                        -Iteration $i -Pipeline $pipelineType -BatchSize $CurrentBatchSize `
                                        -Success $true -IsFallback $true -TokenData $fb.TokenData
                                } catch { }
                            }

                            return $result
                        } else {
                            Write-Host "    [!!]  Fallback to $($recovery.FallbackAgent) also failed (exit $($fb.ExitCode))" -ForegroundColor DarkYellow
                        }
                    }

                    Write-Host "    Retry $($i+1)/$MaxAttempts in $($script:RETRY_DELAY_SECONDS)s (batch unchanged: $CurrentBatchSize)..." -ForegroundColor DarkYellow
                    Write-GsdError -GsdDir $GsdDir -Category "agent_crash" -Phase $Phase -Iteration $i `
                        -Message "$Agent $reason ($($recovery.Diagnosis))" `
                        -Resolution "Retrying at same batch $CurrentBatchSize"
                }
                Start-Sleep -Seconds $script:RETRY_DELAY_SECONDS
                continue
            }

            if (-not $isCrash) {
                $result.Success = $true
                $result.FinalBatchSize = $CurrentBatchSize

                # -- Post-check: validate JSON outputs --
                Invoke-ValidateAllState -GsdDir $GsdDir -Pipeline $(
                    if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
                ) | Out-Null

                # -- Post-check: boundary enforcement (with baseline to avoid false positives) --
                $boundaryAgent = switch ($Agent) {
                    "claude" { "claude" }
                    "codex"  { "codex" }
                    "gemini" {
                        # Map gemini mode to boundary role
                        if ($GeminiMode -match "yolo") { "gemini-spec-fix" } else { "gemini-research" }
                    }
                    default  { $Agent }
                }
                Test-AgentBoundaries -Agent $boundaryAgent `
                    -RepoRoot (Get-Location).Path -GsdDir $GsdDir -Pipeline "any" `
                    -BaselineDirty $baselineDirty | Out-Null

                # -- Save token usage on success --
                if ($tokenData -and $GsdDir) {
                    try {
                        $pipelineType = if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
                        Save-TokenUsage -GsdDir $GsdDir -Agent $Agent -Phase $Phase `
                            -Iteration $i -Pipeline $pipelineType -BatchSize $CurrentBatchSize `
                            -Success $true -TokenData $tokenData
                    } catch { }
                }

                return $result
            }

        } catch {
            $result.Error = $_.Exception.Message
            Write-Host "    [XX] Exception: $($_.Exception.Message)" -ForegroundColor Red

            if ($i -lt $MaxAttempts) {
                # Don't reduce batch for exceptions - retry at same size
                Start-Sleep -Seconds $script:RETRY_DELAY_SECONDS
            }
        }
    }

    if (-not $result.Error) { $result.Error = "All $MaxAttempts attempts failed" }

    # Save token usage on failure (last attempt's data if available)
    if ($tokenData -and $GsdDir) {
        try {
            $pipelineType = if (Test-Path "$GsdDir\blueprint") { "blueprint" } else { "converge" }
            Save-TokenUsage -GsdDir $GsdDir -Agent $Agent -Phase $Phase `
                -Iteration $MaxAttempts -Pipeline $pipelineType -BatchSize $CurrentBatchSize `
                -Success $false -TokenData $tokenData
        } catch { }
    }

    # Engine status: record last error from retry exhaustion
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        Update-EngineStatus -GsdDir $GsdDir -State "running" -LastError $result.Error
    }
    return $result
}


# ===========================================
# 8b. PARALLEL SUB-TASK EXECUTION
# ===========================================

function Invoke-ParallelExecute {
    param(
        [string]$GsdDir,                    # .gsd directory path
        [string]$GlobalDir,                 # .gsd-global directory path
        [int]$Iteration,                    # Current iteration number
        [decimal]$Health,                   # Current health score
        [string]$PromptTemplatePath,        # Path to execute-subtask.md
        [int]$CurrentBatchSize,             # Current batch size (for result)
        [string]$LogFilePrefix,             # e.g., "$GsdDir\logs\iter3-4"
        [string]$InterfaceContext = "",     # Multi-interface context string
        [switch]$DryRun
    )

    $result = @{
        Success        = $false
        PartialSuccess = $false
        FinalBatchSize = $CurrentBatchSize
        Completed      = @()
        Failed         = @()
        Error          = ""
    }

    # â”€â”€ 1. Load parallel config â”€â”€
    $agentMapPath = Join-Path $GlobalDir "config\agent-map.json"
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $parallelCfg = $agentMap.execute_parallel

    if (-not $parallelCfg -or -not $parallelCfg.enabled) {
        $result.Error = "Parallel execution not enabled in agent-map.json"
        return $result
    }

    $maxConcurrent  = [int]$parallelCfg.max_concurrent
    $agentPool      = @($parallelCfg.agent_pool)
    $strategy       = $parallelCfg.strategy        # "round-robin" or "all-same"
    $subtaskTimeout = [int]$parallelCfg.subtask_timeout_minutes

    # â”€â”€ 2. Load queue and decompose into sub-tasks â”€â”€
    $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
    $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
    $batch = @($queue.batch)

    if ($batch.Count -eq 0) {
        $result.Error = "No batch items in queue-current.json"
        return $result
    }

    Write-Host "  [PARALLEL] Decomposing batch: $($batch.Count) sub-tasks" -ForegroundColor Cyan

    # â”€â”€ 3. Build per-subtask prompts â”€â”€
    $templateText = Get-Content $PromptTemplatePath -Raw
    $subtasks = @()

    for ($idx = 0; $idx -lt $batch.Count; $idx++) {
        $item = $batch[$idx]

        # Select agent: complexity-based routing with round-robin fallback
        $itemComplexity = if ($item.complexity) { $item.complexity } else { "medium" }
        if ((Get-Command Get-AgentForComplexity -ErrorAction SilentlyContinue) -and $strategy -ne "all-same") {
            $agent = Get-AgentForComplexity -Complexity $itemComplexity -GlobalDir $GlobalDir -AvailableAgents $agentPool -Index $idx
        } elseif ($strategy -eq "round-robin") {
            $agent = $agentPool[$idx % $agentPool.Count]
        } else {
            $agent = $agentPool[0]
        }

        # Check agent override
        $overridePath = Join-Path $GsdDir "supervisor\agent-override.json"
        if (Test-Path $overridePath) {
            try {
                $ov = Get-Content $overridePath -Raw | ConvertFrom-Json
                if ($ov.execute) { $agent = $ov.execute }
            } catch {}
        }

        # Resolve prompt template with sub-task placeholders
        $prompt = $templateText
        $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
        $prompt = $prompt.Replace("{{HEALTH}}", "$Health")
        $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
        $prompt = $prompt.Replace("{{SUBTASK_INDEX}}", "$($idx + 1)")
        $prompt = $prompt.Replace("{{SUBTASK_TOTAL}}", "$($batch.Count)")
        $prompt = $prompt.Replace("{{SUBTASK_REQ_ID}}", $item.req_id)
        $prompt = $prompt.Replace("{{SUBTASK_DESCRIPTION}}", $item.description)
        $prompt = $prompt.Replace("{{SUBTASK_TARGET_FILES}}", ($item.target_files -join ", "))
        $prompt = $prompt.Replace("{{SUBTASK_INSTRUCTIONS}}", $item.generation_instructions)
        $prompt = $prompt.Replace("{{SUBTASK_ACCEPTANCE}}", $item.acceptance)
        $prompt = $prompt.Replace("{{AGENT}}", $agent)
        $prompt = $prompt.Replace("{{BATCH_SIZE}}", "1")
        $prompt = $prompt.Replace("{{REPO_ROOT}}", (Get-Location).Path)
        $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)
        $prompt = $prompt.Replace("{{FIGMA_PATH}}", "(see interface context)")
        $prompt = $prompt.Replace("{{FIGMA_VERSION}}", "(multi-interface)")

        $subtasks += @{
            Index   = $idx
            ReqId   = $item.req_id
            Agent   = $agent
            Prompt  = $prompt
            LogFile = "${LogFilePrefix}-sub${idx}.log"
        }
    }

    # â”€â”€ 4. Dispatch sub-tasks â”€â”€
    Write-Host "  [PARALLEL] Dispatching $($subtasks.Count) sub-tasks (max concurrent: $maxConcurrent)" -ForegroundColor Cyan
    foreach ($st in $subtasks) {
        Write-Host "    [$($st.Index + 1)] $($st.ReqId) -> $($st.Agent)" -ForegroundColor DarkCyan
    }

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would dispatch $($subtasks.Count) sub-tasks" -ForegroundColor Yellow
        $result.Success = $true
        $result.Completed = $subtasks | ForEach-Object { $_.ReqId }
        return $result
    }

    # â”€â”€ 5. Execute in batches of $maxConcurrent using PowerShell jobs â”€â”€
    $completedReqs = @()
    $failedReqs    = @()

    for ($batchStart = 0; $batchStart -lt $subtasks.Count; $batchStart += $maxConcurrent) {
        $batchEnd = [math]::Min($batchStart + $maxConcurrent, $subtasks.Count) - 1
        $currentBatch = $subtasks[$batchStart..$batchEnd]

        Write-Host "  [PARALLEL] Wave $([math]::Floor($batchStart / $maxConcurrent) + 1): sub-tasks $($batchStart + 1)..$($batchEnd + 1)" -ForegroundColor Cyan

        if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
            Update-EngineStatus -GsdDir $GsdDir -State "running" -Phase "execute" `
                -Agent "parallel($($currentBatch.Count))" `
                -Iteration $Iteration -HealthScore $Health
        }

        $jobs = @()
        foreach ($st in $currentBatch) {
            $jobName = "gsd-subtask-$($st.ReqId)"
            $stAgent   = $st.Agent
            $stPrompt  = $st.Prompt
            $stLogFile = $st.LogFile
            $stReqId   = $st.ReqId

            # Start-Job runs in a separate process -- pass all needed vars
            $job = Start-Job -Name $jobName -ScriptBlock {
                param($Agent, $Prompt, $LogFile, $ReqId, $GlobalDir, $GsdDir, $SubtaskTimeout)

                # Load resilience module inside the job
                . "$GlobalDir\lib\modules\resilience.ps1"

                # Determine AllowedTools and GeminiMode based on agent
                $allowedTools = "Read,Write,Bash,mcp__*"
                $geminiMode   = "--yolo"

                $subResult = Invoke-WithRetry -Agent $Agent -Prompt $Prompt `
                    -Phase "execute" -LogFile $LogFile `
                    -CurrentBatchSize 1 -GsdDir $GsdDir `
                    -AllowedTools $allowedTools -GeminiMode $geminiMode `
                    -MaxAttempts 2

                return @{
                    ReqId   = $ReqId
                    Success = $subResult.Success
                    Error   = $subResult.Error
                    Agent   = $Agent
                }
            } -ArgumentList $stAgent, $stPrompt, $stLogFile, $stReqId, $GlobalDir, $GsdDir, $subtaskTimeout

            $jobs += $job
        }

        # Wait for all jobs in this wave with timeout
        $timeoutSec = $subtaskTimeout * 60
        $allDone = $jobs | Wait-Job -Timeout $timeoutSec

        # Collect results
        foreach ($job in $jobs) {
            $jobResult = $null
            if ($job.State -eq "Completed") {
                $jobResult = Receive-Job -Job $job
            }

            if ($jobResult -and $jobResult.Success) {
                $completedReqs += $jobResult.ReqId
                Write-Host "    [OK] $($jobResult.ReqId) ($($jobResult.Agent))" -ForegroundColor Green
            } else {
                $reqId = if ($jobResult) { $jobResult.ReqId } else { "unknown" }
                $err   = if ($jobResult) { $jobResult.Error } else { "Job timed out or crashed" }
                $failedReqs += $reqId
                Write-Host "    [FAIL] $reqId : $err" -ForegroundColor Red

                # Log the failure
                if (Get-Command Write-GsdError -ErrorAction SilentlyContinue) {
                    Write-GsdError -GsdDir $GsdDir -Category "subtask_failed" `
                        -Phase "execute" -Iteration $Iteration -Message "$reqId : $err"
                }
            }

            # Cleanup
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        # Throttle between waves (adaptive: 3s clean / 30s when quota pressure detected)
        if ($batchEnd -lt ($subtasks.Count - 1)) {
            $cooldownSec = 3
            $cooldownsPath = Join-Path $GsdDir "supervisor\agent-cooldowns.json"
            if (Test-Path $cooldownsPath) {
                try {
                    $cooldowns = Get-Content $cooldownsPath -Raw | ConvertFrom-Json
                    $cutoff = (Get-Date).AddMinutes(-5)
                    foreach ($prop in $cooldowns.PSObject.Properties) {
                        if ([string]$prop.Value -ne "" -and ([DateTime]::Parse($prop.Value)) -gt $cutoff) {
                            $cooldownSec = 30
                            break
                        }
                    }
                } catch { $cooldownSec = 10 }
            }
            Write-Host "  [PARALLEL] Wave complete. ${cooldownSec}s adaptive cooldown..." -ForegroundColor DarkGray
            Start-Sleep -Seconds $cooldownSec
        }
    }

    # â”€â”€ 6. Aggregate results â”€â”€
    $result.Completed = $completedReqs
    $result.Failed    = $failedReqs
    $result.FinalBatchSize = $CurrentBatchSize

    if ($failedReqs.Count -eq 0) {
        $result.Success = $true
        Write-Host "  [PARALLEL] All $($completedReqs.Count)/$($subtasks.Count) sub-tasks completed" -ForegroundColor Green
    }
    elseif ($completedReqs.Count -gt 0) {
        $result.PartialSuccess = $true
        $result.Error = "$($failedReqs.Count)/$($subtasks.Count) sub-tasks failed: $($failedReqs -join ', ')"
        Write-Host "  [PARALLEL] Partial: $($completedReqs.Count) OK, $($failedReqs.Count) failed" -ForegroundColor Yellow
    }
    else {
        $result.Error = "All $($subtasks.Count) sub-tasks failed"
        Write-Host "  [PARALLEL] All sub-tasks failed" -ForegroundColor Red
    }

    return $result
}

# ===========================================
# 9. ENHANCED BUILD VALIDATION (adds SQL)
# ===========================================

$script:OriginalBuildValidation = ${function:Invoke-BuildValidation}

function Invoke-BuildValidation {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [int]$Iteration,
        [switch]$AutoFix
    )

    # Call original build validation (dotnet + npm)
    $result = & $script:OriginalBuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix:$AutoFix

    # Add SQL validation
    $sqlResult = Test-SqlFiles -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration
    if (-not $sqlResult.Passed) {
        $result.Errors += $sqlResult.Errors

        if ($AutoFix) {
            Write-Host "    [SYNC] Auto-fix: sending SQL issues to Codex..." -ForegroundColor DarkYellow
            $sqlFixPrompt = @"
SQL pattern issues found. Fix these:
$($sqlResult.Errors -join "`n")

Rules:
- Add TRY/CATCH to all stored procedures
- Add audit columns (CreatedAt, CreatedBy, ModifiedAt, ModifiedBy) to all CREATE TABLE
- Replace any string concatenation with parameterized queries
- Use sp_executesql for dynamic SQL if absolutely needed
"@
            $sqlFixPrompt | codex exec --full-auto - 2>&1 |
                Out-File -FilePath "$GsdDir\logs\autofix-sql-iter$Iteration.log" -Encoding UTF8

            git add -A; git commit -m "gsd: auto-fix SQL patterns (iter $Iteration)" --no-verify 2>$null
        }

        $result.Passed = $false
    }

    return $result
}

# ===========================================
# 10. ENHANCED PRE-FLIGHT (adds CLI versions)
# ===========================================

$script:OriginalPreFlight = ${function:Test-PreFlight}

function Test-PreFlight {
    param(
        [string]$RepoRoot,
        [string]$GsdDir
    )

    # Run original pre-flight
    $result = & $script:OriginalPreFlight -RepoRoot $RepoRoot -GsdDir $GsdDir
    if (-not $result) { return $false }

    # Add CLI version checks
    $cliOk = Test-CliVersions -GsdDir $GsdDir
    if (-not $cliOk) { return $false }

    # Add network check
    Write-Host "    Checking network..." -ForegroundColor DarkGray
    try {
        $null = claude -p "PING" --max-turns 1 2>$null; if ($LASTEXITCODE -ne 0) { throw "offline" }
        Write-Host "    [OK] Network: online" -ForegroundColor DarkGreen
    } catch {
        Write-Host "    [!!]  Network: offline (will poll when needed)" -ForegroundColor DarkYellow
    }

    return $true
}

# ================================================================
# FILE MAP - Shared function for all pipelines
# Maintains a live inventory of every file in the repo.
# Called by assess, blueprint, and convergence after each iteration.
# ================================================================

function Update-FileMap {
    param(
        [string]$Root,
        [string]$GsdPath
    )

    $mapPath = Join-Path $GsdPath "file-map.json"
    $treePath = Join-Path $GsdPath "file-map-tree.md"

    $excludePattern = '(node_modules|\.git[\\\/]|[\\\/]bin[\\\/]|[\\\/]obj[\\\/]|packages|dist[\\\/]|build[\\\/]|\.gsd|\.vs[\\\/]|\.vscode|\.tmp-bin|TestResults|coverage|__pycache__|\.next|\.nuxt)'

    $allFiles = @(Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excludePattern })

    $dirTree = @{}
    $fileEntries = @()
    $extSummary = @{}

    foreach ($file in $allFiles) {
        $relPath = $file.FullName.Substring($Root.Length).TrimStart('\')
        $relDir = Split-Path $relPath -Parent
        if (-not $relDir) { $relDir = "(root)" }
        $ext = $file.Extension.ToLower()

        $fileEntries += @{
            path = $relPath; dir = $relDir; name = $file.Name
            ext = $ext; size = $file.Length
            modified = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        }

        if (-not $dirTree.ContainsKey($relDir)) {
            $dirTree[$relDir] = @{ files = 0; total_size = 0; extensions = @{} }
        }
        $dirTree[$relDir].files++
        $dirTree[$relDir].total_size += $file.Length
        if ($ext) {
            if (-not $dirTree[$relDir].extensions.ContainsKey($ext)) { $dirTree[$relDir].extensions[$ext] = 0 }
            $dirTree[$relDir].extensions[$ext]++
        }

        if ($ext) {
            if (-not $extSummary.ContainsKey($ext)) { $extSummary[$ext] = @{ count = 0; total_size = 0 } }
            $extSummary[$ext].count++
            $extSummary[$ext].total_size += $file.Length
        }
    }

    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
    if (-not $totalSize) { $totalSize = 0 }

    $fileMap = @{
        generated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        repo_root = $Root; total_files = $fileEntries.Count
        total_dirs = $dirTree.Count; total_size_bytes = $totalSize
        extensions = $extSummary; directories = $dirTree; files = $fileEntries
    }
    Set-Content -Path $mapPath -Value ($fileMap | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8

    # Human-readable tree
    $treeLines = @(
        "# Repository File Map"
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Total: $($fileEntries.Count) files in $($dirTree.Count) directories"
        "Size: $([math]::Round($totalSize / 1MB, 2)) MB"
        ""
        "## File Types"
        ""
    )
    foreach ($e in ($extSummary.GetEnumerator() | Sort-Object { $_.Value.count } -Descending)) {
        $treeLines += "- $($e.Key): $($e.Value.count) files ($([math]::Round($e.Value.total_size / 1024, 1)) KB)"
    }
    $treeLines += ""
    $treeLines += "## Directory Structure"
    $treeLines += ""
    foreach ($d in ($dirTree.GetEnumerator() | Sort-Object Name)) {
        $depth = @($d.Key.Split('\') | Where-Object { $_ }).Count - 1
        if ($depth -lt 0) { $depth = 0 }
        $prefix = "  " * $depth
        $dirName = Split-Path $d.Key -Leaf
        if (-not $dirName) { $dirName = $d.Key }
        $extList = ($d.Value.extensions.GetEnumerator() |
            Sort-Object { $_.Value } -Descending |
            ForEach-Object { "$($_.Key):$($_.Value)" }) -join ", "
        $treeLines += "$prefix- $dirName\ ($($d.Value.files) files: $extList)"
    }
    Set-Content -Path $treePath -Value ($treeLines -join "`n") -Encoding UTF8

    return $mapPath
}

# ===========================================
# 10. PUSH NOTIFICATIONS (ntfy.sh)
# ===========================================

$script:NTFY_TOPIC = $null  # Set via auto-detect, global-config.json, or -NtfyTopic param
$script:LISTENER_JOB = $null  # Background command listener job
$script:ENGINE_STATUS_JOB = $null  # Background engine-status.json heartbeat job

function Get-GsdNtfyTopic {
    <#
    .SYNOPSIS
        Auto-generates an ntfy topic from username + repo name.
        Pattern: gsd-{username}-{reponame} (lowercased, sanitized)
    #>
    # Get username from environment
    $user = $env:USERNAME
    if (-not $user) { $user = $env:USER }        # Linux/macOS fallback
    if (-not $user) { $user = "unknown" }

    # Get repo name from git remote or folder name
    $repoName = $null
    try {
        $remoteUrl = git config --get remote.origin.url 2>$null
        if ($remoteUrl) {
            # Extract repo name from URL (handles both HTTPS and SSH)
            # e.g., https://github.com/user/my-repo.git -> my-repo
            # e.g., git@github.com:user/my-repo.git -> my-repo
            $repoName = ($remoteUrl -replace '\.git$', '') -replace '.*/|.*:', '' | Split-Path -Leaf
        }
    } catch { }

    # Fallback to current directory name
    if (-not $repoName) {
        $repoName = (Get-Item .).Name
    }

    # Sanitize: lowercase, replace non-alphanumeric with hyphens, collapse multiples
    $user = ($user.ToLower() -replace '[^a-z0-9]', '-') -replace '-+', '-' -replace '^-|-$', ''
    $repoName = ($repoName.ToLower() -replace '[^a-z0-9]', '-') -replace '-+', '-' -replace '^-|-$', ''

    return "gsd-$user-$repoName"
}

function Send-GsdNotification {
    <#
    .SYNOPSIS
        Sends a push notification via ntfy.sh. Silent fail if not configured.
    #>
    param(
        [string]$Title,
        [string]$Message,
        [string]$Priority = "default",   # min, low, default, high, urgent
        [string]$Tags = "",              # emoji shortcodes: white_check_mark, warning, x, rocket
        [string]$Topic = $null
    )

    $effectiveTopic = if ($Topic) { $Topic } else { $script:NTFY_TOPIC }
    if (-not $effectiveTopic) { return }

    try {
        $headers = @{ "Title" = $Title; "Priority" = $Priority }
        if ($Tags) { $headers["Tags"] = $Tags }
        Invoke-RestMethod -Uri "https://ntfy.sh/$effectiveTopic" -Method Post `
            -Body $Message -Headers $headers -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # Notification failure should never block the pipeline
    }
}

function Get-CostNotificationText {
    <#
    .SYNOPSIS
        Reads cost-summary.json and returns a compact one-line cost string for ntfy notifications.
        Returns empty string if cost tracking is not available.
    #>
    param(
        [string]$GsdDir,
        [switch]$Detailed   # Include per-agent breakdown
    )
    try {
        $summaryPath = Join-Path $GsdDir "costs\cost-summary.json"
        if (-not (Test-Path $summaryPath)) { return "" }
        $s = Get-Content $summaryPath -Raw | ConvertFrom-Json
        $totalCost = [math]::Round([double]$s.total_cost_usd, 2)
        if ($totalCost -le 0) { return "" }

        $totalTokensK = [math]::Round(([long]$s.total_tokens.input + [long]$s.total_tokens.output) / 1000, 0)
        $runCost = 0
        $runs = @($s.runs)
        if ($runs.Count -gt 0) {
            $runCost = [math]::Round([double]$runs[$runs.Count - 1].cost_usd, 2)
        }

        $line = "Cost: `$$runCost run / `$$totalCost total | ${totalTokensK}K tok"

        if ($Detailed -and $s.by_agent) {
            $parts = @()
            foreach ($agent in @("claude","codex","gemini")) {
                if ($s.by_agent.$agent) {
                    $ac = [math]::Round([double]$s.by_agent.$agent.cost_usd, 2)
                    if ($ac -gt 0) { $parts += "$agent `$$ac" }
                }
            }
            if ($parts.Count -gt 0) { $line += " (" + ($parts -join ", ") + ")" }
        }
        return $line
    } catch { return "" }
}

function Send-HeartbeatIfDue {
    <#
    .SYNOPSIS
        Sends a low-priority "still working" notification if 10+ minutes have passed
        since the last notification. Call before each agent phase for automatic heartbeats.
    #>
    param(
        [string]$Phase,
        [int]$Iteration,
        [double]$Health,
        [string]$RepoName,
        [string]$GsdDir,
        [int]$HeartbeatMinutes = 10
    )
    if (-not $script:LAST_NOTIFY_TIME) { $script:LAST_NOTIFY_TIME = Get-Date }
    $elapsed = (Get-Date) - $script:LAST_NOTIFY_TIME
    if ($elapsed.TotalMinutes -ge $HeartbeatMinutes) {
        $mins = [math]::Floor($elapsed.TotalMinutes)
        $msg = "$RepoName | Iter $Iteration | Health: ${Health}% | ${mins}m elapsed"
        if ($GsdDir) {
            $costLine = Get-CostNotificationText -GsdDir $GsdDir
            if ($costLine) { $msg += "`n$costLine" }
            $locLine = if (Get-Command Get-LocNotificationText -ErrorAction SilentlyContinue) { Get-LocNotificationText -GsdDir $GsdDir -Cumulative } else { "" }
            if ($locLine) { $msg += "`n$locLine" }
        }
        Send-GsdNotification -Title "Working: $Phase" `
            -Message $msg -Tags "hourglass_flowing_sand" -Priority "low"
        $script:LAST_NOTIFY_TIME = Get-Date
    }
}

function Initialize-GsdNotifications {
    <#
    .SYNOPSIS
        Sets up ntfy topic for push notifications. Priority order:
        1. Explicit -NtfyTopic parameter override
        2. ntfy_topic from global-config.json (if not "auto")
        3. Auto-detected: gsd-{username}-{reponame}
    #>
    param([string]$GsdGlobalDir, [string]$OverrideTopic = $null)

    # Initialize heartbeat timer
    $script:LAST_NOTIFY_TIME = Get-Date

    if ($OverrideTopic) {
        $script:NTFY_TOPIC = $OverrideTopic
        Write-Host "  ntfy topic (override): $($script:NTFY_TOPIC)" -ForegroundColor DarkGray
        return
    }

    # Check global config for explicit topic
    $configPath = Join-Path $GsdGlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($config.notifications -and $config.notifications.ntfy_topic -and $config.notifications.ntfy_topic -ne "auto") {
                $script:NTFY_TOPIC = $config.notifications.ntfy_topic
                Write-Host "  ntfy topic (config): $($script:NTFY_TOPIC)" -ForegroundColor DarkGray
                return
            }
        } catch { }
    }

    # Auto-detect from username + repo name
    $script:NTFY_TOPIC = Get-GsdNtfyTopic
    Write-Host "  ntfy topic (auto): $($script:NTFY_TOPIC)" -ForegroundColor DarkGray
}

function Start-BackgroundHeartbeat {
    <#
    .SYNOPSIS
        Starts a background job that sends ntfy heartbeat notifications every N minutes.
        Reads current state from .gsd-checkpoint.json so it works even while agents block.
    #>
    param(
        [string]$GsdDir,
        [string]$NtfyTopic,
        [string]$Pipeline,
        [string]$RepoName,
        [int]$IntervalMinutes = 10
    )

    if (-not $NtfyTopic) { return }

    # Stop any existing heartbeat job
    Stop-BackgroundHeartbeat

    $checkpointPath = Join-Path $GsdDir ".gsd-checkpoint.json"
    $startTime = Get-Date -Format "o"

    $costSummaryPath = Join-Path $GsdDir "costs\cost-summary.json"

    $script:HEARTBEAT_JOB = Start-Job -ScriptBlock {
        param($CheckpointPath, $Topic, $Pipeline, $RepoName, $Interval, $StartTime, $CostPath)
        $pipelineStart = [datetime]::Parse($StartTime)
        while ($true) {
            Start-Sleep -Seconds ($Interval * 60)
            try {
                $totalElapsed = [math]::Floor(((Get-Date) - $pipelineStart).TotalMinutes)
                $phase = $Pipeline
                $iter = "?"
                $health = "?"

                if (Test-Path $CheckpointPath) {
                    $cp = Get-Content $CheckpointPath -Raw | ConvertFrom-Json
                    $phase = $cp.phase
                    $iter = $cp.iteration
                    $health = "$($cp.health)%"
                }

                $title = "Working: $phase"
                $body = "$RepoName | Iter $iter | Health: $health | ${totalElapsed}m total"

                # Append cost info from cost-summary.json
                if ($CostPath -and (Test-Path $CostPath)) {
                    try {
                        $cs = Get-Content $CostPath -Raw | ConvertFrom-Json
                        $tc = [math]::Round([double]$cs.total_cost_usd, 2)
                        if ($tc -gt 0) {
                            $tokK = [math]::Round(([long]$cs.total_tokens.input + [long]$cs.total_tokens.output) / 1000, 0)
                            $rc = 0; $runs = @($cs.runs); if ($runs.Count -gt 0) { $rc = [math]::Round([double]$runs[$runs.Count - 1].cost_usd, 2) }
                            $body += "`nCost: `$$rc run / `$$tc total | ${tokK}K tok"
                        }
                    } catch {}
                }

                $headers = @{
                    "Title"    = $title
                    "Priority" = "low"
                    "Tags"     = "hourglass_flowing_sand"
                }
                Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post `
                    -Body $body -Headers $headers -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
            } catch {
                # Never let notification failure kill the heartbeat loop
            }
        }
    } -ArgumentList $checkpointPath, $NtfyTopic, $Pipeline, $RepoName, $IntervalMinutes, $startTime, $costSummaryPath

    Write-Host "  Heartbeat: every ${IntervalMinutes}m (background)" -ForegroundColor DarkGray
}

function Stop-BackgroundHeartbeat {
    <#
    .SYNOPSIS
        Stops the background heartbeat job if running.
    #>
    if ($script:HEARTBEAT_JOB) {
        Stop-Job -Job $script:HEARTBEAT_JOB -ErrorAction SilentlyContinue
        Remove-Job -Job $script:HEARTBEAT_JOB -Force -ErrorAction SilentlyContinue
        $script:HEARTBEAT_JOB = $null
    }
}

# ===========================================
# 11. NTFY COMMAND LISTENER (progress on demand)
# ===========================================

function Start-CommandListener {
    <#
    .SYNOPSIS
        Starts a background job that polls ntfy for "progress" commands and responds
        with current pipeline status. Only recognizes the exact word "progress".
        Mirrors Start-BackgroundHeartbeat pattern.
    #>
    param(
        [string]$GsdDir,
        [string]$NtfyTopic,
        [string]$Pipeline,
        [string]$RepoName,
        [int]$PollIntervalSeconds = 15
    )

    if (-not $NtfyTopic) { return }

    # Stop any existing listener job
    Stop-CommandListener

    $startTime = Get-Date -Format "o"

    $script:LISTENER_JOB = Start-Job -ScriptBlock {
        param($GsdDir, $Topic, $Pipeline, $RepoName, $PollInterval, $StartTime)
        $pipelineStart = [datetime]::Parse($StartTime)
        $sinceSeconds = $PollInterval + 5  # slight overlap to not miss messages

        while ($true) {
            Start-Sleep -Seconds $PollInterval
            try {
                $uri = "https://ntfy.sh/$Topic/json?poll=1&since=${sinceSeconds}s"
                $raw = Invoke-WebRequest -Uri $uri -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue
                if (-not $raw -or -not $raw.Content) { continue }

                $lines = $raw.Content -split "`n" | Where-Object { $_.Trim() }
                foreach ($line in $lines) {
                    try {
                        $msg = $line | ConvertFrom-Json
                        if ($msg.event -ne "message") { continue }
                        $text = ($msg.message -as [string]).Trim().ToLower()
                        if ($text -ne "progress" -and $text -ne "token" -and $text -ne "tokens" -and $text -ne "cost" -and $text -ne "costs") { continue }

                        # -- TOKEN/COST COMMAND --
                        if ($text -eq "token" -or $text -eq "tokens" -or $text -eq "cost" -or $text -eq "costs") {
                            $costPath = Join-Path $GsdDir "costs\cost-summary.json"
                            $tokenBody = "[GSD-COSTS] Token Cost Report`n$RepoName | $Pipeline pipeline"

                            if (Test-Path $costPath) {
                                try {
                                    $cs = Get-Content $costPath -Raw | ConvertFrom-Json
                                    $tc = [math]::Round([double]$cs.total_cost_usd, 2)
                                    $inK = [math]::Round([long]$cs.total_tokens.input / 1000, 0)
                                    $outK = [math]::Round([long]$cs.total_tokens.output / 1000, 0)
                                    $totalK = $inK + $outK
                                    $calls = [int]$cs.total_calls

                                    $tokenBody += "`n`nTotal Cost: `$$tc"
                                    $tokenBody += "`nTokens: ${totalK}K (${inK}K in / ${outK}K out)"
                                    $tokenBody += "`nAPI Calls: $calls"

                                    # Per-agent breakdown
                                    $tokenBody += "`n`nBy Agent:"
                                    foreach ($ag in @("claude","codex","gemini")) {
                                        if ($cs.by_agent.$ag) {
                                            $ac = [math]::Round([double]$cs.by_agent.$ag.cost_usd, 2)
                                            $aIn = [math]::Round([long]$cs.by_agent.$ag.tokens.input / 1000, 0)
                                            $aOut = [math]::Round([long]$cs.by_agent.$ag.tokens.output / 1000, 0)
                                            $aCalls = [int]$cs.by_agent.$ag.calls
                                            $tokenBody += "`n  $($ag.ToUpper()): `$$ac | $($aIn + $aOut)K tok | $aCalls calls"
                                        }
                                    }

                                    # Per-phase breakdown
                                    if ($cs.by_phase) {
                                        $tokenBody += "`n`nBy Phase:"
                                        $phaseProps = $cs.by_phase | Get-Member -MemberType NoteProperty
                                        foreach ($pp in $phaseProps) {
                                            $pn = $pp.Name
                                            $pv = $cs.by_phase.$pn
                                            $pc = [math]::Round([double]$pv.cost_usd, 2)
                                            if ($pc -gt 0) {
                                                $tokenBody += "`n  $pn : `$$pc ($([int]$pv.calls) calls)"
                                            }
                                        }
                                    }

                                    # Current run cost
                                    $runs = @($cs.runs)
                                    if ($runs.Count -gt 0) {
                                        $lastRun = $runs[$runs.Count - 1]
                                        $rc = [math]::Round([double]$lastRun.cost_usd, 2)
                                        $tokenBody += "`n`nThis Run: `$$rc"
                                    }
                                } catch {
                                    $tokenBody += "`n`nError reading cost data: $($_.Exception.Message)"
                                }
                            } else {
                                $tokenBody += "`n`nNo cost data yet (costs/cost-summary.json not found)"
                            }

                            $totalElapsed = [math]::Floor(((Get-Date) - $pipelineStart).TotalMinutes)
                            $tokenBody += "`nElapsed: ${totalElapsed}m"

                            $tokenHeaders = @{
                                "Title"    = "[GSD-COSTS] $RepoName"
                                "Priority" = "default"
                                "Tags"     = "money_with_wings"
                            }
                            Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post `
                                -Body $tokenBody -Headers $tokenHeaders -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
                            continue
                        }

                        # Gather progress from local files
                        $checkpointPath = Join-Path $GsdDir ".gsd-checkpoint.json"
                        $phase = $Pipeline; $iter = "?"; $health = "?"; $batch = "?"

                        if (Test-Path $checkpointPath) {
                            $cp = Get-Content $checkpointPath -Raw | ConvertFrom-Json
                            $phase = $cp.phase; $iter = $cp.iteration
                            $health = "$($cp.health)%"; $batch = $cp.batch_size
                        }

                        $items = "N/A"
                        if ($Pipeline -eq "converge") {
                            $hPath = Join-Path $GsdDir "health\health-current.json"
                            if (Test-Path $hPath) {
                                $h = Get-Content $hPath -Raw | ConvertFrom-Json
                                $items = "$($h.satisfied) done / $($h.partial) partial / $($h.not_started) todo (of $($h.total_requirements))"
                            }
                        } else {
                            $hPath = Join-Path $GsdDir "blueprint\health.json"
                            if (Test-Path $hPath) {
                                $h = Get-Content $hPath -Raw | ConvertFrom-Json
                                $items = "$($h.completed)/$($h.total) | Tier: $($h.current_tier_name)"
                            }
                        }

                        $totalElapsed = [math]::Floor(((Get-Date) - $pipelineStart).TotalMinutes)
                        $body = "[GSD-STATUS] Progress Report`n$RepoName | $Pipeline pipeline`nHealth: $health | Iter: $iter | Phase: $phase`nItems: $items`nBatch: $batch | Elapsed: ${totalElapsed}m"

                        # Append cost breakdown
                        $costPath = Join-Path $GsdDir "costs\cost-summary.json"
                        if (Test-Path $costPath) {
                            try {
                                $cs = Get-Content $costPath -Raw | ConvertFrom-Json
                                $tc = [math]::Round([double]$cs.total_cost_usd, 2)
                                if ($tc -gt 0) {
                                    $tokK = [math]::Round(([long]$cs.total_tokens.input + [long]$cs.total_tokens.output) / 1000, 0)
                                    $rc = 0; $runs = @($cs.runs); if ($runs.Count -gt 0) { $rc = [math]::Round([double]$runs[$runs.Count - 1].cost_usd, 2) }
                                    $body += "`nCost: `$$rc run / `$$tc total | ${tokK}K tok"
                                    # Per-agent breakdown
                                    $agentParts = @()
                                    foreach ($ag in @("claude","codex","gemini")) {
                                        if ($cs.by_agent.$ag) {
                                            $ac = [math]::Round([double]$cs.by_agent.$ag.cost_usd, 2)
                                            if ($ac -gt 0) { $agentParts += "$ag `$$ac" }
                                        }
                                    }
                                    if ($agentParts.Count -gt 0) { $body += " (" + ($agentParts -join ", ") + ")" }
                                }
                            } catch {}
                        }

                        $headers = @{
                            "Title"    = "[GSD-STATUS] $RepoName"
                            "Priority" = "default"
                            "Tags"     = "bar_chart"
                        }
                        Invoke-RestMethod -Uri "https://ntfy.sh/$Topic" -Method Post `
                            -Body $body -Headers $headers -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
                    } catch {
                        # Individual message parse failure - skip it
                    }
                }
            } catch {
                # Never let listener failure kill the loop
            }
        }
    } -ArgumentList $GsdDir, $NtfyTopic, $Pipeline, $RepoName, $PollIntervalSeconds, $startTime

    Write-Host "  Listener: polls every ${PollIntervalSeconds}s for commands (background)" -ForegroundColor DarkGray
}

function Stop-CommandListener {
    <#
    .SYNOPSIS
        Stops the background command listener job if running.
    #>
    if ($script:LISTENER_JOB) {
        Stop-Job -Job $script:LISTENER_JOB -ErrorAction SilentlyContinue
        Remove-Job -Job $script:LISTENER_JOB -Force -ErrorAction SilentlyContinue
        $script:LISTENER_JOB = $null
    }
}

# ===========================================
# 12. ENGINE STATUS FILE (stall detection)
# ===========================================

function Update-EngineStatus {
    <#
    .SYNOPSIS
        Writes/updates .gsd/health/engine-status.json with live pipeline state.
        Merge-on-write: reads existing file, overwrites only fields explicitly passed.
        Always updates last_heartbeat and elapsed_minutes.
    #>
    param(
        [string]$GsdDir,
        [ValidateSet('starting','running','sleeping','stalled','completed','converged')]
        [string]$State,
        [string]$Phase = $null,
        [string]$Agent = $null,
        [int]$Iteration = -1,
        [string]$Attempt = $null,
        [int]$BatchSize = -1,
        [double]$HealthScore = -1,
        [datetime]$SleepUntil = [datetime]::MinValue,
        [string]$SleepReason = $null,
        [string]$LastError = $null,
        [int]$ErrorsThisIteration = -1,
        [bool]$RecoveredFromError = $false
    )

    try {
        $statusFile = Join-Path $GsdDir "health\engine-status.json"
        $now = (Get-Date).ToUniversalTime().ToString("o")

        # Read existing to preserve fields not being updated
        $existing = $null
        if (Test-Path $statusFile) {
            try { $existing = Get-Content $statusFile -Raw | ConvertFrom-Json } catch {}
        }

        $startedAt = if ($existing -and $existing.started_at) { $existing.started_at } else { $now }
        $elapsed = [math]::Round(((Get-Date).ToUniversalTime() - [datetime]::Parse($startedAt)).TotalMinutes)

        # Build status object - merge existing with new values
        $status = @{
            pid                   = $PID
            state                 = $State
            phase                 = if ($null -ne $Phase) { $Phase }
                                    elseif ($existing -and $State -eq 'running') { $existing.phase }
                                    elseif ($existing) { $existing.phase }
                                    else { $null }
            agent                 = if ($null -ne $Agent) { $Agent }
                                    elseif ($existing -and $State -eq 'running') { $existing.agent }
                                    elseif ($existing) { $existing.agent }
                                    else { $null }
            iteration             = if ($Iteration -ge 0) { $Iteration }
                                    elseif ($existing) { $existing.iteration }
                                    else { 0 }
            attempt               = if ($null -ne $Attempt) { $Attempt }
                                    elseif ($existing) { $existing.attempt }
                                    else { $null }
            batch_size            = if ($BatchSize -ge 0) { $BatchSize }
                                    elseif ($existing) { $existing.batch_size }
                                    else { 0 }
            health_score          = if ($HealthScore -ge 0) { $HealthScore }
                                    elseif ($existing) { $existing.health_score }
                                    else { 0 }
            last_heartbeat        = $now
            started_at            = $startedAt
            elapsed_minutes       = $elapsed
            sleep_until           = if ($SleepUntil -ne [datetime]::MinValue) {
                                        $SleepUntil.ToUniversalTime().ToString("o")
                                    } elseif ($State -eq 'sleeping' -and $existing -and $existing.sleep_until) {
                                        $existing.sleep_until
                                    } else { $null }
            sleep_reason          = if ($null -ne $SleepReason) { $SleepReason }
                                    elseif ($State -eq 'sleeping' -and $existing) { $existing.sleep_reason }
                                    else { $null }
            last_error            = if ($null -ne $LastError) {
                                        if ($LastError.Length -gt 200) { $LastError.Substring(0, 200) } else { $LastError }
                                    } elseif ($existing) { $existing.last_error }
                                    else { $null }
            errors_this_iteration = if ($ErrorsThisIteration -ge 0) { $ErrorsThisIteration }
                                    elseif ($existing) { $existing.errors_this_iteration }
                                    else { 0 }
            recovered_from_error  = if ($RecoveredFromError) { $true }
                                    elseif ($State -eq 'running' -and -not $RecoveredFromError -and $existing -and $existing.state -ne 'sleeping') { $false }
                                    elseif ($existing) { $existing.recovered_from_error }
                                    else { $false }
        }

        # Clear sleep fields when transitioning out of sleeping state
        if ($State -ne 'sleeping') {
            $status.sleep_until = $null
            $status.sleep_reason = $null
        }

        $status | ConvertTo-Json -Depth 3 | Set-Content $statusFile -Encoding UTF8
    } catch {
        # Engine status update should never block the pipeline
    }
}

function Start-EngineStatusHeartbeat {
    <#
    .SYNOPSIS
        Starts a 60-second background job that touches last_heartbeat + elapsed_minutes
        in engine-status.json. Separate from ntfy heartbeat (10min).
    #>
    param([string]$GsdDir)

    Stop-EngineStatusHeartbeat

    $statusPath = Join-Path $GsdDir "health\engine-status.json"

    $script:ENGINE_STATUS_JOB = Start-Job -ScriptBlock {
        param($StatusPath)
        while ($true) {
            Start-Sleep -Seconds 60
            try {
                if (Test-Path $StatusPath) {
                    $status = Get-Content $StatusPath -Raw | ConvertFrom-Json
                    $now = (Get-Date).ToUniversalTime().ToString("o")
                    $elapsed = [math]::Round(
                        ((Get-Date).ToUniversalTime() - [datetime]::Parse($status.started_at)).TotalMinutes
                    )
                    $status.last_heartbeat = $now
                    $status.elapsed_minutes = $elapsed
                    $status | ConvertTo-Json -Depth 3 | Set-Content $StatusPath -Encoding UTF8
                }
            } catch {
                # Never let heartbeat failure kill the loop
            }
        }
    } -ArgumentList $statusPath

    Write-Host "  Engine status: heartbeat every 60s (background)" -ForegroundColor DarkGray
}

function Stop-EngineStatusHeartbeat {
    <#
    .SYNOPSIS
        Stops the engine-status.json heartbeat job if running.
    #>
    if ($script:ENGINE_STATUS_JOB) {
        Stop-Job -Job $script:ENGINE_STATUS_JOB -ErrorAction SilentlyContinue
        Remove-Job -Job $script:ENGINE_STATUS_JOB -Force -ErrorAction SilentlyContinue
        $script:ENGINE_STATUS_JOB = $null
    }
}

# ===========================================
# 13. TOKEN COST TRACKING
# ===========================================

function Extract-TokensFromOutput {
    <#
    .SYNOPSIS
        Parses JSON output from an agent CLI to extract token usage and text content.
        Returns $null if no token data found (graceful degradation).
    #>
    param(
        [string]$Agent,
        [string]$RawOutput
    )

    if (-not $RawOutput) { return $null }

    try {
        if ($Agent -eq "claude") {
            # Claude --output-format json returns a JSON array of messages.
            # The last entry (type="result") has: total_cost_usd, result, duration_ms, num_turns
            $jsonText = $RawOutput.Trim()

            # Handle JSON array (multiple entries) or single object
            $entries = $null
            if ($jsonText.StartsWith("[")) {
                $entries = $jsonText | ConvertFrom-Json -ErrorAction Stop
            } else {
                $entries = @($jsonText | ConvertFrom-Json -ErrorAction Stop)
            }

            # Find the result entry
            $resultEntry = $entries | Where-Object { $_.type -eq "result" } | Select-Object -Last 1
            if (-not $resultEntry) { return $null }

            $textOutput = if ($resultEntry.result) { $resultEntry.result } else { "" }
            $costUsd = if ($null -ne $resultEntry.total_cost_usd) { [double]$resultEntry.total_cost_usd } else { 0 }
            $durationMs = if ($null -ne $resultEntry.duration_ms) { [int]$resultEntry.duration_ms } else { 0 }
            $numTurns = if ($null -ne $resultEntry.num_turns) { [int]$resultEntry.num_turns } else { 0 }

            # Extract token counts from usage if available, otherwise estimate from cost
            $inputTokens = 0; $outputTokens = 0; $cachedTokens = 0
            if ($resultEntry.usage) {
                $inputTokens = if ($resultEntry.usage.input_tokens) { [int]$resultEntry.usage.input_tokens } else { 0 }
                $outputTokens = if ($resultEntry.usage.output_tokens) { [int]$resultEntry.usage.output_tokens } else { 0 }
                $cachedTokens = if ($resultEntry.usage.cache_read_input_tokens) { [int]$resultEntry.usage.cache_read_input_tokens } else { 0 }
            }

            return @{
                Tokens = @{ input = $inputTokens; output = $outputTokens; cached = $cachedTokens }
                CostUsd = $costUsd
                TextOutput = $textOutput
                DurationMs = $durationMs
                NumTurns = $numTurns
            }
        }
        elseif ($Agent -eq "codex") {
            # Codex --json returns JSONL events. Find turn.completed for usage data.
            $lines = $RawOutput -split "`n"
            $totalInput = 0; $totalOutput = 0; $totalCached = 0
            $textParts = @()
            $hasUsage = $false

            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if (-not $trimmed -or -not $trimmed.StartsWith("{")) {
                    if ($trimmed) { $textParts += $trimmed }
                    continue
                }
                try {
                    $evt = $trimmed | ConvertFrom-Json -ErrorAction Stop

                    # Accumulate token usage from turn.completed events
                    if ($evt.type -eq "turn.completed" -and $evt.usage) {
                        $hasUsage = $true
                        $totalInput += if ($evt.usage.input_tokens) { [int]$evt.usage.input_tokens } else { 0 }
                        $totalOutput += if ($evt.usage.output_tokens) { [int]$evt.usage.output_tokens } else { 0 }
                        $totalCached += if ($evt.usage.cached_input_tokens) { [int]$evt.usage.cached_input_tokens } else { 0 }
                    }

                    # Extract text content from message events
                    if ($evt.type -eq "message" -and $evt.content) {
                        $textParts += $evt.content
                    } elseif ($evt.type -eq "item.created" -and $evt.item -and $evt.item.content) {
                        $textParts += $evt.item.content
                    }
                } catch {
                    # Non-JSON line, keep as text
                    $textParts += $trimmed
                }
            }

            if (-not $hasUsage) { return $null }

            # Calculate cost from tokens using pricing
            $pricing = Get-TokenPrice -Agent "codex"
            $costUsd = ($totalInput / 1000000.0) * $pricing.InputPerM + ($totalOutput / 1000000.0) * $pricing.OutputPerM

            return @{
                Tokens = @{ input = $totalInput; output = $totalOutput; cached = $totalCached }
                CostUsd = [math]::Round($costUsd, 6)
                TextOutput = ($textParts -join "`n")
                DurationMs = 0
                NumTurns = 0
            }
        }
        elseif ($Agent -eq "gemini") {
            # Gemini --output-format json returns JSON with stats section
            $jsonText = $RawOutput.Trim()
            $parsed = $null

            if ($jsonText.StartsWith("[")) {
                $entries = $jsonText | ConvertFrom-Json -ErrorAction Stop
                $parsed = $entries | Select-Object -Last 1
            } else {
                $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
            }

            if (-not $parsed) { return $null }

            $textOutput = ""
            if ($parsed.response) { $textOutput = $parsed.response }
            elseif ($parsed.result) { $textOutput = $parsed.result }

            $inputTokens = 0; $outputTokens = 0; $cachedTokens = 0
            if ($parsed.stats) {
                $inputTokens = if ($parsed.stats.prompt_tokens) { [int]$parsed.stats.prompt_tokens } elseif ($parsed.stats.input_tokens) { [int]$parsed.stats.input_tokens } else { 0 }
                $outputTokens = if ($parsed.stats.response_tokens) { [int]$parsed.stats.response_tokens } elseif ($parsed.stats.output_tokens) { [int]$parsed.stats.output_tokens } else { 0 }
                $cachedTokens = if ($parsed.stats.cached_tokens) { [int]$parsed.stats.cached_tokens } else { 0 }
            } elseif ($parsed.usage) {
                $inputTokens = if ($parsed.usage.prompt_tokens) { [int]$parsed.usage.prompt_tokens } elseif ($parsed.usage.input_tokens) { [int]$parsed.usage.input_tokens } else { 0 }
                $outputTokens = if ($parsed.usage.completion_tokens) { [int]$parsed.usage.completion_tokens } elseif ($parsed.usage.output_tokens) { [int]$parsed.usage.output_tokens } else { 0 }
                $cachedTokens = if ($parsed.usage.cached_tokens) { [int]$parsed.usage.cached_tokens } else { 0 }
            }

            if ($inputTokens -eq 0 -and $outputTokens -eq 0) { return $null }

            $pricing = Get-TokenPrice -Agent "gemini"
            $costUsd = ($inputTokens / 1000000.0) * $pricing.InputPerM + ($outputTokens / 1000000.0) * $pricing.OutputPerM

            return @{
                Tokens = @{ input = $inputTokens; output = $outputTokens; cached = $cachedTokens }
                CostUsd = [math]::Round($costUsd, 6)
                TextOutput = $textOutput
                DurationMs = 0
                NumTurns = 0
            }
        }
    } catch {
        # Any parse failure -> return null, caller uses raw output
        return $null
    }

    return $null
}

function Get-TokenPrice {
    <#
    .SYNOPSIS
        Returns pricing for a given agent from pricing-cache.json.
        Falls back to hardcoded prices if cache unavailable.
    #>
    param(
        [string]$Agent
    )

    $fallback = @{
        claude   = @{ InputPerM = 3.00; OutputPerM = 15.00; CacheReadPerM = 0.30;  ModelKey = "claude_sonnet" }
        codex    = @{ InputPerM = 1.50; OutputPerM = 6.00;  CacheReadPerM = 0.00;  ModelKey = "codex" }
        gemini   = @{ InputPerM = 1.25; OutputPerM = 10.00; CacheReadPerM = 0.125; ModelKey = "gemini" }
        kimi     = @{ InputPerM = 0.60; OutputPerM = 2.50;  CacheReadPerM = 0.10;  ModelKey = "kimi" }
        deepseek = @{ InputPerM = 0.28; OutputPerM = 0.42;  CacheReadPerM = 0.028; ModelKey = "deepseek" }
        glm5     = @{ InputPerM = 1.00; OutputPerM = 3.20;  CacheReadPerM = 0.10;  ModelKey = "glm5" }
        minimax  = @{ InputPerM = 0.29; OutputPerM = 1.20;  CacheReadPerM = 0.03;  ModelKey = "minimax" }
    }

    $modelKey = switch ($Agent) {
        "claude"   { "claude_sonnet" }
        "codex"    { "codex" }
        "gemini"   { "gemini" }
        "kimi"     { "kimi" }
        "deepseek" { "deepseek" }
        "glm5"     { "glm5" }
        "minimax"  { "minimax" }
        default    { $Agent }
    }

    try {
        $cachePath = Join-Path $env:USERPROFILE ".gsd-global\pricing-cache.json"
        if (Test-Path $cachePath) {
            $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
            if ($cache.models -and $cache.models.$modelKey) {
                $m = $cache.models.$modelKey
                return @{
                    InputPerM = [double]$m.InputPerM
                    OutputPerM = [double]$m.OutputPerM
                    CacheReadPerM = if ($m.CacheReadPerM) { [double]$m.CacheReadPerM } else { 0 }
                    ModelKey = $modelKey
                }
            }
        }
    } catch { }

    $price = $fallback[$Agent]; if (-not $price) { $price = $fallback["claude"] }; return $price
}

function Initialize-CostTracking {
    <#
    .SYNOPSIS
        Creates .gsd/costs/ directory and records a new run start.
        Idempotent -- safe to call on every pipeline start.
    #>
    param(
        [string]$GsdDir,
        [string]$Pipeline = "converge"
    )

    try {
        $costsDir = Join-Path $GsdDir "costs"
        if (-not (Test-Path $costsDir)) {
            New-Item -ItemType Directory -Path $costsDir -Force | Out-Null
        }

        $summaryPath = Join-Path $costsDir "cost-summary.json"
        $now = (Get-Date).ToUniversalTime().ToString("o")

        if (Test-Path $summaryPath) {
            # Add a new run entry
            $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
            $runs = @($summary.runs)
            # Close the previous run if it has no end time
            for ($r = 0; $r -lt $runs.Count; $r++) {
                if (-not $runs[$r].ended) {
                    $runs[$r].ended = $now
                }
            }
            $runs += @{ started = $now; ended = $null; calls = 0; cost_usd = 0 }
            $summary.runs = $runs
            $summary | ConvertTo-Json -Depth 5 | Set-Content $summaryPath -Encoding UTF8
        } else {
            # Create initial summary
            $summary = @{
                project_start = $now
                last_updated = $now
                total_calls = 0
                total_cost_usd = 0
                total_tokens = @{ input = 0; output = 0; cached = 0 }
                by_agent = @{}
                by_phase = @{}
                runs = @(
                    @{ started = $now; ended = $null; calls = 0; cost_usd = 0 }
                )
            }
            $summary | ConvertTo-Json -Depth 5 | Set-Content $summaryPath -Encoding UTF8
        }

        Write-Host "  Cost tracking: .gsd\costs\ (token-usage.jsonl)" -ForegroundColor DarkGray
    } catch {
        # Cost tracking init should never block the pipeline
    }
}

function Save-TokenUsage {
    <#
    .SYNOPSIS
        Appends a token usage record to .gsd/costs/token-usage.jsonl
        and updates the rolling cost-summary.json.
    #>
    param(
        [string]$GsdDir,
        [string]$Agent,
        [string]$Phase,
        [int]$Iteration = 0,
        [string]$Pipeline = "converge",
        [int]$BatchSize = 0,
        [bool]$Success = $false,
        [bool]$IsFallback = $false,
        [hashtable]$TokenData    # Output from Extract-TokensFromOutput
    )

    try {
        $costsDir = Join-Path $GsdDir "costs"
        if (-not (Test-Path $costsDir)) {
            New-Item -ItemType Directory -Path $costsDir -Force | Out-Null
        }

        $entry = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            pipeline = $Pipeline
            iteration = $Iteration
            phase = $Phase
            agent = $Agent
            batch_size = $BatchSize
            success = $Success
            is_fallback = $IsFallback
            tokens = $TokenData.Tokens
            cost_usd = $TokenData.CostUsd
            duration_seconds = if ($TokenData.DurationMs -gt 0) { [math]::Round($TokenData.DurationMs / 1000.0) } else { 0 }
            num_turns = $TokenData.NumTurns
            estimated = if ($TokenData.Estimated) { $true } else { $false }
        }

        # Append to JSONL (append-only, crash-safe)
        $jsonLine = $entry | ConvertTo-Json -Depth 4 -Compress
        Add-Content -Path (Join-Path $costsDir "token-usage.jsonl") -Value $jsonLine -Encoding UTF8

        # Update rolling summary
        Update-CostSummary -GsdDir $GsdDir -UsageEntry $entry
    } catch {
        # Token tracking must NEVER fail the pipeline
    }
}

function Update-CostSummary {
    <#
    .SYNOPSIS
        Incremental merge-on-write update to cost-summary.json.
        If summary is missing or corrupt, rebuilds from token-usage.jsonl.
    #>
    param(
        [string]$GsdDir,
        [hashtable]$UsageEntry
    )

    try {
        $summaryPath = Join-Path $GsdDir "costs\cost-summary.json"
        $summary = $null

        if (Test-Path $summaryPath) {
            try {
                $raw = Get-Content $summaryPath -Raw | ConvertFrom-Json
                # ConvertFrom-Json returns PSCustomObject -- convert to hashtable so
                # we can dynamically add keys and mutate nested properties in-place
                $summary = ConvertTo-MutableSummary $raw
            } catch {
                # Corrupt -- rebuild
                $summary = Rebuild-CostSummary -GsdDir $GsdDir
            }
        }

        if (-not $summary) {
            $summary = Rebuild-CostSummary -GsdDir $GsdDir
        }

        # Increment totals
        $summary.total_calls = [int]$summary.total_calls + 1
        $summary.total_cost_usd = [math]::Round([double]$summary.total_cost_usd + $UsageEntry.cost_usd, 6)
        $summary.last_updated = (Get-Date).ToUniversalTime().ToString("o")

        # Update total tokens
        if (-not $summary.total_tokens) { $summary.total_tokens = @{ input = 0; output = 0; cached = 0 } }
        $summary.total_tokens.input = [long]$summary.total_tokens.input + [long]$UsageEntry.tokens.input
        $summary.total_tokens.output = [long]$summary.total_tokens.output + [long]$UsageEntry.tokens.output
        $summary.total_tokens.cached = [long]$summary.total_tokens.cached + [long]$UsageEntry.tokens.cached

        # Update by_agent
        if (-not $summary.by_agent) { $summary.by_agent = @{} }
        $agentKey = $UsageEntry.agent
        if (-not $summary.by_agent.$agentKey) {
            $summary.by_agent.$agentKey = @{ calls = 0; cost_usd = 0; tokens = @{ input = 0; output = 0; cached = 0 } }
        }
        $a = $summary.by_agent.$agentKey
        $a.calls = [int]$a.calls + 1
        $a.cost_usd = [math]::Round([double]$a.cost_usd + $UsageEntry.cost_usd, 6)
        $a.tokens.input = [long]$a.tokens.input + [long]$UsageEntry.tokens.input
        $a.tokens.output = [long]$a.tokens.output + [long]$UsageEntry.tokens.output
        $a.tokens.cached = [long]$a.tokens.cached + [long]$UsageEntry.tokens.cached

        # Update by_phase
        if (-not $summary.by_phase) { $summary.by_phase = @{} }
        $phaseKey = $UsageEntry.phase
        if (-not $summary.by_phase.$phaseKey) {
            $summary.by_phase.$phaseKey = @{ calls = 0; cost_usd = 0 }
        }
        $p = $summary.by_phase.$phaseKey
        $p.calls = [int]$p.calls + 1
        $p.cost_usd = [math]::Round([double]$p.cost_usd + $UsageEntry.cost_usd, 6)

        # Update current run (mutate in-place on $summary.runs, not a copy)
        if ($summary.runs -and $summary.runs.Count -gt 0) {
            $summary.runs[$summary.runs.Count - 1].calls = [int]$summary.runs[$summary.runs.Count - 1].calls + 1
            $summary.runs[$summary.runs.Count - 1].cost_usd = [math]::Round(
                [double]$summary.runs[$summary.runs.Count - 1].cost_usd + $UsageEntry.cost_usd, 6)
        }

        $summary | ConvertTo-Json -Depth 5 | Set-Content $summaryPath -Encoding UTF8
    } catch {
        # Summary update failure is non-fatal -- JSONL has the ground truth
    }
}

function Rebuild-CostSummary {
    <#
    .SYNOPSIS
        Rebuilds cost-summary.json from scratch by reading all token-usage.jsonl entries.
        Used for corruption recovery.
    #>
    param([string]$GsdDir)

    $summary = @{
        project_start = (Get-Date).ToUniversalTime().ToString("o")
        last_updated = (Get-Date).ToUniversalTime().ToString("o")
        total_calls = 0
        total_cost_usd = 0
        total_tokens = @{ input = 0; output = 0; cached = 0 }
        by_agent = @{}
        by_phase = @{}
        runs = @()
    }

    $jsonlPath = Join-Path $GsdDir "costs\token-usage.jsonl"
    if (Test-Path $jsonlPath) {
        $lines = Get-Content $jsonlPath -Encoding UTF8
        foreach ($line in $lines) {
            if (-not $line.Trim()) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                $summary.total_calls++
                $summary.total_cost_usd = [math]::Round($summary.total_cost_usd + [double]$entry.cost_usd, 6)

                if ($entry.tokens) {
                    $summary.total_tokens.input += [long]$entry.tokens.input
                    $summary.total_tokens.output += [long]$entry.tokens.output
                    $summary.total_tokens.cached += [long]$entry.tokens.cached
                }

                # by_agent
                $ak = $entry.agent
                if (-not $summary.by_agent[$ak]) {
                    $summary.by_agent[$ak] = @{ calls = 0; cost_usd = 0; tokens = @{ input = 0; output = 0; cached = 0 } }
                }
                $summary.by_agent[$ak].calls++
                $summary.by_agent[$ak].cost_usd = [math]::Round($summary.by_agent[$ak].cost_usd + [double]$entry.cost_usd, 6)
                if ($entry.tokens) {
                    $summary.by_agent[$ak].tokens.input += [long]$entry.tokens.input
                    $summary.by_agent[$ak].tokens.output += [long]$entry.tokens.output
                    $summary.by_agent[$ak].tokens.cached += [long]$entry.tokens.cached
                }

                # by_phase
                $pk = $entry.phase
                if (-not $summary.by_phase[$pk]) {
                    $summary.by_phase[$pk] = @{ calls = 0; cost_usd = 0 }
                }
                $summary.by_phase[$pk].calls++
                $summary.by_phase[$pk].cost_usd = [math]::Round($summary.by_phase[$pk].cost_usd + [double]$entry.cost_usd, 6)

                # Track first entry timestamp as project_start
                if ($summary.total_calls -eq 1 -and $entry.timestamp) {
                    $summary.project_start = $entry.timestamp
                }
            } catch { }
        }
    }

    $summaryPath = Join-Path $GsdDir "costs\cost-summary.json"
    $summary | ConvertTo-Json -Depth 5 | Set-Content $summaryPath -Encoding UTF8

    return $summary
}

function ConvertTo-MutableSummary {
    <#
    .SYNOPSIS
        Converts a PSCustomObject (from ConvertFrom-Json) into nested hashtables
        so that dynamic property addition and in-place mutation work correctly.
    #>
    param([object]$Obj)

    $h = @{
        project_start  = if ($Obj.project_start) { $Obj.project_start } else { (Get-Date).ToUniversalTime().ToString("o") }
        last_updated   = if ($Obj.last_updated) { $Obj.last_updated } else { (Get-Date).ToUniversalTime().ToString("o") }
        total_calls    = [int]$Obj.total_calls
        total_cost_usd = [double]$Obj.total_cost_usd
        total_tokens   = @{
            input  = [long]$Obj.total_tokens.input
            output = [long]$Obj.total_tokens.output
            cached = [long]$Obj.total_tokens.cached
        }
        by_agent = @{}
        by_phase = @{}
        runs     = @()
    }

    # Convert by_agent
    if ($Obj.by_agent) {
        foreach ($prop in $Obj.by_agent.PSObject.Properties) {
            $h.by_agent[$prop.Name] = @{
                calls    = [int]$prop.Value.calls
                cost_usd = [double]$prop.Value.cost_usd
                tokens   = @{
                    input  = [long]$prop.Value.tokens.input
                    output = [long]$prop.Value.tokens.output
                    cached = [long]$prop.Value.tokens.cached
                }
            }
        }
    }

    # Convert by_phase
    if ($Obj.by_phase) {
        foreach ($prop in $Obj.by_phase.PSObject.Properties) {
            $h.by_phase[$prop.Name] = @{
                calls    = [int]$prop.Value.calls
                cost_usd = [double]$prop.Value.cost_usd
            }
        }
    }

    # Convert runs array -- each element must be a mutable hashtable
    if ($Obj.runs) {
        foreach ($run in @($Obj.runs)) {
            $h.runs += @{
                started  = $run.started
                ended    = $run.ended
                calls    = [int]$run.calls
                cost_usd = [double]$run.cost_usd
            }
        }
    }

    return $h
}

function Complete-CostTrackingRun {
    <#
    .SYNOPSIS
        Marks the current run as ended in cost-summary.json.
        Called from the pipeline's finally block.
    #>
    param([string]$GsdDir)

    try {
        $summaryPath = Join-Path $GsdDir "costs\cost-summary.json"
        if (Test-Path $summaryPath) {
            $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json
            $runs = @($summary.runs)
            if ($runs.Count -gt 0 -and -not $runs[$runs.Count - 1].ended) {
                $runs[$runs.Count - 1].ended = (Get-Date).ToUniversalTime().ToString("o")
                $summary.runs = $runs
                $summary | ConvertTo-Json -Depth 5 | Set-Content $summaryPath -Encoding UTF8
            }
        }
    } catch { }
}

Write-Host "  Hardening modules loaded." -ForegroundColor DarkGray


# ===============================================================
# GSD FINAL VALIDATION MODULES - appended to resilience.ps1
# ===============================================================

# -- Final validation config --
$script:FINAL_VALIDATION_TIMEOUT = 300   # 5 min per check
$script:MAX_VALIDATION_ATTEMPTS = 3

function Invoke-FinalValidation {
    <#
    .SYNOPSIS
        Quality gate that runs when health reaches 100%, before declaring CONVERGED.
        Returns structured results: hard failures block convergence, warnings are advisory.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [int]$Iteration
    )

    $result = @{
        Passed       = $true
        HardFailures = @()
        Warnings     = @()
        Details      = @{}
        Timestamp    = (Get-Date).ToUniversalTime().ToString("o")
    }

    $logLines = @("=== Final Validation at iter $Iteration ===", "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "")

    # --- Check 1: Strict .NET Build ---
    try {
        $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
        if ($slnFiles -and $slnFiles.Count -gt 0) {
            $sln = $slnFiles[0].FullName
            $logLines += "CHECK 1: dotnet build --warnaserrors"
            $buildOutput = & dotnet build $sln --no-restore --verbosity quiet 2>&1 | Out-String
            $buildErrors = ($buildOutput -split "`n") | Where-Object { $_ -match "(error CS|error MSB|warning CS)" }
            if ($LASTEXITCODE -ne 0 -or ($buildErrors | Where-Object { $_ -match "error" }).Count -gt 0) {
                $errorCount = ($buildErrors | Where-Object { $_ -match "error" }).Count
                $result.HardFailures += "dotnet build: $errorCount compilation error(s)"
                $result.Passed = $false
                $result.Details["dotnet_build"] = @{ passed=$false; errors=$buildErrors }
                $logLines += "  FAIL: $errorCount error(s)"
                $logLines += $buildErrors
            } else {
                $warnCount = ($buildErrors | Where-Object { $_ -match "warning" }).Count
                if ($warnCount -gt 0) {
                    $result.Warnings += "dotnet build: $warnCount warning(s)"
                    $result.Details["dotnet_build"] = @{ passed=$true; warnings=$warnCount }
                    $logLines += "  WARN: $warnCount warning(s)"
                } else {
                    $result.Details["dotnet_build"] = @{ passed=$true; warnings=0 }
                    $logLines += "  PASS"
                }
            }
        } else {
            $result.Details["dotnet_build"] = @{ skipped=$true; reason="No .sln found" }
            $logLines += "CHECK 1: SKIP (no .sln file)"
        }
    } catch {
        $result.Warnings += "dotnet build check failed: $($_.Exception.Message)"
        $logLines += "CHECK 1: ERROR - $($_.Exception.Message)"
    }

    # --- Check 2: npm Build ---
    try {
        $pkgLocations = @("$RepoRoot\package.json", "$RepoRoot\client\package.json",
                          "$RepoRoot\frontend\package.json", "$RepoRoot\web\package.json",
                          "$RepoRoot\src\client\package.json", "$RepoRoot\src\web\package.json")
        $pkgJson = $pkgLocations | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($pkgJson) {
            $pkgDir = Split-Path $pkgJson -Parent
            $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
            if ($pkg.scripts -and $pkg.scripts.build) {
                $logLines += "CHECK 2: npm run build (in $pkgDir)"
                Push-Location $pkgDir
                try {
                    if (-not (Test-Path "node_modules")) {
                        & npm install --silent 2>&1 | Out-Null
                    }
                    $npmOutput = & npm run build 2>&1 | Out-String
                    $npmErrors = ($npmOutput -split "`n") | Where-Object { $_ -match "(TS\d{4}|SyntaxError|Module not found|Cannot find|ERROR|Failed to compile)" }
                    if ($LASTEXITCODE -ne 0) {
                        $result.HardFailures += "npm build: failed with exit code $LASTEXITCODE"
                        $result.Passed = $false
                        $result.Details["npm_build"] = @{ passed=$false; errors=$npmErrors }
                        $logLines += "  FAIL: exit code $LASTEXITCODE"
                        $logLines += $npmErrors
                    } else {
                        $result.Details["npm_build"] = @{ passed=$true }
                        $logLines += "  PASS"
                    }
                } finally { Pop-Location }
            } else {
                $result.Details["npm_build"] = @{ skipped=$true; reason="No build script in package.json" }
                $logLines += "CHECK 2: SKIP (no build script)"
            }
        } else {
            $result.Details["npm_build"] = @{ skipped=$true; reason="No package.json found" }
            $logLines += "CHECK 2: SKIP (no package.json)"
        }
    } catch {
        $result.Warnings += "npm build check failed: $($_.Exception.Message)"
        $logLines += "CHECK 2: ERROR - $($_.Exception.Message)"
    }

    # --- Check 3: .NET Tests ---
    try {
        $testProjects = Get-ChildItem -Path $RepoRoot -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "\.(Tests?|Specs?)\.csproj$" }

        if ($testProjects -and $testProjects.Count -gt 0) {
            $logLines += "CHECK 3: dotnet test ($($testProjects.Count) test project(s))"
            $allTestsPassed = $true
            $testSummary = @()
            foreach ($tp in $testProjects) {
                $testOutput = & dotnet test $tp.FullName --no-build --verbosity normal 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    $allTestsPassed = $false
                    $failedLines = ($testOutput -split "`n") | Where-Object { $_ -match "(Failed|Error)" } | Select-Object -First 10
                    $testSummary += "$($tp.Name): FAILED"
                    $testSummary += $failedLines
                } else {
                    $passedMatch = [regex]::Match($testOutput, "Passed!\s+-\s+Failed:\s+(\d+),\s+Passed:\s+(\d+)")
                    if ($passedMatch.Success) {
                        $testSummary += "$($tp.Name): Passed ($($passedMatch.Groups[2].Value) tests)"
                    } else {
                        $testSummary += "$($tp.Name): Passed"
                    }
                }
            }
            if (-not $allTestsPassed) {
                $failCount = ($testSummary | Where-Object { $_ -match "FAILED" }).Count
                $result.HardFailures += "dotnet test: $failCount test project(s) failed"
                $result.Passed = $false
                $result.Details["dotnet_test"] = @{ passed=$false; summary=$testSummary }
                $logLines += "  FAIL: $failCount project(s) failed"
            } else {
                $result.Details["dotnet_test"] = @{ passed=$true; summary=$testSummary }
                $logLines += "  PASS: all $($testProjects.Count) project(s)"
            }
            $logLines += $testSummary
        } else {
            $result.Warnings += "No .NET test projects detected"
            $result.Details["dotnet_test"] = @{ skipped=$true; reason="No test projects found" }
            $logLines += "CHECK 3: SKIP (no test projects) - WARNING: no tests"
        }
    } catch {
        $result.Warnings += "dotnet test check failed: $($_.Exception.Message)"
        $logLines += "CHECK 3: ERROR - $($_.Exception.Message)"
    }

    # --- Check 4: npm Tests ---
    try {
        if ($pkgJson) {
            $pkg = Get-Content $pkgJson -Raw | ConvertFrom-Json
            $hasRealTests = $pkg.scripts -and $pkg.scripts.test -and
                $pkg.scripts.test -notmatch 'echo\s+"?Error' -and
                $pkg.scripts.test -ne "exit 1"

            if ($hasRealTests) {
                $pkgDir = Split-Path $pkgJson -Parent
                $logLines += "CHECK 4: npm test (in $pkgDir)"
                Push-Location $pkgDir
                try {
                    $env:CI = "true"  # prevents interactive watch mode
                    $npmTestOutput = & npm test 2>&1 | Out-String
                    $env:CI = $null
                    if ($LASTEXITCODE -ne 0) {
                        $failLines = ($npmTestOutput -split "`n") | Where-Object { $_ -match "(FAIL|Error|failed)" } | Select-Object -First 10
                        $result.HardFailures += "npm test: tests failed"
                        $result.Passed = $false
                        $result.Details["npm_test"] = @{ passed=$false; output=$failLines }
                        $logLines += "  FAIL"
                        $logLines += $failLines
                    } else {
                        $result.Details["npm_test"] = @{ passed=$true }
                        $logLines += "  PASS"
                    }
                } finally { Pop-Location }
            } else {
                $result.Warnings += "No real npm test script detected"
                $result.Details["npm_test"] = @{ skipped=$true; reason="Default or missing test script" }
                $logLines += "CHECK 4: SKIP (no real test script) - WARNING: no tests"
            }
        } else {
            $result.Details["npm_test"] = @{ skipped=$true; reason="No package.json" }
            $logLines += "CHECK 4: SKIP (no package.json)"
        }
    } catch {
        $result.Warnings += "npm test check failed: $($_.Exception.Message)"
        $logLines += "CHECK 4: ERROR - $($_.Exception.Message)"
    }

    # --- Check 5: SQL Validation ---
    try {
        if (Get-Command Test-SqlFiles -ErrorAction SilentlyContinue) {
            $logLines += "CHECK 5: SQL validation"
            $sqlResult = Test-SqlFiles -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration
            if (-not $sqlResult.Passed) {
                $result.Warnings += "SQL issues: $($sqlResult.Errors.Count) pattern violation(s)"
                $result.Details["sql_validation"] = @{ passed=$false; errors=$sqlResult.Errors }
                $logLines += "  WARN: $($sqlResult.Errors.Count) issue(s)"
                $logLines += $sqlResult.Errors
            } else {
                $result.Details["sql_validation"] = @{ passed=$true }
                $logLines += "  PASS"
            }
        } else {
            $result.Details["sql_validation"] = @{ skipped=$true; reason="Test-SqlFiles not available" }
            $logLines += "CHECK 5: SKIP (function not available)"
        }
    } catch {
        $result.Warnings += "SQL validation failed: $($_.Exception.Message)"
        $logLines += "CHECK 5: ERROR - $($_.Exception.Message)"
    }

    # --- Check 6: .NET Vulnerability Audit ---
    try {
        $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
        if ($slnFiles -and $slnFiles.Count -gt 0 -and (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            $logLines += "CHECK 6: dotnet list package --vulnerable"
            $vulnOutput = & dotnet list package --vulnerable 2>&1 | Out-String
            $vulnLines = ($vulnOutput -split "`n") | Where-Object { $_ -match "(Critical|High|Moderate)" }
            if ($vulnLines.Count -gt 0) {
                $result.Warnings += "NuGet vulnerabilities: $($vulnLines.Count) package(s) flagged"
                $result.Details["dotnet_audit"] = @{ passed=$false; vulnerabilities=$vulnLines }
                $logLines += "  WARN: $($vulnLines.Count) vulnerable package(s)"
            } else {
                $result.Details["dotnet_audit"] = @{ passed=$true }
                $logLines += "  PASS"
            }
        } else {
            $result.Details["dotnet_audit"] = @{ skipped=$true }
            $logLines += "CHECK 6: SKIP (no .sln or dotnet)"
        }
    } catch {
        $result.Details["dotnet_audit"] = @{ skipped=$true; error=$_.Exception.Message }
        $logLines += "CHECK 6: ERROR - $($_.Exception.Message)"
    }

    # --- Check 7: npm Vulnerability Audit ---
    try {
        if ($pkgJson -and (Get-Command npm -ErrorAction SilentlyContinue)) {
            $pkgDir = Split-Path $pkgJson -Parent
            $logLines += "CHECK 7: npm audit --audit-level=high"
            Push-Location $pkgDir
            try {
                $auditOutput = & npm audit --audit-level=high 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    $vulnCount = if ($auditOutput -match "(\d+)\s+vulnerabilit") { $Matches[1] } else { "unknown" }
                    $result.Warnings += "npm audit: $vulnCount high+ severity vulnerability/ies"
                    $result.Details["npm_audit"] = @{ passed=$false; output=$auditOutput.Substring(0, [math]::Min(2000, $auditOutput.Length)) }
                    $logLines += "  WARN: $vulnCount vulnerability/ies"
                } else {
                    $result.Details["npm_audit"] = @{ passed=$true }
                    $logLines += "  PASS"
                }
            } finally { Pop-Location }
        } else {
            $result.Details["npm_audit"] = @{ skipped=$true }
            $logLines += "CHECK 7: SKIP (no package.json or npm)"
        }
    } catch {
        $result.Details["npm_audit"] = @{ skipped=$true; error=$_.Exception.Message }
        $logLines += "CHECK 7: ERROR - $($_.Exception.Message)"
    }

    # --- Write results ---
    $logLines += ""
    $logLines += "=== Summary ==="
    $logLines += "Passed: $($result.Passed)"
    $logLines += "Hard failures: $($result.HardFailures.Count)"
    $logLines += "Warnings: $($result.Warnings.Count)"

    # Save log
    $logPath = Join-Path $GsdDir "logs\final-validation.log"
    $logLines -join "`n" | Set-Content $logPath -Encoding UTF8

    # Save structured results
    $jsonPath = Join-Path $GsdDir "health\final-validation.json"
    @{
        passed        = $result.Passed
        hard_failures = $result.HardFailures
        warnings      = $result.Warnings
        iteration     = $Iteration
        timestamp     = $result.Timestamp
        checks        = @{
            dotnet_build = $result.Details["dotnet_build"]
            npm_build    = $result.Details["npm_build"]
            dotnet_test  = $result.Details["dotnet_test"]
            npm_test     = $result.Details["npm_test"]
            sql          = $result.Details["sql_validation"]
            dotnet_audit = $result.Details["dotnet_audit"]
            npm_audit    = $result.Details["npm_audit"]
        }
    } | ConvertTo-Json -Depth 4 | Set-Content $jsonPath -Encoding UTF8

    # Log via structured error system if failures
    if (-not $result.Passed -and (Get-Command Write-GsdError -ErrorAction SilentlyContinue)) {
        Write-GsdError -GsdDir $GsdDir -Category "validation_fail" -Phase "final-validation" `
            -Iteration $Iteration -Message ($result.HardFailures -join "; ")
    }

    return $result
}


function New-DeveloperHandoff {
    <#
    .SYNOPSIS
        Generates developer-handoff.md in the repo root with everything a developer
        needs to pick up, compile, and run the project.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$Pipeline = "converge",
        [string]$ExitReason = "unknown",
        [double]$FinalHealth = 0,
        [int]$Iteration = 0,
        $ValidationResult = $null
    )

    $repoName = Split-Path $RepoRoot -Leaf
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $md = @()

    # ===== HEADER =====
    $md += "# Developer Handoff - $repoName"
    $md += ""
    $md += "| Field | Value |"
    $md += "|-------|-------|"
    $md += "| Generated | $timestamp |"
    $md += "| Pipeline | $Pipeline |"
    $md += "| Exit Reason | $ExitReason |"
    $md += "| Final Health | ${FinalHealth}% |"
    $md += "| Iterations | $Iteration |"
    $md += ""

    # ===== QUICK START =====
    $md += "## Quick Start"
    $md += ""
    $buildCmds = @()

    # .NET
    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
    if ($slnFiles -and $slnFiles.Count -gt 0) {
        $slnRel = $slnFiles[0].FullName.Replace("$RepoRoot\", "")
        $buildCmds += "### .NET"
        $buildCmds += '```bash'
        $buildCmds += "dotnet restore $slnRel"
        $buildCmds += "dotnet build $slnRel"
        $buildCmds += "dotnet test    # if test projects exist"
        $buildCmds += '```'
        $buildCmds += ""
    }

    # npm
    $pkgLocations = @("$RepoRoot\package.json", "$RepoRoot\client\package.json",
                      "$RepoRoot\frontend\package.json", "$RepoRoot\web\package.json",
                      "$RepoRoot\src\client\package.json", "$RepoRoot\src\web\package.json")
    $pkgJson = $pkgLocations | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($pkgJson) {
        $pkgDir = (Split-Path $pkgJson -Parent).Replace("$RepoRoot\", "")
        if ($pkgDir -eq (Split-Path $pkgJson -Parent)) { $pkgDir = "." }
        $buildCmds += "### Node.js / React"
        $buildCmds += '```bash'
        if ($pkgDir -ne ".") { $buildCmds += "cd $pkgDir" }
        $buildCmds += "npm install"
        $buildCmds += "npm run build"
        $buildCmds += "npm test       # if tests exist"
        $buildCmds += '```'
        $buildCmds += ""
    }

    # Docker
    $dockerFiles = @("$RepoRoot\docker-compose.yml", "$RepoRoot\docker-compose.yaml")
    $dockerFile = $dockerFiles | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($dockerFile) {
        $buildCmds += "### Docker"
        $buildCmds += '```bash'
        $buildCmds += "docker-compose up -d"
        $buildCmds += '```'
        $buildCmds += ""
    }

    if ($buildCmds.Count -eq 0) {
        $buildCmds += "*No build system detected. Check project root for build instructions.*"
        $buildCmds += ""
    }
    $md += $buildCmds

    # ===== DATABASE SETUP =====
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git|bin|obj)" } |
        Sort-Object Name

    if ($sqlFiles -and $sqlFiles.Count -gt 0) {
        $md += "## Database Setup"
        $md += ""

        # Connection string from appsettings
        $appSettings = @("$RepoRoot\appsettings.json", "$RepoRoot\src\appsettings.json",
                         "$RepoRoot\Api\appsettings.json", "$RepoRoot\src\Api\appsettings.json")
        $appSettingsFile = $appSettings | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($appSettingsFile) {
            try {
                $config = Get-Content $appSettingsFile -Raw | ConvertFrom-Json
                if ($config.ConnectionStrings) {
                    $md += "### Connection Strings"
                    $md += ""
                    $md += "From ``$(Split-Path $appSettingsFile -Leaf)``:"
                    $md += '```json'
                    $md += ($config.ConnectionStrings | ConvertTo-Json -Depth 2)
                    $md += '```'
                    $md += ""
                    $md += "> Update server name, credentials, and database name for your environment."
                    $md += ""
                }
            } catch {}
        }

        $md += "### SQL Scripts ($($sqlFiles.Count) files)"
        $md += ""
        $md += "Execute in this order:"
        $md += ""
        $md += "| # | File | Size |"
        $md += "|---|------|------|"
        $i = 0
        foreach ($sf in $sqlFiles) {
            $i++
            $relPath = $sf.FullName.Replace("$RepoRoot\", "")
            $sizeKb = [math]::Round($sf.Length / 1024, 1)
            $md += "| $i | ``$relPath`` | ${sizeKb} KB |"
        }
        $md += ""
    }

    # ===== ENVIRONMENT CONFIGURATION =====
    $md += "## Environment Configuration"
    $md += ""

    # appsettings
    $allAppSettings = Get-ChildItem -Path $RepoRoot -Filter "appsettings*.json" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git|bin|obj)" }
    if ($allAppSettings -and $allAppSettings.Count -gt 0) {
        $md += "### Configuration Files"
        $md += ""
        foreach ($as in $allAppSettings) {
            $relPath = $as.FullName.Replace("$RepoRoot\", "")
            $md += "- ``$relPath``"
        }
        $md += ""
    }

    # .env files
    $envFiles = Get-ChildItem -Path $RepoRoot -Filter ".env*" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git)" }
    if ($envFiles -and $envFiles.Count -gt 0) {
        $md += "### Environment Files"
        $md += ""
        foreach ($ef in $envFiles) {
            $relPath = $ef.FullName.Replace("$RepoRoot\", "")
            $md += "- ``$relPath``"
        }
        $md += ""
        $md += "> Copy ``.env.example`` to ``.env`` and fill in values before running."
        $md += ""
    }

    if ((-not $allAppSettings -or $allAppSettings.Count -eq 0) -and (-not $envFiles -or $envFiles.Count -eq 0)) {
        $md += "*No configuration files detected.*"
        $md += ""
    }

    # ===== PROJECT STRUCTURE =====
    $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
    if (Test-Path $fileTreePath) {
        $md += "## Project Structure"
        $md += ""
        $md += '```'
        $treeContent = Get-Content $fileTreePath -Raw
        if ($treeContent.Length -gt 5000) {
            $md += $treeContent.Substring(0, 5000)
            $md += "... (truncated, see .gsd/file-map-tree.md for full tree)"
        } else {
            $md += $treeContent
        }
        $md += '```'
        $md += ""
    }

    # ===== REQUIREMENTS STATUS =====
    $matrixPath = if ($Pipeline -eq "blueprint") {
        Join-Path $GsdDir "blueprint\blueprint.json"
    } else {
        Join-Path $GsdDir "health\requirements-matrix.json"
    }

    if (Test-Path $matrixPath) {
        try {
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $reqs = if ($Pipeline -eq "blueprint" -and $matrix.tiers) {
                $allItems = @()
                foreach ($tier in $matrix.tiers) {
                    foreach ($item in $tier.items) {
                        $allItems += [PSCustomObject]@{
                            id          = if ($item.id) { $item.id } else { $item.file }
                            description = if ($item.description) { $item.description } else { $item.file }
                            status      = if ($item.status) { $item.status } else { "not_started" }
                            files       = if ($item.file) { @($item.file) } else { @() }
                        }
                    }
                }
                $allItems
            } elseif ($matrix.requirements) {
                $matrix.requirements
            } else { @() }

            if ($reqs.Count -gt 0) {
                $md += "## Requirements Status"
                $md += ""

                $satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" })
                $partial   = @($reqs | Where-Object { $_.status -eq "partial" })
                $notStarted = @($reqs | Where-Object { $_.status -eq "not_started" })

                $md += "| Status | Count |"
                $md += "|--------|-------|"
                $md += "| Satisfied | $($satisfied.Count) |"
                $md += "| Partial | $($partial.Count) |"
                $md += "| Not Started | $($notStarted.Count) |"
                $md += "| **Total** | **$($reqs.Count)** |"
                $md += ""

                $md += "<details>"
                $md += "<summary>Full requirements list ($($reqs.Count) items)</summary>"
                $md += ""
                $md += "| ID | Description | Status | Implemented In |"
                $md += "|----|-------------|--------|---------------|"

                # Satisfied first, then partial, then not_started
                foreach ($r in ($satisfied + $partial + $notStarted)) {
                    $id = if ($r.id) { $r.id } else { "-" }
                    $desc = if ($r.description) { $r.description.Substring(0, [math]::Min(80, $r.description.Length)) } else { "-" }
                    $files = if ($r.satisfied_by) { ($r.satisfied_by | Select-Object -First 3) -join ", " }
                             elseif ($r.files) { ($r.files | Select-Object -First 3) -join ", " }
                             else { "-" }
                    $statusIcon = switch ($r.status) {
                        "satisfied"   { "OK" }
                        "partial"     { "PARTIAL" }
                        "not_started" { "TODO" }
                        default       { $r.status }
                    }
                    $md += "| $id | $desc | $statusIcon | $files |"
                }
                $md += ""
                $md += "</details>"
                $md += ""
            }
        } catch {
            $md += "## Requirements Status"
            $md += ""
            $md += "*Could not parse requirements matrix: $($_.Exception.Message)*"
            $md += ""
        }
    }

    # ===== VALIDATION RESULTS =====
    $md += "## Validation Results"
    $md += ""

    $valJsonPath = Join-Path $GsdDir "health\final-validation.json"
    if ($ValidationResult) {
        if ($ValidationResult.Passed) {
            $md += "**Status: PASSED**"
        } else {
            $md += "**Status: FAILED**"
        }
        $md += ""

        if ($ValidationResult.HardFailures -and $ValidationResult.HardFailures.Count -gt 0) {
            $md += "### Failures (blocking)"
            $md += ""
            foreach ($f in $ValidationResult.HardFailures) { $md += "- $f" }
            $md += ""
        }

        if ($ValidationResult.Warnings -and $ValidationResult.Warnings.Count -gt 0) {
            $md += "### Warnings (non-blocking)"
            $md += ""
            foreach ($w in $ValidationResult.Warnings) { $md += "- $w" }
            $md += ""
        }

        if ((-not $ValidationResult.HardFailures -or $ValidationResult.HardFailures.Count -eq 0) -and
            (-not $ValidationResult.Warnings -or $ValidationResult.Warnings.Count -eq 0)) {
            $md += "All checks passed with no warnings."
            $md += ""
        }
    } elseif (Test-Path $valJsonPath) {
        try {
            $valData = Get-Content $valJsonPath -Raw | ConvertFrom-Json
            $md += "**Status: $(if ($valData.passed) {'PASSED'} else {'FAILED'})**"
            $md += ""
            if ($valData.hard_failures.Count -gt 0) {
                $md += "### Failures"
                $md += ""
                foreach ($f in $valData.hard_failures) { $md += "- $f" }
                $md += ""
            }
            if ($valData.warnings.Count -gt 0) {
                $md += "### Warnings"
                $md += ""
                foreach ($w in $valData.warnings) { $md += "- $w" }
                $md += ""
            }
        } catch {
            $md += "*Could not parse validation results.*"
            $md += ""
        }
    } else {
        $md += "*Final validation was not run (health did not reach 100%).*"
        $md += ""
    }

    # ===== KNOWN ISSUES =====
    $md += "## Known Issues"
    $md += ""

    $hasIssues = $false

    # Drift report
    $driftPath = Join-Path $GsdDir "health\drift-report.md"
    if (Test-Path $driftPath) {
        $driftContent = (Get-Content $driftPath -Raw).Trim()
        if ($driftContent.Length -gt 10) {
            $md += "### Remaining Gaps"
            $md += ""
            $md += $driftContent
            $md += ""
            $hasIssues = $true
        }
    }

    # Recent errors
    $errorsPath = Join-Path $GsdDir "logs\errors.jsonl"
    if (Test-Path $errorsPath) {
        $errorLines = Get-Content $errorsPath -ErrorAction SilentlyContinue | Select-Object -Last 10
        if ($errorLines -and $errorLines.Count -gt 0) {
            $md += "### Recent Errors (last 10)"
            $md += ""
            $md += "| Category | Phase | Message |"
            $md += "|----------|-------|---------|"
            foreach ($line in $errorLines) {
                try {
                    $err = $line | ConvertFrom-Json
                    $msg = if ($err.message.Length -gt 80) { $err.message.Substring(0, 80) + "..." } else { $err.message }
                    $md += "| $($err.category) | $($err.phase) | $msg |"
                } catch {}
            }
            $md += ""
            $hasIssues = $true
        }
    }

    if (-not $hasIssues) {
        $md += "*No known issues.*"
        $md += ""
    }

    # ===== HEALTH PROGRESSION =====
    $historyPath = if ($Pipeline -eq "blueprint") {
        Join-Path $GsdDir "blueprint\health-history.jsonl"
    } else {
        Join-Path $GsdDir "health\health-history.jsonl"
    }

    if (Test-Path $historyPath) {
        $entries = Get-Content $historyPath -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch {} }
        if ($entries -and $entries.Count -gt 0) {
            $md += "## Health Progression"
            $md += ""
            $md += '```'
            foreach ($e in $entries) {
                $iter = if ($e.iteration) { $e.iteration } else { "?" }
                $h = if ($e.health_score) { $e.health_score } elseif ($e.health) { $e.health } else { 0 }
                $filled = [math]::Floor($h / 5)
                $empty = 20 - $filled
                $bar = "#" * $filled + "." * $empty
                $md += "  Iter {0,3}: [{1}] {2,5:N1}%" -f $iter, $bar, $h
            }
            $md += '```'
            $md += ""
        }
    }

    # ===== LLM COUNCIL REVIEW =====
    $councilPath = Join-Path $GsdDir "health\council-review.json"
    if (Test-Path $councilPath) {
        try {
            $council = Get-Content $councilPath -Raw | ConvertFrom-Json
            $md += "## LLM Council Review"
            $md += ""
            $md += "| Field | Value |"
            $md += "|-------|-------|"
            $md += "| Verdict | $(if ($council.approved) { 'APPROVED' } else { 'BLOCKED' }) |"
            $md += "| Confidence | $($council.confidence)% |"
            $md += ""

            if ($council.votes) {
                $md += "### Agent Votes"
                $md += ""
                $md += "| Agent | Vote |"
                $md += "|-------|------|"
                $council.votes.PSObject.Properties | ForEach-Object {
                    $md += "| $($_.Name) | $($_.Value) |"
                }
                $md += ""
            }

            if ($council.strengths -and $council.strengths.Count -gt 0) {
                $md += "### Strengths"
                $md += ""
                foreach ($s in $council.strengths) { $md += "- $s" }
                $md += ""
            }

            if ($council.concerns -and $council.concerns.Count -gt 0) {
                $md += "### Concerns"
                $md += ""
                foreach ($c in $council.concerns) { $md += "- $c" }
                $md += ""
            }

            if ($council.reason) {
                $md += "### Reasoning"
                $md += ""
                $md += $council.reason
                $md += ""
            }
        } catch {
            $md += "## LLM Council Review"
            $md += ""
            $md += "*Could not parse council data.*"
            $md += ""
        }
    }

    # ===== LOC METRICS =====
    $locPath = Join-Path $GsdDir "costs\loc-metrics.json"
    if (Test-Path $locPath) {
        try {
            $locData = Get-Content $locPath -Raw | ConvertFrom-Json
            $md += "## Lines of Code (AI-Generated)"
            $md += ""
            $md += "| Metric | Value |"
            $md += "|--------|-------|"
            $md += "| Lines Added | $($locData.cumulative.lines_added) |"
            $md += "| Lines Deleted | $($locData.cumulative.lines_deleted) |"
            $md += "| Net Lines | $($locData.cumulative.lines_net) |"
            $md += "| Files Changed | $($locData.cumulative.files_changed) |"
            $md += "| Iterations | $($locData.cumulative.iterations) |"
            if ($locData.cost_per_line -and [double]$locData.cost_per_line.cost_per_added_line -gt 0) {
                $md += "| Cost per Added Line | `$$($locData.cost_per_line.cost_per_added_line) |"
                $md += "| Cost per Net Line | `$$($locData.cost_per_line.cost_per_net_line) |"
                $md += "| Total API Cost | `$$($locData.cost_per_line.total_cost_usd) |"
            }
            $md += ""
            $md += "### Per-Iteration LOC Breakdown"
            $md += ""
            $md += "| Iter | Added | Deleted | Net | Files |"
            $md += "|------|-------|---------|-----|-------|"
            foreach ($locIter in $locData.iterations) {
                $md += "| $($locIter.iteration) | +$($locIter.lines_added) | -$($locIter.lines_deleted) | $($locIter.lines_net) | $($locIter.files_changed) |"
            }
            $md += ""
        } catch {}
    }

    # ===== COST SUMMARY =====
    $costPath = Join-Path $GsdDir "costs\cost-summary.json"
    if (Test-Path $costPath) {
        try {
            $costs = Get-Content $costPath -Raw | ConvertFrom-Json
            $md += "## Cost Summary"
            $md += ""
            $md += "| Metric | Value |"
            $md += "|--------|-------|"
            $md += "| Total API Cost | `$$('{0:N2}' -f $costs.total_cost_usd) |"
            $md += "| Total API Calls | $($costs.total_calls) |"
            if ($costs.total_tokens) {
                $md += "| Input Tokens | $('{0:N0}' -f $costs.total_tokens.input) |"
                $md += "| Output Tokens | $('{0:N0}' -f $costs.total_tokens.output) |"
                if ($costs.total_tokens.cached) {
                    $md += "| Cached Tokens | $('{0:N0}' -f $costs.total_tokens.cached) |"
                }
            }
            $md += ""

            if ($costs.by_agent) {
                $md += "### Cost by Agent"
                $md += ""
                $md += "| Agent | Calls | Cost |"
                $md += "|-------|-------|------|"
                $costs.by_agent.PSObject.Properties | ForEach-Object {
                    $md += "| $($_.Name) | $($_.Value.calls) | `$$('{0:N2}' -f $_.Value.cost_usd) |"
                }
                $md += ""
            }

            if ($costs.by_phase) {
                $md += "### Cost by Phase"
                $md += ""
                $md += "| Phase | Calls | Cost |"
                $md += "|-------|-------|------|"
                $costs.by_phase.PSObject.Properties | ForEach-Object {
                    $md += "| $($_.Name) | $($_.Value.calls) | `$$('{0:N2}' -f $_.Value.cost_usd) |"
                }
                $md += ""
            }
        } catch {
            $md += "## Cost Summary"
            $md += ""
            $md += "*Could not parse cost data.*"
            $md += ""
        }
    }

    # ===== FOOTER =====
    $md += "---"
    $md += "*Generated by GSD Autonomous Dev Engine*"

    # Write file
    $handoffPath = Join-Path $RepoRoot "developer-handoff.md"
    ($md -join "`n") | Set-Content $handoffPath -Encoding UTF8

    Write-Host "  [DOC] Generated: developer-handoff.md" -ForegroundColor Green

    return $handoffPath
}

Write-Host "  Final validation modules loaded." -ForegroundColor DarkGray

# ===============================================================
# GSD LLM COUNCIL MODULE - appended to resilience.ps1
# ===============================================================

function Build-RequirementChunks {
    <#
    .SYNOPSIS
        Groups requirements dynamically based on fields in the matrix.
        No hardcoded domain maps -- discovers best grouping from actual data.
    #>
    param(
        [string]$MatrixPath,
        [int]$MaxChunkSize = 25,
        [int]$MinGroupSize = 5,
        [string]$Strategy = "auto"
    )

    if (-not (Test-Path $MatrixPath)) { return @() }
    $matrix = Get-Content $MatrixPath -Raw | ConvertFrom-Json
    $reqs = @($matrix.requirements)
    if ($reqs.Count -eq 0) { return @() }

    # If total reqs fit in one chunk, return single chunk
    if ($reqs.Count -le $MaxChunkSize) {
        return @(@{
            Name = "all"
            Requirements = $reqs
            FileHints = @($reqs | Where-Object { $_.notes } | ForEach-Object { $_.notes })
        })
    }

    $groupField = $null
    $groups = @{}

    if ($Strategy -eq "auto") {
        # Discover best grouping field dynamically from the data
        $candidateFields = @("pattern", "sdlc_phase", "priority", "source", "spec_doc")
        $bestField = $null
        $bestScore = [int]::MaxValue  # Lower = better (closer to target chunk size)

        foreach ($field in $candidateFields) {
            $hasField = @($reqs | Where-Object { $_.$field }).Count
            if ($hasField -lt ($reqs.Count * 0.5)) { continue }

            $testGroups = @{}
            foreach ($req in $reqs) {
                $key = if ($req.$field) { $req.$field.ToString() } else { "unknown" }
                if (-not $testGroups.ContainsKey($key)) { $testGroups[$key] = 0 }
                $testGroups[$key]++
            }

            $groupCount = $testGroups.Count
            if ($groupCount -lt 2 -or $groupCount -gt ($reqs.Count / 2)) { continue }

            $targetSize = [math]::Min($MaxChunkSize, [math]::Ceiling($reqs.Count / [math]::Max(3, $groupCount)))
            $score = 0
            foreach ($count in $testGroups.Values) {
                $score += [math]::Abs($count - $targetSize)
            }

            if ($score -lt $bestScore) {
                $bestScore = $score
                $bestField = $field
            }
        }

        $groupField = if ($bestField) { $bestField } else { $null }
    }
    elseif ($Strategy -match "^field:(.+)$") {
        $groupField = $Matches[1]
    }

    if ($groupField) {
        foreach ($req in $reqs) {
            $key = if ($req.$groupField) { $req.$groupField.ToString() } else { "unknown" }
            if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
            $groups[$key] += $req
        }
    }
    else {
        $Strategy = "id-range"
    }

    $chunks = @()

    if ($Strategy -eq "id-range") {
        for ($i = 0; $i -lt $reqs.Count; $i += $MaxChunkSize) {
            $end = [math]::Min($i + $MaxChunkSize - 1, $reqs.Count - 1)
            $slice = @($reqs[$i..$end])
            $chunks += @{
                Name = "block-$([math]::Floor($i / $MaxChunkSize) + 1)"
                Requirements = $slice
                FileHints = @($slice | Where-Object { $_.notes } | ForEach-Object { $_.notes })
            }
        }
        return $chunks
    }

    $pendingSmall = @()
    $pendingNames = @()

    foreach ($key in ($groups.Keys | Sort-Object)) {
        $groupReqs = @($groups[$key])

        if ($groupReqs.Count -gt $MaxChunkSize) {
            for ($i = 0; $i -lt $groupReqs.Count; $i += $MaxChunkSize) {
                $end = [math]::Min($i + $MaxChunkSize - 1, $groupReqs.Count - 1)
                $slice = @($groupReqs[$i..$end])
                $subIdx = [math]::Floor($i / $MaxChunkSize) + 1
                $chunks += @{
                    Name = "$key-$subIdx"
                    Requirements = $slice
                    FileHints = @($slice | Where-Object { $_.notes } | ForEach-Object { $_.notes })
                }
            }
        }
        elseif ($groupReqs.Count -lt $MinGroupSize) {
            $pendingSmall += $groupReqs
            $pendingNames += $key
            if ($pendingSmall.Count -ge [math]::Floor($MaxChunkSize * 0.6)) {
                $chunks += @{
                    Name = ($pendingNames -join "+")
                    Requirements = @($pendingSmall)
                    FileHints = @($pendingSmall | Where-Object { $_.notes } | ForEach-Object { $_.notes })
                }
                $pendingSmall = @()
                $pendingNames = @()
            }
        }
        else {
            $chunks += @{
                Name = $key
                Requirements = $groupReqs
                FileHints = @($groupReqs | Where-Object { $_.notes } | ForEach-Object { $_.notes })
            }
        }
    }

    if ($pendingSmall.Count -gt 0) {
        $chunks += @{
            Name = ($pendingNames -join "+")
            Requirements = @($pendingSmall)
            FileHints = @($pendingSmall | Where-Object { $_.notes } | ForEach-Object { $_.notes })
        }
    }

    return $chunks
}

function Build-ChunkContext {
    <#
    .SYNOPSIS
        Builds focused context for one chunk -- only that chunk's requirements + file hints.
    #>
    param(
        [hashtable]$Chunk,
        [int]$ChunkIndex,
        [int]$TotalChunks,
        [double]$Health,
        [int]$Iteration,
        [string]$Pipeline,
        [string]$CouncilType,
        [string]$GsdDir,
        [string]$GroupField = ""
    )

    $context = @()
    $context += "# Council Chunk Review: $($Chunk.Name) [$($ChunkIndex + 1)/$TotalChunks]"
    $context += "- Health: ${Health}% | Iteration: $Iteration | Pipeline: $Pipeline"
    $context += "- Chunk: $($Chunk.Name) | Requirements: $($Chunk.Requirements.Count)"
    if ($GroupField) { $context += "- Grouped by: $GroupField" }
    $context += ""

    $chunkReqs = $Chunk.Requirements | ForEach-Object {
        $r = @{ id = $_.id; status = $_.status; description = $_.description }
        if ($_.priority) { $r.priority = $_.priority }
        if ($_.pattern) { $r.pattern = $_.pattern }
        if ($_.notes) { $r.notes = $_.notes }
        if ($_.spec_doc) { $r.spec_doc = $_.spec_doc }
        $r
    }
    $context += "## Requirements in This Chunk"
    $context += '```json'
    $context += ($chunkReqs | ConvertTo-Json -Depth 3 -Compress)
    $context += '```'
    $context += ""

    if ($Chunk.FileHints -and $Chunk.FileHints.Count -gt 0) {
        $context += "## Relevant Files"
        foreach ($hint in ($Chunk.FileHints | Select-Object -Unique)) {
            $context += "- $hint"
        }
        $context += ""
    }

    $driftPath = Join-Path $GsdDir "health\drift-report.md"
    if (Test-Path $driftPath) {
        $driftRaw = (Get-Content $driftPath -Raw).Trim()
        if ($driftRaw.Length -gt 1000) { $driftRaw = $driftRaw.Substring(0, 1000) + "`n... (truncated)" }
        $context += "## Drift Report"
        $context += $driftRaw
        $context += ""
    }

    return ($context -join "`n")
}

function Invoke-LlmCouncil {
    <#
    .SYNOPSIS
        Multi-agent council review: 2 agents (Codex + Gemini) review independently,
        Claude synthesizes a consensus verdict on project readiness.
    .PARAMETER CouncilType
        convergence (default) - 2-agent review at 100% health (Codex + Gemini)
        post-research   - 2-agent check after research phase (Codex + Gemini validate findings)
        pre-execute     - 2-agent check before execute phase (Codex + Gemini validate plan)
        post-blueprint  - 2-agent review after blueprint manifest generated (Codex + Gemini)
        stall-diagnosis - 2-agent parallel stall diagnosis (Codex + Gemini)
        post-spec-fix   - 2-agent check after spec conflict resolution (Codex + Gemini validate fix)
    .RETURNS
        @{ Approved = bool; Findings = @{...}; Report = string }
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [int]$Iteration = 0,
        [double]$Health = 0,
        [string]$Pipeline = "converge",
        [ValidateSet("convergence","post-research","pre-execute","post-blueprint","stall-diagnosis","post-spec-fix")]
        [string]$CouncilType = "convergence"
    )

    $councilDir = Join-Path $GsdDir "health"
    $reviewDir = Join-Path $GsdDir "code-review"
    $logDir = Join-Path $GsdDir "logs"
    $supervisorDir = Join-Path $GsdDir "supervisor"
    foreach ($d in @($councilDir, $reviewDir, $logDir, $supervisorDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $globalDir = Join-Path $env:USERPROFILE ".gsd-global"
    $promptDir = Join-Path $globalDir "prompts\council"

    Write-Host "  [SCALES] Building council context..." -ForegroundColor DarkGray

    # â”€â”€ 1. BUILD SHARED CONTEXT â”€â”€
    $context = @()
    $context += "# LLM Council Review Context ($CouncilType)"
    $context += "- Health: ${Health}% | Iteration: $Iteration | Pipeline: $Pipeline | Type: $CouncilType"
    $context += ""

    # Requirements matrix
    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    if (Test-Path $matrixPath) {
        $matrixRaw = Get-Content $matrixPath -Raw
        if ($matrixRaw.Length -gt 3000) { $matrixRaw = $matrixRaw.Substring(0, 3000) + "`n... (truncated)" }
        $context += "## Requirements Matrix"
        $context += '```json'
        $context += $matrixRaw
        $context += '```'
        $context += ""
    }

    # Code review findings
    $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
    if (Test-Path $reviewPath) {
        $reviewRaw = (Get-Content $reviewPath -Raw).Trim()
        if ($reviewRaw.Length -gt 2000) { $reviewRaw = $reviewRaw.Substring(0, 2000) + "`n... (truncated)" }
        $context += "## Latest Code Review"
        $context += $reviewRaw
        $context += ""
    }

    # Drift report
    $driftPath = Join-Path $GsdDir "health\drift-report.md"
    if (Test-Path $driftPath) {
        $driftRaw = (Get-Content $driftPath -Raw).Trim()
        if ($driftRaw.Length -gt 1000) { $driftRaw = $driftRaw.Substring(0, 1000) + "`n... (truncated)" }
        $context += "## Drift Report"
        $context += $driftRaw
        $context += ""
    }

    # File tree
    $treePath = Join-Path $GsdDir "file-map-tree.md"
    if (Test-Path $treePath) {
        $treeRaw = (Get-Content $treePath -Raw).Trim()
        if ($treeRaw.Length -gt 2000) { $treeRaw = $treeRaw.Substring(0, 2000) + "`n... (truncated)" }
        $context += "## File Structure"
        $context += $treeRaw
        $context += ""
    }

    # Health history (last 5 entries)
    $histPath = Join-Path $GsdDir "health\health-history.jsonl"
    if (Test-Path $histPath) {
        $histLines = Get-Content $histPath -Tail 5
        $context += "## Recent Health History"
        $context += '```'
        $context += ($histLines -join "`n")
        $context += '```'
        $context += ""
    }

    $sharedContext = $context -join "`n"

    # â”€â”€ 2. PARALLEL AGENT REVIEWS (Codex + Gemini only, Claude synthesizes) â”€â”€
    # Select agents and templates based on council type
    switch ($CouncilType) {
        "post-research" {
            $agents = @(
                @{ Name = "codex";  Template = "post-research-codex.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "post-research-gemini.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-post-research"
        }
        "pre-execute" {
            $agents = @(
                @{ Name = "codex";  Template = "pre-execute-codex.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "pre-execute-gemini.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-pre-execute"
        }
        "post-blueprint" {
            $agents = @(
                @{ Name = "codex";  Template = "post-blueprint-codex.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "post-blueprint-gemini.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-post-blueprint"
        }
        "stall-diagnosis" {
            $agents = @(
                @{ Name = "codex";  Template = "stall-codex.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "stall-gemini.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-stall-diagnosis"
        }
        "post-spec-fix" {
            $agents = @(
                @{ Name = "codex";  Template = "post-spec-fix-codex.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "post-spec-fix-gemini.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-post-spec-fix"
        }
        default {
            # "convergence" -- 2-agent review (codex + gemini), claude synthesizes
            $agents = @(
                @{ Name = "codex";  Template = "codex-review.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "gemini-review.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-review"
        }
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ MULTI-MODEL: Dynamic reviewer pool expansion from agent-map.json Ã¢â€â‚¬Ã¢â€â‚¬
    if ($CouncilType -in @("convergence", "post-research", "pre-execute", "post-blueprint", "stall-diagnosis", "post-spec-fix")) {
        $agentMapPathMM = Join-Path $globalDir "config\agent-map.json"
        if (Test-Path $agentMapPathMM) {
            try {
                $amCfg = Get-Content $agentMapPathMM -Raw | ConvertFrom-Json
                if ($amCfg.council -and $amCfg.council.reviewers) {
                    $alreadyInPool = @($agents | ForEach-Object { $_.Name })
                    foreach ($reviewerName in @($amCfg.council.reviewers)) {
                        if ($alreadyInPool -contains $reviewerName) { continue }
                        if (-not (Test-IsOpenAICompatAgent -AgentName $reviewerName)) { continue }

                        # Use agent-specific template if exists, otherwise generic
                        $specificTpl = "$reviewerName-review.md"
                        $genericTpl  = "openai-compat-review.md"
                        $tplToUse = if (Test-Path (Join-Path $promptDir $specificTpl)) { $specificTpl } else { $genericTpl }

                        $agents += @{
                            Name         = $reviewerName
                            Template     = $tplToUse
                            Mode         = ""
                            AllowedTools = ""
                        }
                    }
                }
            } catch { }
        }
    }

    # â”€â”€ CHUNKING DECISION â”€â”€
    $useChunking = $false
    $chunkingCfg = $null
    $groupFieldUsed = ""

    if ($CouncilType -eq "convergence") {
        $agentMapPath = Join-Path $globalDir "config\agent-map.json"
        if (Test-Path $agentMapPath) {
            try {
                $agentMapCfg = Get-Content $agentMapPath -Raw | ConvertFrom-Json
                $chunkingCfg = $agentMapCfg.council.chunking
            } catch { }
        }

        if ($chunkingCfg -and $chunkingCfg.enabled) {
            $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
            if (Test-Path $matrixPath) {
                $matrixCheck = Get-Content $matrixPath -Raw | ConvertFrom-Json
                $reqCount = @($matrixCheck.requirements).Count
                $minToChunk = if ($chunkingCfg.min_requirements_to_chunk) { [int]$chunkingCfg.min_requirements_to_chunk } else { 30 }
                if ($reqCount -ge $minToChunk) {
                    $useChunking = $true
                }
            }
        }
    }

    if ($useChunking) {
        # â”€â”€ CHUNKED CONVERGENCE PATH â”€â”€
        $maxChunk = if ($chunkingCfg.max_chunk_size) { [int]$chunkingCfg.max_chunk_size } else { 25 }
        $minGroup = if ($chunkingCfg.min_group_size) { [int]$chunkingCfg.min_group_size } else { 5 }
        $chunkStrategy = if ($chunkingCfg.strategy) { $chunkingCfg.strategy } else { "auto" }
        $cooldownSec = if ($chunkingCfg.cooldown_seconds) { [int]$chunkingCfg.cooldown_seconds } else { 5 }

        $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
        $chunks = Build-RequirementChunks -MatrixPath $matrixPath -MaxChunkSize $maxChunk -MinGroupSize $minGroup -Strategy $chunkStrategy

        Write-Host "  [SCALES] Chunked review: $($chunks.Count) chunks from $reqCount requirements (strategy: $chunkStrategy)" -ForegroundColor Cyan

        $allChunkVerdicts = @()
        $totalChunkSuccesses = 0

        for ($ci = 0; $ci -lt $chunks.Count; $ci++) {
            $chunk = $chunks[$ci]
            Write-Host "  [SCALES] Chunk $($ci + 1)/$($chunks.Count): $($chunk.Name) ($($chunk.Requirements.Count) reqs)..." -ForegroundColor DarkGray

            $chunkContext = Build-ChunkContext -Chunk $chunk -ChunkIndex $ci -TotalChunks $chunks.Count `
                -Health $Health -Iteration $Iteration -Pipeline $Pipeline -CouncilType $CouncilType `
                -GsdDir $GsdDir -GroupField $groupFieldUsed

            $chunkReviews = @{}

            foreach ($agent in $agents) {
                $templatePath = Join-Path $promptDir $agent.Template
                if (-not (Test-Path $templatePath)) {
                    Write-Host "    [WARN] Missing template: $templatePath -- skipping $($agent.Name)" -ForegroundColor DarkYellow
                    $chunkReviews[$agent.Name] = @{ Success = $false; Output = "Template not found" }
                    continue
                }

                $prompt = (Get-Content $templatePath -Raw)
                $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration").Replace("{{HEALTH}}", "$Health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot)
                $prompt += "`n`n$chunkContext"

                Write-Host "    $($agent.Name.ToUpper()) reviewing chunk $($chunk.Name)..." -ForegroundColor DarkGray

                $chunkPhase = "council-review-chunk$($ci + 1)"
                $retryParams = @{
                    Agent          = $agent.Name
                    Prompt         = $prompt
                    Phase          = $chunkPhase
                    LogFile        = "$logDir\council-convergence-$($agent.Name)-chunk$($ci + 1).log"
                    MaxAttempts    = 2
                    CurrentBatchSize = 1
                    GsdDir         = $GsdDir
                }
                if ($agent.AllowedTools) { $retryParams["AllowedTools"] = $agent.AllowedTools }
                if ($agent.Mode) { $retryParams["GeminiMode"] = $agent.Mode }

                $result = Invoke-WithRetry @retryParams
                $chunkReviews[$agent.Name] = $result

                if ($result.Success) {
                    Write-Host "    $($agent.Name.ToUpper()) chunk $($chunk.Name) complete" -ForegroundColor DarkGreen
                } else {
                    Write-Host "    $($agent.Name.ToUpper()) chunk $($chunk.Name) failed: $($result.Error)" -ForegroundColor DarkYellow
                }
            }

            # Collect chunk verdict from logs
            $chunkVerdict = @{ ChunkName = $chunk.Name; ReqCount = $chunk.Requirements.Count; AgentResults = @{} }
            $chunkHasSuccess = $false
            foreach ($agent in $agents) {
                $chunkLog = "$logDir\council-convergence-$($agent.Name)-chunk$($ci + 1).log"
                if ((Test-Path $chunkLog) -and $chunkReviews[$agent.Name].Success) {
                    $logContent = Get-Content $chunkLog -Raw -ErrorAction SilentlyContinue
                    if ($logContent -and $logContent.Length -gt 2000) {
                        $logContent = $logContent.Substring(0, 2000) + "`n... (truncated)"
                    }
                    $chunkVerdict.AgentResults[$agent.Name] = $logContent
                    $chunkHasSuccess = $true
                }
            }
            if ($chunkHasSuccess) { $totalChunkSuccesses++ }
            $allChunkVerdicts += $chunkVerdict

            # Cooldown between chunks (not after last)
            if ($ci -lt ($chunks.Count - 1) -and $cooldownSec -gt 0) {
                Start-Sleep -Seconds $cooldownSec
            }
        }

        # Quorum check on chunks
        if ($totalChunkSuccesses -lt 1) {
            Write-Host "  [SCALES] All chunk reviews failed -- auto-approving (no quorum)" -ForegroundColor DarkYellow
            $fallbackResult = @{
                Approved = $true
                Findings = @{
                    approved   = $true
                    confidence = 50
                    votes      = @{}
                    concerns   = @("Council quorum not met (0/$($chunks.Count) chunks had successful reviews)")
                    strengths  = @()
                    reason     = "Auto-approved: no chunk reviews succeeded"
                }
                Report = ""
            }
            $fallbackResult.Findings | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $councilDir "council-review.json") -Encoding UTF8
            return $fallbackResult
        }

        # â”€â”€ CHUNKED SYNTHESIS â”€â”€
        Write-Host "  [SCALES] Synthesizing $($chunks.Count) chunk verdicts..." -ForegroundColor DarkGray

        $synthesisPrompt = ""
        $synthTemplatePath = Join-Path $promptDir "synthesize-chunked.md"
        if (Test-Path $synthTemplatePath) {
            $synthesisPrompt = (Get-Content $synthTemplatePath -Raw)
            $synthesisPrompt = $synthesisPrompt.Replace("{{ITERATION}}", "$Iteration").Replace("{{HEALTH}}", "$Health").Replace("{{GSD_DIR}}", $GsdDir)
            $synthesisPrompt = $synthesisPrompt.Replace("{{CHUNK_COUNT}}", "$($chunks.Count)").Replace("{{TOTAL_REQS}}", "$reqCount")
        } else {
            $synthesisPrompt = "You are the synthesis judge. Read all chunk review verdicts below. Produce a JSON verdict."
        }

        # Append all chunk verdicts
        foreach ($cv in $allChunkVerdicts) {
            $synthesisPrompt += "`n`n## Chunk: $($cv.ChunkName) ($($cv.ReqCount) requirements)"
            foreach ($agentName in $cv.AgentResults.Keys) {
                $synthesisPrompt += "`n### $($agentName.ToUpper())`n$($cv.AgentResults[$agentName])"
            }
        }

        $synthResult = Invoke-WithRetry -Agent "claude" -Prompt $synthesisPrompt -Phase "council-synthesize" `
            -LogFile "$logDir\council-convergence-synthesis.log" -MaxAttempts 2 -CurrentBatchSize 1 -GsdDir $GsdDir `
            -AllowedTools "Read"

    } else {
        # â”€â”€ MONOLITHIC PATH (non-convergence or chunking disabled) â”€â”€
        Write-Host "  [SCALES] Dispatching $($agents.Count) independent reviews ($CouncilType)..." -ForegroundColor DarkGray

        $reviews = @{}

        foreach ($agent in $agents) {
            $templatePath = Join-Path $promptDir $agent.Template
            if (-not (Test-Path $templatePath)) {
                Write-Host "    [WARN] Missing template: $templatePath -- skipping $($agent.Name)" -ForegroundColor DarkYellow
                $reviews[$agent.Name] = @{ Success = $false; Output = "Template not found" }
                continue
            }

            $prompt = (Get-Content $templatePath -Raw)
            $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration").Replace("{{HEALTH}}", "$Health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot)
            $prompt += "`n`n$sharedContext"

            Write-Host "    $($agent.Name.ToUpper()) reviewing..." -ForegroundColor DarkGray

            $retryParams = @{
                Agent          = $agent.Name
                Prompt         = $prompt
                Phase          = $phaseName
                LogFile        = "$logDir\council-$CouncilType-$($agent.Name).log"
                MaxAttempts    = 2
                CurrentBatchSize = 1
                GsdDir         = $GsdDir
            }
            if ($agent.AllowedTools) { $retryParams["AllowedTools"] = $agent.AllowedTools }
            if ($agent.Mode) { $retryParams["GeminiMode"] = $agent.Mode }

            $result = Invoke-WithRetry @retryParams
            $reviews[$agent.Name] = $result

            if ($result.Success) {
                Write-Host "    $($agent.Name.ToUpper()) review complete" -ForegroundColor DarkGreen
            } else {
                Write-Host "    $($agent.Name.ToUpper()) review failed: $($result.Error)" -ForegroundColor DarkYellow
            }
        }

        # Count successful reviews
        $successCount = ($reviews.Values | Where-Object { $_.Success }).Count
        if ($successCount -lt 1) {
            Write-Host "  [SCALES] All reviews failed -- auto-approving (no quorum)" -ForegroundColor DarkYellow
            $fallbackResult = @{
                Approved = $true
                Findings = @{
                    approved   = $true
                    confidence = 50
                    votes      = @{}
                    concerns   = @("Council quorum not met ($successCount/2 reviewers responded)")
                    strengths  = @()
                    reason     = "Auto-approved: insufficient council quorum"
                }
                Report = ""
            }
            $fallbackResult.Findings | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $councilDir "council-review.json") -Encoding UTF8
            return $fallbackResult
        }

        # â”€â”€ 3. SYNTHESIS (Claude reads all reviews) â”€â”€
        Write-Host "  [SCALES] Synthesizing council verdict..." -ForegroundColor DarkGray

        $synthesisPrompt = ""
        $synthTemplatePath = Join-Path $promptDir "synthesize.md"
        if (Test-Path $synthTemplatePath) {
            $synthesisPrompt = (Get-Content $synthTemplatePath -Raw)
            $synthesisPrompt = $synthesisPrompt.Replace("{{ITERATION}}", "$Iteration").Replace("{{HEALTH}}", "$Health").Replace("{{GSD_DIR}}", $GsdDir)
        } else {
            $synthesisPrompt = "You are the synthesis judge. Read all reviews below. Produce a JSON verdict."
        }

        # Append each agent's review log
        foreach ($agentEntry in $agents) {
            $agentName = $agentEntry.Name
            $logPath = "$logDir\council-$CouncilType-$agentName.log"
            if (Test-Path $logPath) {
                $logContent = (Get-Content $logPath -Raw -ErrorAction SilentlyContinue)
                if ($logContent -and $logContent.Length -gt 3000) { $logContent = $logContent.Substring(0, 3000) + "`n... (truncated)" }
                if ($logContent) {
                    $synthesisPrompt += "`n`n## $($agentName.ToUpper()) Review`n$logContent"
                }
            }
        }

        $synthResult = Invoke-WithRetry -Agent "claude" -Prompt $synthesisPrompt -Phase "council-synthesize" `
            -LogFile "$logDir\council-$CouncilType-synthesis.log" -MaxAttempts 2 -CurrentBatchSize 1 -GsdDir $GsdDir `
            -AllowedTools "Read"
    }

    # â”€â”€ 4. PARSE VERDICT & WRITE OUTPUTS â”€â”€
    $approved = $true
    $findings = @{
        approved   = $true
        confidence = 75
        votes      = @{
            claude = "unknown"
            codex  = "unknown"
            gemini = "unknown"
        }
        concerns   = @()
        strengths  = @()
        reason     = ""
    }

    if ($synthResult.Success) {
        $synthLog = "$logDir\council-$CouncilType-synthesis.log"
        if (Test-Path $synthLog) {
            $synthContent = Get-Content $synthLog -Raw -ErrorAction SilentlyContinue
            # Try to extract JSON from output
            if ($synthContent -match '\{[\s\S]*"approved"\s*:[\s\S]*\}') {
                try {
                    $parsed = $Matches[0] | ConvertFrom-Json
                    if ($null -ne $parsed.approved) { $findings.approved = $parsed.approved; $approved = [bool]$parsed.approved }
                    if ($parsed.confidence) { $findings.confidence = $parsed.confidence }
                    if ($parsed.votes) { $findings.votes = $parsed.votes }
                    if ($parsed.concerns) { $findings.concerns = @($parsed.concerns) }
                    if ($parsed.strengths) { $findings.strengths = @($parsed.strengths) }
                    if ($parsed.reason) { $findings.reason = $parsed.reason }
                } catch {
                    Write-Host "    [WARN] Could not parse synthesis JSON -- defaulting to approved" -ForegroundColor DarkYellow
                }
            }

            # Check for explicit block keywords even if JSON parsing fails
            if ($synthContent -match '"vote"\s*:\s*"block"' -or $synthContent -match '"approved"\s*:\s*false') {
                $approved = $false
                $findings.approved = $false
            }
        }
    } else {
        Write-Host "  [SCALES] Synthesis failed -- auto-approving" -ForegroundColor DarkYellow
        $findings.reason = "Synthesis agent failed; auto-approved"
    }

    # Write council-review.json
    $findings | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $councilDir "council-review.json") -Encoding UTF8

    # Write council-findings.md (readable report)
    $report = @()
    $report += "# LLM Council Review ($CouncilType) -- Iteration $Iteration"
    $report += ""
    $report += "| Field | Value |"
    $report += "|-------|-------|"
    $report += "| Verdict | $(if ($approved) { 'APPROVED' } else { 'BLOCKED' }) |"
    $report += "| Confidence | $($findings.confidence)% |"
    $report += "| Health | ${Health}% |"
    $report += "| Timestamp | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |"
    $report += ""

    if ($findings.votes) {
        $report += "## Agent Votes"
        $report += ""
        $report += "| Agent | Vote |"
        $report += "|-------|------|"
        if ($findings.votes -is [hashtable]) {
            foreach ($k in $findings.votes.Keys) { $report += "| $k | $($findings.votes[$k]) |" }
        } elseif ($findings.votes.PSObject) {
            $findings.votes.PSObject.Properties | ForEach-Object { $report += "| $($_.Name) | $($_.Value) |" }
        }
        $report += ""
    }

    if ($findings.strengths -and $findings.strengths.Count -gt 0) {
        $report += "## Strengths"
        foreach ($s in $findings.strengths) { $report += "- $s" }
        $report += ""
    }

    if ($findings.concerns -and $findings.concerns.Count -gt 0) {
        $report += "## Concerns"
        foreach ($c in $findings.concerns) { $report += "- $c" }
        $report += ""
    }

    if ($findings.reason) {
        $report += "## Reasoning"
        $report += $findings.reason
        $report += ""
    }

    $reportPath = Join-Path $reviewDir "council-findings.md"
    ($report -join "`n") | Set-Content $reportPath -Encoding UTF8

    # If blocked, write council feedback for next iteration's prompts
    if (-not $approved) {
        $feedback = @()
        $feedback += "## LLM Council Feedback (DO NOT IGNORE)"
        $feedback += ""
        $feedback += "The LLM Council reviewed the codebase and BLOCKED convergence."
        $feedback += "You MUST address these concerns before the project can be approved:"
        $feedback += ""
        foreach ($c in $findings.concerns) { $feedback += "- $c" }
        $feedback += ""
        $feedback += "Fix these issues in this iteration. The council will re-review."

        $feedbackPath = Join-Path $supervisorDir "council-feedback.md"
        ($feedback -join "`n") | Set-Content $feedbackPath -Encoding UTF8
        Write-Host "  [SCALES] Council feedback written to supervisor/council-feedback.md" -ForegroundColor DarkYellow
    } else {
        # Clear any previous council feedback
        $feedbackPath = Join-Path $supervisorDir "council-feedback.md"
        if (Test-Path $feedbackPath) { Remove-Item $feedbackPath -ErrorAction SilentlyContinue }
    }

    Write-Host "  [SCALES] Council verdict: $(if ($approved) { 'APPROVED' } else { 'BLOCKED' }) (confidence: $($findings.confidence)%)" -ForegroundColor $(if ($approved) { 'Green' } else { 'Yellow' })

    return @{
        Approved = $approved
        Findings = $findings
        Report   = $reportPath
    }
}

Write-Host "  LLM Council module loaded." -ForegroundColor DarkGray


# ===============================================================
# SPEC CONSISTENCY CHECK - catches contradictions before iterating
# ===============================================================

function Invoke-SpecConsistencyCheck {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [array]$Interfaces,
        [switch]$DryRun
    )

    Write-Host "  [CLIP] Spec consistency pre-check..." -ForegroundColor Cyan

    $specSources = @()
    $docsPath = Join-Path $RepoRoot "docs"
    if (Test-Path $docsPath) { $specSources += "docs\ (SDLC Phase A-E)" }

    foreach ($iface in $Interfaces) {
        if ($iface.HasAnalysis) {
            $specSources += "$($iface.VersionPath)\_analysis\ ($($iface.Label) - $($iface.AnalysisFileCount) deliverables)"
        }
    }

    if ($specSources.Count -eq 0) {
        Write-Host "    [!!]  No spec sources found. Skipping." -ForegroundColor DarkYellow
        return @{ Passed = $true; Conflicts = @(); Warnings = @() }
    }

    $sourceList = ($specSources | ForEach-Object { "- $_" }) -join "`n"

    $prompt = @"
You are a SPEC AUDITOR. Fast consistency check across all specification documents.
Runs BEFORE code generation - catch conflicts that would waste iterations.

## Spec Sources
$sourceList

## Check For
1. Data type conflicts: Same entity defined differently across docs
2. API contract conflicts: Same endpoint with different signatures
3. Navigation conflicts: Same route mapped to different screens
4. Business rule conflicts: Contradictory requirements
5. Design system conflicts: Different values for same token across interfaces
6. Database conflicts: Same table defined with different columns
7. Missing cross-refs: endpoint in hooks but not in API contracts

## Output
Write to: $GsdDir\spec-consistency-report.json
{
  "status": "pass|conflicts_found|warnings_only",
  "conflicts": [
    {
      "severity": "critical|warning",
      "type": "data_type|api_contract|navigation|business_rule|design_system|database|missing_ref",
      "description": "What conflicts",
      "source_a": "File A, section",
      "source_b": "File B, section",
      "recommendation": "How to resolve"
    }
  ],
  "summary": { "total_conflicts": N, "critical": N, "warnings": N, "specs_checked": N }
}

Also write: $GsdDir\spec-consistency-report.md

Rules: Be FAST. Only flag REAL conflicts. Under 2000 tokens output.
"@

    if ($DryRun) {
        Write-Host "    [DRY RUN] claude -> spec check" -ForegroundColor DarkYellow
        return @{ Passed = $true; Conflicts = @(); Warnings = @() }
    }

    $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "spec-consistency" `
        -LogFile "$GsdDir\logs\spec-consistency.log" -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2

    if (-not $result.Success) {
        Write-Host "    [!!]  Spec check failed - proceeding anyway" -ForegroundColor DarkYellow
        return @{ Passed = $true; Conflicts = @(); Warnings = @() }
    }

    $reportFile = Join-Path $GsdDir "spec-consistency-report.json"
    if (Test-Path $reportFile) {
        try {
            $report = Get-Content $reportFile -Raw | ConvertFrom-Json
            $criticals = @($report.conflicts | Where-Object { $_.severity -eq "critical" })
            $warnings = @($report.conflicts | Where-Object { $_.severity -eq "warning" })

            if ($criticals.Count -gt 0) {
                Write-Host "    [XX] $($criticals.Count) CRITICAL conflicts:" -ForegroundColor Red
                foreach ($c in $criticals) {
                    Write-Host "      - [$($c.type)] $($c.description)" -ForegroundColor Red
                }

                # Always write conflicts to file for review or auto-resolution
                $conflictsDir = Join-Path $GsdDir "spec-conflicts"
                if (-not (Test-Path $conflictsDir)) { New-Item -ItemType Directory -Path $conflictsDir -Force | Out-Null }
                @{
                    generated_at = (Get-Date -Format "o")
                    total_critical = $criticals.Count
                    total_warnings = $warnings.Count
                    conflicts = @($criticals) + @($warnings | Where-Object { $_ })
                } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $conflictsDir "conflicts-to-resolve.json") -Encoding UTF8
                Write-Host "    [>>]  Written to: .gsd\spec-conflicts\conflicts-to-resolve.json" -ForegroundColor DarkGray

                Write-Host "    [BLOCK] Fix these in your specs or use -AutoResolve to auto-fix." -ForegroundColor Red
                return @{ Passed = $false; Conflicts = $criticals; Warnings = $warnings }
            }

            if ($warnings.Count -gt 0) {
                Write-Host "    [!!]  $($warnings.Count) warnings (non-blocking)" -ForegroundColor DarkYellow
            }

            Write-Host "    [OK] Spec consistency passed" -ForegroundColor Green
            return @{ Passed = $true; Conflicts = @(); Warnings = $warnings }
        } catch {
            Write-Host "    [!!]  Could not parse report - proceeding" -ForegroundColor DarkYellow
        }
    }

    return @{ Passed = $true; Conflicts = @(); Warnings = @() }
}


# ===============================================================
# SQLCMD SYNTAX VALIDATION - uses sqlcmd parse-only when available
# ===============================================================

function Test-SqlSyntaxWithSqlcmd {
    param([string]$SqlFilePath, [string]$GsdDir)

    if (-not $script:HasSqlCmd) { return @{ Passed = $true; Error = $null } }
    if (-not (Test-Path $SqlFilePath)) { return @{ Passed = $true; Error = $null } }

    try {
        $output = sqlcmd -S "(localdb)\PARSE_CHECK" -i $SqlFilePath -b 2>&1
        $syntaxErrors = $output | Where-Object {
            $_ -match "(Incorrect syntax|Unexpected|Invalid column|Must declare|Unclosed)" -and
            $_ -notmatch "(Login failed|network-related|server was not found)"
        }
        if ($syntaxErrors.Count -gt 0) {
            return @{ Passed = $false; Error = ($syntaxErrors | Select-Object -First 3) -join "; " }
        }
        return @{ Passed = $true; Error = $null }
    } catch {
        return @{ Passed = $true; Error = $null }
    }
}

# ===============================================================
# ENHANCED Test-SqlFiles - pattern checks + sqlcmd when available
# ===============================================================

# Save original if it exists and hasn't been saved yet
if ((Get-Command Test-SqlFiles -ErrorAction SilentlyContinue) -and -not $script:SqlFilesV3) {
    $script:SqlFilesV3 = $true

    function Test-SqlFiles {
        param([string]$RepoRoot, [string]$GsdDir, [int]$Iteration)

        $sqlFiles = git -C $RepoRoot diff --name-only HEAD 2>$null | Where-Object { $_ -match "\.sql$" }
        if (-not $sqlFiles -or $sqlFiles.Count -eq 0) { return @{ Passed = $true; Errors = @() } }

        Write-Host "    [SEARCH] Checking $($sqlFiles.Count) SQL files..." -ForegroundColor DarkGray
        $sqlErrors = @()

        foreach ($sqlFile in $sqlFiles) {
            $fullPath = Join-Path $RepoRoot $sqlFile
            if (-not (Test-Path $fullPath)) { continue }
            $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            # Pattern checks
            if ($content -match "string\.Format|`"\s*\+\s*.*SELECT|\$`".*SELECT") {
                $sqlErrors += "$sqlFile : String concatenation in SQL"
            }
            if ($content -match "CREATE\s+(OR\s+ALTER\s+)?PROC" -and $content -notmatch "BEGIN\s+TRY") {
                $sqlErrors += "$sqlFile : Missing TRY/CATCH in stored procedure"
            }
            if ($content -match "CREATE\s+TABLE" -and $content -notmatch "CreatedAt") {
                $sqlErrors += "$sqlFile : Missing audit columns in CREATE TABLE"
            }

            # sqlcmd syntax validation
            if ($script:HasSqlCmd) {
                $syntaxResult = Test-SqlSyntaxWithSqlcmd -SqlFilePath $fullPath -GsdDir $GsdDir
                if (-not $syntaxResult.Passed) {
                    $sqlErrors += "$sqlFile : Syntax error: $($syntaxResult.Error)"
                }
            }
        }

        if ($sqlErrors.Count -gt 0) {
            Write-Host "    [!!]  $($sqlErrors.Count) SQL issues:" -ForegroundColor DarkYellow
            $sqlErrors | Select-Object -First 5 | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow }
        } else {
            Write-Host "    [OK] SQL OK$(if ($script:HasSqlCmd) { ' (sqlcmd verified)' })" -ForegroundColor DarkGreen
        }

        return @{ Passed = ($sqlErrors.Count -eq 0); Errors = $sqlErrors }
    }
}

# ===============================================================
# CLI VERSION COMPATIBILITY CHECK
# ===============================================================

$script:TESTED_CLAUDE_MAJORS = @(1, 2)
$script:TESTED_CODEX_MAJORS = @(0, 1)
$script:TESTED_DOTNET_MAJOR = 8

function Test-CliVersionCompat {
    param([string]$Tool, [string]$VersionOutput, [int[]]$TestedMajors)

    $versionMatch = [regex]::Match($VersionOutput, '(\d+)\.(\d+)')
    if (-not $versionMatch.Success) {
        return @{ Compatible = $true; Version = "unknown"; Warning = $null }
    }

    $major = [int]$versionMatch.Groups[1].Value
    $version = $versionMatch.Value

    if ($major -notin $TestedMajors) {
        return @{
            Compatible = $true
            Version = $version
            Warning = "$Tool v$version detected - scripts tested with major versions: $($TestedMajors -join ', '). May need flag updates."
        }
    }

    return @{ Compatible = $true; Version = $version; Warning = $null }
}

# Enhance Test-CliVersions to use version compat
if ((Get-Command Test-CliVersions -ErrorAction SilentlyContinue) -and -not $script:CliVersionsV2) {
    $script:CliVersionsV2 = $true

    function Test-CliVersions {
        param([string]$GsdDir)
        Write-Host "    Checking CLI versions..." -ForegroundColor DarkGray

        try {
            $claudeVer = (claude --version 2>&1) -join " "
            $compat = Test-CliVersionCompat -Tool "claude" -VersionOutput $claudeVer -TestedMajors $script:TESTED_CLAUDE_MAJORS
            Write-Host "    [OK] claude: $($compat.Version)" -ForegroundColor DarkGreen
            if ($compat.Warning) { Write-Host "    [!!]  $($compat.Warning)" -ForegroundColor DarkYellow }
        } catch { Write-Host "    [XX] claude CLI not found" -ForegroundColor Red; return $false }

        try {
            $codexVer = (codex --version 2>&1) -join " "
            $compat = Test-CliVersionCompat -Tool "codex" -VersionOutput $codexVer -TestedMajors $script:TESTED_CODEX_MAJORS
            Write-Host "    [OK] codex: $($compat.Version)" -ForegroundColor DarkGreen
            if ($compat.Warning) { Write-Host "    [!!]  $($compat.Warning)" -ForegroundColor DarkYellow }
        } catch { Write-Host "    [XX] codex CLI not found" -ForegroundColor Red; return $false }

        try {
            $dotnetVer = (dotnet --version 2>&1) -join " "
            $compat = Test-CliVersionCompat -Tool "dotnet" -VersionOutput $dotnetVer -TestedMajors @($script:TESTED_DOTNET_MAJOR)
            Write-Host "    [OK] dotnet: $($compat.Version)" -ForegroundColor DarkGreen
            if ($compat.Warning) { Write-Host "    [!!]  $($compat.Warning)" -ForegroundColor DarkYellow }
        } catch { Write-Host "    [!!]  dotnet not found" -ForegroundColor DarkYellow }

        try {
            $nodeVer = (node --version 2>&1) -join " "
            $npmVer = (npm --version 2>&1) -join " "
            Write-Host "    [OK] node: $nodeVer / npm: $npmVer" -ForegroundColor DarkGreen
        } catch { Write-Host "    [!!]  node/npm not found" -ForegroundColor DarkYellow }

        try {
            $null = sqlcmd -? 2>&1
            Write-Host "    [OK] sqlcmd: available" -ForegroundColor DarkGreen
            $script:HasSqlCmd = $true
        } catch {
            Write-Host "    [>>]  sqlcmd not found (SQL linting pattern-only)" -ForegroundColor DarkGray
            $script:HasSqlCmd = $false
        }

        return $true
    }
}


# ===============================================================
# SPEC CONFLICT AUTO-RESOLUTION - Gemini resolves contradictions
# (saves Claude/Codex quota for code generation)
# ===============================================================

function Invoke-SpecConflictResolution {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [array]$Interfaces,
        [array]$Conflicts,
        [array]$Warnings,
        [int]$MaxResolveAttempts = 2,
        [switch]$DryRun
    )

    $totalConflicts = $Conflicts.Count
    Write-Host "  [WRENCH] Auto-resolving $totalConflicts spec conflict(s) via Gemini..." -ForegroundColor Cyan

    # Create spec-conflicts directory
    $conflictsDir = Join-Path $GsdDir "spec-conflicts"
    if (-not (Test-Path $conflictsDir)) {
        New-Item -ItemType Directory -Path $conflictsDir -Force | Out-Null
    }

    # Build interface source paths for prompt
    $ifaceSources = ""
    foreach ($iface in $Interfaces) {
        if ($iface.HasAnalysis) {
            $ifaceSources += "5. $($iface.VersionPath)\_analysis\ - $($iface.Label) deliverables`n"
        }
    }

    # Load prompt template
    $promptTemplatePath = Join-Path $env:USERPROFILE ".gsd-global\prompts\gemini\resolve-spec-conflicts.md"
    if (-not (Test-Path $promptTemplatePath)) {
        Write-Host "    [XX] Prompt template not found: $promptTemplatePath" -ForegroundColor Red
        return @{ Resolved = $false; Attempts = 0 }
    }
    $promptTemplate = Get-Content $promptTemplatePath -Raw

    # Resolution loop
    for ($attempt = 1; $attempt -le $MaxResolveAttempts; $attempt++) {
        Write-Host "    Attempt $attempt/$MaxResolveAttempts (batch: $($Conflicts.Count))..." -ForegroundColor DarkCyan

        # Write conflicts-to-resolve.json for this attempt
        $conflictsFile = Join-Path $conflictsDir "conflicts-to-resolve.json"
        $resolvePayload = @{
            generated_at = (Get-Date -Format "o")
            resolve_attempt = $attempt
            total_critical = $Conflicts.Count
            total_warnings = if ($Warnings) { $Warnings.Count } else { 0 }
            conflicts = @($Conflicts) + @($Warnings | Where-Object { $_ })
        } | ConvertTo-Json -Depth 5
        Set-Content -Path $conflictsFile -Value $resolvePayload -Encoding UTF8

        # Resolve prompt template variables
        $prompt = $promptTemplate.Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{ATTEMPT}}", "$attempt").Replace("{{MAX_ATTEMPTS}}", "$MaxResolveAttempts").Replace("{{INTERFACE_SOURCES}}", $ifaceSources)

        if ($DryRun) {
            Write-Host "    [DRY RUN] codex -> resolve-spec-conflicts" -ForegroundColor DarkYellow
            return @{ Resolved = $false; Attempts = $attempt }
        }

        # Spawn Gemini agent via Invoke-WithRetry (saves Claude/Codex quota)
        $result = Invoke-WithRetry -Agent "gemini" -Prompt $prompt -Phase "spec-conflict-resolution" `
            -LogFile "$GsdDir\logs\spec-conflict-resolution.log" `
            -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2 `
            -GeminiMode "--yolo"

        if (-not $result.Success) {
            Write-Host "    [!!]  Resolution agent failed" -ForegroundColor DarkYellow
            if (Get-Command Write-GsdError -ErrorAction SilentlyContinue) {
                Write-GsdError -GsdDir $GsdDir -Category "agent_crash" -Phase "spec-conflict-resolution" `
                    -Iteration $attempt -Message "Gemini spec resolution failed" -Resolution "Manual fix required"
            }
            return @{ Resolved = $false; Attempts = $attempt }
        }

        # Re-run spec consistency check to verify resolution
        Write-Host "    Re-checking spec consistency..." -ForegroundColor Cyan
        $recheck = Invoke-SpecConsistencyCheck -RepoRoot $RepoRoot -GsdDir $GsdDir `
            -Interfaces $Interfaces

        if ($recheck.Passed) {
            Write-Host "    [OK] All conflicts resolved after $attempt attempt(s)!" -ForegroundColor Green

            # Ã¢â€â‚¬Ã¢â€â‚¬ POST-SPEC-FIX COUNCIL Ã¢â€â‚¬Ã¢â€â‚¬
            # Validate Gemini's spec resolution via multi-agent review before declaring success
            if (Get-Command Invoke-LlmCouncil -ErrorAction SilentlyContinue) {
                Write-Host "    [SCALES] Post-spec-fix council review..." -ForegroundColor DarkCyan
                $councilResult = Invoke-LlmCouncil -RepoRoot $RepoRoot -GsdDir $GsdDir `
                    -Iteration $attempt -Health 0 -Pipeline "spec-fix" -CouncilType "post-spec-fix"
                if (-not $councilResult.Approved) {
                    $concernCount = if ($councilResult.Findings.concerns) { $councilResult.Findings.concerns.Count } else { 0 }
                    Write-Host "    [SCALES] Council found $concernCount concern(s) in spec resolution" -ForegroundColor Yellow
                    # If council blocks, treat as unresolved so next attempt picks up feedback
                    if ($attempt -lt $MaxResolveAttempts) {
                        Write-Host "    Retrying with council feedback..." -ForegroundColor DarkYellow
                        $Conflicts = @()  # Re-check will find any remaining issues
                        continue
                    }
                } else {
                    Write-Host "    [SCALES] Council approved spec resolution" -ForegroundColor Green
                }
            }

            return @{ Resolved = $true; Attempts = $attempt }
        }

        # Still have criticals - update for next attempt
        if ($attempt -lt $MaxResolveAttempts) {
            $remaining = $recheck.Conflicts.Count
            Write-Host "    [!!]  $remaining conflict(s) remain. Retrying..." -ForegroundColor DarkYellow
            $Conflicts = $recheck.Conflicts
            $Warnings = $recheck.Warnings
        }
    }

    # Exhausted all attempts
    Write-Host "    [XX] Could not auto-resolve all conflicts after $MaxResolveAttempts attempt(s)" -ForegroundColor Red
    Write-Host "    See: $conflictsDir\resolution-summary.md" -ForegroundColor Yellow
    Write-Host "    See: $conflictsDir\conflicts-to-resolve.json" -ForegroundColor Yellow
    return @{ Resolved = $false; Attempts = $MaxResolveAttempts }
}


# ===============================================================
# GSD RESILIENCE HARDENING -- appended to resilience.ps1
# Token Tracking, Auth Detection, Quota Recovery
# ===============================================================

function New-EstimatedTokenData {
    <#
    .SYNOPSIS
        Creates an estimated token data object when the agent didn't return usage info.
        Estimates cost from prompt length (assumes prompt was sent and billed).
        Used when Extract-TokensFromOutput returns $null (agent returned error text, not JSON).
    #>
    param(
        [string]$Agent,
        [string]$PromptText,
        [string]$ErrorType = "unknown"
    )

    # Rough estimate: 1 token ~ 4 chars
    $estimatedInputTokens = [math]::Max(100, [math]::Floor($PromptText.Length / 4))
    $estimatedOutputTokens = 50  # Minimum: error response

    $pricing = Get-TokenPrice -Agent $Agent
    $estimatedCost = ($estimatedInputTokens / 1000000.0) * $pricing.InputPerM +
                     ($estimatedOutputTokens / 1000000.0) * $pricing.OutputPerM

    return @{
        Tokens   = @{ input = $estimatedInputTokens; output = $estimatedOutputTokens; cached = 0 }
        CostUsd  = [math]::Round($estimatedCost, 6)
        TextOutput = "[ESTIMATED] $ErrorType - no token data returned by agent"
        DurationMs = 0
        NumTurns   = 0
        Estimated  = $true
    }
}

function Get-NextAvailableAgent {
    <#
    .SYNOPSIS
        Returns the next agent from the pool that hasn't recently been quota-exhausted.
        Uses a cooldown file to track which agents are in quota backoff.
    #>
    param(
        [string]$CurrentAgent,
        [string]$GsdDir
    )

    # Agent pool -- read from model-registry.json, fall back to legacy 3-agent list
    $pool = @("claude", "codex", "gemini")  # legacy fallback
    $regPath = Join-Path $env:USERPROFILE ".gsd-global\config\model-registry.json"
    if (Test-Path $regPath) {
        try {
            $reg = Get-Content $regPath -Raw | ConvertFrom-Json
            if ($reg.rotation_pool_default) {
                # Only include agents whose API keys are set (REST) or CLIs exist (CLI)
                $validPool = @()
                foreach ($agentName in $reg.rotation_pool_default) {
                    $agentCfg = $reg.agents.$agentName
                    if (-not $agentCfg) { continue }
                    if ($agentCfg.type -eq "cli") {
                        $validPool += $agentName
                    } elseif ($agentCfg.type -eq "openai-compat" -and $agentCfg.enabled -ne $false) {
                        $keyVal = [System.Environment]::GetEnvironmentVariable($agentCfg.api_key_env)
                        if (-not $keyVal) { $keyVal = [System.Environment]::GetEnvironmentVariable($agentCfg.api_key_env, 'User') }
                        if (-not $keyVal) { $keyVal = [System.Environment]::GetEnvironmentVariable($agentCfg.api_key_env, 'Machine') }
                        if ($keyVal) { $validPool += $agentName }
                    }
                }
                if ($validPool.Count -ge 2) { $pool = $validPool }
            }
        } catch { }
    }

    # Read cooldown state
    $cooldownPath = Join-Path $GsdDir "supervisor\agent-cooldowns.json"
    $cooldowns = @{}
    if (Test-Path $cooldownPath) {
        try {
            $raw = Get-Content $cooldownPath -Raw | ConvertFrom-Json
            foreach ($prop in $raw.PSObject.Properties) {
                $cooldowns[$prop.Name] = [datetime]$prop.Value
            }
        } catch { }
    }

    $now = Get-Date

    foreach ($agent in $pool) {
        if ($agent -eq $CurrentAgent) { continue }

        # Check if this agent is still in cooldown
        if ($cooldowns.ContainsKey($agent)) {
            $cooldownUntil = $cooldowns[$agent]
            if ($now -lt $cooldownUntil) {
                continue  # Still cooling down
            }
        }

        # This agent is available
        return $agent
    }

    return $null  # All agents exhausted
}

function Set-AgentCooldown {
    <#
    .SYNOPSIS
        Marks an agent as in cooldown for a specified duration.
        Writes to .gsd/supervisor/agent-cooldowns.json.
    #>
    param(
        [string]$Agent,
        [string]$GsdDir,
        [int]$CooldownMinutes = 30
    )

    $supervisorDir = Join-Path $GsdDir "supervisor"
    if (-not (Test-Path $supervisorDir)) {
        New-Item -ItemType Directory -Path $supervisorDir -Force | Out-Null
    }

    $cooldownPath = Join-Path $supervisorDir "agent-cooldowns.json"
    $cooldowns = @{}
    if (Test-Path $cooldownPath) {
        try {
            $raw = Get-Content $cooldownPath -Raw | ConvertFrom-Json
            foreach ($prop in $raw.PSObject.Properties) {
                $cooldowns[$prop.Name] = $prop.Value
            }
        } catch { }
    }

    $cooldowns[$Agent] = (Get-Date).AddMinutes($CooldownMinutes).ToString("o")

    $cooldowns | ConvertTo-Json -Depth 2 | Set-Content $cooldownPath -Encoding UTF8
}

# ===============================================================
# QUALITY GATES -- Database Completeness, Security Compliance, Spec Validation
# Added by patch-gsd-quality-gates.ps1 (Script 20)
# ===============================================================

function Test-DatabaseCompleteness {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [switch]$Detailed
    )

    Write-Host "    [DB] Checking database completeness..." -ForegroundColor DarkGray

    $configPath = Join-Path $env:USERPROFILE ".gsd-global\config\global-config.json"
    $qgEnabled = $true; $requireSeed = $true; $minCoverage = 90
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.quality_gates -and $cfg.quality_gates.database_completeness) {
                $qg = $cfg.quality_gates.database_completeness
                if ($null -ne $qg.enabled) { $qgEnabled = $qg.enabled }
                if ($null -ne $qg.require_seed_data) { $requireSeed = $qg.require_seed_data }
                if ($null -ne $qg.min_coverage_pct) { $minCoverage = $qg.min_coverage_pct }
            }
        } catch { }
    }

    if (-not $qgEnabled) {
        Write-Host "    [>>]  Database completeness check disabled" -ForegroundColor DarkGray
        return @{ Passed = $true; Coverage = @{}; Issues = @(); Skipped = $true }
    }

    $issues = @()
    $apiEndpoints = @()

    # Discover from 11-api-to-sp-map.md
    $spMapFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "11-api-to-sp-map.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($spMapFiles) {
        $mapContent = Get-Content $spMapFiles.FullName -Raw -ErrorAction SilentlyContinue
        $tableRows = [regex]::Matches($mapContent, '\|\s*\S+.*?\|\s*(GET|POST|PUT|DELETE|PATCH)\s*\|\s*(/\S+)\s*\|\s*(\S+)\s*\|\s*(usp_\S+|MISSING|-)\s*\|\s*(\S.*?)\s*\|\s*(\S.*?)\s*\|')
        foreach ($row in $tableRows) {
            $apiEndpoints += @{ Method = $row.Groups[1].Value; Route = $row.Groups[2].Value; StoredProc = $row.Groups[4].Value.Trim() }
        }
    }

    # Fallback: scan .cs files
    if ($apiEndpoints.Count -eq 0) {
        $csFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.cs" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "(bin|obj|node_modules|\.git)" }
        foreach ($cs in $csFiles) {
            $content = Get-Content $cs.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            $httpMatches = [regex]::Matches($content, '\[(Http(Get|Post|Put|Delete|Patch))\s*\("([^"]*?)"\)\]')
            foreach ($m in $httpMatches) {
                $apiEndpoints += @{ Method = $m.Groups[2].Value.ToUpper(); Route = $m.Groups[3].Value; StoredProc = "" }
            }
        }
    }

    # Discover SPs, tables, seed data from .sql files
    $spDefined = @(); $tablesDefined = @(); $tablesWithSeed = @()
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.sql" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "(bin|obj|node_modules|\.git)" }
    foreach ($sql in $sqlFiles) {
        $content = Get-Content $sql.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        foreach ($m in [regex]::Matches($content, 'CREATE\s+(OR\s+ALTER\s+)?PROC(?:EDURE)?\s+\[?dbo\]?\.\[?(usp_\w+|sp_\w+|\w+)\]?', 'IgnoreCase')) { $spDefined += $m.Groups[2].Value }
        foreach ($m in [regex]::Matches($content, 'CREATE\s+TABLE\s+\[?dbo\]?\.\[?(\w+)\]?', 'IgnoreCase')) { $tablesDefined += $m.Groups[1].Value }
        foreach ($m in [regex]::Matches($content, 'INSERT\s+INTO\s+\[?dbo\]?\.\[?(\w+)\]?', 'IgnoreCase')) { if ($m.Groups[1].Value -notin $tablesWithSeed) { $tablesWithSeed += $m.Groups[1].Value } }
        foreach ($m in [regex]::Matches($content, 'MERGE\s+\[?dbo\]?\.\[?(\w+)\]?', 'IgnoreCase')) { if ($m.Groups[1].Value -notin $tablesWithSeed) { $tablesWithSeed += $m.Groups[1].Value } }
    }

    # Cross-reference
    $apiToSpCovered = 0; $missingStoredProcs = @()
    foreach ($ep in $apiEndpoints) {
        $sp = $ep.StoredProc
        if ($sp -and $sp -ne "-" -and $sp -ne "MISSING") {
            if ($sp -in $spDefined -or $spDefined.Count -eq 0) { $apiToSpCovered++ } else { $missingStoredProcs += "$($ep.Method) $($ep.Route) -> $sp (not found)" }
        } elseif ($sp -eq "MISSING" -or -not $sp) { $missingStoredProcs += "$($ep.Method) $($ep.Route) -> NO SP mapped" }
        else { $apiToSpCovered++ }
    }

    $tablesWithSeedCount = 0; $missingSeedData = @()
    foreach ($tbl in $tablesDefined) { if ($tbl -in $tablesWithSeed) { $tablesWithSeedCount++ } else { $missingSeedData += $tbl } }

    $coverage = @{
        api_to_sp = @{ total = $apiEndpoints.Count; covered = $apiToSpCovered; missing = $missingStoredProcs; pct = if ($apiEndpoints.Count -gt 0) { [math]::Round(($apiToSpCovered / $apiEndpoints.Count) * 100, 1) } else { 100 } }
        tables_defined = $tablesDefined.Count; sps_defined = $spDefined.Count
        tables_to_seed = @{ total = $tablesDefined.Count; covered = $tablesWithSeedCount; missing = $missingSeedData; pct = if ($tablesDefined.Count -gt 0) { [math]::Round(($tablesWithSeedCount / $tablesDefined.Count) * 100, 1) } else { 100 } }
    }

    if ($missingStoredProcs.Count -gt 0) { $issues += "$($missingStoredProcs.Count) API endpoint(s) missing stored procedures" }
    if ($requireSeed -and $missingSeedData.Count -gt 0) { $issues += "$($missingSeedData.Count) table(s) missing seed data: $($missingSeedData -join ', ')" }

    $overallPct = 100
    $vals = @()
    if ($apiEndpoints.Count -gt 0) { $vals += $coverage.api_to_sp.pct }
    if ($tablesDefined.Count -gt 0) { $vals += $coverage.tables_to_seed.pct }
    if ($vals.Count -gt 0) { $overallPct = [math]::Round(($vals | Measure-Object -Average).Average, 1) }

    $passed = $issues.Count -eq 0 -or $overallPct -ge $minCoverage
    $assessDir = Join-Path $GsdDir "assessment"
    if (-not (Test-Path $assessDir)) { New-Item -Path $assessDir -ItemType Directory -Force | Out-Null }
    @{ timestamp = (Get-Date).ToString("o"); coverage = $coverage; overall_pct = $overallPct; passed = $passed; issues = $issues } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $assessDir "db-completeness.json") -Encoding UTF8

    if ($passed) { Write-Host "    [OK] Database completeness: ${overallPct}% ($($spDefined.Count) SPs, $($tablesDefined.Count) tables, $tablesWithSeedCount seeded)" -ForegroundColor DarkGreen }
    else { Write-Host "    [!!]  Database completeness: ${overallPct}% - $($issues.Count) issue(s)" -ForegroundColor DarkYellow; $issues | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow } }

    return @{ Passed = $passed; Coverage = $coverage; OverallPct = $overallPct; Issues = $issues; MissingStoredProcs = $missingStoredProcs; MissingSeedData = $missingSeedData }
}

function Test-SecurityCompliance {
    param([string]$RepoRoot, [string]$GsdDir, [switch]$Detailed)

    Write-Host "    [LOCK] Checking security compliance..." -ForegroundColor DarkGray

    $configPath = Join-Path $env:USERPROFILE ".gsd-global\config\global-config.json"
    $qgEnabled = $true; $blockOnCritical = $true
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.quality_gates -and $cfg.quality_gates.security_compliance) {
                $qg = $cfg.quality_gates.security_compliance
                if ($null -ne $qg.enabled) { $qgEnabled = $qg.enabled }
                if ($null -ne $qg.block_on_critical) { $blockOnCritical = $qg.block_on_critical }
            }
        } catch { }
    }
    if (-not $qgEnabled) { Write-Host "    [>>]  Security compliance check disabled" -ForegroundColor DarkGray; return @{ Passed = $true; Violations = @(); ViolationCount = 0; Skipped = $true } }

    $violations = @()
    $patterns = @(
        @{ Regex = 'string\.Format\s*\(.*?(SELECT|INSERT|UPDATE|DELETE)|"\s*\+\s*.*?(SELECT|INSERT|UPDATE|DELETE)|\$".*?(SELECT|INSERT|UPDATE|DELETE)'; Severity = "Critical"; Desc = "SQL injection via string concatenation"; Filter = ".cs" }
        @{ Regex = 'dangerouslySetInnerHTML'; Severity = "Critical"; Desc = "XSS: dangerouslySetInnerHTML"; Filter = ".tsx,.jsx" }
        @{ Regex = '\beval\s*\('; Severity = "Critical"; Desc = "Code injection: eval()"; Filter = ".ts,.tsx,.js,.jsx" }
        @{ Regex = 'new\s+Function\s*\('; Severity = "Critical"; Desc = "Code injection: new Function()"; Filter = ".ts,.tsx,.js,.jsx" }
        @{ Regex = 'localStorage\.(setItem|getItem).*?(token|password|secret|jwt|ssn)'; Severity = "Critical"; Desc = "Secrets in localStorage"; Filter = ".ts,.tsx,.js,.jsx" }
        @{ Regex = 'BinaryFormatter'; Severity = "Critical"; Desc = "Deserialization CVE: BinaryFormatter"; Filter = ".cs" }
        @{ Regex = '(password|secret|apikey|connectionstring)\s*=\s*"[^{][^"]{4,}"'; Severity = "Critical"; Desc = "Hardcoded secret"; Filter = ".cs,.json" }
        @{ Regex = 'console\.(log|error|warn).*?(password|token|ssn|creditcard|secret)'; Severity = "High"; Desc = "Sensitive data in console log"; Filter = ".ts,.tsx,.js,.jsx" }
        @{ Regex = 'sp_executesql.*\+'; Severity = "Critical"; Desc = "Dynamic SQL with concatenation"; Filter = ".sql" }
    )

    $allFiles = Get-ChildItem -Path $RepoRoot -Recurse -Include "*.cs","*.ts","*.tsx","*.js","*.jsx","*.sql","*.json" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "(bin|obj|node_modules|\.git|\.gsd|dist|build|package-lock)" }
    foreach ($pattern in $patterns) {
        $filterExts = $pattern.Filter -split ","
        foreach ($file in ($allFiles | Where-Object { $_.Extension -in $filterExts })) {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }
            foreach ($m in [regex]::Matches($content, $pattern.Regex, 'IgnoreCase')) {
                if ($pattern.Desc -match "dangerouslySetInnerHTML" -and $content -match "DOMPurify") { continue }
                if ($pattern.Desc -match "Hardcoded secret" -and $file.Name -match "appsettings\.Development") { continue }
                $relPath = $file.FullName.Replace($RepoRoot, "").TrimStart("\", "/")
                $lineNum = ($content.Substring(0, $m.Index) -split "`n").Count
                $violations += @{ Severity = $pattern.Severity; Description = $pattern.Desc; File = $relPath; Line = $lineNum; Match = $m.Value.Substring(0, [Math]::Min($m.Value.Length, 80)) }
            }
        }
    }

    # Check missing [Authorize] on controllers
    foreach ($ctrl in ($allFiles | Where-Object { $_.Name -match "Controller\.cs$" })) {
        $content = Get-Content $ctrl.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match "\[ApiController\]" -and $content -notmatch "\[Authorize") {
            $violations += @{ Severity = "High"; Description = "Controller missing [Authorize]"; File = $ctrl.FullName.Replace($RepoRoot, "").TrimStart("\", "/"); Line = 1; Match = $ctrl.Name }
        }
    }

    # Check CREATE TABLE missing audit columns
    foreach ($sql in ($allFiles | Where-Object { $_.Extension -eq ".sql" })) {
        $content = Get-Content $sql.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match "CREATE\s+TABLE" -and $content -notmatch "CreatedAt") {
            $violations += @{ Severity = "Medium"; Description = "Missing audit columns in CREATE TABLE"; File = $sql.FullName.Replace($RepoRoot, "").TrimStart("\", "/"); Line = 1; Match = "CREATE TABLE without CreatedAt" }
        }
    }

    $assessDir = Join-Path $GsdDir "assessment"
    if (-not (Test-Path $assessDir)) { New-Item -Path $assessDir -ItemType Directory -Force | Out-Null }
    $criticals = @($violations | Where-Object { $_.Severity -eq "Critical" })
    $highs = @($violations | Where-Object { $_.Severity -eq "High" })
    $mediums = @($violations | Where-Object { $_.Severity -eq "Medium" })
    $passed = -not ($blockOnCritical -and $criticals.Count -gt 0)
    @{ timestamp = (Get-Date).ToString("o"); passed = $passed; violation_count = $violations.Count; by_severity = @{ critical = $criticals.Count; high = $highs.Count; medium = $mediums.Count }; violations = $violations } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $assessDir "security-compliance.json") -Encoding UTF8

    if ($violations.Count -eq 0) { Write-Host "    [OK] Security compliance: 0 violations" -ForegroundColor DarkGreen }
    else {
        $color = if ($criticals.Count -gt 0) { "Red" } elseif ($highs.Count -gt 0) { "DarkYellow" } else { "DarkGray" }
        Write-Host "    [!!]  Security: $($criticals.Count) critical, $($highs.Count) high, $($mediums.Count) medium" -ForegroundColor $color
        if ($Detailed) { $violations | Select-Object -First 10 | ForEach-Object { Write-Host "      [$($_.Severity)] $($_.File):$($_.Line) - $($_.Description)" -ForegroundColor $color } }
    }
    return @{ Passed = $passed; Violations = $violations; ViolationCount = $violations.Count; Criticals = $criticals.Count; Highs = $highs.Count; Mediums = $mediums.Count }
}

function Invoke-SpecQualityGate {
    param([string]$RepoRoot, [string]$GsdDir, [array]$Interfaces = @(), [switch]$DryRun, [int]$MinClarityScore = 70)

    Write-Host "    [SEARCH] Running spec quality gate..." -ForegroundColor DarkGray

    $configPath = Join-Path $env:USERPROFILE ".gsd-global\config\global-config.json"
    $qgEnabled = $true; $checkCrossArtifact = $true
    if (Test-Path $configPath) {
        try {
            $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($cfg.quality_gates -and $cfg.quality_gates.spec_quality) {
                $qg = $cfg.quality_gates.spec_quality
                if ($null -ne $qg.enabled) { $qgEnabled = $qg.enabled }
                if ($null -ne $qg.min_clarity_score) { $MinClarityScore = $qg.min_clarity_score }
                if ($null -ne $qg.check_cross_artifact) { $checkCrossArtifact = $qg.check_cross_artifact }
            }
        } catch { }
    }
    if (-not $qgEnabled) { Write-Host "    [>>]  Spec quality gate disabled" -ForegroundColor DarkGray; return @{ Passed = $true; ClarityScore = 100; ConsistencyPassed = $true; Issues = @(); Skipped = $true } }

    $issues = @(); $clarityScore = 100; $consistencyPassed = $true

    # Step 1: Existing consistency check
    if (Get-Command Invoke-SpecConsistencyCheck -ErrorAction SilentlyContinue) {
        try {
            $specResult = Invoke-SpecConsistencyCheck -RepoRoot $RepoRoot -GsdDir $GsdDir -Interfaces $Interfaces
            if (-not $specResult.Passed) { $issues += "Spec consistency check found conflicts"; $consistencyPassed = $false }
        } catch { Write-Host "    [!!]  Spec consistency check error: $_" -ForegroundColor DarkYellow }
    }

    # Step 2: Clarity check via Claude
    if (-not $DryRun) {
        $clarityPrompt = Join-Path $env:USERPROFILE ".gsd-global\prompts\claude\spec-clarity-check.md"
        if (Test-Path $clarityPrompt) {
            try {
                $promptContent = (Get-Content $clarityPrompt -Raw).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{GSD_DIR}}", $GsdDir)
                $figmaPath = ""; $amPath = Join-Path $env:USERPROFILE ".gsd-global\config\agent-map.json"
                if (Test-Path $amPath) { try { $figmaPath = (Get-Content $amPath -Raw | ConvertFrom-Json).figma_path } catch { } }
                $promptContent = $promptContent.Replace("{{FIGMA_PATH}}", $figmaPath)
                $ifaceCtx = ""; foreach ($iface in $Interfaces) { $aDir = Join-Path $RepoRoot "$($iface.name)\_analysis"; if (Test-Path $aDir) { $ifaceCtx += "- $($iface.name): has _analysis/ dir`n" } }
                $promptContent = $promptContent.Replace("{{INTERFACE_ANALYSIS}}", $ifaceCtx)
                Write-Host "    [SEARCH] Running spec clarity check via Claude..." -ForegroundColor DarkGray
                $clarityResult = Invoke-WithRetry -Agent "claude" -Prompt $promptContent -Phase "spec-clarity-check" -RepoRoot $RepoRoot -GsdDir $GsdDir -MaxOutputTokens 4000
                if ($clarityResult.Success) {
                    $scoreMatch = [regex]::Match($clarityResult.Response, '"clarity_score"\s*:\s*(\d+)')
                    if ($scoreMatch.Success) { $clarityScore = [int]$scoreMatch.Groups[1].Value }
                    Write-Host "    [OK] Spec clarity score: $clarityScore" -ForegroundColor $(if ($clarityScore -ge 85) { "DarkGreen" } elseif ($clarityScore -ge 70) { "DarkYellow" } else { "Red" })
                }
            } catch { Write-Host "    [!!]  Spec clarity check error: $_" -ForegroundColor DarkYellow }
        }
    }

    # Step 3: Cross-artifact consistency
    if ($checkCrossArtifact -and -not $DryRun) {
        $hasAnalysis = $false
        foreach ($iface in $Interfaces) { if (Test-Path (Join-Path $RepoRoot "$($iface.name)\_analysis")) { $hasAnalysis = $true; break } }
        if (Test-Path (Join-Path $RepoRoot "_analysis")) { $hasAnalysis = $true }
        if ($hasAnalysis) {
            $cPrompt = Join-Path $env:USERPROFILE ".gsd-global\prompts\claude\cross-artifact-consistency.md"
            if (Test-Path $cPrompt) {
                try {
                    $promptContent = (Get-Content $cPrompt -Raw).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{GSD_DIR}}", $GsdDir)
                    $ifaceName = if ($Interfaces.Count -gt 0) { $Interfaces[0].name } else { "" }
                    $ifaceAnalysis = if ($ifaceName) { Join-Path $RepoRoot "$ifaceName\_analysis" } else { Join-Path $RepoRoot "_analysis" }
                    $promptContent = $promptContent.Replace("{{INTERFACE_NAME}}", $ifaceName).Replace("{{INTERFACE_ANALYSIS}}", $ifaceAnalysis)
                    Write-Host "    [SEARCH] Running cross-artifact consistency check..." -ForegroundColor DarkGray
                    $crossResult = Invoke-WithRetry -Agent "claude" -Prompt $promptContent -Phase "cross-artifact-check" -RepoRoot $RepoRoot -GsdDir $GsdDir -MaxOutputTokens 4000
                    if ($crossResult.Success) {
                        $cm = [regex]::Match($crossResult.Response, '"consistent"\s*:\s*(true|false)')
                        if ($cm.Success -and $cm.Groups[1].Value -eq "false") { $consistencyPassed = $false; $issues += "Cross-artifact consistency check found mismatches" }
                    }
                } catch { Write-Host "    [!!]  Cross-artifact check error: $_" -ForegroundColor DarkYellow }
            }
        }
    }

    $passed = $clarityScore -ge $MinClarityScore -and $consistencyPassed
    $assessDir = Join-Path $GsdDir "assessment"
    if (-not (Test-Path $assessDir)) { New-Item -Path $assessDir -ItemType Directory -Force | Out-Null }
    $verdict = if ($clarityScore -ge 90) { "PASS" } elseif ($clarityScore -ge 70) { "WARN" } else { "BLOCK" }
    @{ timestamp = (Get-Date).ToString("o"); passed = $passed; clarity_score = $clarityScore; min_clarity_score = $MinClarityScore; consistency_passed = $consistencyPassed; issues = $issues; verdict = $verdict } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $assessDir "spec-quality-gate.json") -Encoding UTF8

    if ($passed) { Write-Host "    [OK] Spec quality gate: $verdict (clarity=$clarityScore, consistency=$consistencyPassed)" -ForegroundColor DarkGreen }
    else { Write-Host "    [!!]  Spec quality gate: $verdict (clarity=$clarityScore, consistency=$consistencyPassed)" -ForegroundColor $(if ($clarityScore -lt 70) { "Red" } else { "DarkYellow" }); $issues | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow } }

    return @{ Passed = $passed; ClarityScore = $clarityScore; ConsistencyPassed = $consistencyPassed; Issues = $issues; Verdict = $verdict }
}

# ===============================================================
# GSD MULTI-MODEL -- OpenAI-Compatible REST API Adapter
# Appended by patch-gsd-multi-model.ps1
# ===============================================================

function Test-IsOpenAICompatAgent {
    <#
    .SYNOPSIS
        Checks if the given agent name is an enabled openai-compat agent in model-registry.json.
    #>
    param([string]$AgentName)

    $regPath = Join-Path $env:USERPROFILE ".gsd-global\config\model-registry.json"
    if (-not (Test-Path $regPath)) { return $false }
    try {
        $registry = Get-Content $regPath -Raw | ConvertFrom-Json
        $cfg = $registry.agents.$AgentName
        return ($null -ne $cfg -and $cfg.type -eq "openai-compat" -and $cfg.enabled -ne $false)
    } catch { return $false }
}

function Invoke-OpenAICompatibleAgent {
    <#
    .SYNOPSIS
        Calls an OpenAI-compatible chat completions API via REST.
        Returns a synthetic JSON envelope that Extract-TokensFromOutput can parse,
        or an error string matching the GSD error taxonomy (rate_limit:, unauthorized:, etc.)
    #>
    param(
        [string]$AgentName,
        [string]$Prompt,
        [int]$TimeoutSeconds = 600
    )

    # Load registry config
    $regPath = Join-Path $env:USERPROFILE ".gsd-global\config\model-registry.json"
    if (-not (Test-Path $regPath)) {
        return "error: model-registry.json not found at $regPath"
    }
    $registry = Get-Content $regPath -Raw | ConvertFrom-Json
    $cfg = $registry.agents.$AgentName
    if (-not $cfg -or $cfg.type -ne "openai-compat") {
        return "error: Agent '$AgentName' not found in model-registry.json or not openai-compat type"
    }

    # Check if agent is disabled in registry
    if ($cfg.enabled -eq $false) {
        $reason = if ($cfg.disabled_reason) { $cfg.disabled_reason } else { "disabled in model-registry.json" }
        return "connection_failed: Agent '$AgentName' is disabled - $reason"
    }

    # Resolve API key from environment (check Process, then User, then Machine store)
    $apiKey = [System.Environment]::GetEnvironmentVariable($cfg.api_key_env)
    if (-not $apiKey) {
        $apiKey = [System.Environment]::GetEnvironmentVariable($cfg.api_key_env, 'User')
        if (-not $apiKey) { $apiKey = [System.Environment]::GetEnvironmentVariable($cfg.api_key_env, 'Machine') }
        if ($apiKey) { [System.Environment]::SetEnvironmentVariable($cfg.api_key_env, $apiKey, 'Process') }
    }
    if (-not $apiKey) {
        return "unauthorized: $($cfg.api_key_env) environment variable not set"
    }

    # Enforce TLS 1.2+ (required by many API providers, especially Chinese endpoints)
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13

    # Build request body
    $requestBody = @{
        model       = $cfg.model_id
        messages    = @(
            @{ role = "user"; content = $Prompt }
        )
        max_tokens  = [int]$cfg.max_tokens
        temperature = [double]$cfg.temperature
    } | ConvertTo-Json -Depth 5 -Compress

    # Call REST API
    try {
        $headers = @{
            "Authorization" = "Bearer $apiKey"
            "Content-Type"  = "application/json"
        }

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-RestMethod -Uri $cfg.endpoint -Method POST `
            -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($requestBody)) `
            -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        $stopwatch.Stop()

        # Extract response content
        $textContent = ""
        if ($response.choices -and $response.choices.Count -gt 0) {
            $textContent = $response.choices[0].message.content
        }

        # Extract usage tokens
        $inputTokens = 0; $outputTokens = 0; $cachedTokens = 0
        if ($response.usage) {
            $inputTokens  = if ($response.usage.prompt_tokens)     { [int]$response.usage.prompt_tokens }     else { 0 }
            $outputTokens = if ($response.usage.completion_tokens) { [int]$response.usage.completion_tokens } else { 0 }
            $cachedTokens = if ($response.usage.cached_tokens)     { [int]$response.usage.cached_tokens }     else { 0 }
        }

        # Return synthetic JSON envelope for Extract-TokensFromOutput
        $envelope = @{
            type        = "openai-compat-result"
            agent       = $AgentName
            result      = $textContent
            usage       = @{
                input_tokens  = $inputTokens
                output_tokens = $outputTokens
                cached_tokens = $cachedTokens
            }
            duration_ms = [int]$stopwatch.ElapsedMilliseconds
        }
        return ($envelope | ConvertTo-Json -Depth 5 -Compress)

    } catch {
        $errMsg = $_.Exception.Message
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        }

        # Map HTTP status codes to GSD error taxonomy strings
        # These must match the regex patterns in Test-IsQuotaError and auth detection
        if ($statusCode -eq 429) {
            return "rate_limit: too many requests - $errMsg (HTTP 429)"
        } elseif ($statusCode -eq 402) {
            return "quota_exhausted: billing limit reached - $errMsg (HTTP 402)"
        } elseif ($statusCode -eq 401) {
            return "unauthorized: invalid API key - $errMsg (HTTP 401)"
        } elseif ($statusCode -eq 403) {
            # Could be auth or rate limit -- check message content
            if ($errMsg -match "(resource|exhausted|limit|capacity|quota)") {
                return "rate_limit: resource exhausted - $errMsg (HTTP 403)"
            } else {
                return "unauthorized: access denied - $errMsg (HTTP 403)"
            }
        } elseif ($statusCode -ge 500) {
            return "server_error: $errMsg (HTTP $statusCode)"
        } elseif ($errMsg -match "(Unable to connect|No such host|name.*(not|could not).*resolve|ConnectFailure|connection refused|actively refused|unreachable|SocketException|NameResolutionFailure)") {
            # Endpoint unreachable Ã¢â‚¬â€ fail fast, don't retry
            return "connection_failed: endpoint unreachable for $AgentName ($($cfg.endpoint)) - $errMsg"
        } else {
            return "error: $errMsg"
        }
    }
}


# ===========================================
# DIFFERENTIAL CODE REVIEW
# ===========================================

function Get-DifferentialContext {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [string]$RepoRoot
    )

    $result = @{
        UseDifferential = $false
        DiffContent     = ""
        ChangedFiles    = @()
        Reason          = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (-not (Test-Path $configPath)) {
        $result.Reason = "No global-config.json"
        return $result
    }

    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch {
        $result.Reason = "Failed to parse global-config.json"
        return $result
    }

    $diffCfg = $config.differential_review
    if (-not $diffCfg -or -not $diffCfg.enabled) {
        $result.Reason = "Differential review disabled in config"
        return $result
    }

    # Check cache
    $cacheDir = Join-Path $GsdDir "cache"
    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }
    $cachePath = Join-Path $cacheDir "reviewed-files.json"

    # Get last reviewed commit
    $lastCommit = $null
    if (Test-Path $cachePath) {
        try {
            $cache = Get-Content $cachePath -Raw | ConvertFrom-Json
            $lastCommit = $cache.last_reviewed_commit
            $lastIteration = [int]$cache.last_iteration

            # Check cache TTL
            $ttl = [int]$diffCfg.cache_ttl_iterations
            if ($ttl -gt 0 -and ($Iteration - $lastIteration) -ge $ttl) {
                $result.Reason = "Cache TTL expired (last: iter $lastIteration, current: iter $Iteration, TTL: $ttl)"
                return $result
            }
        } catch {
            $result.Reason = "Failed to parse reviewed-files cache"
            return $result
        }
    } else {
        $result.Reason = "No reviewed-files cache (first run)"
        return $result
    }

    if (-not $lastCommit) {
        $result.Reason = "No last_reviewed_commit in cache"
        return $result
    }

    # Verify commit still exists
    $commitExists = git rev-parse --verify "$lastCommit^{commit}" 2>$null
    if (-not $commitExists) {
        $result.Reason = "Last reviewed commit $lastCommit no longer exists"
        return $result
    }

    # Get changed files
    $changedFiles = @(git diff --name-only $lastCommit HEAD 2>$null)

    if ($changedFiles.Count -eq 0) {
        $result.Reason = "No files changed since last review"
        $result.UseDifferential = $true
        $result.ChangedFiles = @()
        return $result
    }

    # Filter out .gsd/ and non-source files
    $sourceFiles = $changedFiles | Where-Object {
        $_ -notlike ".gsd/*" -and
        $_ -notlike "node_modules/*" -and
        $_ -notlike "bin/*" -and
        $_ -notlike "obj/*" -and
        $_ -notlike ".git/*" -and
        $_ -notlike "dist/*" -and
        $_ -notlike "build/*"
    }

    # Check diff percentage
    $totalFiles = @(git ls-files 2>$null | Where-Object {
        $_ -notlike "node_modules/*" -and $_ -notlike "bin/*" -and
        $_ -notlike "obj/*" -and $_ -notlike ".git/*"
    })

    if ($totalFiles.Count -gt 0) {
        $diffPct = [math]::Round(($sourceFiles.Count / $totalFiles.Count) * 100, 1)
        $maxPct = [int]$diffCfg.max_diff_pct

        if ($diffPct -gt $maxPct) {
            $result.Reason = "Diff too large: $diffPct% > max $maxPct% ($($sourceFiles.Count)/$($totalFiles.Count) files)"
            return $result
        }
    }

    # Get actual diff content (truncated to 50KB to avoid token overflow)
    $diffOutput = git diff $lastCommit HEAD -- $sourceFiles 2>$null
    if ($diffOutput.Length -gt 51200) {
        $diffOutput = $diffOutput.Substring(0, 51200) + "`n... (diff truncated at 50KB)"
    }

    $result.UseDifferential = $true
    $result.DiffContent = $diffOutput
    $result.ChangedFiles = $sourceFiles
    $result.Reason = "Differential: $($sourceFiles.Count) files changed ($diffPct%)"

    return $result
}

function Save-ReviewedCommit {
    param(
        [string]$GsdDir,
        [int]$Iteration
    )

    $cacheDir = Join-Path $GsdDir "cache"
    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }

    $currentCommit = git rev-parse HEAD 2>$null
    if ($currentCommit) {
        $cache = @{
            last_reviewed_commit = $currentCommit
            last_iteration       = $Iteration
            timestamp            = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }
        $cachePath = Join-Path $cacheDir "reviewed-files.json"
        $cache | ConvertTo-Json -Depth 5 | Set-Content -Path $cachePath -Encoding UTF8
    }
}

# ===========================================
# PRE-EXECUTE COMPILE GATE
# ===========================================

function Invoke-PreExecuteGate {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [decimal]$Health,
        [string]$ExecuteAgent = "codex"
    )

    $result = @{
        Passed     = $true
        FixApplied = $false
        Errors     = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $gateCfg = $config.pre_execute_gate
            if (-not $gateCfg -or -not $gateCfg.enabled) {
                Write-Host "  [GATE] Pre-execute gate disabled" -ForegroundColor DarkGray
                return $result
            }
        } catch {
            return $result
        }
    } else {
        return $result
    }

    $maxAttempts = if ($gateCfg.max_fix_attempts) { [int]$gateCfg.max_fix_attempts } else { 2 }
    $includeTests = if ($gateCfg.include_tests) { $gateCfg.include_tests } else { $false }

    Write-Host "  [GATE] Running pre-execute compile gate..." -ForegroundColor Cyan

    for ($attempt = 1; $attempt -le ($maxAttempts + 1); $attempt++) {
        $errors = @()

        # Check for .sln (dotnet build)
        $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue
        if ($slnFiles) {
            $buildOutput = & dotnet build $slnFiles[0].FullName --no-restore 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $errors += "=== DOTNET BUILD ERRORS ===`n$buildOutput"
            }
        }

        # Check for package.json (npm build)
        $pkgJson = Join-Path $RepoRoot "package.json"
        if (Test-Path $pkgJson) {
            Push-Location $RepoRoot
            $npmOutput = & npm run build 2>&1 | Out-String
            Pop-Location
            if ($LASTEXITCODE -ne 0) {
                $errors += "=== NPM BUILD ERRORS ===`n$npmOutput"
            }
        }

        # Optional: run tests
        if ($includeTests) {
            if ($slnFiles) {
                $testOutput = & dotnet test $slnFiles[0].FullName --no-build 2>&1 | Out-String
                if ($LASTEXITCODE -ne 0) {
                    $errors += "=== DOTNET TEST ERRORS ===`n$testOutput"
                }
            }
            if (Test-Path $pkgJson) {
                Push-Location $RepoRoot
                $npmTestOutput = & npm test 2>&1 | Out-String
                Pop-Location
                if ($LASTEXITCODE -ne 0) {
                    $errors += "=== NPM TEST ERRORS ===`n$npmTestOutput"
                }
            }
        }

        if ($errors.Count -eq 0) {
            if ($attempt -gt 1) {
                Write-Host "  [GATE] Build passed after $($attempt - 1) fix attempt(s)" -ForegroundColor Green
                $result.FixApplied = $true
            } else {
                Write-Host "  [GATE] Build passed on first check" -ForegroundColor Green
            }
            $result.Passed = $true
            return $result
        }

        # Build failed
        $allErrors = $errors -join "`n`n"

        if ($attempt -le $maxAttempts) {
            Write-Host "  [GATE] Build failed (attempt $attempt/$maxAttempts) -- sending errors to $ExecuteAgent for fix" -ForegroundColor Yellow

            # Truncate errors to 8KB
            if ($allErrors.Length -gt 8192) {
                $allErrors = $allErrors.Substring(0, 8192) + "`n... (truncated)"
            }

            # Build fix prompt
            $fixTemplatePath = Join-Path $GlobalDir "prompts\codex\fix-compile-errors.md"
            if (Test-Path $fixTemplatePath) {
                $fixPrompt = Get-Content $fixTemplatePath -Raw
                $fixPrompt = $fixPrompt.Replace("{{ITERATION}}", "$Iteration")
                $fixPrompt = $fixPrompt.Replace("{{COMPILE_ERRORS}}", $allErrors)
            } else {
                $fixPrompt = "Fix these compile errors. Only fix what's broken, don't refactor:`n`n$allErrors"
            }

            # Call the executing agent to fix
            $fixResult = Invoke-WithRetry -Agent $ExecuteAgent -Prompt $fixPrompt `
                -Phase "fix-compile" -LogFile "$GsdDir\logs\iter${Iteration}-fix-${attempt}.log" `
                -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 1

            if (-not $fixResult.Success) {
                Write-Host "  [GATE] Fix attempt $attempt failed -- agent error" -ForegroundColor Red
            }
        } else {
            # Exhausted fix attempts -- fall through (commit broken code, handle in next iteration)
            Write-Host "  [GATE] Build still failing after $maxAttempts fix attempts -- committing as-is" -ForegroundColor Yellow
            $result.Passed = $false
            $result.Errors = $allErrors

            # Log to errors.jsonl
            if (Get-Command Write-GsdError -ErrorAction SilentlyContinue) {
                Write-GsdError -GsdDir $GsdDir -Category "pre_execute_gate_failed" `
                    -Phase "execute" -Iteration $Iteration -Message "Build failed after $maxAttempts fix attempts"
            }
        }
    }

    return $result
}

# ===========================================
# PER-REQUIREMENT ACCEPTANCE TESTS
# ===========================================

function Test-RequirementAcceptance {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [string]$RepoRoot,
        [int]$Iteration
    )

    $results = @{
        Total   = 0
        Passed  = 0
        Failed  = 0
        Skipped = 0
        Details = @()
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.acceptance_tests -or -not $config.acceptance_tests.enabled) {
                Write-Host "  [TEST] Acceptance tests disabled" -ForegroundColor DarkGray
                return $results
            }
        } catch { return $results }
    } else { return $results }

    $maxTime = if ($config.acceptance_tests.max_test_time_seconds) {
        [int]$config.acceptance_tests.max_test_time_seconds
    } else { 60 }

    # Load queue
    $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
    if (-not (Test-Path $queuePath)) {
        Write-Host "  [TEST] No queue-current.json -- skipping acceptance tests" -ForegroundColor DarkGray
        return $results
    }

    try {
        $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
        $batch = @($queue.batch)
    } catch {
        Write-Host "  [TEST] Failed to parse queue-current.json" -ForegroundColor Yellow
        return $results
    }

    Write-Host "  [TEST] Running acceptance tests for $($batch.Count) requirements..." -ForegroundColor Cyan

    foreach ($item in $batch) {
        $results.Total++
        $reqId = $item.req_id
        $test = $item.acceptance_test

        if (-not $test) {
            $results.Skipped++
            $results.Details += @{ req_id = $reqId; status = "skipped"; reason = "No acceptance_test defined" }
            continue
        }

        $testType = $test.type
        $passed = $false
        $reason = ""

        try {
            switch ($testType) {
                "file_exists" {
                    $allExist = $true
                    foreach ($p in $test.paths) {
                        $fullPath = Join-Path $RepoRoot $p
                        if (-not (Test-Path $fullPath)) {
                            $allExist = $false
                            $reason = "File not found: $p"
                            break
                        }
                    }
                    $passed = $allExist
                    if ($passed) { $reason = "All $($test.paths.Count) files exist" }
                }

                "pattern_match" {
                    $filePath = Join-Path $RepoRoot $test.file
                    if (-not (Test-Path $filePath)) {
                        $reason = "File not found: $($test.file)"
                    } else {
                        $content = Get-Content $filePath -Raw
                        $missingPatterns = @()
                        foreach ($pattern in $test.patterns) {
                            if ($content -notmatch [regex]::Escape($pattern)) {
                                $missingPatterns += $pattern
                            }
                        }
                        if ($missingPatterns.Count -eq 0) {
                            $passed = $true
                            $reason = "All $($test.patterns.Count) patterns found"
                        } else {
                            $reason = "Missing patterns: $($missingPatterns -join ', ')"
                        }
                    }
                }

                "build_check" {
                    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue
                    if ($slnFiles) {
                        $output = & dotnet build $slnFiles[0].FullName --no-restore 2>&1 | Out-String
                        $passed = ($LASTEXITCODE -eq 0)
                        $reason = if ($passed) { "Build succeeded" } else { "Build failed" }
                    } else {
                        $passed = $true
                        $reason = "No .sln found -- skipped"
                    }
                }

                "dotnet_test" {
                    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue
                    if ($slnFiles -and $test.filter) {
                        $output = & dotnet test $slnFiles[0].FullName --filter $test.filter --no-build 2>&1 | Out-String
                        $passed = ($LASTEXITCODE -eq 0)
                        $reason = if ($passed) { "Tests passed" } else { "Tests failed" }
                    } else {
                        $results.Skipped++; $results.Total--
                        continue
                    }
                }

                "npm_test" {
                    $pkgJson = Join-Path $RepoRoot "package.json"
                    if ((Test-Path $pkgJson) -and $test.filter) {
                        Push-Location $RepoRoot
                        $env:TEST_FILTER = $test.filter
                        $output = & npm test -- --testPathPattern="$($test.filter)" 2>&1 | Out-String
                        Pop-Location
                        $passed = ($LASTEXITCODE -eq 0)
                        $reason = if ($passed) { "Tests passed" } else { "Tests failed" }
                    } else {
                        $results.Skipped++; $results.Total--
                        continue
                    }
                }

                default {
                    $results.Skipped++
                    $results.Details += @{ req_id = $reqId; status = "skipped"; reason = "Unknown test type: $testType" }
                    continue
                }
            }
        } catch {
            $reason = "Exception: $($_.Exception.Message)"
            $passed = $false
        }

        if ($passed) {
            $results.Passed++
            Write-Host "    [PASS] $reqId ($testType)" -ForegroundColor Green
        } else {
            $results.Failed++
            Write-Host "    [FAIL] $reqId ($testType): $reason" -ForegroundColor Red
        }

        $results.Details += @{
            req_id  = $reqId
            status  = if ($passed) { "passed" } else { "failed" }
            type    = $testType
            reason  = $reason
        }
    }

    # Save results
    $testDir = Join-Path $GsdDir "tests"
    if (-not (Test-Path $testDir)) {
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
    }
    $resultsPath = Join-Path $testDir "acceptance-results.json"
    @{
        iteration = $Iteration
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        summary   = @{ total = $results.Total; passed = $results.Passed; failed = $results.Failed; skipped = $results.Skipped }
        details   = $results.Details
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $resultsPath -Encoding UTF8

    # Append to history
    $historyPath = Join-Path $testDir "acceptance-history.jsonl"
    $historyLine = @{ iteration = $Iteration; passed = $results.Passed; failed = $results.Failed; skipped = $results.Skipped; timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } | ConvertTo-Json -Compress
    Add-Content -Path $historyPath -Value $historyLine -Encoding UTF8

    $passRate = if ($results.Total -gt 0) { [math]::Round(($results.Passed / $results.Total) * 100, 1) } else { 0 }
    Write-Host "  [TEST] Results: $($results.Passed)/$($results.Total) passed ($passRate%), $($results.Skipped) skipped" -ForegroundColor $(if ($results.Failed -eq 0) { "Green" } else { "Yellow" })

    return $results
}

# ===========================================
# CONTRACT-FIRST API VALIDATION
# ===========================================

function Test-ApiContractCompliance {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $result = @{
        Passed   = $true
        Blocking = @()
        Warnings = @()
        Summary  = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.api_contract_validation -or -not $config.api_contract_validation.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    Write-Host "  [API] Running contract compliance scan..." -ForegroundColor Cyan

    # Ã¢â€â‚¬Ã¢â€â‚¬ 1. Find API contract source Ã¢â€â‚¬Ã¢â€â‚¬
    $contractPaths = @(
        (Join-Path $RepoRoot "docs\_analysis\06-api-contracts.md"),
        (Join-Path $RepoRoot "_analysis\06-api-contracts.md"),
        (Join-Path $RepoRoot "design\api\06-api-contracts.md")
    )

    $contractFile = $null
    foreach ($cp in $contractPaths) {
        if (Test-Path $cp) { $contractFile = $cp; break }
    }

    if (-not $contractFile) {
        Write-Host "  [API] No 06-api-contracts.md found -- skipping" -ForegroundColor DarkGray
        return $result
    }

    $contractContent = Get-Content $contractFile -Raw

    # Ã¢â€â‚¬Ã¢â€â‚¬ 2. Extract documented endpoints from contract Ã¢â€â‚¬Ã¢â€â‚¬
    $endpoints = @()
    $endpointRegex = '(?i)(GET|POST|PUT|PATCH|DELETE)\s+(/api/[^\s\|]+)'
    $matches = [regex]::Matches($contractContent, $endpointRegex)
    foreach ($m in $matches) {
        $endpoints += @{
            Method = $m.Groups[1].Value.ToUpper()
            Route  = $m.Groups[2].Value
        }
    }

    if ($endpoints.Count -eq 0) {
        Write-Host "  [API] No endpoints found in contract -- skipping" -ForegroundColor DarkGray
        return $result
    }

    Write-Host "  [API] Found $($endpoints.Count) documented endpoints" -ForegroundColor DarkCyan

    # Ã¢â€â‚¬Ã¢â€â‚¬ 3. Find controller files Ã¢â€â‚¬Ã¢â€â‚¬
    $scanPatterns = @($config.api_contract_validation.scan_patterns)
    if ($scanPatterns.Count -eq 0) { $scanPatterns = @("*Controller*.cs") }

    $controllers = @()
    foreach ($pattern in $scanPatterns) {
        $found = Get-ChildItem -Path $RepoRoot -Filter $pattern -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike "*\bin\*" -and $_.FullName -notlike "*\obj\*" -and $_.FullName -notlike "*\node_modules\*" }
        $controllers += $found
    }

    if ($controllers.Count -eq 0) {
        Write-Host "  [API] No controller files found -- all endpoints missing" -ForegroundColor Yellow
        foreach ($ep in $endpoints) {
            $result.Blocking += "Missing: $($ep.Method) $($ep.Route) -- no controller file"
        }
        $result.Passed = $false
        return $result
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 4. Read all controller content Ã¢â€â‚¬Ã¢â€â‚¬
    $allControllerContent = ""
    foreach ($ctrl in $controllers) {
        $allControllerContent += Get-Content $ctrl.FullName -Raw + "`n"
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 5. Validate each documented endpoint Ã¢â€â‚¬Ã¢â€â‚¬
    foreach ($ep in $endpoints) {
        $method = $ep.Method
        $route = $ep.Route

        # Convert route to regex pattern: /api/users/{id} -> api/users/\{?\w+\}?
        $routePattern = [regex]::Escape($route) -replace '\\{[^}]+\\}', '\{?\w+\}?'
        $routePattern = $routePattern -replace '^/', ''

        # Check for route attribute
        $httpAttr = "[Http${method}"
        $hasRoute = $allControllerContent -match $routePattern
        $hasMethod = $allControllerContent -match [regex]::Escape($httpAttr)

        if (-not $hasRoute -and -not $hasMethod) {
            $result.Blocking += "Missing endpoint: $method $route"
        } elseif (-not $hasMethod) {
            $result.Warnings += "Route exists but HTTP method may not match: $method $route"
        }
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 6. Check for [Authorize] on controllers Ã¢â€â‚¬Ã¢â€â‚¬
    foreach ($ctrl in $controllers) {
        $ctrlContent = Get-Content $ctrl.FullName -Raw
        $hasAuthorize = $ctrlContent -match '\[Authorize'
        $hasAllowAnon = $ctrlContent -match '\[AllowAnonymous\]'

        if (-not $hasAuthorize -and -not $hasAllowAnon) {
            $ctrlName = $ctrl.Name
            $result.Warnings += "Controller $ctrlName has no [Authorize] or [AllowAnonymous] attribute"
        }
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 7. Check for inline SQL (should use stored procedures) Ã¢â€â‚¬Ã¢â€â‚¬
    $inlineSqlPatterns = @(
        'new SqlCommand\(',
        'ExecuteSqlRaw\(',
        'FromSqlRaw\(',
        '"SELECT\s+',
        '"INSERT\s+INTO',
        '"UPDATE\s+\w+\s+SET',
        '"DELETE\s+FROM'
    )

    foreach ($ctrl in $controllers) {
        $ctrlContent = Get-Content $ctrl.FullName -Raw
        foreach ($sqlPattern in $inlineSqlPatterns) {
            if ($ctrlContent -match $sqlPattern) {
                $result.Blocking += "Inline SQL detected in $($ctrl.Name) (must use stored procedures): $sqlPattern"
                break
            }
        }
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 8. SP mapping validation Ã¢â€â‚¬Ã¢â€â‚¬
    $spMapPaths = @(
        (Join-Path $RepoRoot "docs\_analysis\11-api-to-sp-map.md"),
        (Join-Path $RepoRoot "_analysis\11-api-to-sp-map.md")
    )

    $spMapFile = $null
    foreach ($sp in $spMapPaths) {
        if (Test-Path $sp) { $spMapFile = $sp; break }
    }

    if ($spMapFile) {
        $spMapContent = Get-Content $spMapFile -Raw
        # Extract SP names from the map
        $spNames = @()
        $spRegex = '(?i)(usp_\w+|sp_\w+)'
        $spMatches = [regex]::Matches($spMapContent, $spRegex)
        foreach ($m in $spMatches) { $spNames += $m.Value }

        # Check if controllers reference the documented SPs
        $spNames = $spNames | Select-Object -Unique
        foreach ($sp in $spNames) {
            if ($allControllerContent -notmatch [regex]::Escape($sp)) {
                $result.Warnings += "Documented SP '$sp' not referenced in any controller"
            }
        }
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 9. Summary Ã¢â€â‚¬Ã¢â€â‚¬
    if ($result.Blocking.Count -gt 0) {
        $result.Passed = $false
    }

    $result.Summary = "Endpoints: $($endpoints.Count) documented, $($result.Blocking.Count) blocking, $($result.Warnings.Count) warnings"
    Write-Host "  [API] $($result.Summary)" -ForegroundColor $(if ($result.Passed) { "Green" } else { "Yellow" })

    if ($result.Blocking.Count -gt 0) {
        Write-Host "  [API] Blocking issues:" -ForegroundColor Red
        foreach ($b in $result.Blocking) {
            Write-Host "    - $b" -ForegroundColor Red
        }
    }

    # Save results
    $apiDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $apiDir)) {
        New-Item -Path $apiDir -ItemType Directory -Force | Out-Null
    }
    @{
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed    = $result.Passed
        blocking  = $result.Blocking
        warnings  = $result.Warnings
        summary   = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $apiDir "api-contract-results.json") -Encoding UTF8

    return $result
}

# ===========================================
# VISUAL VALIDATION (FIGMA SCREENSHOT DIFF)
# ===========================================

function Invoke-VisualValidation {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $result = @{
        Passed     = $true
        Components = @()
        Summary    = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.visual_validation -or -not $config.visual_validation.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    $maxDiffPct = [int]$config.visual_validation.max_diff_pct
    $screenshotDir = $config.visual_validation.screenshot_dir
    $blockOnDiff = $config.visual_validation.block_on_high_diff

    # Check for Figma screenshots
    $screenshotPath = Join-Path $RepoRoot $screenshotDir
    if (-not (Test-Path $screenshotPath)) {
        # Also check design/{interface}/screenshots/
        $designScreenshots = Get-ChildItem -Path $RepoRoot -Filter "screenshots" -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*design*" }

        if ($designScreenshots.Count -eq 0) {
            Write-Host "  [VISUAL] No screenshot directory found -- skipping visual validation" -ForegroundColor DarkGray
            Write-Host "  [VISUAL] Place Figma exports in: $screenshotDir" -ForegroundColor DarkGray
            return $result
        }
        $screenshotPath = $designScreenshots[0].FullName
    }

    # Find reference screenshots (PNG/JPG)
    $refScreenshots = Get-ChildItem -Path $screenshotPath -Include "*.png","*.jpg","*.jpeg" -Recurse -ErrorAction SilentlyContinue
    if ($refScreenshots.Count -eq 0) {
        Write-Host "  [VISUAL] No reference screenshots found in $screenshotPath" -ForegroundColor DarkGray
        return $result
    }

    Write-Host "  [VISUAL] Found $($refScreenshots.Count) reference screenshots" -ForegroundColor Cyan

    # Check for Playwright
    $hasPlaywright = $null -ne (Get-Command npx -ErrorAction SilentlyContinue)
    $hasPixelmatch = $false

    if ($hasPlaywright) {
        # Check if playwright and pixelmatch are available
        $playwrightCheck = & npx playwright --version 2>$null
        $hasPlaywright = ($LASTEXITCODE -eq 0)
    }

    if (-not $hasPlaywright) {
        Write-Host "  [VISUAL] Playwright not available -- using file-size heuristic comparison" -ForegroundColor Yellow
        Write-Host "  [VISUAL] Install: npm install -D playwright @playwright/test" -ForegroundColor DarkGray

        # Fallback: just report which screenshots exist vs which components exist
        foreach ($ref in $refScreenshots) {
            $componentName = [System.IO.Path]::GetFileNameWithoutExtension($ref.Name)
            $componentFiles = Get-ChildItem -Path $RepoRoot -Filter "*${componentName}*" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in ".tsx", ".jsx", ".ts", ".js" -and $_.FullName -notlike "*node_modules*" }

            $status = if ($componentFiles.Count -gt 0) { "implemented" } else { "missing" }
            $result.Components += @{
                name        = $componentName
                reference   = $ref.FullName
                status      = $status
                component   = if ($componentFiles.Count -gt 0) { $componentFiles[0].FullName } else { $null }
                diff_pct    = if ($status -eq "missing") { 100 } else { -1 }
            }

            if ($status -eq "missing") {
                Write-Host "    [MISS] $componentName -- no matching component file" -ForegroundColor Red
            } else {
                Write-Host "    [OK] $componentName -> $($componentFiles[0].Name)" -ForegroundColor Green
            }
        }
    } else {
        # Full Playwright screenshot comparison
        $viewport_w = [int]$config.visual_validation.viewport_width
        $viewport_h = [int]$config.visual_validation.viewport_height
        $timeout = [int]$config.visual_validation.playwright_timeout_ms

        # Check if dev server is running (React typically on port 3000)
        $devServerRunning = $false
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:3000" -TimeoutSec 3 -ErrorAction SilentlyContinue
            $devServerRunning = ($response.StatusCode -eq 200)
        } catch {
            $devServerRunning = $false
        }

        if (-not $devServerRunning) {
            Write-Host "  [VISUAL] Dev server not running on localhost:3000 -- using component-match only" -ForegroundColor Yellow

            foreach ($ref in $refScreenshots) {
                $componentName = [System.IO.Path]::GetFileNameWithoutExtension($ref.Name)
                $componentFiles = Get-ChildItem -Path $RepoRoot -Filter "*${componentName}*" -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in ".tsx", ".jsx", ".ts", ".js" -and $_.FullName -notlike "*node_modules*" }

                $status = if ($componentFiles.Count -gt 0) { "implemented" } else { "missing" }
                $result.Components += @{
                    name      = $componentName
                    reference = $ref.FullName
                    status    = $status
                    diff_pct  = if ($status -eq "missing") { 100 } else { -1 }
                }
            }
        } else {
            Write-Host "  [VISUAL] Dev server detected. Running Playwright screenshot capture..." -ForegroundColor Cyan

            # Create temp screenshot dir for captured screenshots
            $captureDir = Join-Path $GsdDir "validation\screenshots-captured"
            if (-not (Test-Path $captureDir)) {
                New-Item -Path $captureDir -ItemType Directory -Force | Out-Null
            }

            foreach ($ref in $refScreenshots) {
                $componentName = [System.IO.Path]::GetFileNameWithoutExtension($ref.Name)

                # Try to capture screenshot of the component route
                $route = $componentName.ToLower() -replace '_', '/' -replace '-', '/'
                $url = "http://localhost:3000/$route"

                $capturedPath = Join-Path $captureDir "$componentName.png"

                try {
                    # Use Playwright to capture
                    $playwrightScript = @"
const { chromium } = require('playwright');
(async () => {
    const browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: $viewport_w, height: $viewport_h } });
    await page.goto('$url', { timeout: $timeout });
    await page.screenshot({ path: '$($capturedPath -replace '\\', '/')' });
    await browser.close();
})();
"@
                    $scriptPath = Join-Path $GsdDir "validation\.playwright-capture.js"
                    Set-Content -Path $scriptPath -Value $playwrightScript -Encoding UTF8
                    & node $scriptPath 2>$null

                    if (Test-Path $capturedPath) {
                        # Compare file sizes as rough diff metric (full pixel diff requires additional npm package)
                        $refSize = (Get-Item $ref.FullName).Length
                        $capSize = (Get-Item $capturedPath).Length
                        $sizeDiff = [math]::Abs($refSize - $capSize) / [math]::Max($refSize, 1) * 100

                        $result.Components += @{
                            name       = $componentName
                            reference  = $ref.FullName
                            captured   = $capturedPath
                            status     = "captured"
                            diff_pct   = [math]::Round($sizeDiff, 1)
                        }

                        if ($sizeDiff -gt $maxDiffPct) {
                            Write-Host "    [DIFF] ${componentName}: $([math]::Round($sizeDiff,1))% deviation" -ForegroundColor Yellow
                        } else {
                            Write-Host "    [OK] ${componentName}: $([math]::Round($sizeDiff,1))% deviation" -ForegroundColor Green
                        }
                    } else {
                        $result.Components += @{
                            name     = $componentName
                            status   = "capture_failed"
                            diff_pct = -1
                        }
                        Write-Host "    [FAIL] ${componentName}: screenshot capture failed" -ForegroundColor Red
                    }

                    Remove-Item $scriptPath -ErrorAction SilentlyContinue
                } catch {
                    $result.Components += @{
                        name     = $componentName
                        status   = "error"
                        diff_pct = -1
                        error    = $_.Exception.Message
                    }
                }
            }
        }
    }

    # Determine pass/fail
    $highDiffCount = ($result.Components | Where-Object { $_.diff_pct -gt $maxDiffPct }).Count
    $missingCount = ($result.Components | Where-Object { $_.status -eq "missing" }).Count

    if ($blockOnDiff -and ($highDiffCount -gt 0 -or $missingCount -gt 0)) {
        $result.Passed = $false
    }

    $result.Summary = "Components: $($result.Components.Count), High diff: $highDiffCount, Missing: $missingCount"
    Write-Host "  [VISUAL] $($result.Summary)" -ForegroundColor $(if ($highDiffCount -eq 0 -and $missingCount -eq 0) { "Green" } else { "Yellow" })

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) {
        New-Item -Path $valDir -ItemType Directory -Force | Out-Null
    }
    @{
        iteration  = $Iteration
        timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed     = $result.Passed
        max_diff   = $maxDiffPct
        components = $result.Components
        summary    = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "visual-results.json") -Encoding UTF8

    return $result
}

# ===========================================
# DESIGN TOKEN ENFORCEMENT
# ===========================================

function Test-DesignTokenCompliance {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $result = @{
        Passed     = $true
        Violations = @()
        Summary    = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.design_token_enforcement -or -not $config.design_token_enforcement.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    $blockOnViolation = $config.design_token_enforcement.block_on_violation
    $scanExtensions = @($config.design_token_enforcement.scan_extensions)
    $allowedRawColors = @($config.design_token_enforcement.allowed_raw_colors)

    Write-Host "  [TOKEN] Running design token compliance scan..." -ForegroundColor Cyan

    # Ã¢â€â‚¬Ã¢â€â‚¬ 1. Load design tokens if available Ã¢â€â‚¬Ã¢â€â‚¬
    $tokenPaths = @(
        (Join-Path $RepoRoot "_analysis\design-tokens.json"),
        (Join-Path $RepoRoot "design\tokens\tokens.json"),
        (Join-Path $RepoRoot "design\web\tokens.json"),
        (Join-Path $RepoRoot "src\styles\tokens.json"),
        (Join-Path $RepoRoot "src\theme\tokens.json")
    )

    $tokenFile = $null
    $designTokens = @{}
    foreach ($tp in $tokenPaths) {
        if (Test-Path $tp) {
            try {
                $designTokens = Get-Content $tp -Raw | ConvertFrom-Json
                $tokenFile = $tp
                Write-Host "  [TOKEN] Loaded design tokens from: $tp" -ForegroundColor DarkCyan
            } catch {}
            break
        }
    }

    if (-not $tokenFile) {
        Write-Host "  [TOKEN] No design tokens file found -- scanning for hardcoded values only" -ForegroundColor DarkGray
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 2. Find source files to scan Ã¢â€â‚¬Ã¢â€â‚¬
    $filesToScan = @()
    foreach ($ext in $scanExtensions) {
        $pattern = "*$ext"
        $found = Get-ChildItem -Path $RepoRoot -Filter $pattern -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike "*\node_modules\*" -and
                $_.FullName -notlike "*\bin\*" -and
                $_.FullName -notlike "*\obj\*" -and
                $_.FullName -notlike "*\dist\*" -and
                $_.FullName -notlike "*\build\*" -and
                $_.FullName -notlike "*\.gsd\*" -and
                $_.Name -notlike "*.min.*" -and
                $_.Name -notlike "*.bundle.*"
            }
        $filesToScan += $found
    }

    if ($filesToScan.Count -eq 0) {
        Write-Host "  [TOKEN] No source files to scan" -ForegroundColor DarkGray
        return $result
    }

    Write-Host "  [TOKEN] Scanning $($filesToScan.Count) files..." -ForegroundColor DarkCyan

    # Ã¢â€â‚¬Ã¢â€â‚¬ 3. Hardcoded value patterns Ã¢â€â‚¬Ã¢â€â‚¬
    $patterns = @(
        @{
            Name    = "Hardcoded hex color"
            Regex   = '#[0-9a-fA-F]{3,8}(?![\w-])'
            Type    = "color"
        },
        @{
            Name    = "Hardcoded rgb/rgba"
            Regex   = 'rgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+'
            Type    = "color"
        },
        @{
            Name    = "Hardcoded pixel font-size"
            Regex   = 'font-size:\s*\d+px'
            Type    = "typography"
        },
        @{
            Name    = "Hardcoded pixel spacing"
            Regex   = '(?:margin|padding|gap):\s*\d+px'
            Type    = "spacing"
        },
        @{
            Name    = "Hardcoded pixel border-radius"
            Regex   = 'border-radius:\s*\d+px'
            Type    = "border"
        },
        @{
            Name    = "Inline style with hardcoded color"
            Regex   = 'color:\s*[''"]#[0-9a-fA-F]{3,8}[''"]'
            Type    = "color"
        },
        @{
            Name    = "Inline style object color"
            Regex   = "color:\s*['""]#[0-9a-fA-F]{3,8}['""]"
            Type    = "color"
        }
    )

    # Ã¢â€â‚¬Ã¢â€â‚¬ 4. Scan files Ã¢â€â‚¬Ã¢â€â‚¬
    foreach ($file in $filesToScan) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $relativePath = $file.FullName.Substring($RepoRoot.Length + 1)

        foreach ($pattern in $patterns) {
            $matches = [regex]::Matches($content, $pattern.Regex)
            foreach ($match in $matches) {
                $value = $match.Value

                # Skip allowed raw colors
                $isAllowed = $false
                foreach ($allowed in $allowedRawColors) {
                    if ($value -like "*$allowed*") { $isAllowed = $true; break }
                }
                if ($isAllowed) { continue }

                # Skip CSS custom property references (var(--xxx))
                $lineContent = ""
                $matchIdx = $match.Index
                $lineStart = $content.LastIndexOf("`n", [math]::Max(0, $matchIdx - 1)) + 1
                $lineEnd = $content.IndexOf("`n", $matchIdx)
                if ($lineEnd -lt 0) { $lineEnd = $content.Length }
                $lineContent = $content.Substring($lineStart, $lineEnd - $lineStart).Trim()

                if ($lineContent -match 'var\(--') { continue }

                # Calculate line number
                $lineNum = ($content.Substring(0, $matchIdx) -split "`n").Count

                $result.Violations += @{
                    file    = $relativePath
                    line    = $lineNum
                    type    = $pattern.Type
                    pattern = $pattern.Name
                    value   = $value
                    context = $lineContent.Substring(0, [math]::Min(120, $lineContent.Length))
                }
            }
        }
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 5. Summary Ã¢â€â‚¬Ã¢â€â‚¬
    if ($result.Violations.Count -gt 0) {
        $byType = $result.Violations | Group-Object -Property type
        $typeSummary = ($byType | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ", "
        $result.Summary = "$($result.Violations.Count) hardcoded values found ($typeSummary)"

        if ($blockOnViolation) { $result.Passed = $false }

        Write-Host "  [TOKEN] $($result.Summary)" -ForegroundColor Yellow

        # Show top 10 violations
        $top = $result.Violations | Select-Object -First 10
        foreach ($v in $top) {
            Write-Host "    $($v.file):$($v.line) -- $($v.pattern): $($v.value)" -ForegroundColor DarkYellow
        }
        if ($result.Violations.Count -gt 10) {
            Write-Host "    ... and $($result.Violations.Count - 10) more" -ForegroundColor DarkGray
        }
    } else {
        $result.Summary = "No hardcoded design values found"
        Write-Host "  [TOKEN] $($result.Summary)" -ForegroundColor Green
    }

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) {
        New-Item -Path $valDir -ItemType Directory -Force | Out-Null
    }
    @{
        timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed     = $result.Passed
        violations = $result.Violations.Count
        by_type    = ($result.Violations | Group-Object type | ForEach-Object { @{ type = $_.Name; count = $_.Count } })
        details    = $result.Violations | Select-Object -First 50
        summary    = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "design-token-results.json") -Encoding UTF8

    return $result
}

# ===========================================
# COMPLIANCE ENGINE
# ===========================================

# Ã¢â€â‚¬Ã¢â€â‚¬ Per-Iteration Compliance Audit Ã¢â€â‚¬Ã¢â€â‚¬

function Invoke-PerIterationCompliance {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $result = @{
        Passed   = $true
        Critical = @()
        High     = @()
        Medium   = @()
        RuleResults = @()
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.compliance_engine -or -not $config.compliance_engine.per_iteration_audit -or
                -not $config.compliance_engine.per_iteration_audit.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    Write-Host "  [COMPLIANCE] Running per-iteration compliance audit..." -ForegroundColor Cyan

    # Structured rule engine: ID -> regex -> severity -> file glob
    $rules = @(
        # Network Security (SEC-NET-*)
        @{ Id="SEC-NET-01"; Name="SQL Injection"; Severity="critical"; Glob="*.cs"; Pattern='string\.Format\s*\(\s*".*SELECT|".*\+.*sql|SqlCommand\(\s*\$"|\.ExecuteSqlRaw\(\s*\$"' }
        @{ Id="SEC-NET-02"; Name="XSS via innerHTML"; Severity="critical"; Glob="*.tsx,*.jsx"; Pattern='dangerouslySetInnerHTML|\.innerHTML\s*=' }
        @{ Id="SEC-NET-03"; Name="Eval usage"; Severity="critical"; Glob="*.ts,*.tsx,*.js,*.jsx"; Pattern='\beval\s*\(|new\s+Function\s*\(' }
        @{ Id="SEC-NET-04"; Name="Hardcoded secrets"; Severity="critical"; Glob="*.cs,*.ts,*.json"; Pattern='(?i)(password|secret|api_key|apikey|connection_string)\s*[:=]\s*"[^"]{8,}"' }
        @{ Id="SEC-NET-05"; Name="Missing Authorize"; Severity="high"; Glob="*Controller*.cs"; Pattern='(?s)\[ApiController\](?!.*\[Authorize)' }
        @{ Id="SEC-NET-06"; Name="HTTP instead of HTTPS"; Severity="high"; Glob="*.cs,*.ts"; Pattern='http://(?!localhost|127\.0\.0\.1|0\.0\.0\.0)' }
        @{ Id="SEC-NET-07"; Name="Console.log sensitive data"; Severity="medium"; Glob="*.ts,*.tsx,*.js"; Pattern='console\.\w+\(.*(?i)(password|token|secret|ssn|credit)' }
        @{ Id="SEC-NET-08"; Name="localStorage for tokens"; Severity="high"; Glob="*.ts,*.tsx,*.js"; Pattern='localStorage\.\w+\(.*(?i)(token|jwt|auth|session)' }

        # SQL Security (SEC-SQL-*)
        @{ Id="SEC-SQL-01"; Name="String concatenation in SQL"; Severity="critical"; Glob="*.sql"; Pattern='\+\s*@|\+\s*CAST|''.*\+' }
        @{ Id="SEC-SQL-02"; Name="Missing parameterized query"; Severity="high"; Glob="*.cs"; Pattern='new SqlCommand\(\s*\$"|SqlCommand\(\s*".*\+' }
        @{ Id="SEC-SQL-03"; Name="Dynamic SQL without sp_executesql"; Severity="high"; Glob="*.sql"; Pattern='EXEC\s*\(\s*@(?!.*sp_executesql)' }

        # Frontend Security (SEC-FE-*)
        @{ Id="SEC-FE-01"; Name="Missing CSRF token"; Severity="high"; Glob="*.cs"; Pattern='\[HttpPost\](?!.*\[ValidateAntiForgeryToken\])' }
        @{ Id="SEC-FE-02"; Name="Unvalidated redirect"; Severity="medium"; Glob="*.cs"; Pattern='Redirect\(\s*\w+\)(?!.*IsLocalUrl)' }

        # HIPAA (COMP-HIPAA-*)
        @{ Id="COMP-HIPAA-01"; Name="PII in log output"; Severity="critical"; Glob="*.cs"; Pattern='(?i)_logger\.\w+\(.*(?:ssn|social.*security|date.*birth|medical)' }
        @{ Id="COMP-HIPAA-02"; Name="Unencrypted PII storage"; Severity="critical"; Glob="*.cs"; Pattern='(?i)(?:ssn|social_security)\s*=\s*(?!.*Encrypt|.*Hash)' }

        # SOC 2 (COMP-SOC2-*)
        @{ Id="COMP-SOC2-01"; Name="Missing audit log"; Severity="high"; Glob="*.cs"; Pattern='(?s)(?:INSERT|UPDATE|DELETE)(?!.*AuditLog|.*_logger|.*LogAudit)' }

        # PCI (COMP-PCI-*)
        @{ Id="COMP-PCI-01"; Name="Credit card in logs"; Severity="critical"; Glob="*.cs,*.ts"; Pattern='(?i)_logger\.\w+\(.*(?:card.*number|credit.*card|cvv|ccv)' }
        @{ Id="COMP-PCI-02"; Name="Unmasked card display"; Severity="high"; Glob="*.tsx,*.jsx"; Pattern='(?i)card.*number.*\{(?!.*mask|.*\*\*\*|.*slice\(-4\))' }

        # GDPR (COMP-GDPR-*)
        @{ Id="COMP-GDPR-01"; Name="Missing data deletion endpoint"; Severity="medium"; Glob="*Controller*.cs"; Pattern='(?!)' }  # placeholder -- checked separately
    )

    # Scan source files
    $sourceFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notlike "*\node_modules\*" -and
            $_.FullName -notlike "*\bin\*" -and
            $_.FullName -notlike "*\obj\*" -and
            $_.FullName -notlike "*\.gsd\*" -and
            $_.FullName -notlike "*\.git\*" -and
            $_.Extension -in ".cs", ".ts", ".tsx", ".jsx", ".js", ".sql", ".json"
        }

    $fileContents = @{}
    foreach ($f in $sourceFiles) {
        try {
            $fileContents[$f.FullName] = @{
                Content  = Get-Content $f.FullName -Raw
                Relative = $f.FullName.Substring($RepoRoot.Length + 1)
                Extension = $f.Extension
            }
        } catch {}
    }

    foreach ($rule in $rules) {
        if ($rule.Pattern -eq '(?!)') { continue }  # skip placeholder rules

        $ruleGlobs = $rule.Glob -split ','
        $violations = @()

        foreach ($kvp in $fileContents.GetEnumerator()) {
            $info = $kvp.Value
            $matchesGlob = $false
            foreach ($g in $ruleGlobs) {
                if ($info.Relative -like $g.Trim()) { $matchesGlob = $true; break }
            }
            if (-not $matchesGlob) { continue }

            try {
                $regexMatches = [regex]::Matches($info.Content, $rule.Pattern)
                foreach ($m in $regexMatches) {
                    $lineNum = ($info.Content.Substring(0, $m.Index) -split "`n").Count
                    $violations += @{
                        file = $info.Relative
                        line = $lineNum
                        match = $m.Value.Substring(0, [math]::Min(80, $m.Value.Length))
                    }
                }
            } catch {}
        }

        $status = if ($violations.Count -eq 0) { "passed" } else { "failed" }
        $result.RuleResults += @{
            id         = $rule.Id
            name       = $rule.Name
            severity   = $rule.Severity
            status     = $status
            violations = $violations.Count
            details    = $violations | Select-Object -First 5
        }

        if ($violations.Count -gt 0) {
            switch ($rule.Severity) {
                "critical" { $result.Critical += "$($rule.Id): $($rule.Name) ($($violations.Count) violations)" }
                "high"     { $result.High += "$($rule.Id): $($rule.Name) ($($violations.Count) violations)" }
                "medium"   { $result.Medium += "$($rule.Id): $($rule.Name) ($($violations.Count) violations)" }
            }
        }
    }

    # Determine pass/fail
    $blockOnCritical = $config.compliance_engine.per_iteration_audit.block_on_critical
    if ($blockOnCritical -and $result.Critical.Count -gt 0) {
        $result.Passed = $false
    }

    $total = $result.RuleResults.Count
    $passed = ($result.RuleResults | Where-Object { $_.status -eq "passed" }).Count
    $result.Summary = "Rules: $passed/$total passed. Critical: $($result.Critical.Count), High: $($result.High.Count), Medium: $($result.Medium.Count)"

    Write-Host "  [COMPLIANCE] $($result.Summary)" -ForegroundColor $(if ($result.Critical.Count -eq 0) { "Green" } else { "Red" })

    if ($result.Critical.Count -gt 0) {
        foreach ($c in $result.Critical) { Write-Host "    [CRITICAL] $c" -ForegroundColor Red }
    }

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) { New-Item -Path $valDir -ItemType Directory -Force | Out-Null }
    @{
        iteration = $Iteration
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed    = $result.Passed
        summary   = $result.Summary
        critical  = $result.Critical
        high      = $result.High
        medium    = $result.Medium
        rules     = $result.RuleResults
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "compliance-scan.json") -Encoding UTF8

    return $result
}

# Ã¢â€â‚¬Ã¢â€â‚¬ Database Migration Validation Ã¢â€â‚¬Ã¢â€â‚¬

function Test-DatabaseMigrationIntegrity {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $result = @{
        Passed   = $true
        Issues   = @()
        Summary  = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.compliance_engine -or -not $config.compliance_engine.db_migration -or
                -not $config.compliance_engine.db_migration.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    Write-Host "  [DB] Running database migration integrity scan..." -ForegroundColor Cyan

    # Find SQL files
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "*\node_modules\*" -and $_.FullName -notlike "*\.gsd\*" }

    if ($sqlFiles.Count -eq 0) {
        Write-Host "  [DB] No SQL files found -- skipping" -ForegroundColor DarkGray
        return $result
    }

    $allSqlContent = ""
    foreach ($sf in $sqlFiles) {
        $allSqlContent += (Get-Content $sf.FullName -Raw) + "`n"
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 1. Foreign Key Consistency Ã¢â€â‚¬Ã¢â€â‚¬
    if ($config.compliance_engine.db_migration.check_foreign_keys) {
        # Find REFERENCES clauses and verify target tables exist
        $fkRegex = '(?i)REFERENCES\s+\[?(\w+)\]?\s*\(\s*\[?(\w+)\]?\s*\)'
        $fkMatches = [regex]::Matches($allSqlContent, $fkRegex)

        $createTableRegex = '(?i)CREATE\s+TABLE\s+\[?(?:dbo\.)?\]?\[?(\w+)\]?'
        $tables = @([regex]::Matches($allSqlContent, $createTableRegex) | ForEach-Object { $_.Groups[1].Value.ToLower() })

        foreach ($fk in $fkMatches) {
            $refTable = $fk.Groups[1].Value.ToLower()
            if ($refTable -notin $tables) {
                $result.Issues += @{
                    type    = "foreign_key"
                    severity = "high"
                    message = "FK references table '$($fk.Groups[1].Value)' which is not defined in any CREATE TABLE"
                }
            }
        }
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 2. Index Coverage Ã¢â€â‚¬Ã¢â€â‚¬
    if ($config.compliance_engine.db_migration.check_index_coverage) {
        # Find WHERE clauses in SPs and check for indexes
        $whereRegex = '(?i)WHERE\s+\[?(\w+)\]?\s*='
        $whereMatches = [regex]::Matches($allSqlContent, $whereRegex)
        $queriedColumns = @($whereMatches | ForEach-Object { $_.Groups[1].Value.ToLower() } | Select-Object -Unique)

        $indexRegex = '(?i)CREATE\s+(?:UNIQUE\s+)?(?:NONCLUSTERED\s+)?INDEX\s+\w+\s+ON\s+\[?\w+\]?\s*\(\s*\[?(\w+)\]?'
        $pkRegex = '(?i)PRIMARY\s+KEY\s*\(\s*\[?(\w+)\]?'
        $indexedColumns = @()
        $indexedColumns += [regex]::Matches($allSqlContent, $indexRegex) | ForEach-Object { $_.Groups[1].Value.ToLower() }
        $indexedColumns += [regex]::Matches($allSqlContent, $pkRegex) | ForEach-Object { $_.Groups[1].Value.ToLower() }
        $indexedColumns = $indexedColumns | Select-Object -Unique

        foreach ($col in $queriedColumns) {
            if ($col -notin $indexedColumns -and $col -ne "id") {
                $result.Issues += @{
                    type    = "index_coverage"
                    severity = "medium"
                    message = "Column '$col' used in WHERE clause but no index found"
                }
            }
        }
    }

    # Ã¢â€â‚¬Ã¢â€â‚¬ 3. Seed Data Integrity Ã¢â€â‚¬Ã¢â€â‚¬
    if ($config.compliance_engine.db_migration.check_seed_integrity) {
        # Find INSERT statements and verify referenced tables exist
        $insertRegex = '(?i)INSERT\s+INTO\s+\[?(?:dbo\.)?\]?\[?(\w+)\]?'
        $insertMatches = [regex]::Matches($allSqlContent, $insertRegex)
        $seededTables = @($insertMatches | ForEach-Object { $_.Groups[1].Value.ToLower() } | Select-Object -Unique)

        $createTableRegex2 = '(?i)CREATE\s+TABLE\s+\[?(?:dbo\.)?\]?\[?(\w+)\]?'
        $tables2 = @([regex]::Matches($allSqlContent, $createTableRegex2) | ForEach-Object { $_.Groups[1].Value.ToLower() })

        foreach ($st in $seededTables) {
            if ($st -notin $tables2) {
                $result.Issues += @{
                    type    = "seed_integrity"
                    severity = "high"
                    message = "INSERT INTO '$st' but table not defined in CREATE TABLE"
                }
            }
        }
    }

    # Summary
    $highCount = ($result.Issues | Where-Object { $_.severity -eq "high" }).Count
    $medCount = ($result.Issues | Where-Object { $_.severity -eq "medium" }).Count
    $result.Summary = "DB integrity: $($result.Issues.Count) issues (high: $highCount, medium: $medCount)"
    if ($highCount -gt 0) { $result.Passed = $false }

    Write-Host "  [DB] $($result.Summary)" -ForegroundColor $(if ($result.Passed) { "Green" } else { "Yellow" })

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) { New-Item -Path $valDir -ItemType Directory -Force | Out-Null }
    @{
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed    = $result.Passed
        issues    = $result.Issues
        summary   = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "db-migration-results.json") -Encoding UTF8

    return $result
}

# Ã¢â€â‚¬Ã¢â€â‚¬ PII Flow Tracking Ã¢â€â‚¬Ã¢â€â‚¬

function Invoke-PiiFlowAnalysis {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $result = @{
        Passed    = $true
        Risks     = @()
        PiiFields = @()
        Summary   = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.compliance_engine -or -not $config.compliance_engine.pii_tracking -or
                -not $config.compliance_engine.pii_tracking.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    $piiFieldNames = @($config.compliance_engine.pii_tracking.pii_fields)

    Write-Host "  [PII] Running PII flow analysis..." -ForegroundColor Cyan

    # Find source files
    $sourceFiles = Get-ChildItem -Path $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -in ".cs", ".ts", ".tsx", ".sql" -and
            $_.FullName -notlike "*\node_modules\*" -and
            $_.FullName -notlike "*\bin\*" -and
            $_.FullName -notlike "*\obj\*" -and
            $_.FullName -notlike "*\.gsd\*"
        }

    foreach ($field in $piiFieldNames) {
        $fieldPattern = "(?i)$([regex]::Escape($field))"
        $foundIn = @()

        foreach ($f in $sourceFiles) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            if ($content -match $fieldPattern) {
                $relativePath = $f.FullName.Substring($RepoRoot.Length + 1)
                $foundIn += $relativePath

                # Check for logging risks (PII in log output)
                if ($config.compliance_engine.pii_tracking.check_logging) {
                    if ($content -match "(?i)(_logger|Console|console)\.\w+\(.*$field") {
                        $result.Risks += @{
                            type    = "pii_in_logs"
                            field   = $field
                            file    = $relativePath
                            severity = "critical"
                            message = "PII field '$field' appears in log output"
                        }
                    }
                }

                # Check for encryption (PII stored without encryption)
                if ($config.compliance_engine.pii_tracking.check_encryption -and $f.Extension -eq ".cs") {
                    if ($content -match "(?i)$field\s*=" -and $content -notmatch "(?i)(Encrypt|Hash|Protect|DataProtect).*$field|$field.*(Encrypt|Hash)") {
                        # Only flag if it looks like storage (not just reading)
                        if ($content -match "(?i)(INSERT|UPDATE|SaveChanges|Repository)") {
                            $result.Risks += @{
                                type    = "pii_unencrypted"
                                field   = $field
                                file    = $relativePath
                                severity = "high"
                                message = "PII field '$field' may be stored without encryption"
                            }
                        }
                    }
                }

                # Check UI masking (PII displayed without masking)
                if ($config.compliance_engine.pii_tracking.check_ui_masking -and $f.Extension -in ".tsx", ".jsx") {
                    if ($content -match "(?i)\{.*$field.*\}" -and $content -notmatch "(?i)(mask|hide|\*\*\*|slice\(-4\)|substring).*$field|$field.*(mask|hide)") {
                        $result.Risks += @{
                            type    = "pii_unmasked_ui"
                            field   = $field
                            file    = $relativePath
                            severity = "high"
                            message = "PII field '$field' displayed in UI without masking"
                        }
                    }
                }
            }
        }

        if ($foundIn.Count -gt 0) {
            $result.PiiFields += @{
                field    = $field
                found_in = $foundIn
                count    = $foundIn.Count
            }
        }
    }

    # Summary
    $criticalCount = ($result.Risks | Where-Object { $_.severity -eq "critical" }).Count
    $highCount = ($result.Risks | Where-Object { $_.severity -eq "high" }).Count
    $result.Summary = "PII fields: $($result.PiiFields.Count) tracked, Risks: $($result.Risks.Count) (critical: $criticalCount, high: $highCount)"

    if ($criticalCount -gt 0) { $result.Passed = $false }

    Write-Host "  [PII] $($result.Summary)" -ForegroundColor $(if ($criticalCount -eq 0) { "Green" } else { "Red" })

    if ($criticalCount -gt 0) {
        foreach ($r in ($result.Risks | Where-Object { $_.severity -eq "critical" })) {
            Write-Host "    [CRITICAL] $($r.message) ($($r.file))" -ForegroundColor Red
        }
    }

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) { New-Item -Path $valDir -ItemType Directory -Force | Out-Null }
    @{
        timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed     = $result.Passed
        pii_fields = $result.PiiFields
        risks      = $result.Risks
        summary    = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "pii-flow-results.json") -Encoding UTF8

    return $result
}

# ===========================================
# SPEED OPTIMIZATIONS
# ===========================================

# Ã¢â€â‚¬Ã¢â€â‚¬ Conditional Research Skip Ã¢â€â‚¬Ã¢â€â‚¬

function Test-ShouldSkipResearch {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [decimal]$CurrentHealth,
        [decimal]$PreviousHealth,
        [int]$Iteration
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $skipCfg = $config.speed_optimizations.conditional_research_skip
            if (-not $skipCfg -or -not $skipCfg.enabled) { return $false }
        } catch { return $false }
    } else { return $false }

    # Don't skip on first iteration
    if ($Iteration -le 1) { return $false }

    # Check health improvement
    $minDelta = if ($skipCfg.min_health_delta) { [decimal]$skipCfg.min_health_delta } else { 1 }
    $healthDelta = $CurrentHealth - $PreviousHealth

    if ($healthDelta -lt $minDelta) {
        # Health not improving -- DO research (might be stuck)
        return $false
    }

    # Check if batch has new "not_started" requirements
    $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
    if (Test-Path $queuePath) {
        try {
            $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
            $batch = @($queue.batch)
            $newItems = $batch | Where-Object { $_.status -eq "not_started" }
            if ($newItems.Count -gt 0) {
                # New requirements need research
                return $false
            }
        } catch {}
    }

    Write-Host "  [SPEED] Skipping research: health improving (+$healthDelta%), no new requirements" -ForegroundColor DarkGray
    return $true
}

# Ã¢â€â‚¬Ã¢â€â‚¬ Smart Batch Sizing Ã¢â€â‚¬Ã¢â€â‚¬

function Get-OptimalBatchSize {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$CurrentBatchSize,
        [int]$Iteration
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $batchCfg = $config.speed_optimizations.smart_batch_sizing
            if (-not $batchCfg -or -not $batchCfg.enabled) { return $CurrentBatchSize }
        } catch { return $CurrentBatchSize }
    } else { return $CurrentBatchSize }

    $contextLimit = [int]$batchCfg.context_limit_tokens
    $utilTarget = [decimal]$batchCfg.utilization_target
    $minBatch = [int]$batchCfg.min_batch
    $maxBatch = [int]$batchCfg.max_batch

    # Read cost history to compute avg tokens per requirement
    $costPath = Join-Path $GsdDir "costs\cost-summary.json"
    if (-not (Test-Path $costPath)) { return $CurrentBatchSize }

    try {
        $costs = Get-Content $costPath -Raw | ConvertFrom-Json
    } catch { return $CurrentBatchSize }

    # Calculate from runs history
    $runs = @($costs.runs)
    if ($runs.Count -lt 2) { return $CurrentBatchSize }

    # Get execute phase token usage
    $executeTokens = @()
    $executeBatches = @()
    foreach ($run in $runs) {
        if ($run.by_phase) {
            $execPhase = $run.by_phase | Where-Object { $_.phase -eq "execute" }
            if ($execPhase -and $execPhase.output_tokens -gt 0) {
                $executeTokens += [int]$execPhase.output_tokens
                $executeBatches += [int]$(if ($run.batch_size) { $run.batch_size } else { $CurrentBatchSize })
            }
        }
    }

    if ($executeTokens.Count -eq 0) { return $CurrentBatchSize }

    # Average tokens per requirement
    $totalTokens = ($executeTokens | Measure-Object -Sum).Sum
    $totalBatchItems = ($executeBatches | Measure-Object -Sum).Sum
    if ($totalBatchItems -eq 0) { return $CurrentBatchSize }

    $avgTokensPerReq = [math]::Ceiling($totalTokens / $totalBatchItems)
    if ($avgTokensPerReq -le 0) { return $CurrentBatchSize }

    # Calculate optimal batch
    $optimal = [math]::Floor(($contextLimit * $utilTarget) / $avgTokensPerReq)
    $optimal = [math]::Max($minBatch, [math]::Min($maxBatch, $optimal))

    if ($optimal -ne $CurrentBatchSize) {
        Write-Host "  [SPEED] Smart batch: $CurrentBatchSize -> $optimal (avg $avgTokensPerReq tokens/req)" -ForegroundColor Cyan
    }

    return [int]$optimal
}

# Ã¢â€â‚¬Ã¢â€â‚¬ Incremental File Map Ã¢â€â‚¬Ã¢â€â‚¬

function Update-FileMapIncremental {
    param(
        [string]$Root,
        [string]$GsdPath
    )

    # Check if git is available and we have a previous file map
    $fileMapPath = Join-Path $GsdPath "file-map.json"
    if (-not (Test-Path $fileMapPath)) {
        # No existing file map -- do full scan
        if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
            return Update-FileMap -Root $Root -GsdPath $GsdPath
        }
        return $null
    }

    # Check config
    $configPath = Join-Path (Split-Path (Split-Path $GsdPath)) ".gsd-global\config\global-config.json"
    # Try standard global path
    $globalConfigPath = Join-Path $env:USERPROFILE ".gsd-global\config\global-config.json"
    if (Test-Path $globalConfigPath) {
        try {
            $config = Get-Content $globalConfigPath -Raw | ConvertFrom-Json
            if (-not $config.speed_optimizations -or -not $config.speed_optimizations.incremental_file_map -or
                -not $config.speed_optimizations.incremental_file_map.enabled) {
                if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
                    return Update-FileMap -Root $Root -GsdPath $GsdPath
                }
                return $null
            }
        } catch {}
    }

    # Get changed files since last file map update
    $changedFiles = @(git diff --name-only HEAD~1 HEAD 2>$null)
    $untrackedFiles = @(git ls-files --others --exclude-standard 2>$null)
    $allChanged = $changedFiles + $untrackedFiles | Select-Object -Unique

    if ($allChanged.Count -eq 0) {
        Write-Host "  [SPEED] File map unchanged (no file changes detected)" -ForegroundColor DarkGray
        return $null
    }

    # If more than 30% files changed, do full scan
    $totalFiles = @(git ls-files 2>$null).Count
    if ($totalFiles -gt 0 -and ($allChanged.Count / $totalFiles) -gt 0.3) {
        Write-Host "  [SPEED] >30% files changed -- doing full file map scan" -ForegroundColor DarkGray
        if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
            return Update-FileMap -Root $Root -GsdPath $GsdPath
        }
        return $null
    }

    Write-Host "  [SPEED] Incremental file map: $($allChanged.Count) files changed" -ForegroundColor DarkGray

    # Load existing file map and update only changed entries
    try {
        $fileMap = Get-Content $fileMapPath -Raw | ConvertFrom-Json
    } catch {
        if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
            return Update-FileMap -Root $Root -GsdPath $GsdPath
        }
        return $null
    }

    # Update the file map with changed files
    # For simplicity, update the tree view
    $treePath = Join-Path $GsdPath "file-map-tree.md"
    if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
        return Update-FileMap -Root $Root -GsdPath $GsdPath
    }

    return $fileMap
}

# Ã¢â€â‚¬Ã¢â€â‚¬ Enhanced Prompt Resolution with Deduplication Ã¢â€â‚¬Ã¢â€â‚¬

function Resolve-PromptWithDedup {
    param(
        [string]$PromptText,
        [string]$GlobalDir
    )

    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $dedupCfg = $config.speed_optimizations.prompt_deduplication
            if (-not $dedupCfg -or -not $dedupCfg.enabled) { return $PromptText }
        } catch { return $PromptText }
    } else { return $PromptText }

    # Inject {{SECURITY_STANDARDS}} if referenced
    if ($dedupCfg.inject_security_standards -and $PromptText -match '{{SECURITY_STANDARDS}}') {
        $secPath = Join-Path $GlobalDir "prompts\shared\security-standards.md"
        if (Test-Path $secPath) {
            $secContent = Get-Content $secPath -Raw
            $PromptText = $PromptText.Replace("{{SECURITY_STANDARDS}}", $secContent)
        }
    }

    # Inject {{CODING_CONVENTIONS}} if referenced
    if ($dedupCfg.inject_coding_conventions -and $PromptText -match '{{CODING_CONVENTIONS}}') {
        $convPath = Join-Path $GlobalDir "prompts\shared\coding-conventions.md"
        if (Test-Path $convPath) {
            $convContent = Get-Content $convPath -Raw
            $PromptText = $PromptText.Replace("{{CODING_CONVENTIONS}}", $convContent)
        }
    }

    return $PromptText
}

# ===========================================
# AGENT INTELLIGENCE
# ===========================================

# Ã¢â€â‚¬Ã¢â€â‚¬ Agent Performance Scoring Ã¢â€â‚¬Ã¢â€â‚¬

function Update-AgentPerformanceScore {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [string]$Agent,
        [string]$Phase,
        [int]$TokensUsed,
        [int]$RequirementsSatisfied,
        [int]$RequirementsRegressed,
        [int]$Iteration
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.agent_intelligence -or -not $config.agent_intelligence.performance_scoring -or
                -not $config.agent_intelligence.performance_scoring.enabled) { return }
        } catch { return }
    } else { return }

    # Load or create scores
    $scoresDir = Join-Path $GsdDir "intelligence"
    if (-not (Test-Path $scoresDir)) {
        New-Item -Path $scoresDir -ItemType Directory -Force | Out-Null
    }
    $scoresPath = Join-Path $scoresDir "agent-scores.json"

    $scores = @{}
    if (Test-Path $scoresPath) {
        try { $scores = Get-Content $scoresPath -Raw | ConvertFrom-Json -AsHashtable } catch { $scores = @{} }
    }

    # Initialize agent entry if missing
    if (-not $scores.ContainsKey($Agent)) {
        $scores[$Agent] = @{
            total_tokens             = 0
            total_requirements_done  = 0
            total_regressions        = 0
            samples                  = 0
            efficiency_score         = 0.0
            reliability_score        = 0.0
            overall_score            = 0.0
            history                  = @()
        }
    }

    $agentData = $scores[$Agent]
    $agentData.total_tokens += $TokensUsed
    $agentData.total_requirements_done += $RequirementsSatisfied
    $agentData.total_regressions += $RequirementsRegressed
    $agentData.samples += 1

    # Record history entry
    $agentData.history += @{
        iteration    = $Iteration
        phase        = $Phase
        tokens       = $TokensUsed
        satisfied    = $RequirementsSatisfied
        regressed    = $RequirementsRegressed
        timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # Keep last 50 entries
    if ($agentData.history.Count -gt 50) {
        $agentData.history = $agentData.history | Select-Object -Last 50
    }

    # Calculate scores
    if ($agentData.total_tokens -gt 0) {
        # Efficiency: requirements satisfied per 1000 tokens
        $agentData.efficiency_score = [math]::Round(($agentData.total_requirements_done / ($agentData.total_tokens / 1000)), 3)
    }

    if ($agentData.total_requirements_done -gt 0) {
        # Reliability: 1 - (regressions / total done)
        $agentData.reliability_score = [math]::Round(1 - ($agentData.total_regressions / $agentData.total_requirements_done), 3)
    } else {
        $agentData.reliability_score = 0
    }

    # Overall: weighted average (60% reliability, 40% efficiency normalized)
    $agentData.overall_score = [math]::Round(($agentData.reliability_score * 0.6) + ([math]::Min(1.0, $agentData.efficiency_score) * 0.4), 3)

    $scores[$Agent] = $agentData
    $scores | ConvertTo-Json -Depth 10 | Set-Content -Path $scoresPath -Encoding UTF8

    # Also update global intelligence
    $globalScoresDir = Join-Path $GlobalDir "intelligence"
    if (-not (Test-Path $globalScoresDir)) {
        New-Item -Path $globalScoresDir -ItemType Directory -Force | Out-Null
    }
    $globalScoresPath = Join-Path $globalScoresDir "agent-scores-global.json"

    $globalScores = @{}
    if (Test-Path $globalScoresPath) {
        try { $globalScores = Get-Content $globalScoresPath -Raw | ConvertFrom-Json -AsHashtable } catch { $globalScores = @{} }
    }

    if (-not $globalScores.ContainsKey($Agent)) {
        $globalScores[$Agent] = @{
            total_tokens = 0; total_requirements_done = 0; total_regressions = 0; samples = 0;
            efficiency_score = 0.0; reliability_score = 0.0; overall_score = 0.0;
            projects = @()
        }
    }

    $globalData = $globalScores[$Agent]
    $globalData.total_tokens += $TokensUsed
    $globalData.total_requirements_done += $RequirementsSatisfied
    $globalData.total_regressions += $RequirementsRegressed
    $globalData.samples += 1

    if ($globalData.total_tokens -gt 0) {
        $globalData.efficiency_score = [math]::Round(($globalData.total_requirements_done / ($globalData.total_tokens / 1000)), 3)
    }
    if ($globalData.total_requirements_done -gt 0) {
        $globalData.reliability_score = [math]::Round(1 - ($globalData.total_regressions / $globalData.total_requirements_done), 3)
    }
    $globalData.overall_score = [math]::Round(($globalData.reliability_score * 0.6) + ([math]::Min(1.0, $globalData.efficiency_score) * 0.4), 3)

    $globalScores[$Agent] = $globalData
    $globalScores | ConvertTo-Json -Depth 10 | Set-Content -Path $globalScoresPath -Encoding UTF8
}

function Get-BestAgentForPhase {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [string]$Phase,
        [string]$DefaultAgent
    )

    $scoresPath = Join-Path $GsdDir "intelligence\agent-scores.json"
    if (-not (Test-Path $scoresPath)) { return $DefaultAgent }

    try {
        $scores = Get-Content $scoresPath -Raw | ConvertFrom-Json -AsHashtable
    } catch { return $DefaultAgent }

    # Check config for min samples
    $minSamples = 3
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if ($config.agent_intelligence.performance_scoring.min_samples) {
                $minSamples = [int]$config.agent_intelligence.performance_scoring.min_samples
            }
        } catch {}
    }

    # Find best agent for this phase
    $bestAgent = $DefaultAgent
    $bestScore = -1

    foreach ($kvp in $scores.GetEnumerator()) {
        $agent = $kvp.Key
        $data = $kvp.Value
        if ($data.samples -ge $minSamples -and $data.overall_score -gt $bestScore) {
            # Check if this agent has history for the requested phase
            $phaseHistory = $data.history | Where-Object { $_.phase -eq $Phase }
            if ($phaseHistory.Count -ge $minSamples) {
                $bestScore = $data.overall_score
                $bestAgent = $agent
            }
        }
    }

    if ($bestAgent -ne $DefaultAgent) {
        Write-Host "  [INTELLIGENCE] Agent recommendation for $Phase`: $bestAgent (score: $bestScore) vs default: $DefaultAgent" -ForegroundColor Cyan
    }

    return $bestAgent
}

# Ã¢â€â‚¬Ã¢â€â‚¬ Warm-Start Pattern Cache Ã¢â€â‚¬Ã¢â€â‚¬

function Save-ProjectPatterns {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.agent_intelligence -or -not $config.agent_intelligence.warm_start -or
                -not $config.agent_intelligence.warm_start.enabled) { return }
        } catch { return }
    } else { return }

    # Detect project type
    $projectType = "unknown"
    $hasDotnet = (Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue).Count -gt 0
    $hasReact = $false
    $pkgJson = Join-Path $RepoRoot "package.json"
    if (Test-Path $pkgJson) {
        $pkg = Get-Content $pkgJson -Raw -ErrorAction SilentlyContinue
        $hasReact = $pkg -match '"react"'
    }

    if ($hasDotnet -and $hasReact) { $projectType = "dotnet-react" }
    elseif ($hasDotnet) { $projectType = "dotnet-api" }
    elseif ($hasReact) { $projectType = "react-spa" }

    # Save patterns to global cache
    $cacheDir = Join-Path $GlobalDir "intelligence"
    if (-not (Test-Path $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }

    $cachePath = Join-Path $cacheDir "pattern-cache.json"
    $cache = @{}
    if (Test-Path $cachePath) {
        try { $cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable } catch { $cache = @{} }
    }

    # Save detected patterns
    $patternsPath = Join-Path $GsdDir "assessment\detected-patterns.json"
    if (Test-Path $patternsPath) {
        $patterns = Get-Content $patternsPath -Raw

        if (-not $cache.ContainsKey($projectType)) {
            $cache[$projectType] = @{
                patterns = @()
                last_updated = ""
            }
        }

        $repoName = Split-Path $RepoRoot -Leaf
        $entry = @{
            repo     = $repoName
            patterns = $patterns
            saved    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        }

        # Update or add
        $existingIdx = -1
        for ($i = 0; $i -lt $cache[$projectType].patterns.Count; $i++) {
            if ($cache[$projectType].patterns[$i].repo -eq $repoName) {
                $existingIdx = $i; break
            }
        }

        if ($existingIdx -ge 0) {
            $cache[$projectType].patterns[$existingIdx] = $entry
        } else {
            $cache[$projectType].patterns += $entry
        }

        $cache[$projectType].last_updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

        $cache | ConvertTo-Json -Depth 10 | Set-Content -Path $cachePath -Encoding UTF8
        Write-Host "  [WARM] Saved project patterns to global cache (type: $projectType)" -ForegroundColor Green
    }
}

function Get-WarmStartPatterns {
    param(
        [string]$RepoRoot,
        [string]$GlobalDir
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.agent_intelligence -or -not $config.agent_intelligence.warm_start -or
                -not $config.agent_intelligence.warm_start.enabled) { return $null }
        } catch { return $null }
    } else { return $null }

    # Detect project type
    $projectType = "unknown"
    $hasDotnet = (Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue).Count -gt 0
    $hasReact = $false
    $pkgJson = Join-Path $RepoRoot "package.json"
    if (Test-Path $pkgJson) {
        $pkg = Get-Content $pkgJson -Raw -ErrorAction SilentlyContinue
        $hasReact = $pkg -match '"react"'
    }

    if ($hasDotnet -and $hasReact) { $projectType = "dotnet-react" }
    elseif ($hasDotnet) { $projectType = "dotnet-api" }
    elseif ($hasReact) { $projectType = "react-spa" }

    # Load global pattern cache
    $cachePath = Join-Path $GlobalDir "intelligence\pattern-cache.json"
    if (-not (Test-Path $cachePath)) { return $null }

    try {
        $cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable
    } catch { return $null }

    if ($cache.ContainsKey($projectType) -and $cache[$projectType].patterns.Count -gt 0) {
        $latest = $cache[$projectType].patterns | Select-Object -Last 1
        Write-Host "  [WARM] Loaded warm-start patterns for $projectType (from: $($latest.repo))" -ForegroundColor Green
        return $latest.patterns
    }

    return $null
}

# ===========================================
# LOC TRACKING (LINES OF CODE METRICS)
# ===========================================

function Update-LocMetrics {
    <#
    .SYNOPSIS
        Captures git diff stats after an execute phase commit and updates
        loc-metrics.json with per-iteration and cumulative LOC data.
        Cross-references cost-summary.json to compute cost-per-line.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [string]$Pipeline = "convergence"
    )

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.loc_tracking -or -not $config.loc_tracking.enabled) { return $null }
        } catch { return $null }
    } else { return $null }

    $excludePaths = @($config.loc_tracking.exclude_paths)
    $includeExts = @($config.loc_tracking.include_extensions)
    $trackPerFile = if ($config.loc_tracking.track_per_file) { $true } else { $false }
    $calcCostPerLine = if ($config.loc_tracking.cost_per_line) { $true } else { $false }

    # Get git diff stats for the last commit (execute phase output)
    $numstat = @()
    try {
        Push-Location $RepoRoot
        $numstat = @(git diff --numstat HEAD~1 HEAD 2>$null)
        Pop-Location
    } catch {
        Pop-Location
        return $null
    }

    if ($numstat.Count -eq 0) {
        Write-Host "  [LOC] No changes detected in last commit" -ForegroundColor DarkGray
        return $null
    }

    # Parse numstat output: "added<tab>deleted<tab>filename"
    $totalAdded = 0
    $totalDeleted = 0
    $filesChanged = 0
    $fileDetails = @()

    foreach ($line in $numstat) {
        if (-not $line -or $line -eq "") { continue }
        $parts = $line -split "\t"
        if ($parts.Count -lt 3) { continue }

        # Binary files show "-" for added/deleted
        if ($parts[0] -eq "-" -or $parts[1] -eq "-") { continue }

        $added = [int]$parts[0]
        $deleted = [int]$parts[1]
        $filePath = $parts[2]

        # Apply exclusion filters
        $excluded = $false
        foreach ($excl in $excludePaths) {
            $exclPattern = $excl -replace '\*', '.*' -replace '/', '[/\\]'
            if ($filePath -match $exclPattern) { $excluded = $true; break }
        }
        if ($excluded) { continue }

        # Apply inclusion filter (by extension)
        if ($includeExts.Count -gt 0) {
            $ext = [System.IO.Path]::GetExtension($filePath)
            if ($ext -and $ext -notin $includeExts) { continue }
        }

        $totalAdded += $added
        $totalDeleted += $deleted
        $filesChanged++

        if ($trackPerFile) {
            $fileDetails += @{
                file    = $filePath
                added   = $added
                deleted = $deleted
                net     = $added - $deleted
            }
        }
    }

    $netLines = $totalAdded - $totalDeleted

    Write-Host "  [LOC] Iteration ${Iteration}: +$totalAdded / -$totalDeleted (net $netLines) | $filesChanged files" -ForegroundColor Cyan

    # Load or create metrics file
    $costsDir = Join-Path $GsdDir "costs"
    if (-not (Test-Path $costsDir)) {
        New-Item -Path $costsDir -ItemType Directory -Force | Out-Null
    }
    $metricsPath = Join-Path $costsDir "loc-metrics.json"

    $metrics = $null
    if (Test-Path $metricsPath) {
        try { $metrics = Get-Content $metricsPath -Raw | ConvertFrom-Json } catch {}
    }
    if (-not $metrics) {
        $metrics = [PSCustomObject]@{
            pipeline           = $Pipeline
            started            = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            cumulative         = [PSCustomObject]@{
                lines_added    = 0
                lines_deleted  = 0
                lines_net      = 0
                files_changed  = 0
                iterations     = 0
            }
            cost_per_line      = [PSCustomObject]@{
                cost_per_added_line = 0
                cost_per_net_line   = 0
                total_cost_usd      = 0
            }
            iterations         = @()
        }
    }

    # Build iteration entry
    $iterEntry = [PSCustomObject]@{
        iteration     = $Iteration
        timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        lines_added   = $totalAdded
        lines_deleted = $totalDeleted
        lines_net     = $netLines
        files_changed = $filesChanged
    }

    if ($trackPerFile -and $fileDetails.Count -gt 0) {
        # Sort by most lines added, top 20
        $topFiles = $fileDetails | Sort-Object { $_.added } -Descending | Select-Object -First 20
        $iterEntry | Add-Member -NotePropertyName "top_files" -NotePropertyValue $topFiles
    }

    # Update cumulative
    $metrics.cumulative.lines_added = [int]$metrics.cumulative.lines_added + $totalAdded
    $metrics.cumulative.lines_deleted = [int]$metrics.cumulative.lines_deleted + $totalDeleted
    $metrics.cumulative.lines_net = [int]$metrics.cumulative.lines_net + $netLines
    $metrics.cumulative.files_changed = [int]$metrics.cumulative.files_changed + $filesChanged
    $metrics.cumulative.iterations = [int]$metrics.cumulative.iterations + 1

    # Append iteration
    $iters = @($metrics.iterations) + @($iterEntry)
    $metrics.iterations = $iters

    # Cross-reference with cost-summary.json for cost-per-line
    if ($calcCostPerLine) {
        $costPath = Join-Path $GsdDir "costs\cost-summary.json"
        if (Test-Path $costPath) {
            try {
                $costs = Get-Content $costPath -Raw | ConvertFrom-Json
                $totalCost = [double]$costs.total_cost_usd
                if ($totalCost -gt 0 -and [int]$metrics.cumulative.lines_added -gt 0) {
                    $metrics.cost_per_line.total_cost_usd = [math]::Round($totalCost, 4)
                    $metrics.cost_per_line.cost_per_added_line = [math]::Round($totalCost / [int]$metrics.cumulative.lines_added, 4)
                    if ([int]$metrics.cumulative.lines_net -gt 0) {
                        $metrics.cost_per_line.cost_per_net_line = [math]::Round($totalCost / [int]$metrics.cumulative.lines_net, 4)
                    }
                }
            } catch {}
        }
    }

    $metrics.last_updated = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

    # Save
    $metrics | ConvertTo-Json -Depth 10 | Set-Content -Path $metricsPath -Encoding UTF8

    return @{
        Added        = $totalAdded
        Deleted      = $totalDeleted
        Net          = $netLines
        Files        = $filesChanged
        CumAdded     = [int]$metrics.cumulative.lines_added
        CumDeleted   = [int]$metrics.cumulative.lines_deleted
        CumNet       = [int]$metrics.cumulative.lines_net
        CostPerLine  = $metrics.cost_per_line.cost_per_added_line
    }
}

function Get-LocNotificationText {
    <#
    .SYNOPSIS
        Reads loc-metrics.json and returns a compact one-line LOC string for ntfy notifications.
        Returns empty string if LOC tracking is not available.
    #>
    param(
        [string]$GsdDir,
        [switch]$Cumulative   # Show cumulative instead of last iteration
    )
    try {
        $metricsPath = Join-Path $GsdDir "costs\loc-metrics.json"
        if (-not (Test-Path $metricsPath)) { return "" }
        $m = Get-Content $metricsPath -Raw | ConvertFrom-Json

        if ($Cumulative) {
            $added = [int]$m.cumulative.lines_added
            $deleted = [int]$m.cumulative.lines_deleted
            $net = [int]$m.cumulative.lines_net
            $files = [int]$m.cumulative.files_changed
            if ($added -eq 0 -and $deleted -eq 0) { return "" }
            $line = "LOC total: +$added / -$deleted net $net | $files files"
            if ($m.cost_per_line -and [double]$m.cost_per_line.cost_per_added_line -gt 0) {
                $cpl = [math]::Round([double]$m.cost_per_line.cost_per_added_line, 4)
                $line += " | `$$cpl/line"
            }
            return $line
        } else {
            $iters = @($m.iterations)
            if ($iters.Count -eq 0) { return "" }
            $last = $iters[$iters.Count - 1]
            $added = [int]$last.lines_added
            $deleted = [int]$last.lines_deleted
            $net = [int]$last.lines_net
            $files = [int]$last.files_changed
            if ($added -eq 0 -and $deleted -eq 0) { return "" }
            $cplText = ""
            $metricsObj = $m
            if ($metricsObj.cost_per_line -and [double]$metricsObj.cost_per_line.cost_per_added_line -gt 0) {
                $cpl = [math]::Round([double]$metricsObj.cost_per_line.cost_per_added_line, 4)
                $cplText = " | `$$cpl/line"
            }
            return "LOC: +$added / -$deleted net $net | $files files$cplText"
        }
    } catch { return "" }
}


# ===============================================================
# GSD RUNTIME SMOKE TEST MODULES - appended to resilience.ps1
# ===============================================================

function Test-SeedDataFkOrder {
    <#
    .SYNOPSIS
        Static scan of SQL seed files to detect FK ordering violations.
        Zero-cost: no database connection or LLM calls needed.
    #>
    param(
        [string]$RepoRoot
    )

    $result = @{ Passed = $true; Violations = @(); TablesFound = @() }

    # Find SQL files that look like seed data
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git|bin|obj|migrations)" } |
        Sort-Object Name

    if (-not $sqlFiles -or $sqlFiles.Count -eq 0) { return $result }

    # Build FK dependency map from CREATE TABLE statements
    $fkMap = @{}   # child_table -> @(parent_table, ...)
    $insertOrder = [System.Collections.ArrayList]@()

    foreach ($sf in $sqlFiles) {
        $content = Get-Content $sf.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Extract CREATE TABLE ... FOREIGN KEY ... REFERENCES patterns
        $fkMatches = [regex]::Matches($content,
            'CREATE\s+TABLE\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?.*?FOREIGN\s+KEY.*?REFERENCES\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::Singleline)

        foreach ($m in $fkMatches) {
            $childTable = $m.Groups[1].Value.ToLower()
            $parentTable = $m.Groups[2].Value.ToLower()
            if (-not $fkMap.ContainsKey($childTable)) { $fkMap[$childTable] = @() }
            $fkMap[$childTable] += $parentTable
        }

        # Also catch inline FK: REFERENCES [Table](Column) in column definitions
        $inlineFkMatches = [regex]::Matches($content,
            'CREATE\s+TABLE\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?[^;]*?REFERENCES\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::Singleline)

        foreach ($m in $inlineFkMatches) {
            $childTable = $m.Groups[1].Value.ToLower()
            $parentTable = $m.Groups[2].Value.ToLower()
            if ($childTable -ne $parentTable) {
                if (-not $fkMap.ContainsKey($childTable)) { $fkMap[$childTable] = @() }
                if ($fkMap[$childTable] -notcontains $parentTable) {
                    $fkMap[$childTable] += $parentTable
                }
            }
        }

        # Track INSERT order across all files
        $insertMatches = [regex]::Matches($content,
            'INSERT\s+INTO\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        foreach ($m in $insertMatches) {
            $tableName = $m.Groups[1].Value.ToLower()
            if ($insertOrder -notcontains $tableName) {
                [void]$insertOrder.Add($tableName)
            }
        }
    }

    $result.TablesFound = @($insertOrder)

    # Check: for each child table INSERT, verify parent table was INSERTed first
    foreach ($childTable in $insertOrder) {
        if ($fkMap.ContainsKey($childTable)) {
            $childIdx = $insertOrder.IndexOf($childTable)
            foreach ($parentTable in $fkMap[$childTable]) {
                $parentIdx = $insertOrder.IndexOf($parentTable)
                if ($parentIdx -lt 0) {
                    $result.Violations += "FK MISSING: '$childTable' references '$parentTable' but '$parentTable' has no INSERT statement"
                    $result.Passed = $false
                } elseif ($parentIdx -gt $childIdx) {
                    $result.Violations += "FK ORDER: '$childTable' is INSERTed before its parent '$parentTable' (will cause FK violation)"
                    $result.Passed = $false
                }
            }
        }
    }

    return $result
}


function Find-ApiEndpoints {
    <#
    .SYNOPSIS
        Discovers API endpoints from controllers, route attributes, and OpenAPI specs.
        Returns list of @{ Method; Path } objects.
    #>
    param(
        [string]$RepoRoot
    )

    $endpoints = @()

    # Strategy 1: Parse .NET controller route attributes
    $controllers = Get-ChildItem -Path $RepoRoot -Filter "*Controller*.cs" -Recurse -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git|bin|obj|Tests?)" }

    foreach ($ctrl in $controllers) {
        $content = Get-Content $ctrl.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Extract class-level route prefix
        $classRoute = ""
        $classRouteMatch = [regex]::Match($content, '\[Route\("([^"]+)"\)\]')
        if ($classRouteMatch.Success) {
            $classRoute = $classRouteMatch.Groups[1].Value
            # Replace [controller] placeholder
            $ctrlName = [regex]::Match($ctrl.BaseName, '(\w+?)Controller').Groups[1].Value.ToLower()
            $classRoute = $classRoute -replace '\[controller\]', $ctrlName
        }

        # Extract method-level HTTP attributes
        $httpMethods = [regex]::Matches($content,
            '\[(Http(Get|Post|Put|Delete|Patch))(?:\("([^"]*)"\))?\]',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        foreach ($m in $httpMethods) {
            $method = $m.Groups[2].Value.ToUpper()
            $methodRoute = $m.Groups[3].Value

            $fullPath = if ($methodRoute) {
                if ($methodRoute.StartsWith("/")) { $methodRoute }
                elseif ($classRoute) { "$classRoute/$methodRoute".TrimEnd("/") }
                else { $methodRoute }
            } else { $classRoute }

            # Normalize: ensure starts with /
            if ($fullPath -and -not $fullPath.StartsWith("/")) { $fullPath = "/$fullPath" }

            # Replace route parameters with test values
            $testPath = $fullPath -replace '\{[^}]*:?int\}', '1' `
                                  -replace '\{[^}]*:?guid\}', '00000000-0000-0000-0000-000000000001' `
                                  -replace '\{[^}]*\}', 'test'

            if ($testPath) {
                $endpoints += @{ Method = $method; Path = $testPath; Source = $ctrl.Name }
            }
        }
    }

    # Strategy 2: Parse OpenAPI/Swagger JSON if available
    $swaggerFiles = Get-ChildItem -Path $RepoRoot -Filter "swagger*.json" -Recurse -Depth 3 -ErrorAction SilentlyContinue
    $swaggerFiles += Get-ChildItem -Path $RepoRoot -Filter "openapi*.json" -Recurse -Depth 3 -ErrorAction SilentlyContinue

    foreach ($sf in $swaggerFiles) {
        try {
            $spec = Get-Content $sf.FullName -Raw | ConvertFrom-Json
            if ($spec.paths) {
                $spec.paths.PSObject.Properties | ForEach-Object {
                    $path = $_.Name
                    $testPath = $path -replace '\{[^}]*\}', 'test'
                    $_.Value.PSObject.Properties | Where-Object { $_.Name -in @("get","post","put","delete","patch") } | ForEach-Object {
                        $endpoints += @{ Method = $_.Name.ToUpper(); Path = $testPath; Source = $sf.Name }
                    }
                }
            }
        } catch {}
    }

    # Deduplicate
    $seen = @{}
    $unique = @()
    foreach ($ep in $endpoints) {
        $key = "$($ep.Method):$($ep.Path)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $ep
        }
    }

    return $unique
}


function Invoke-ApiSmokeTest {
    <#
    .SYNOPSIS
        Starts the application, hits API endpoints, checks for non-500 responses.
        This is the primary runtime validation that catches DI errors, FK violations,
        and unhandled exceptions.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $result = @{
        Passed       = $true
        StartupOk    = $false
        EndpointsTested = 0
        Failures     = @()
        Warnings     = @()
        Details      = @()
        HealthCheck  = $null
    }

    # Load config
    $startupTimeout = 30
    $requestTimeout = 10
    $maxEndpoints = 50
    $healthEndpoint = "/api/health"
    $failOnAny500 = $true

    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = (Get-Content $configPath -Raw | ConvertFrom-Json).runtime_smoke_test
            if ($config) {
                if ($config.startup_timeout_seconds) { $startupTimeout = [int]$config.startup_timeout_seconds }
                if ($config.request_timeout_seconds) { $requestTimeout = [int]$config.request_timeout_seconds }
                if ($config.max_endpoints_to_test) { $maxEndpoints = [int]$config.max_endpoints_to_test }
                if ($config.health_endpoint) { $healthEndpoint = $config.health_endpoint }
                if ($null -ne $config.fail_on_any_500) { $failOnAny500 = $config.fail_on_any_500 }
            }
        } catch {}
    }

    # Find the .NET project to run
    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
    if (-not $slnFiles -or $slnFiles.Count -eq 0) {
        $result.Warnings += "No .sln found -- skipping runtime smoke test"
        return $result
    }

    # Find the web/API project (not test, not class library)
    $apiProject = Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "(Tests?|\.Test\.|test)" -and
            (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match "Microsoft\.NET\.Sdk\.Web"
        } | Select-Object -First 1

    if (-not $apiProject) {
        $result.Warnings += "No web/API .csproj found -- skipping runtime smoke test"
        return $result
    }

    # Determine port - check launchSettings.json
    $port = 5000
    $launchSettings = Join-Path (Split-Path $apiProject.FullName -Parent) "Properties\launchSettings.json"
    if (Test-Path $launchSettings) {
        try {
            $ls = Get-Content $launchSettings -Raw | ConvertFrom-Json
            $profiles = $ls.profiles.PSObject.Properties | Select-Object -First 1
            if ($profiles.Value.applicationUrl) {
                $urlMatch = [regex]::Match($profiles.Value.applicationUrl, 'https?://[^:]+:(\d+)')
                if ($urlMatch.Success) { $port = [int]$urlMatch.Groups[1].Value }
            }
        } catch {}
    }

    # Config override
    if ($config -and $config.port_override -and [int]$config.port_override -gt 0) {
        $port = [int]$config.port_override
    }

    $baseUrl = "http://localhost:$port"
    Write-Host "  [SMOKE] Starting app on port $port..." -ForegroundColor Cyan

    # Start the application
    $process = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "dotnet"
        $psi.Arguments = "run --project `"$($apiProject.FullName)`" --no-build --urls `"$baseUrl`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables["ASPNETCORE_ENVIRONMENT"] = "Development"
        $psi.EnvironmentVariables["DOTNET_ENVIRONMENT"] = "Development"

        $process = [System.Diagnostics.Process]::Start($psi)

        # Wait for startup - poll the health endpoint
        $startTime = Get-Date
        $ready = $false
        $startupError = ""

        while (((Get-Date) - $startTime).TotalSeconds -lt $startupTimeout) {
            Start-Sleep -Seconds 2

            # Check if process crashed
            if ($process.HasExited) {
                $stderr = $process.StandardError.ReadToEnd()
                $stdout = $process.StandardOutput.ReadToEnd()
                $startupError = "Application crashed on startup (exit code $($process.ExitCode))"

                # Extract specific error messages
                $allOutput = "$stderr`n$stdout"
                if ($allOutput -match "Cannot resolve scoped service") {
                    $startupError += "`nDI ERROR: Scoped service resolved from root provider"
                    $diMatch = [regex]::Match($allOutput, "Cannot resolve scoped service '([^']+)'")
                    if ($diMatch.Success) {
                        $startupError += " - Service: $($diMatch.Groups[1].Value)"
                    }
                }
                if ($allOutput -match "InvalidOperationException") {
                    $ioMatch = [regex]::Match($allOutput, "InvalidOperationException:\s*(.+?)(?:\r?\n|$)")
                    if ($ioMatch.Success) { $startupError += "`n$($ioMatch.Groups[1].Value)" }
                }
                if ($allOutput -match "SqlException") {
                    $sqlMatch = [regex]::Match($allOutput, "SqlException:\s*(.+?)(?:\r?\n|$)")
                    if ($sqlMatch.Success) { $startupError += "`nDB ERROR: $($sqlMatch.Groups[1].Value)" }
                }
                break
            }

            # Try to connect
            try {
                $response = Invoke-WebRequest -Uri "$baseUrl$healthEndpoint" -TimeoutSec 3 -ErrorAction Stop -UseBasicParsing
                if ($response.StatusCode -lt 500) {
                    $ready = $true
                    break
                }
            } catch {
                # Also try root endpoint as fallback
                try {
                    $response = Invoke-WebRequest -Uri "$baseUrl/" -TimeoutSec 3 -ErrorAction Stop -UseBasicParsing
                    if ($response.StatusCode -lt 500) {
                        $ready = $true
                        break
                    }
                } catch {
                    # Try swagger endpoint
                    try {
                        $response = Invoke-WebRequest -Uri "$baseUrl/swagger/index.html" -TimeoutSec 3 -ErrorAction Stop -UseBasicParsing
                        if ($response.StatusCode -lt 500) {
                            $ready = $true
                            break
                        }
                    } catch {
                        # Not ready yet, keep waiting
                    }
                }
            }
        }

        if (-not $ready) {
            if ($startupError) {
                $result.Failures += "STARTUP CRASH: $startupError"
            } else {
                $result.Failures += "STARTUP TIMEOUT: App did not respond within ${startupTimeout}s on $baseUrl"
            }
            $result.Passed = $false
            $result.StartupOk = $false
            return $result
        }

        $result.StartupOk = $true
        Write-Host "  [SMOKE] App ready. Testing endpoints..." -ForegroundColor Green

        # Test health endpoint specifically
        try {
            $healthResponse = Invoke-WebRequest -Uri "$baseUrl$healthEndpoint" -TimeoutSec $requestTimeout -ErrorAction Stop -UseBasicParsing
            $result.HealthCheck = @{
                StatusCode = $healthResponse.StatusCode
                Body = $healthResponse.Content.Substring(0, [math]::Min(500, $healthResponse.Content.Length))
            }
            if ($healthResponse.StatusCode -ge 500) {
                $result.Failures += "HEALTH ENDPOINT: $healthEndpoint returned $($healthResponse.StatusCode)"
                $result.Passed = $false
            } else {
                Write-Host "    [PASS] Health endpoint: $($healthResponse.StatusCode)" -ForegroundColor Green
            }
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -ge 500) {
                $result.Failures += "HEALTH ENDPOINT: $healthEndpoint returned $statusCode"
                $result.Passed = $false
                Write-Host "    [FAIL] Health endpoint: $statusCode" -ForegroundColor Red
            } elseif ($statusCode -eq 404) {
                $result.Warnings += "No health endpoint at $healthEndpoint (add HealthController)"
                Write-Host "    [WARN] Health endpoint not found (404)" -ForegroundColor Yellow
            } else {
                $result.Warnings += "Health endpoint error: $($_.Exception.Message)"
            }
        }

        # Discover and test API endpoints
        $endpoints = Find-ApiEndpoints -RepoRoot $RepoRoot
        if ($endpoints.Count -eq 0) {
            $result.Warnings += "No API endpoints discovered from controllers"
        } else {
            Write-Host "  [SMOKE] Found $($endpoints.Count) endpoints to test" -ForegroundColor Cyan

            $testCount = 0
            $failCount = 0

            foreach ($ep in ($endpoints | Select-Object -First $maxEndpoints)) {
                # Only smoke-test GET endpoints (safe, no side effects)
                if ($ep.Method -ne "GET") { continue }

                $testCount++
                $url = "$baseUrl$($ep.Path)"

                try {
                    $response = Invoke-WebRequest -Uri $url -Method GET -TimeoutSec $requestTimeout -ErrorAction Stop -UseBasicParsing
                    $detail = @{ endpoint = $ep.Path; method = $ep.Method; status = $response.StatusCode; result = "ok"; source = $ep.Source }
                    $result.Details += $detail

                    if ($response.StatusCode -ge 500) {
                        $failCount++
                        $result.Failures += "HTTP $($response.StatusCode): GET $($ep.Path) (from $($ep.Source))"
                        Write-Host "    [FAIL] GET $($ep.Path) -> $($response.StatusCode)" -ForegroundColor Red
                    } else {
                        Write-Host "    [PASS] GET $($ep.Path) -> $($response.StatusCode)" -ForegroundColor Green
                    }
                } catch {
                    $statusCode = 0
                    $errorBody = ""
                    if ($_.Exception.Response) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                        try {
                            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                            $errorBody = $reader.ReadToEnd()
                            $reader.Close()
                        } catch {}
                    }

                    $detail = @{ endpoint = $ep.Path; method = $ep.Method; status = $statusCode; result = "error"; error = $_.Exception.Message }
                    $result.Details += $detail

                    if ($statusCode -ge 500) {
                        $failCount++
                        $errorSummary = ""

                        # Extract meaningful error from response body
                        if ($errorBody -match "FOREIGN KEY constraint") {
                            $fkMatch = [regex]::Match($errorBody, 'FOREIGN KEY constraint "([^"]+)".*?table "([^"]+)"')
                            if ($fkMatch.Success) {
                                $errorSummary = "FK VIOLATION: $($fkMatch.Groups[1].Value) on $($fkMatch.Groups[2].Value)"
                            } else {
                                $errorSummary = "FK VIOLATION in response"
                            }
                        } elseif ($errorBody -match "Cannot resolve scoped service") {
                            $diMatch = [regex]::Match($errorBody, "Cannot resolve scoped service '([^']+)'")
                            $errorSummary = "DI ERROR: $(if ($diMatch.Success) { $diMatch.Groups[1].Value } else { 'scoped from root' })"
                        } elseif ($errorBody -match "SqlException") {
                            $sqlMatch = [regex]::Match($errorBody, "SqlException[^:]*:\s*(.+?)(?:\r?\n|$)")
                            $errorSummary = "DB ERROR: $(if ($sqlMatch.Success) { $sqlMatch.Groups[1].Value } else { 'SQL failure' })"
                        } else {
                            $errorSummary = "HTTP $statusCode"
                        }

                        $result.Failures += "${errorSummary}: GET $($ep.Path) (from $($ep.Source))"
                        Write-Host "    [FAIL] GET $($ep.Path) -> $statusCode ($errorSummary)" -ForegroundColor Red
                    } elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                        # Auth-protected endpoints are expected to reject anonymous requests
                        Write-Host "    [SKIP] GET $($ep.Path) -> $statusCode (auth required)" -ForegroundColor DarkGray
                    } elseif ($statusCode -eq 404) {
                        $result.Warnings += "Endpoint not found: GET $($ep.Path)"
                        Write-Host "    [WARN] GET $($ep.Path) -> 404" -ForegroundColor Yellow
                    } else {
                        Write-Host "    [PASS] GET $($ep.Path) -> $statusCode" -ForegroundColor Green
                    }
                }
            }

            $result.EndpointsTested = $testCount

            if ($failCount -gt 0 -and $failOnAny500) {
                $result.Passed = $false
            }
        }

    } catch {
        $result.Failures += "Smoke test error: $($_.Exception.Message)"
        $result.Passed = $false
    } finally {
        # Kill the application process
        if ($process -and -not $process.HasExited) {
            try {
                $process.Kill($true)  # Kill process tree
                $process.WaitForExit(5000)
            } catch {}
        }
        if ($process) { $process.Dispose() }
    }

    # Save results
    $testDir = Join-Path $GsdDir "tests"
    if (-not (Test-Path $testDir)) {
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
    }
    $smokeResultsPath = Join-Path $testDir "smoke-test-results.json"
    @{
        iteration        = $Iteration
        timestamp        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed           = $result.Passed
        startup_ok       = $result.StartupOk
        endpoints_tested = $result.EndpointsTested
        failures         = $result.Failures
        warnings         = $result.Warnings
        health_check     = $result.HealthCheck
        endpoint_details = $result.Details
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $smokeResultsPath -Encoding UTF8

    return $result
}


function Invoke-RuntimeSmokeTest {
    <#
    .SYNOPSIS
        Orchestrator that runs all runtime checks: seed FK order, DI validation,
        and API smoke test. Called from Invoke-FinalValidation as checks 8-10.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $result = @{
        Passed       = $true
        HardFailures = @()
        Warnings     = @()
        SeedCheck    = $null
        SmokeTest    = $null
    }

    # Check if enabled
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = (Get-Content $configPath -Raw | ConvertFrom-Json).runtime_smoke_test
            if ($config -and $config.enabled -eq $false) {
                Write-Host "  [SMOKE] Runtime smoke test disabled" -ForegroundColor DarkGray
                return $result
            }
        } catch {}
    }

    Write-Host ""
    Write-Host "  [SMOKE] === Runtime Smoke Test ===" -ForegroundColor Cyan

    # --- Check A: Seed Data FK Order ---
    Write-Host "  [SMOKE] Check A: Seed data FK ordering..." -ForegroundColor Cyan
    try {
        $seedResult = Test-SeedDataFkOrder -RepoRoot $RepoRoot
        $result.SeedCheck = $seedResult

        if (-not $seedResult.Passed) {
            foreach ($v in $seedResult.Violations) {
                $result.HardFailures += $v
                Write-Host "    [FAIL] $v" -ForegroundColor Red
            }
            $result.Passed = $false
        } else {
            $tableCount = if ($seedResult.TablesFound) { $seedResult.TablesFound.Count } else { 0 }
            Write-Host "    [PASS] $tableCount tables, FK ordering correct" -ForegroundColor Green
        }
    } catch {
        $result.Warnings += "Seed FK check error: $($_.Exception.Message)"
        Write-Host "    [WARN] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # --- Check B: Runtime API Smoke Test ---
    Write-Host "  [SMOKE] Check B: Runtime API smoke test..." -ForegroundColor Cyan
    try {
        $smokeResult = Invoke-ApiSmokeTest -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GlobalDir -Iteration $Iteration
        $result.SmokeTest = $smokeResult

        if (-not $smokeResult.Passed) {
            foreach ($f in $smokeResult.Failures) {
                $result.HardFailures += "RUNTIME: $f"
            }
            $result.Passed = $false
        }
        foreach ($w in $smokeResult.Warnings) {
            $result.Warnings += $w
        }
    } catch {
        $result.Warnings += "API smoke test error: $($_.Exception.Message)"
        Write-Host "    [WARN] Smoke test error: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Summary
    if ($result.Passed) {
        Write-Host "  [SMOKE] === ALL RUNTIME CHECKS PASSED ===" -ForegroundColor Green
    } else {
        Write-Host "  [SMOKE] === $($result.HardFailures.Count) RUNTIME FAILURE(S) ===" -ForegroundColor Red
        Write-Host "  [SMOKE] Health will be set to 99% for auto-fix loop" -ForegroundColor Yellow
    }

    return $result
}

Write-Host "  Runtime smoke test modules loaded." -ForegroundColor DarkGray


# ===========================================
# RUNTIME SMOKE TEST INTEGRATION
# ===========================================

# Wrap original Invoke-FinalValidation to add runtime checks
if (Get-Command Invoke-FinalValidation -ErrorAction SilentlyContinue) {
    # Save reference to original
    $script:OriginalFinalValidation = ${function:Invoke-FinalValidation}

    function Invoke-FinalValidation {
        param(
            [string]$RepoRoot,
            [string]$GsdDir,
            [int]$Iteration
        )

        # Run original 7 checks
        $result = & $script:OriginalFinalValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration

        # Run runtime smoke test (checks 8-10)
        $globalDir = Join-Path $env:USERPROFILE ".gsd-global"
        if (Get-Command Invoke-RuntimeSmokeTest -ErrorAction SilentlyContinue) {
            Write-Host ""
            Write-Host "  [SHIELD] Running runtime smoke tests (checks 8-10)..." -ForegroundColor Yellow

            $runtimeResult = Invoke-RuntimeSmokeTest -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $globalDir -Iteration $Iteration

            # Merge runtime failures into main result
            if (-not $runtimeResult.Passed) {
                $result.Passed = $false
                foreach ($f in $runtimeResult.HardFailures) {
                    $result.HardFailures += $f
                }
            }
            foreach ($w in $runtimeResult.Warnings) {
                $result.Warnings += $w
            }

            # Add to details
            $result.Details["seed_fk_check"] = $runtimeResult.SeedCheck
            $result.Details["api_smoke_test"] = $runtimeResult.SmokeTest

            # Update saved results
            $jsonPath = Join-Path $GsdDir "health\final-validation.json"
            @{
                passed        = $result.Passed
                hard_failures = $result.HardFailures
                warnings      = $result.Warnings
                iteration     = $Iteration
                timestamp     = $result.Timestamp
                checks        = @{
                    dotnet_build   = $result.Details["dotnet_build"]
                    npm_build      = $result.Details["npm_build"]
                    dotnet_test    = $result.Details["dotnet_test"]
                    npm_test       = $result.Details["npm_test"]
                    sql            = $result.Details["sql_validation"]
                    dotnet_audit   = $result.Details["dotnet_audit"]
                    npm_audit      = $result.Details["npm_audit"]
                    seed_fk_check  = $result.Details["seed_fk_check"]
                    api_smoke_test = $result.Details["api_smoke_test"]
                }
            } | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8

            # Log runtime failures
            if (-not $runtimeResult.Passed -and (Get-Command Write-GsdError -ErrorAction SilentlyContinue)) {
                Write-GsdError -GsdDir $GsdDir -Category "runtime_failure" -Phase "smoke-test" `
                    -Iteration $Iteration -Message ($runtimeResult.HardFailures -join "; ")
            }
        }

        return $result
    }
}


# ===============================================================


# ===============================================================
# GSD PARTITIONED CODE REVIEW MODULES - appended to resilience.ps1
# ===============================================================

# Agent rotation matrix: maps (iteration % 7) to agent assignments for partitions A-G
$script:PARTITION_ROTATION = @(
    @{ A = "claude";   B = "codex";    C = "gemini";  D = "kimi";     E = "deepseek"; F = "glm5";     G = "minimax" } # Iter 1
    @{ A = "minimax";  B = "claude";   C = "codex";   D = "gemini";   E = "kimi";     F = "deepseek"; G = "glm5"    } # Iter 2
    @{ A = "glm5";     B = "minimax";  C = "claude";  D = "codex";    E = "gemini";   F = "kimi";     G = "deepseek" } # Iter 3
    @{ A = "deepseek"; B = "glm5";     C = "minimax"; D = "claude";   E = "codex";    F = "gemini";   G = "kimi"     } # Iter 4
    @{ A = "kimi";     B = "deepseek"; C = "glm5";     D = "minimax";  E = "claude";   F = "codex";    G = "gemini"   } # Iter 5
    @{ A = "gemini";   B = "kimi";     C = "deepseek"; D = "glm5";     E = "minimax";  F = "claude";   G = "codex"    } # Iter 6
    @{ A = "codex";    B = "gemini";   C = "kimi";     D = "deepseek"; E = "glm5";     F = "minimax";  G = "claude"   } # Iter 7
)


function Split-RequirementsIntoPartitions {
    <#
    .SYNOPSIS
        Splits requirements matrix into 7 roughly equal partitions.
        Each partition includes the requirement IDs and their associated files.
    #>
    param(
        [string]$GsdDir,
        [int]$PartitionCount = 7
    )

    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        Write-Host "  [WARN] No requirements-matrix.json found" -ForegroundColor Yellow
        return $null
    }

    try {
        $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
        $reqs = @($matrix.requirements)
    } catch {
        Write-Host "  [WARN] Failed to parse requirements-matrix.json" -ForegroundColor Yellow
        return $null
    }

    if ($reqs.Count -lt $PartitionCount) {
        Write-Host "  [WARN] Only $($reqs.Count) requirements -- too few to partition" -ForegroundColor Yellow
        return $null
    }

    # Sort requirements: not_started first, then partial, then satisfied
    $sorted = $reqs | Sort-Object @{
        Expression = {
            switch ($_.status) {
                "not_started" { 0 }
                "partial"     { 1 }
                "satisfied"   { 2 }
                default       { 3 }
            }
        }
    }

    # Round-robin distribute to ensure even split
    $partitions = @()
    for ($i = 0; $i -lt $PartitionCount; $i++) {
        $partitions += ,@()
    }

    $idx = 0
    foreach ($req in $sorted) {
        $partitions[$idx % $PartitionCount] += $req
        $idx++
    }

    # Build partition objects with file lists
    $labels = @("A", "B", "C", "D", "E", "F", "G")
    $result = @()
    for ($i = 0; $i -lt $PartitionCount; $i++) {
        $reqIds = @($partitions[$i] | ForEach-Object { $_.id })
        $files = @($partitions[$i] | ForEach-Object {
            if ($_.satisfied_by) { $_.satisfied_by }
            elseif ($_.files) { $_.files }
            elseif ($_.target_files) { $_.target_files }
        } | Where-Object { $_ } | Select-Object -Unique)

        # Format requirements as table for prompt injection
        $reqTable = "| ID | Description | Current Status |`n|-----|-------------|----------------|"
        foreach ($r in $partitions[$i]) {
            $desc = if ($r.description -and $r.description.Length -gt 60) { $r.description.Substring(0, 60) + "..." } else { $r.description }
            $reqTable += "`n| $($r.id) | $desc | $($r.status) |"
        }

        $result += @{
            Label         = $labels[$i]
            Requirements  = $partitions[$i]
            RequirementIds = $reqIds
            Files         = $files
            ReqTable      = $reqTable
            Count         = $partitions[$i].Count
        }
    }

    return $result
}


function Get-SpecAndFigmaPaths {
    <#
    .SYNOPSIS
        Discovers spec documents and Figma analysis files in the project.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir
    )

    $specPaths = @()
    $figmaPaths = @()

    # Spec files: look in .gsd/specs/, design/, docs/
    $specDirs = @(
        (Join-Path $GsdDir "specs"),
        (Join-Path $RepoRoot "design"),
        (Join-Path $RepoRoot "docs"),
        (Join-Path $RepoRoot "_analysis")
    )
    foreach ($dir in $specDirs) {
        if (Test-Path $dir) {
            $specFiles = Get-ChildItem -Path $dir -Filter "*.md" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch "(figma|screenshot|visual)" }
            foreach ($sf in $specFiles) {
                $relPath = $sf.FullName.Replace("$RepoRoot\", "").Replace("$GsdDir\", ".gsd\")
                $specPaths += $relPath
            }
        }
    }

    # Figma analysis files: look in design/*/_analysis/, .gsd/specs/figma*
    $figmaDirs = @(
        (Join-Path $RepoRoot "design"),
        (Join-Path $GsdDir "specs")
    )
    foreach ($dir in $figmaDirs) {
        if (Test-Path $dir) {
            $figmaFiles = Get-ChildItem -Path $dir -Filter "*.md" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "(figma|_analysis|storyboard|visual|screenshot)" }
            foreach ($ff in $figmaFiles) {
                $relPath = $ff.FullName.Replace("$RepoRoot\", "").Replace("$GsdDir\", ".gsd\")
                $figmaPaths += $relPath
            }
        }
    }

    # Also look for Figma mapping in .gsd
    $figmaMapping = Join-Path $GsdDir "specs\figma-mapping.md"
    if ((Test-Path $figmaMapping) -and ($figmaPaths -notcontains ".gsd\specs\figma-mapping.md")) {
        $figmaPaths += ".gsd\specs\figma-mapping.md"
    }

    return @{
        SpecPaths  = $specPaths | Select-Object -Unique
        FigmaPaths = $figmaPaths | Select-Object -Unique
    }
}


function Invoke-PartitionedCodeReview {
    <#
    .SYNOPSIS
        Runs 3-partition parallel code review with agent rotation.
        Replaces single-agent code review when enabled.
    .RETURNS
        Hashtable with merged health score and combined review findings.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [double]$Health,
        [int]$CurrentBatchSize = 8,
        [string]$InterfaceContext = "",
        [switch]$DryRun
    )

    $result = @{
        Success    = $true
        Health     = $Health
        Error      = ""
        AgentMap   = @{}
        Partitions = @()
    }

    # Load config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    $pcConfig = $null
    if (Test-Path $configPath) {
        try {
            $pcConfig = (Get-Content $configPath -Raw | ConvertFrom-Json).partitioned_code_review
        } catch {}
    }

    if (-not $pcConfig -or -not $pcConfig.enabled) {
        $result.Success = $false
        $result.Error = "Partitioned code review disabled"
        return $result
    }

    $agents = @($pcConfig.agents)
    if ($agents.Count -lt 3) { $agents = @("claude", "codex", "gemini") }
    $cooldown = if ($pcConfig.cooldown_between_agents) { [int]$pcConfig.cooldown_between_agents } else { 5 }

    # 1. Split requirements into partitions
    Write-Host "  [PARTITION] Splitting requirements into 7 partitions..." -ForegroundColor Cyan
    $partitions = Split-RequirementsIntoPartitions -GsdDir $GsdDir -PartitionCount 7

    if (-not $partitions -or $partitions.Count -lt 7) {
        Write-Host "  [PARTITION] Cannot partition (too few requirements). Falling back to single review." -ForegroundColor Yellow
        $result.Success = $false
        $result.Error = "Too few requirements to partition"
        return $result
    }

    foreach ($p in $partitions) {
        Write-Host "    Partition $($p.Label): $($p.Count) requirements, $($p.Files.Count) files" -ForegroundColor DarkGray
    }

    # 2. Determine agent rotation for this iteration
    $rotationIdx = ($Iteration - 1) % 7
    $rotation = $script:PARTITION_ROTATION[$rotationIdx]

    Write-Host "  [PARTITION] Rotation (iter $Iteration -> slot $rotationIdx):" -ForegroundColor Cyan
    Write-Host "    A=$($rotation.A)  B=$($rotation.B)  C=$($rotation.C)  D=$($rotation.D)  E=$($rotation.E)  F=$($rotation.F)  G=$($rotation.G)" -ForegroundColor White
    $result.AgentMap = $rotation

    # 3. Discover spec and Figma paths
    $deliverables = Get-SpecAndFigmaPaths -RepoRoot $RepoRoot -GsdDir $GsdDir
    $specList = if ($deliverables.SpecPaths.Count -gt 0) {
        ($deliverables.SpecPaths | ForEach-Object { "- Read: ``$_``" }) -join "`n"
    } else { "- No spec documents found. Review code against requirements descriptions." }

    $figmaList = if ($deliverables.FigmaPaths.Count -gt 0) {
        ($deliverables.FigmaPaths | ForEach-Object { "- Read: ``$_``" }) -join "`n"
    } else { "- No Figma analysis files found. Skip Figma validation." }

    # 4. Build prompts for each partition
    $templateDir = Join-Path $GlobalDir "prompts\shared"
    $labels = @("A", "B", "C", "D", "E", "F", "G")
    $agentKeys = @("A", "B", "C", "D", "E", "F", "G")
    $prompts = @{}
    $logFiles = @{}

    foreach ($label in $labels) {
        $partition = $partitions | Where-Object { $_.Label -eq $label }
        $agent = $rotation[$label]
        $templateFile = Join-Path $templateDir "code-review-partition-$label.md"

        if (-not (Test-Path $templateFile)) {
            Write-Host "  [WARN] Template not found: code-review-partition-$label.md" -ForegroundColor Yellow
            continue
        }

        $template = Get-Content $templateFile -Raw

        # Resolve placeholders
        $fileList = if ($partition.Files.Count -gt 0) {
            ($partition.Files | ForEach-Object { "- ``$_``" }) -join "`n"
        } else { "- (No specific files mapped. Scan requirements descriptions for target files.)" }

        $prompt = $template.Replace("{{PARTITION_REQUIREMENTS}}", $partition.ReqTable)
        $prompt = $prompt.Replace("{{PARTITION_FILES}}", $fileList)
        $prompt = $prompt.Replace("{{SPEC_PATHS}}", $specList)
        $prompt = $prompt.Replace("{{FIGMA_PATHS}}", $figmaList)
        $prompt = $prompt.Replace("{{ITERATION}}", "$Iteration")
        $prompt = $prompt.Replace("{{AGENT_NAME}}", $agent)
        $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
        $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
        $prompt = $prompt.Replace("{{BATCH_SIZE}}", "$CurrentBatchSize")

        # Append interface context if available
        if ($InterfaceContext) {
            $prompt += "`n`n## Interface Context`n$InterfaceContext"
        }

        # Append file map
        $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
        if (Test-Path $fileTreePath) {
            $prompt += "`n`n## Repository File Map`nRead the tree file at: $fileTreePath"
        }

        # Append supervisor context
        $errorCtxPath = Join-Path $GsdDir "supervisor\error-context.md"
        $hintPath = Join-Path $GsdDir "supervisor\prompt-hints.md"
        if (Test-Path $errorCtxPath) { $prompt += "`n`n## Previous Iteration Errors`n" + (Get-Content $errorCtxPath -Raw) }
        if (Test-Path $hintPath) { $prompt += "`n`n## Supervisor Instructions`n" + (Get-Content $hintPath -Raw) }

        # Council feedback
        $councilFeedbackPath = Join-Path $GsdDir "supervisor\council-feedback.md"
        if (Test-Path $councilFeedbackPath) { $prompt += "`n`n" + (Get-Content $councilFeedbackPath -Raw) }

        $prompts[$label] = @{ Agent = $agent; Prompt = $prompt }
        $logFiles[$label] = Join-Path $GsdDir "logs\iter${Iteration}-1-partition-$label.log"
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would launch 3 parallel reviews" -ForegroundColor DarkGray
        return $result
    }

    # 5. Launch all 3 agents in parallel
    Write-Host "  [PARTITION] Launching 3 parallel reviews..." -ForegroundColor Cyan

    $jobs = @{}
    foreach ($label in $labels) {
        $entry = $prompts[$label]
        $agent = $entry.Agent
        $prompt = $entry.Prompt
        $logFile = $logFiles[$label]

        Write-Host "    $($agent.ToUpper()) -> Partition $label ($($partitions | Where-Object { $_.Label -eq $label } | ForEach-Object { $_.Count }) reqs)" -ForegroundColor Magenta

        # Determine allowed tools per agent type
        $allowedTools = switch ($agent) {
            "claude" { "Read,Write,Bash" }
            "codex"  { $null }  # codex manages its own tools
            "gemini" { $null }  # gemini manages its own tools
            default  { "Read,Write,Bash" }
        }

        # Use PowerShell jobs for parallel execution
        $jobParams = @{
            ScriptBlock = {
                param($GlobalDir, $Agent, $Prompt, $Phase, $LogFile, $BatchSize, $GsdDir, $AllowedTools, $GeminiMode)
                . "$GlobalDir\lib\modules\resilience.ps1"
                $invokeParams = @{
                    Agent = $Agent
                    Prompt = $Prompt
                    Phase = $Phase
                    LogFile = $LogFile
                    CurrentBatchSize = $BatchSize
                    GsdDir = $GsdDir
                }
                if ($AllowedTools) { $invokeParams["AllowedTools"] = $AllowedTools }
                if ($GeminiMode) { $invokeParams["GeminiMode"] = $GeminiMode }
                Invoke-WithRetry @invokeParams
            }
            ArgumentList = @(
                $GlobalDir,
                $agent,
                $prompt,
                "code-review",
                $logFile,
                $CurrentBatchSize,
                $GsdDir,
                $allowedTools,
                $(if ($agent -eq "gemini") { "--approval-mode plan" } else { $null })
            )
        }

        $jobs[$label] = Start-Job @jobParams

        # Small cooldown between launches to avoid burst
        if ($cooldown -gt 0) { Start-Sleep -Seconds $cooldown }
    }

    # 6. Wait for all jobs to complete
    $timeout = if ($pcConfig.timeout_seconds) { [int]$pcConfig.timeout_seconds } else { 900 }
    Write-Host "  [PARTITION] Waiting for all 7 reviews (timeout: ${timeout}s)..." -ForegroundColor Cyan

    $completedJobs = @{}
    $failedPartitions = @()

    foreach ($label in $labels) {
        $job = $jobs[$label]
        $agent = $prompts[$label].Agent

        try {
            $jobResult = $job | Wait-Job -Timeout $timeout | Receive-Job -ErrorAction SilentlyContinue
            if ($job.State -eq "Completed") {
                $completedJobs[$label] = $jobResult
                Write-Host "    [PASS] Partition $label ($agent) completed" -ForegroundColor Green
            } else {
                $failedPartitions += $label
                Write-Host "    [FAIL] Partition $label ($agent) timed out or failed" -ForegroundColor Red
            }
        } catch {
            $failedPartitions += $label
            Write-Host "    [FAIL] Partition $label ($agent): $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    # 7. Merge partition results
    Write-Host "  [PARTITION] Merging results from $($completedJobs.Count)/7 partitions..." -ForegroundColor Cyan

    $mergeResult = Merge-PartitionedReviews -GsdDir $GsdDir -Partitions $partitions `
        -CompletedLabels @($completedJobs.Keys) -FailedLabels $failedPartitions `
        -Rotation $rotation -Iteration $Iteration

    $result.Health = $mergeResult.Health
    $result.Partitions = $partitions

    if ($failedPartitions.Count -gt 0) {
        $result.Error = "Partitions failed: $($failedPartitions -join ', ')"
        if ($failedPartitions.Count -ge 7) {
            $result.Success = $false
        }
    }

    # 8. Save rotation history
    $rotHistoryPath = Join-Path $GsdDir "code-review\rotation-history.jsonl"
    $rotEntry = @{
        iteration = $Iteration
        rotation_slot = $rotationIdx
        agent_map = $rotation
        partitions = @($partitions | ForEach-Object { @{ label=$_.Label; count=$_.Count; req_ids=$_.RequirementIds } })
        completed = @($completedJobs.Keys)
        failed = $failedPartitions
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json -Compress -Depth 4
    Add-Content -Path $rotHistoryPath -Value $rotEntry -Encoding UTF8

    # Show coverage summary
    $coverageFile = Join-Path $GsdDir "code-review\coverage-matrix.json"
    Update-CoverageMatrix -GsdDir $GsdDir -Iteration $Iteration -Rotation $rotation `
        -CompletedLabels @($completedJobs.Keys) -PartitionReqIds @(
            $partitions | ForEach-Object { @{ Label=$_.Label; ReqIds=$_.RequirementIds } }
        )

    return $result
}


function Merge-PartitionedReviews {
    <#
    .SYNOPSIS
        Merges partition review outputs into unified health score and review files.
    #>
    param(
        [string]$GsdDir,
        [array]$Partitions,
        [array]$CompletedLabels,
        [array]$FailedLabels,
        [hashtable]$Rotation,
        [int]$Iteration
    )

    $result = @{ Health = 0; MergedReview = "" }

    # Re-read the requirements matrix (agents may have updated it)
    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    if (Test-Path $matrixPath) {
        try {
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            $reqs = @($matrix.requirements)
            $total = $reqs.Count
            $satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
            $health = if ($total -gt 0) { [math]::Round(($satisfied / $total) * 100, 1) } else { 0 }

            # Update health
            $matrix.meta.health_score = $health
            $matrix.meta.satisfied = $satisfied
            $matrix.meta.iteration = $Iteration
            $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

            # Update health file
            $healthFile = Join-Path $GsdDir "health\health-current.json"
            @{
                health_score = $health
                total_requirements = $total
                satisfied = $satisfied
                partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
                not_started = @($reqs | Where-Object { $_.status -eq "not_started" }).Count
                iteration = $Iteration
            } | ConvertTo-Json | Set-Content $healthFile -Encoding UTF8

            # Append to health history
            $historyPath = Join-Path $GsdDir "health\health-history.jsonl"
            @{ iteration=$Iteration; health_score=$health; satisfied=$satisfied; total=$total; timestamp=(Get-Date -Format "o"); review_type="partitioned" } |
                ConvertTo-Json -Compress | Add-Content $historyPath -Encoding UTF8

            $result.Health = $health
        } catch {
            Write-Host "  [WARN] Failed to merge health: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Merge partition reviews into unified review-current.md
    $mergedLines = @("# Code Review - Iteration $Iteration (Partitioned)", "")
    $mergedLines += "| Partition | Agent | Status |"
    $mergedLines += "|-----------|-------|--------|"

    $labels = @("A", "B", "C", "D", "E", "F", "G")
    foreach ($label in $labels) {
        $agent = $Rotation[$label]
        $status = if ($CompletedLabels -contains $label) { "Completed" } else { "FAILED" }
        $mergedLines += "| $label | $agent | $status |"
    }
    $mergedLines += ""

    foreach ($label in $labels) {
        $partReviewPath = Join-Path $GsdDir "code-review\partition-$label-review.md"
        if (Test-Path $partReviewPath) {
            $content = (Get-Content $partReviewPath -Raw).Trim()
            $mergedLines += $content
            $mergedLines += ""
        }
    }

    # Merge drift reports
    $mergedDrift = @()
    foreach ($label in $labels) {
        $driftPath = Join-Path $GsdDir "code-review\partition-$label-drift.md"
        if (Test-Path $driftPath) {
            $content = (Get-Content $driftPath -Raw).Trim()
            if ($content.Length -gt 5) {
                $mergedDrift += "### Partition $label ($($Rotation[$label]))"
                $mergedDrift += $content
                $mergedDrift += ""
            }
        }
    }

    # Write merged files
    $reviewPath = Join-Path $GsdDir "code-review\review-current.md"
    ($mergedLines -join "`n") | Set-Content $reviewPath -Encoding UTF8

    $driftPath = Join-Path $GsdDir "health\drift-report.md"
    if ($mergedDrift.Count -gt 0) {
        ($mergedDrift -join "`n") | Set-Content $driftPath -Encoding UTF8
    }

    $result.MergedReview = $reviewPath
    return $result
}


function Update-CoverageMatrix {
    <#
    .SYNOPSIS
        Tracks which agent has reviewed which requirements across iterations.
        After 7 iterations, every requirement should be reviewed by all 7 agents.
    #>
    param(
        [string]$GsdDir,
        [int]$Iteration,
        [hashtable]$Rotation,
        [array]$CompletedLabels,
        [array]$PartitionReqIds
    )

    $coveragePath = Join-Path $GsdDir "code-review\coverage-matrix.json"
    $coverage = @{}

    if (Test-Path $coveragePath) {
        try { $coverage = Get-Content $coveragePath -Raw | ConvertFrom-Json -AsHashtable } catch { $coverage = @{} }
    }

    # Update coverage for completed partitions
    foreach ($pInfo in $PartitionReqIds) {
        $label = $pInfo.Label
        if ($CompletedLabels -notcontains $label) { continue }

        $agent = $Rotation[$label]
        foreach ($reqId in $pInfo.ReqIds) {
            if (-not $coverage.ContainsKey($reqId)) {
                $coverage[$reqId] = @{}
            }
            $coverage[$reqId][$agent] = $Iteration
        }
    }

    # Save and report
    $coverage | ConvertTo-Json -Depth 4 | Set-Content $coveragePath -Encoding UTF8

    # Count full-coverage requirements (reviewed by all 7 agents)
    $fullCoverage = 0
    $totalReqs = $coverage.Keys.Count
    foreach ($reqId in $coverage.Keys) {
        if ($coverage[$reqId].Keys.Count -ge 7) { $fullCoverage++ }
    }

    Write-Host "  [COVERAGE] $fullCoverage/$totalReqs requirements reviewed by all 7 agents" -ForegroundColor $(if ($fullCoverage -eq $totalReqs) { "Green" } else { "Yellow" })
}

Write-Host "  Partitioned code review modules loaded." -ForegroundColor DarkGray

# ===========================================
# 7-MODEL OPTIMIZATION: PARALLEL RESEARCH
# ===========================================

function Invoke-ParallelResearch {
    <#
    .SYNOPSIS
        Dispatches research across 3 agents in parallel: Gemini (Phase A+B),
        DeepSeek (Phase C+D), Kimi (Phase E+Figma). Merges outputs into
        research-findings.md for the planner.
    #>
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration,
        [decimal]$Health,
        [string]$RepoRoot,
        [string]$InterfaceContext = ""
    )

    $result = @{ Success = $false; Error = "" }

    # Load config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (-not (Test-Path $configPath)) { $result.Error = "global-config.json not found"; return $result }
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
    } catch { $result.Error = "Failed to parse global-config.json"; return $result }

    if (-not $config.parallel_research -or -not $config.parallel_research.enabled) {
        $result.Error = "parallel_research not enabled in global-config.json"
        return $result
    }

    $researchCfg = $config.parallel_research
    $timeoutSec  = [int]$researchCfg.timeout_minutes * 60

    # Resolve Figma path for prompt injection
    $figmaPath = Join-Path $RepoRoot "design\figma"
    if (-not (Test-Path $figmaPath)) { $figmaPath = Join-Path $RepoRoot "design" }

    # Dispatch one job per agent config
    $jobs = @()
    foreach ($agentCfg in $researchCfg.agents) {
        $agentName  = $agentCfg.agent
        $promptDir  = if ($agentCfg.prompt_dir) { $agentCfg.prompt_dir } else { "shared" }
        $promptFile = Join-Path $GlobalDir "prompts\$promptDir\$($agentCfg.prompt)"

        if (-not (Test-Path $promptFile)) {
            Write-Host "  [PAR-RESEARCH] Prompt not found for $agentName ($promptFile) -- skipping" -ForegroundColor Yellow
            continue
        }

        $phases = if ($agentCfg.phases) { ($agentCfg.phases -join "+") } else { "?" }
        Write-Host "  [PAR-RESEARCH] Dispatching $agentName -> Phase $phases" -ForegroundColor DarkCyan

        $job = Start-Job -Name "gsd-research-$agentName" -ScriptBlock {
            param($Agent, $PromptFile, $GsdDir, $GlobalDir, $Iteration, $Health, $RepoRoot, $FigmaPath, $InterfaceContext)

            . "$GlobalDir\lib\modules\resilience.ps1"

            $promptText = Get-Content $PromptFile -Raw
            $promptText = $promptText.Replace("{{ITERATION}}", "$Iteration")
            $promptText = $promptText.Replace("{{HEALTH}}",    "$Health")
            $promptText = $promptText.Replace("{{GSD_DIR}}",   $GsdDir)
            $promptText = $promptText.Replace("{{REPO_ROOT}}", $RepoRoot)
            $promptText = $promptText.Replace("{{FIGMA_PATH}}", $FigmaPath)
            $promptText = $promptText.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

            $logFile = "$GsdDir\logs\iter${Iteration}-2-research-${Agent}.log"

            $subResult = Invoke-WithRetry -Agent $Agent -Prompt $promptText `
                -Phase "research" -LogFile $logFile `
                -CurrentBatchSize 1 -GsdDir $GsdDir `
                -MaxAttempts 2

            return @{ Agent = $Agent; Success = $subResult.Success; Error = $subResult.Error }
        } -ArgumentList $agentName, $promptFile, $GsdDir, $GlobalDir, $Iteration, $Health, $RepoRoot, $figmaPath, $InterfaceContext

        $jobs += $job
    }

    if ($jobs.Count -eq 0) {
        $result.Error = "No parallel research agents could be dispatched"
        return $result
    }

    # Wait for all jobs
    $jobs | Wait-Job -Timeout $timeoutSec | Out-Null

    $succeeded = 0
    $failed    = 0
    foreach ($job in $jobs) {
        $jr = $null
        if ($job.State -eq "Completed") {
            $jr = Receive-Job $job -ErrorAction SilentlyContinue
        }
        if ($jr -and $jr.Success) {
            $succeeded++
            Write-Host "  [PAR-RESEARCH] $($jr.Agent): OK" -ForegroundColor Green
        } else {
            $failed++
            $errMsg = if ($jr) { $jr.Error } else { "timed out or crashed" }
            Write-Host "  [PAR-RESEARCH] $($job.Name): FAIL ($errMsg)" -ForegroundColor Yellow
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }

    # Merge sub-findings into unified research-findings.md for the planner
    if ($succeeded -gt 0) {
        $mergedPath = Join-Path $GsdDir "research\research-findings.md"
        $merged     = "# Research Findings -- Parallel (Iteration $Iteration)`n`n"
        $merged    += "> Generated by 3-agent parallel research: Gemini (Phase A+B), DeepSeek (Phase C+D), Kimi (Phase E+Figma)`n`n"

        foreach ($suffix in @("ab", "cd", "e-figma")) {
            $subFile = Join-Path $GsdDir "research\research-findings-$suffix.md"
            if (Test-Path $subFile) {
                $subContent = Get-Content $subFile -Raw
                $merged += $subContent.Trim() + "`n`n---`n`n"
            }
        }

        $merged | Set-Content $mergedPath -Encoding UTF8
        Write-Host "  [PAR-RESEARCH] Merged research-findings.md ($succeeded/$($succeeded+$failed) agents OK)" -ForegroundColor Green
        $result.Success = $true
    } else {
        $result.Error = "All parallel research agents failed"
    }

    return $result
}

# ===========================================
# 7-MODEL OPTIMIZATION: COMPLEXITY ROUTING
# ===========================================

function Get-AgentForComplexity {
    <#
    .SYNOPSIS
        Returns the best available agent for a given requirement complexity level.
        Falls back to round-robin if complexity routing is disabled or no preferred
        agent is in the available pool.
    #>
    param(
        [string]$Complexity,       # low | medium | high
        [string]$GlobalDir,
        [string[]]$AvailableAgents,
        [int]$Index = 0            # for round-robin fallback
    )

    $fallback = $AvailableAgents[$Index % $AvailableAgents.Count]

    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (-not (Test-Path $configPath)) { return $fallback }

    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if (-not $config.complexity_routing -or -not $config.complexity_routing.enabled) {
            return $fallback
        }

        $preferred = switch ($Complexity) {
            "low"    { @($config.complexity_routing.low.preferred_agents) }
            "medium" { @($config.complexity_routing.medium.preferred_agents) }
            "high"   { @($config.complexity_routing.high.preferred_agents) }
            default  { @() }
        }

        foreach ($p in $preferred) {
            if ($AvailableAgents -contains $p) {
                if ($p -ne $fallback) {
                    Write-Host "  [COMPLEXITY] $Complexity requirement -> $p (preferred over round-robin: $fallback)" -ForegroundColor DarkCyan
                }
                return $p
            }
        }
    } catch {}

    return $fallback
}

# ===============================================================
# GSD COUNCIL REQUIREMENTS MODULE - appended to resilience.ps1
# Partitioned extract + cross-verify: each agent reads 1/3,
# then a different agent verifies the extraction
# ===============================================================

function Get-SpecFiles {
    <#
    .SYNOPSIS
        Scans docs/ and design/ for spec files to partition across agents.
        Returns array of relative file paths.
    #>
    param([string]$RepoRoot)

    $specFiles = @()

    # Scan docs/ recursively for .md files
    $docsDir = Join-Path $RepoRoot "docs"
    if (Test-Path $docsDir) {
        Get-ChildItem -Path $docsDir -Recurse -Filter "*.md" -File | ForEach-Object {
            $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
            $specFiles += $rel
        }
    }

    # Scan design/ for _analysis .md files (latest version only)
    $designDir = Join-Path $RepoRoot "design"
    if (Test-Path $designDir) {
        $versions = Get-ChildItem -Path $designDir -Recurse -Directory | Where-Object {
            $_.Name -match '^v\d+$'
        } | Sort-Object { [int]($_.Name -replace 'v','') } -Descending

        if ($versions.Count -gt 0) {
            $latestVersion = $versions[0].FullName
            Get-ChildItem -Path $latestVersion -Recurse -Filter "*.md" -File | Where-Object {
                $_.FullName -like "*_analysis*" -or $_.FullName -like "*_stubs*"
            } | ForEach-Object {
                $rel = $_.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
                $specFiles += $rel
            }
        }
    }

    return $specFiles
}

function Split-IntoChunks {
    <#
    .SYNOPSIS Splits an array into chunks of specified size.
    #>
    param([array]$Items, [int]$ChunkSize = 10)

    $chunks = @()
    for ($i = 0; $i -lt $Items.Count; $i += $ChunkSize) {
        $end = [math]::Min($i + $ChunkSize, $Items.Count)
        $chunk = @($Items[$i..($end - 1)])
        $chunks += ,@($chunk)
    }
    return $chunks
}

function Invoke-CouncilRequirements {
    <#
    .SYNOPSIS
        Two-phase council requirements: partitioned extract + cross-verify.
        Phase 1: Each agent extracts from 1/3 of specs (chunked).
        Phase 2: A different agent verifies each extraction.
        Phase 3: Claude synthesizes all verified outputs.
    .RETURNS
        @{ Success = bool; MatrixPath = string; AgentsSucceeded = int; Error = string }
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [switch]$DryRun,
        [bool]$UseJobs = $false,
        [string]$SkipAgent = "",
        [switch]$SkipVerify
    )

    $result = @{
        Success         = $false
        MatrixPath      = Join-Path $GsdDir "health\requirements-matrix.json"
        AgentsSucceeded = 0
        Error           = ""
    }

    $globalDir = Join-Path $env:USERPROFILE ".gsd-global"
    $promptDir = Join-Path $globalDir "prompts\council"
    $healthDir = Join-Path $GsdDir "health"
    $logDir    = Join-Path $GsdDir "logs"

    foreach ($d in @($healthDir, $logDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Initialize ntfy notifications (so push notifications work standalone)
    if (Get-Command Initialize-GsdNotifications -ErrorAction SilentlyContinue) {
        if (-not $script:NTFY_TOPIC) {
            Initialize-GsdNotifications -GsdGlobalDir $globalDir
        }
    }

    # Load config
    $crConfig = $null
    $configPath = Join-Path $globalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try { $crConfig = (Get-Content $configPath -Raw | ConvertFrom-Json).council_requirements } catch {}
    }
    $timeout   = if ($crConfig -and $crConfig.timeout_seconds) { [int]$crConfig.timeout_seconds } else { 600 }
    $cooldown  = if ($crConfig -and $crConfig.cooldown_between_agents) { [int]$crConfig.cooldown_between_agents } else { 5 }
    $minAgents = if ($crConfig -and $crConfig.min_agents_for_merge) { [int]$crConfig.min_agents_for_merge } else { 2 }
    $chunkSize = if ($crConfig -and $crConfig.chunk_size) { [int]$crConfig.chunk_size } else { 10 }

    # Build interface context
    $InterfaceContext = ""
    if (Get-Command Initialize-ProjectInterfaces -ErrorAction SilentlyContinue) {
        try {
            $ifaceResult = Initialize-ProjectInterfaces -RepoRoot $RepoRoot -GsdDir $GsdDir
            $InterfaceContext = $ifaceResult.Context
        } catch {}
    }

    # Agent definitions with cross-verify assignments
    $agents = @(
        @{ Name = "claude";  Prefix = "CL";  Verifier = "codex";  AllowedTools = "Read,Write,Bash"; GeminiMode = $null }
        @{ Name = "codex";   Prefix = "CX";  Verifier = "gemini"; AllowedTools = $null;             GeminiMode = $null }
        @{ Name = "gemini";  Prefix = "GM";  Verifier = "claude"; AllowedTools = $null;             GeminiMode = "--approval-mode yolo" }
    )

    # Filter out skipped agent and adjust verifier chain
    if ($SkipAgent) {
        $agents = @($agents | Where-Object { $_.Name -ne $SkipAgent })
        # Fix broken verifier chain
        foreach ($agent in $agents) {
            if ($agent.Verifier -eq $SkipAgent) {
                $otherAgent = $agents | Where-Object { $_.Name -ne $agent.Name } | Select-Object -First 1
                $agent.Verifier = $otherAgent.Name
            }
        }
        Write-Host "  [SKIP] $SkipAgent excluded -- running with $($agents.Count) agents" -ForegroundColor DarkYellow
    }

    # Check CLI availability
    $availableAgents = @()
    foreach ($agent in $agents) {
        $cliAvailable = $null -ne (Get-Command $agent.Name -ErrorAction SilentlyContinue)
        if ($cliAvailable) {
            $availableAgents += $agent
        } else {
            Write-Host "  [!!] $($agent.Name) CLI not found -- skipping" -ForegroundColor DarkYellow
        }
    }
    $agents = $availableAgents

    # Fix verifier chain for unavailable agents
    foreach ($agent in $agents) {
        $verifierAvailable = $agents | Where-Object { $_.Name -eq $agent.Verifier }
        if (-not $verifierAvailable) {
            $otherAgent = $agents | Where-Object { $_.Name -ne $agent.Name } | Select-Object -First 1
            if ($otherAgent) { $agent.Verifier = $otherAgent.Name }
        }
    }

    if ($agents.Count -lt $minAgents) {
        $result.Error = "Only $($agents.Count) agents available (need $minAgents)"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    # Scan for spec files
    Write-Host "  [SCAN] Scanning for specification files..." -ForegroundColor Cyan
    $specFiles = @(Get-SpecFiles -RepoRoot $RepoRoot)
    Write-Host "  [SCAN] Found $($specFiles.Count) spec files" -ForegroundColor Cyan

    if ($specFiles.Count -eq 0) {
        $result.Error = "No spec files found in docs/ or design/"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    # Partition files across available agents (round-robin)
    $partitions = @{}
    foreach ($agent in $agents) { $partitions[$agent.Name] = @() }
    for ($i = 0; $i -lt $specFiles.Count; $i++) {
        $agentIndex = $i % $agents.Count
        $partitions[$agents[$agentIndex].Name] += $specFiles[$i]
    }

    foreach ($agent in $agents) {
        $count = $partitions[$agent.Name].Count
        $chunks = [math]::Ceiling($count / $chunkSize)
        Write-Host "  [PARTITION] $($agent.Name): $count files in $chunks chunk(s) -- verified by $($agent.Verifier)" -ForegroundColor DarkGray
    }

    # Update file map
    if (Get-Command Update-FileMap -ErrorAction SilentlyContinue) {
        Update-FileMap -Root $RepoRoot -GsdPath $GsdDir 2>$null | Out-Null
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would dispatch $($agents.Count) agents across $($specFiles.Count) files" -ForegroundColor DarkGray
        Write-Host "  [DRY RUN] Then cross-verify each extraction with a different agent" -ForegroundColor DarkGray
        $result.Success = $true
        return $result
    }

    # Load prompt templates
    $extractTemplatePath = Join-Path $promptDir "requirements-extract-chunk.md"
    $verifyTemplatePath  = Join-Path $promptDir "requirements-verify.md"
    if (-not (Test-Path $extractTemplatePath)) {
        $result.Error = "Prompt template not found: requirements-extract-chunk.md"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }
    $extractTemplate = Get-Content $extractTemplatePath -Raw
    $verifyTemplate  = if (Test-Path $verifyTemplatePath) { Get-Content $verifyTemplatePath -Raw } else { $null }

    # ================================================================
    # PHASE 1: EXTRACT (parallel -- agents run simultaneously)
    # ================================================================
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "  PHASE 1: EXTRACT (parallel, partitioned, chunked)" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan

    $agentNames = @($agents | ForEach-Object { $_.Name }) -join ", "
    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        Send-GsdNotification -Title "Council Phase 1: EXTRACT" `
            -Message "$($agents.Count) agents ($agentNames) extracting from $($specFiles.Count) spec files in parallel" `
            -Priority "default" -Tags "rocket"
    }

    $completedAgents = @()
    $failedAgents = @()
    $resiliencePath = Join-Path $env:USERPROFILE ".gsd-global\lib\modules\resilience.ps1"
    $fileTreePath = Join-Path $GsdDir "file-map-tree.md"
    $fileTreeExists = Test-Path $fileTreePath

    # Launch one background job per agent (agents run in parallel, chunks sequential within each)
    $extractJobs = @()
    foreach ($agent in $agents) {
        $agentFiles = @($partitions[$agent.Name])
        if ($agentFiles.Count -eq 0) {
            Write-Host "    $($agent.Name.ToUpper()) -> no files assigned, skipping" -ForegroundColor DarkYellow
            continue
        }

        $totalChunks = [math]::Ceiling($agentFiles.Count / $chunkSize)
        Write-Host "    $($agent.Name.ToUpper()) -> $($agentFiles.Count) files in $totalChunks chunk(s) [LAUNCHING]" -ForegroundColor Magenta

        # Serialize file list as pipe-delimited string (avoids JSON single-item array issues)
        $filesStr = $agentFiles -join "|"

        $job = Start-Job -ScriptBlock {
            param($resPath, $aName, $aPrefix, $aTools, $aGeminiMode,
                  $filesStr, $chunkSz, $cooldownSec, $template,
                  $hDir, $lDir, $rRoot, $gDir, $iCtx, $ftPath, $ftExists)

            try { . $resPath } catch {
                return @{ AgentName = $aName; Success = $false; Error = "Failed to load resilience: $($_.Exception.Message)"; ReqCount = 0; ChunksFailed = 0 }
            }

            $agentFiles = @($filesStr -split '\|')
            $agentChunks = @(Split-IntoChunks -Items $agentFiles -ChunkSize $chunkSz)
            $totalChunks = $agentChunks.Count
            $agentAllReqs = @()
            $chunksFailed = 0
            $idCounter = 1

            for ($c = 0; $c -lt $totalChunks; $c++) {
                $chunkFiles = $agentChunks[$c]
                $chunkNum = $c + 1

                $fileListLines = @()
                foreach ($f in $chunkFiles) {
                    $fullPath = Join-Path $rRoot $f
                    $fileListLines += "- Read: $fullPath"
                }
                $fileList = $fileListLines -join "`n"

                $outputPath = Join-Path $hDir "council-extract-$aName-chunk$chunkNum.json"

                $prompt = $template
                $prompt = $prompt.Replace("{{CHUNK_NUM}}", "$chunkNum")
                $prompt = $prompt.Replace("{{TOTAL_CHUNKS}}", "$totalChunks")
                $prompt = $prompt.Replace("{{AGENT_NAME}}", $aName)
                $prompt = $prompt.Replace("{{REPO_ROOT}}", $rRoot)
                $prompt = $prompt.Replace("{{GSD_DIR}}", $gDir)
                $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $iCtx)
                $prompt = $prompt.Replace("{{FILE_LIST}}", $fileList)
                $prompt = $prompt.Replace("{{OUTPUT_PATH}}", $outputPath)
                $prompt = $prompt.Replace("{{ID_PREFIX}}", $aPrefix)
                $idStart = "{0:D3}" -f $idCounter
                $prompt = $prompt.Replace("{{ID_START}}", $idStart)

                if ($ftExists) {
                    $prompt += "`n`n## Repository File Map`nRead: $ftPath"
                }

                $logFile = Join-Path $lDir "council-requirements-$aName-chunk$chunkNum.log"

                try {
                    $invokeParams = @{
                        Agent   = $aName
                        Prompt  = $prompt
                        Phase   = "council-requirements"
                        LogFile = $logFile
                        CurrentBatchSize = 1
                        GsdDir  = $gDir
                    }
                    if ($aTools) { $invokeParams["AllowedTools"] = $aTools }
                    if ($aGeminiMode) { $invokeParams["GeminiMode"] = $aGeminiMode }

                    Invoke-WithRetry @invokeParams | Out-Null

                    # Read chunk output
                    if (Test-Path $outputPath) {
                        try {
                            $chunkData = Get-Content $outputPath -Raw | ConvertFrom-Json
                            if ($chunkData.requirements) {
                                $reqCount = @($chunkData.requirements).Count
                                $agentAllReqs += @($chunkData.requirements)
                                $idCounter += $reqCount
                            }
                        } catch { $chunksFailed++ }
                    } else {
                        # Try parsing from log
                        if (Test-Path $logFile) {
                            $logContent = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
                            if ($logContent -match '\{[\s\S]*"requirements"\s*:\s*\[[\s\S]*\][\s\S]*\}') {
                                try {
                                    $chunkData = $Matches[0] | ConvertFrom-Json
                                    if ($chunkData.requirements) {
                                        $reqCount = @($chunkData.requirements).Count
                                        $agentAllReqs += @($chunkData.requirements)
                                        $idCounter += $reqCount
                                    }
                                } catch { $chunksFailed++ }
                            } else { $chunksFailed++ }
                        } else { $chunksFailed++ }
                    }
                } catch { $chunksFailed++ }

                if ($c -lt ($totalChunks - 1) -and $cooldownSec -gt 0) {
                    Start-Sleep -Seconds $cooldownSec
                }
            }

            # Write combined agent output to disk
            if ($agentAllReqs.Count -gt 0) {
                $combinedOutput = [PSCustomObject]@{
                    agent         = $aName
                    focus         = "partitioned"
                    requirements  = $agentAllReqs
                    total_found   = $agentAllReqs.Count
                    chunks_total  = $totalChunks
                    chunks_failed = $chunksFailed
                }
                $combinedPath = Join-Path $hDir "council-extract-$aName.json"
                $combinedOutput | ConvertTo-Json -Depth 10 | Set-Content $combinedPath -Encoding UTF8
            }

            return @{
                AgentName    = $aName
                Success      = ($agentAllReqs.Count -gt 0)
                ReqCount     = $agentAllReqs.Count
                ChunksFailed = $chunksFailed
                Error        = ""
            }
        } -ArgumentList @(
            $resiliencePath, $agent.Name, $agent.Prefix,
            $agent.AllowedTools, $agent.GeminiMode,
            $filesStr, $chunkSize, $cooldown, $extractTemplate,
            $healthDir, $logDir, $RepoRoot, $GsdDir, $InterfaceContext,
            $fileTreePath, $fileTreeExists
        )

        $extractJobs += @{ Job = $job; Agent = $agent }
    }

    # Wait for all extraction jobs with live progress monitoring
    if ($extractJobs.Count -gt 0) {
        $maxChunksPerAgent = [math]::Max(1, [math]::Ceiling($specFiles.Count / ([math]::Max(1, $agents.Count) * $chunkSize)))
        $totalTimeout = ($timeout * $maxChunksPerAgent) + 120
        Write-Host ""
        Write-Host "  Waiting for $($extractJobs.Count) parallel agents (timeout: ~${totalTimeout}s)..." -ForegroundColor DarkGray

        # Poll for progress by watching chunk output files on disk
        $allJobs = @($extractJobs | ForEach-Object { $_.Job })
        $pollInterval = 15
        $elapsed = 0
        $lastSeen = @{}
        foreach ($ej in $extractJobs) { $lastSeen[$ej.Agent.Name] = 0 }

        while ($elapsed -lt $totalTimeout) {
            $running = @($allJobs | Where-Object { $_.State -eq "Running" })
            if ($running.Count -eq 0) { break }

            Start-Sleep -Seconds $pollInterval
            $elapsed += $pollInterval

            # Check each agent for new chunk files
            foreach ($ej in $extractJobs) {
                $aName = $ej.Agent.Name
                if ($ej.Job.State -ne "Running") { continue }
                $chunkFiles = @(Get-ChildItem -Path $healthDir -Filter "council-extract-$aName-chunk*.json" -ErrorAction SilentlyContinue)
                $currentChunks = $chunkFiles.Count
                if ($currentChunks -gt $lastSeen[$aName]) {
                    $totalExpected = [math]::Ceiling($partitions[$aName].Count / $chunkSize)
                    $reqsSoFar = 0
                    foreach ($cf in $chunkFiles) {
                        try {
                            $cd = Get-Content $cf.FullName -Raw | ConvertFrom-Json
                            if ($cd.requirements) { $reqsSoFar += @($cd.requirements).Count }
                        } catch {}
                    }
                    Write-Host "    [PROGRESS] ${aName}: chunk $currentChunks/$totalExpected done ($reqsSoFar reqs so far) [${elapsed}s]" -ForegroundColor DarkCyan
                    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
                        Send-GsdNotification -Title "Extract: ${aName} chunk $currentChunks/$totalExpected" `
                            -Message "$reqsSoFar requirements so far (${elapsed}s elapsed)" `
                            -Priority "low" -Tags "mag"
                    }
                    $lastSeen[$aName] = $currentChunks
                }
            }

            # Show per-agent heartbeat every 60s with chunk counts and working indicators
            if (($elapsed % 60) -lt $pollInterval) {
                $statusParts = @()
                foreach ($ej in $extractJobs) {
                    $aName = $ej.Agent.Name
                    $totalExpected = [math]::Ceiling($partitions[$aName].Count / $chunkSize)
                    $doneChunks = $lastSeen[$aName]
                    $state = $ej.Job.State
                    if ($state -eq "Running") {
                        # Check for log files as "working" indicator (log created before chunk completes)
                        $logFiles = @(Get-ChildItem -Path $logDir -Filter "council-requirements-$aName-chunk*.log" -ErrorAction SilentlyContinue)
                        $activeChunk = $logFiles.Count
                        if ($activeChunk -gt $doneChunks) {
                            $statusParts += "${aName}: chunk $doneChunks/$totalExpected done (working on chunk $activeChunk)"
                        } else {
                            # Check if agent process is alive
                            $agentProc = Get-Process -Name $aName -ErrorAction SilentlyContinue
                            $procStatus = if ($agentProc) { "process alive" } else { "waiting" }
                            $statusParts += "${aName}: chunk $doneChunks/$totalExpected done ($procStatus)"
                        }
                    } else {
                        $statusParts += "${aName}: $state ($doneChunks/$totalExpected)"
                    }
                }
                Write-Host "    [HEARTBEAT] ${elapsed}s -- $($statusParts -join ' | ')" -ForegroundColor DarkGray
            }
        }

        # Final check for stragglers
        $stillRunning = @($allJobs | Where-Object { $_.State -eq "Running" })
        if ($stillRunning.Count -gt 0) {
            Write-Host "    [TIMEOUT] $($stillRunning.Count) job(s) still running after ${totalTimeout}s -- stopping" -ForegroundColor DarkYellow
            $stillRunning | Stop-Job -ErrorAction SilentlyContinue
        }

        foreach ($ej in $extractJobs) {
            $agentName = $ej.Agent.Name

            if ($ej.Job.State -eq "Completed") {
                $jobResult = Receive-Job -Job $ej.Job
                if ($jobResult.Success) {
                    Write-Host "    [PASS] ${agentName}: $($jobResult.ReqCount) requirements ($($jobResult.ChunksFailed) chunk failures)" -ForegroundColor Green
                    $completedAgents += $agentName
                } else {
                    $errMsg = if ($jobResult.Error) { $jobResult.Error } else { "no requirements extracted" }
                    Write-Host "    [FAIL] ${agentName}: $errMsg" -ForegroundColor Red
                    $failedAgents += $agentName
                }
            } else {
                Write-Host "    [FAIL] ${agentName}: job state=$($ej.Job.State) (timeout or error)" -ForegroundColor Red
                $failedAgents += $agentName
                # Check if partial results were written to disk before timeout
                $partialPath = Join-Path $healthDir "council-extract-$agentName.json"
                if (Test-Path $partialPath) {
                    try {
                        $pd = Get-Content $partialPath -Raw | ConvertFrom-Json
                        if ($pd.requirements -and @($pd.requirements).Count -gt 0) {
                            Write-Host "    [PARTIAL] ${agentName}: $(@($pd.requirements).Count) requirements recovered from disk" -ForegroundColor DarkYellow
                            $completedAgents += $agentName
                            $failedAgents = @($failedAgents | Where-Object { $_ -ne $agentName })
                        }
                    } catch {}
                }
            }
            Remove-Job -Job $ej.Job -Force -ErrorAction SilentlyContinue
        }
    }

    $result.AgentsSucceeded = $completedAgents.Count
    Write-Host ""
    Write-Host "  Phase 1 complete: $($completedAgents.Count)/$($agents.Count) agents succeeded" -ForegroundColor Cyan

    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        $p1Tag = if ($completedAgents.Count -eq $agents.Count) { "white_check_mark" } else { "warning" }
        $p1Details = @()
        foreach ($a in $completedAgents) { $p1Details += "$a OK" }
        foreach ($a in $failedAgents) { $p1Details += "$a FAILED" }
        $p1Cost = ""
        if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) {
            $p1Cost = Get-CostNotificationText -GsdDir $GsdDir -Detailed
        }
        $p1Msg = ($p1Details -join " | ")
        if ($p1Cost) { $p1Msg += "`n$p1Cost" }
        Send-GsdNotification -Title "Phase 1 Done: $($completedAgents.Count)/$($agents.Count) agents" `
            -Message $p1Msg -Priority "default" -Tags $p1Tag
    }

    if ($completedAgents.Count -eq 0) {
        $result.Error = "No agent produced valid requirement output"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    # ================================================================
    # PHASE 2: CROSS-VERIFY (parallel -- verifiers run simultaneously)
    # ================================================================
    $verifiedAgents = @()

    if (-not $SkipVerify -and $verifyTemplate -and $completedAgents.Count -ge 2) {
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Yellow
        Write-Host "  PHASE 2: CROSS-VERIFY (parallel)" -ForegroundColor Yellow
        Write-Host "  ============================================" -ForegroundColor Yellow

        if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
            Send-GsdNotification -Title "Council Phase 2: CROSS-VERIFY" `
                -Message "$($completedAgents.Count) extractions being cross-verified in parallel" `
                -Priority "default" -Tags "eyes"
        }

        $verifyJobs = @()
        foreach ($agent in $agents) {
            if ($agent.Name -notin $completedAgents) { continue }

            $verifierName = $agent.Verifier
            $verifierAvailable = $null -ne (Get-Command $verifierName -ErrorAction SilentlyContinue)
            if (-not $verifierAvailable) {
                Write-Host "    [SKIP] Cannot verify $($agent.Name) -- $verifierName not available" -ForegroundColor DarkYellow
                continue
            }

            $extractionPath = Join-Path $healthDir "council-extract-$($agent.Name).json"
            if (-not (Test-Path $extractionPath)) { continue }

            # Build file list of the same spec files
            $agentFiles = @($partitions[$agent.Name])
            $fileListLines = @()
            foreach ($f in $agentFiles) {
                $fullPath = Join-Path $RepoRoot $f
                $fileListLines += "- Read: $fullPath"
            }
            $fileList = $fileListLines -join "`n"

            $verifyOutputPath = Join-Path $healthDir "council-verify-$($agent.Name)-by-$verifierName.json"

            $verifierAgent = $agents | Where-Object { $_.Name -eq $verifierName }
            $vPrefix = if ($verifierAgent) { $verifierAgent.Prefix } else { "V" }
            $vTools = if ($verifierAgent) { $verifierAgent.AllowedTools } else { $null }
            $vGemini = if ($verifierAgent) { $verifierAgent.GeminiMode } else { $null }

            $prompt = $verifyTemplate
            $prompt = $prompt.Replace("{{VERIFIER_NAME}}", $verifierName)
            $prompt = $prompt.Replace("{{EXTRACTOR_NAME}}", $agent.Name)
            $prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
            $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
            $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)
            $prompt = $prompt.Replace("{{EXTRACTION_PATH}}", "Read: $extractionPath")
            $prompt = $prompt.Replace("{{FILE_LIST}}", $fileList)
            $prompt = $prompt.Replace("{{OUTPUT_PATH}}", $verifyOutputPath)
            $prompt = $prompt.Replace("{{ID_PREFIX}}", $vPrefix)

            Write-Host "    $($verifierName.ToUpper()) verifying $($agent.Name)'s extraction [LAUNCHING]" -ForegroundColor Yellow

            $job = Start-Job -ScriptBlock {
                param($resPath, $vName, $vToolsArg, $vGeminiArg, $promptText,
                      $vLogFile, $gDir, $vOutPath, $extractorName)

                try { . $resPath } catch {
                    return @{ ExtractorName = $extractorName; Success = $false; Error = "Failed to load resilience: $($_.Exception.Message)" }
                }

                try {
                    $invokeParams = @{
                        Agent   = $vName
                        Prompt  = $promptText
                        Phase   = "council-verify"
                        LogFile = $vLogFile
                        CurrentBatchSize = 1
                        GsdDir  = $gDir
                    }
                    if ($vToolsArg) { $invokeParams["AllowedTools"] = $vToolsArg }
                    if ($vGeminiArg) { $invokeParams["GeminiMode"] = $vGeminiArg }

                    Invoke-WithRetry @invokeParams | Out-Null

                    if (Test-Path $vOutPath) {
                        try {
                            $verifyData = Get-Content $vOutPath -Raw | ConvertFrom-Json
                            $confirmed = if ($verifyData.summary) { $verifyData.summary.confirmed } else { 0 }
                            $missed    = if ($verifyData.missed_requirements) { @($verifyData.missed_requirements).Count } else { 0 }
                            $corrected = if ($verifyData.summary) { $verifyData.summary.corrected } else { 0 }
                            $flagged   = if ($verifyData.false_positives) { @($verifyData.false_positives).Count } else { 0 }
                            return @{ ExtractorName = $extractorName; Success = $true; Confirmed = $confirmed; Missed = $missed; Corrected = $corrected; Flagged = $flagged; Error = "" }
                        } catch {
                            return @{ ExtractorName = $extractorName; Success = $false; Error = "invalid JSON output" }
                        }
                    } else {
                        # Try parsing from log
                        if (Test-Path $vLogFile) {
                            $logContent = Get-Content $vLogFile -Raw -ErrorAction SilentlyContinue
                            if ($logContent -match '\{[\s\S]*"verified_requirements"\s*:\s*\[[\s\S]*\][\s\S]*\}') {
                                try {
                                    $verifyData = $Matches[0] | ConvertFrom-Json
                                    $verifyData | ConvertTo-Json -Depth 10 | Set-Content $vOutPath -Encoding UTF8
                                    return @{ ExtractorName = $extractorName; Success = $true; Confirmed = 0; Missed = 0; Corrected = 0; Flagged = 0; Error = "" }
                                } catch {}
                            }
                        }
                        return @{ ExtractorName = $extractorName; Success = $false; Error = "no output file produced" }
                    }
                } catch {
                    return @{ ExtractorName = $extractorName; Success = $false; Error = $_.Exception.Message }
                }
            } -ArgumentList @(
                $resiliencePath, $verifierName, $vTools, $vGemini, $prompt,
                (Join-Path $logDir "council-verify-$($agent.Name)-by-$verifierName.log"),
                $GsdDir, $verifyOutputPath, $agent.Name
            )

            $verifyJobs += @{ Job = $job; Agent = $agent; Verifier = $verifierName }
        }

        # Wait for all verification jobs with progress monitoring
        if ($verifyJobs.Count -gt 0) {
            $verifyTimeout = $timeout + 120
            Write-Host ""
            Write-Host "  Waiting for $($verifyJobs.Count) parallel verifiers (timeout: ${verifyTimeout}s)..." -ForegroundColor DarkGray

            $allVJobs = @($verifyJobs | ForEach-Object { $_.Job })
            $vElapsed = 0
            $vPoll = 15
            $vSeen = @{}

            while ($vElapsed -lt $verifyTimeout) {
                $vRunning = @($allVJobs | Where-Object { $_.State -eq "Running" })
                if ($vRunning.Count -eq 0) { break }

                Start-Sleep -Seconds $vPoll
                $vElapsed += $vPoll

                # Check for completed verification output files
                foreach ($vj in $verifyJobs) {
                    $eName = $vj.Agent.Name
                    $vName = $vj.Verifier
                    $vKey = "$eName-by-$vName"
                    if ($vSeen[$vKey]) { continue }
                    if ($vj.Job.State -ne "Running") {
                        if (-not $vSeen[$vKey]) {
                            Write-Host "    [PROGRESS] ${vName} verifying ${eName}: completed [${vElapsed}s]" -ForegroundColor DarkCyan
                            $vSeen[$vKey] = $true
                        }
                        continue
                    }
                    $vOutFile = Join-Path $healthDir "council-verify-$eName-by-$vName.json"
                    if (Test-Path $vOutFile) {
                        Write-Host "    [PROGRESS] ${vName} verifying ${eName}: output written [${vElapsed}s]" -ForegroundColor DarkCyan
                        $vSeen[$vKey] = $true
                    }
                }

                # Heartbeat every 60s
                if (($vElapsed % 60) -lt $vPoll) {
                    $vStates = @($verifyJobs | ForEach-Object { "$($_.Verifier)->$($_.Agent.Name)=$($_.Job.State)" })
                    Write-Host "    [HEARTBEAT] ${vElapsed}s elapsed -- $($vStates -join ', ')" -ForegroundColor DarkGray
                }
            }

            $vStillRunning = @($allVJobs | Where-Object { $_.State -eq "Running" })
            if ($vStillRunning.Count -gt 0) {
                Write-Host "    [TIMEOUT] $($vStillRunning.Count) verifier(s) still running -- stopping" -ForegroundColor DarkYellow
                $vStillRunning | Stop-Job -ErrorAction SilentlyContinue
            }

            foreach ($vj in $verifyJobs) {
                $extractorName = $vj.Agent.Name
                $verifierName = $vj.Verifier

                if ($vj.Job.State -eq "Completed") {
                    $vjResult = Receive-Job -Job $vj.Job
                    if ($vjResult.Success) {
                        Write-Host "    [OK] ${verifierName} verified ${extractorName}: $($vjResult.Confirmed) confirmed, $($vjResult.Missed) missed, $($vjResult.Corrected) corrected, $($vjResult.Flagged) flagged" -ForegroundColor Green
                        $verifiedAgents += $extractorName
                    } else {
                        Write-Host "    [WARN] ${verifierName} verify of ${extractorName}: $($vjResult.Error) -- extraction accepted as-is" -ForegroundColor DarkYellow
                    }
                } else {
                    Write-Host "    [WARN] ${verifierName} verify of ${extractorName}: job $($vj.Job.State) -- extraction accepted as-is" -ForegroundColor DarkYellow
                    # Check if output was written to disk before timeout
                    $vOutCheck = Join-Path $healthDir "council-verify-$extractorName-by-$verifierName.json"
                    if (Test-Path $vOutCheck) {
                        Write-Host "    [PARTIAL] Verification output found on disk" -ForegroundColor DarkYellow
                        $verifiedAgents += $extractorName
                    }
                }
                Remove-Job -Job $vj.Job -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Host ""
        Write-Host "  Phase 2 complete: $($verifiedAgents.Count)/$($completedAgents.Count) extractions verified" -ForegroundColor Yellow
        if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
            $p2Cost = ""
            if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) {
                $p2Cost = Get-CostNotificationText -GsdDir $GsdDir -Detailed
            }
            $p2Msg = "Cross-verification complete"
            if ($p2Cost) { $p2Msg += "`n$p2Cost" }
            Send-GsdNotification -Title "Phase 2 Done: $($verifiedAgents.Count)/$($completedAgents.Count) verified" `
                -Message $p2Msg -Priority "default" -Tags "white_check_mark"
        }
    } else {
        if ($SkipVerify) {
            Write-Host ""
            Write-Host "  [SKIP] Phase 2 (verification) skipped by user" -ForegroundColor DarkYellow
        }
    }

    # ================================================================
    # PHASE 3: SYNTHESIS (Claude merges all verified outputs)
    # ================================================================
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Green
    Write-Host "  PHASE 3: SYNTHESIZE" -ForegroundColor Green
    Write-Host "  ============================================" -ForegroundColor Green

    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        Send-GsdNotification -Title "Council Phase 3: SYNTHESIZE" `
            -Message "Merging $($completedAgents.Count) agent outputs into requirements matrix" `
            -Priority "default" -Tags "gear"
    }

    # Collect outputs for synthesis
    $agentOutputs = @{}
    foreach ($agentName in $completedAgents) {
        $extractPath = Join-Path $healthDir "council-extract-$agentName.json"
        if (Test-Path $extractPath) {
            try {
                $parsed = Get-Content $extractPath -Raw | ConvertFrom-Json
                if ($parsed.requirements -and @($parsed.requirements).Count -gt 0) {
                    $agentOutputs[$agentName] = $parsed
                    Write-Host "    ${agentName}: $(@($parsed.requirements).Count) requirements" -ForegroundColor DarkGray
                }
            } catch {}
        }
    }

    if ($agentOutputs.Count -eq 0) {
        $result.Error = "No agent produced valid requirement output"
        Write-Host "  [XX] $($result.Error)" -ForegroundColor Red
        return $result
    }

    Write-Host "  [SCALES] Claude synthesizing merged requirements matrix..." -ForegroundColor Cyan

    $isPartial = $agentOutputs.Count -lt $agents.Count
    $synthTemplateName = if ($isPartial) { "requirements-synthesize-partial.md" } else { "requirements-synthesize.md" }
    $synthTemplatePath = Join-Path $promptDir $synthTemplateName

    if (-not (Test-Path $synthTemplatePath)) {
        $synthTemplatePath = Join-Path $promptDir "requirements-synthesize.md"
    }

    $synthPrompt = if (Test-Path $synthTemplatePath) {
        (Get-Content $synthTemplatePath -Raw)
    } else {
        "Read the agent extraction files below. Merge and write requirements-matrix.json to {{GSD_DIR}}\health\requirements-matrix.json"
    }

    $synthPrompt = $synthPrompt.Replace("{{GSD_DIR}}", $GsdDir)
    $synthPrompt = $synthPrompt.Replace("{{AGENT_COUNT}}", "$($agentOutputs.Count)")

    # Build agent output section (extractions + verification results)
    $outputSection = ""
    foreach ($agentName in $agentOutputs.Keys) {
        $extractPath = Join-Path $healthDir "council-extract-$agentName.json"
        if (Test-Path $extractPath) {
            $outputSection += "`n## $($agentName.ToUpper()) Extraction`nRead: $extractPath`n"
        }
        # Include verification results if they exist
        $verifyFiles = Get-ChildItem -Path $healthDir -Filter "council-verify-$agentName-by-*.json" -ErrorAction SilentlyContinue
        foreach ($vf in $verifyFiles) {
            $outputSection += "`n## Verification of $($agentName.ToUpper())`nRead: $($vf.FullName)`n"
        }
    }
    $synthPrompt = $synthPrompt.Replace("{{AGENT_OUTPUTS}}", $outputSection)

    if ($isPartial) {
        $allAgentNames = @($agents | ForEach-Object { $_.Name })
        $missing = @($allAgentNames | Where-Object { $_ -notin $agentOutputs.Keys })
        $synthPrompt = $synthPrompt.Replace("{{MISSING_AGENT}}", ($missing -join ", "))
    }

    $synthLogFile = Join-Path $logDir "council-requirements-synthesis.log"

    $synthResult = Invoke-WithRetry -Agent "claude" -Prompt $synthPrompt -Phase "council-requirements-synthesis" `
        -LogFile $synthLogFile -MaxAttempts 2 -CurrentBatchSize 1 -GsdDir $GsdDir `
        -AllowedTools "Read,Write"

    # Verify matrix was written
    $matrixPath = Join-Path $healthDir "requirements-matrix.json"
    if (Test-Path $matrixPath) {
        try {
            $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
            if ($matrix.requirements -and @($matrix.requirements).Count -gt 0) {
                $result.Success = $true
                Write-Host "  [OK] Requirements matrix: $(@($matrix.requirements).Count) requirements" -ForegroundColor Green
                Write-Host "  [OK] Health: $($matrix.meta.health_score)%" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Synthesis produced empty matrix -- trying local merge" -ForegroundColor DarkYellow
                $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
                $result.Success = $localResult.Success
            }
        } catch {
            Write-Host "  [WARN] Matrix file invalid -- trying local merge" -ForegroundColor DarkYellow
            $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
            $result.Success = $localResult.Success
        }
    } else {
        Write-Host "  [WARN] Synthesis did not write matrix -- trying local merge" -ForegroundColor DarkYellow
        $localResult = Merge-CouncilRequirementsLocal -AgentOutputs $agentOutputs -GsdDir $GsdDir
        $result.Success = $localResult.Success
    }

    # Final ntfy notification with cost summary
    if (Get-Command Send-GsdNotification -ErrorAction SilentlyContinue) {
        $finalCost = ""
        if (Get-Command Get-CostNotificationText -ErrorAction SilentlyContinue) {
            $finalCost = Get-CostNotificationText -GsdDir $GsdDir -Detailed
        }
        if ($result.Success) {
            $reqCount = 0
            try { $reqCount = @((Get-Content (Join-Path $healthDir "requirements-matrix.json") -Raw | ConvertFrom-Json).requirements).Count } catch {}
            $finalMsg = "Requirements matrix: $reqCount requirements"
            if ($finalCost) { $finalMsg += "`n$finalCost" }
            Send-GsdNotification -Title "Council COMPLETE" `
                -Message $finalMsg -Priority "high" -Tags "tada"
        } else {
            $finalMsg = "Error: $($result.Error)"
            if ($finalCost) { $finalMsg += "`n$finalCost" }
            Send-GsdNotification -Title "Council FAILED" `
                -Message $finalMsg -Priority "high" -Tags "x"
        }
    }

    return $result
}


function Merge-CouncilRequirementsLocal {
    <#
    .SYNOPSIS
        Local PowerShell fallback: merges agent outputs using token-overlap deduplication
        when the Claude synthesis agent fails or produces invalid output.
    #>
    param(
        [hashtable]$AgentOutputs,
        [string]$GsdDir
    )

    $result = @{ Success = $false }

    $allReqs = @()
    foreach ($agentName in $AgentOutputs.Keys) {
        $output = $AgentOutputs[$agentName]
        foreach ($req in @($output.requirements)) {
            $allReqs += @{
                Agent       = $agentName
                Description = $req.description
                Source      = $req.source
                SpecDoc     = $req.spec_doc
                SdlcPhase   = $req.sdlc_phase
                Pattern     = $req.pattern
                Priority    = $req.priority
                Status      = $req.status
                SatisfiedBy = $req.satisfied_by
                Notes       = $req.notes
            }
        }
    }

    if ($allReqs.Count -eq 0) {
        Write-Host "  [XX] No requirements to merge" -ForegroundColor Red
        return $result
    }

    # Deduplication via Jaccard similarity
    $groups = @()
    $assigned = @{}

    for ($i = 0; $i -lt $allReqs.Count; $i++) {
        if ($assigned.ContainsKey($i)) { continue }
        $group = @($allReqs[$i])
        $assigned[$i] = $true

        $descA = $allReqs[$i].Description.ToLower() -replace '[^a-z0-9\s]', ''
        $tokensA = @($descA -split '\s+' | Where-Object { $_.Length -gt 2 })

        for ($j = $i + 1; $j -lt $allReqs.Count; $j++) {
            if ($assigned.ContainsKey($j)) { continue }
            $descB = $allReqs[$j].Description.ToLower() -replace '[^a-z0-9\s]', ''
            $tokensB = @($descB -split '\s+' | Where-Object { $_.Length -gt 2 })

            if ($tokensA.Count -gt 0 -and $tokensB.Count -gt 0) {
                $setA = [System.Collections.Generic.HashSet[string]]::new([string[]]$tokensA)
                $setB = [System.Collections.Generic.HashSet[string]]::new([string[]]$tokensB)
                $intersection = [System.Collections.Generic.HashSet[string]]::new($setA)
                $intersection.IntersectWith($setB)
                $union = [System.Collections.Generic.HashSet[string]]::new($setA)
                $union.UnionWith($setB)
                $similarity = if ($union.Count -gt 0) { $intersection.Count / $union.Count } else { 0 }
                if ($similarity -gt 0.5) {
                    $group += $allReqs[$j]
                    $assigned[$j] = $true
                }
            }
        }
        $groups += ,@($group)
    }

    $mergedReqs = @()
    $reqNum = 1
    $priorityRank = @{ "high" = 3; "medium" = 2; "low" = 1 }
    $statusRank   = @{ "not_started" = 3; "partial" = 2; "satisfied" = 1 }

    foreach ($group in $groups) {
        $bestDesc = ($group | Sort-Object { $_.Description.Length } -Descending | Select-Object -First 1).Description
        $bestStatus = "satisfied"
        foreach ($member in $group) {
            $s = $member.Status
            if ($s -and $statusRank.ContainsKey($s) -and $statusRank[$s] -gt $statusRank[$bestStatus]) { $bestStatus = $s }
        }
        $bestPriority = "low"
        foreach ($member in $group) {
            $p = $member.Priority
            if ($p -and $priorityRank.ContainsKey($p) -and $priorityRank[$p] -gt $priorityRank[$bestPriority]) { $bestPriority = $p }
        }
        $foundBy = @($group | ForEach-Object { $_.Agent } | Select-Object -Unique)
        $confidence = switch ($foundBy.Count) { 3 { "high" } 2 { "medium" } default { "low" } }

        $id = "REQ-{0:D3}" -f $reqNum
        $mergedReqs += [PSCustomObject]@{
            id           = $id
            description  = $bestDesc
            source       = ($group[0].Source)
            spec_doc     = ($group[0].SpecDoc)
            sdlc_phase   = ($group[0].SdlcPhase)
            pattern      = ($group[0].Pattern)
            priority     = $bestPriority
            status       = $bestStatus
            satisfied_by = ($group | Where-Object { $_.SatisfiedBy } | Select-Object -First 1 -ExpandProperty SatisfiedBy)
            notes        = ($group | Where-Object { $_.Notes } | Select-Object -First 1 -ExpandProperty Notes)
            confidence   = $confidence
            found_by     = $foundBy
        }
        $reqNum++
    }

    $total = $mergedReqs.Count
    $satisfied = @($mergedReqs | Where-Object { $_.status -eq "satisfied" }).Count
    $partial = @($mergedReqs | Where-Object { $_.status -eq "partial" }).Count
    $notStarted = @($mergedReqs | Where-Object { $_.status -eq "not_started" }).Count
    $healthScore = if ($total -gt 0) { [math]::Round(($satisfied / $total) * 100, 1) } else { 0 }

    $matrix = [PSCustomObject]@{
        meta = [PSCustomObject]@{
            total_requirements  = $total; satisfied = $satisfied; partial = $partial
            not_started = $notStarted; health_score = $healthScore; iteration = 0
            extraction_method   = "council-local-merge"
            agents_participated = @($AgentOutputs.Keys | Sort-Object)
            timestamp           = (Get-Date).ToUniversalTime().ToString("o")
        }
        requirements = $mergedReqs
    }

    $matrixPath = Join-Path $GsdDir "health\requirements-matrix.json"
    $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8

    $healthPath = Join-Path $GsdDir "health\health-current.json"
    @{ health_score = $healthScore; total_requirements = $total; satisfied = $satisfied; partial = $partial; not_started = $notStarted; iteration = 0 } | ConvertTo-Json | Set-Content $healthPath -Encoding UTF8

    $high = @($mergedReqs | Where-Object { $_.confidence -eq "high" }).Count
    $med = @($mergedReqs | Where-Object { $_.confidence -eq "medium" }).Count
    $low = @($mergedReqs | Where-Object { $_.confidence -eq "low" }).Count

    $report = @(
        "# Council Requirements Report (Local Merge)", ""
        "| Metric | Value |", "|--------|-------|"
        "| Total requirements | $total |", "| High confidence | $high |"
        "| Medium confidence | $med |", "| Low confidence | $low |"
        "| Agents participated | $($AgentOutputs.Keys -join ', ') |"
        "| Health score | ${healthScore}% |", ""
    )
    $reportPath = Join-Path $GsdDir "health\council-requirements-report.md"
    ($report -join "`n") | Set-Content $reportPath -Encoding UTF8

    Write-Host "  [OK] Local merge: $total requirements (${healthScore}% health)" -ForegroundColor Green
    $result.Success = $true
    return $result
}

Write-Host "  Council Requirements module loaded." -ForegroundColor DarkGray
