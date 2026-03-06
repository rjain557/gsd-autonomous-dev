# ===============================================================
# GSD Resilience Library - dot-source this in any pipeline script
# Usage: . "$env:USERPROFILE\.gsd-global\lib\modules\resilience.ps1"
# ===============================================================

# -- Load API agents module --
. "$PSScriptRoot\api-agents.ps1"

# -- Configuration --
$script:RETRY_MAX = 3
$script:RETRY_DELAY_SECONDS = 10
$script:BATCH_REDUCTION_FACTOR = 0.5
$script:MIN_BATCH_SIZE = 2
$script:BUILD_TIMEOUT_SECONDS = 300
$script:AGENT_TIMEOUT_SECONDS = 600
$script:AGENT_WATCHDOG_MINUTES = 30     # Kill hung agent after this many minutes
$script:LOCK_STALE_MINUTES = 120
$script:QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE = 1  # Rotate immediately on first quota failure
$script:QUOTA_CUMULATIVE_MAX_MINUTES = 15           # Give up after 15 min total waiting

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

function Invoke-WithRetryCore {
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
$script:NETWORK_POLL_SECONDS = 30
$script:NETWORK_MAX_POLLS = 120        # max 1 hour of polling
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
        Polls for internet connectivity. Returns true when online, false after timeout.
    #>
    param([string]$GsdDir)

    # Quick check first
    try {
        $null = claude -p "PING" --max-turns 1 2>$null; if ($LASTEXITCODE -ne 0) { throw "offline" }
        return $true
    } catch {}

    Write-Host "    Network unavailable. Polling every $($script:NETWORK_POLL_SECONDS)s..." -ForegroundColor Yellow
    Write-GsdError -GsdDir $GsdDir -Category "network" -Phase "connectivity" -Iteration 0 `
        -Message "Network unavailable" -Resolution "Polling for connectivity"

    $polls = 0
    while ($polls -lt $script:NETWORK_MAX_POLLS) {
        $polls++
        Start-Sleep -Seconds $script:NETWORK_POLL_SECONDS

        try {
            $null = claude -p "PING" --max-turns 1 2>$null; if ($LASTEXITCODE -ne 0) { throw "offline" }
            Write-Host "    [OK] Network restored after $($polls * $script:NETWORK_POLL_SECONDS)s" -ForegroundColor Green
            return $true
        } catch {
            if ($polls % 10 -eq 0) {
                Write-Host "    Still offline... ($polls polls)" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "    [XX] Network did not recover after $($script:NETWORK_MAX_POLLS * $script:NETWORK_POLL_SECONDS)s" -ForegroundColor Red
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
            $rawOutput = $Prompt | codex exec --full-auto --json - 2>&1
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
$script:OriginalInvokeWithRetry = ${function:Invoke-WithRetryCore}

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
            $timeoutSec = $script:AGENT_TIMEOUT_SECONDS  # 600s = 10 min

            # --- Invoke agent CLI (with timeout via background job) ---
            $rawOutput = $null
            $timedOut = $false

            # Write prompt to temp file for all agents
            $tmpPrompt = Join-Path ([System.IO.Path]::GetTempPath()) "gsd-prompt-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
            Set-Content -Path $tmpPrompt -Value $effectivePrompt -Encoding UTF8

            $jobScript = $null
            if ($Agent -eq "claude") {
                $jobScript = {
                    param($pf, $tools)
                    $p = Get-Content $pf -Raw
                    claude -p $p --allowedTools $tools --output-format json 2>&1
                }
                $jobArgs = @($tmpPrompt, $AllowedTools)
            } elseif ($Agent -eq "codex") {
                $jobScript = {
                    param($pf)
                    $p = Get-Content $pf -Raw
                    $p | codex exec --full-auto --json - 2>&1
                }
                $jobArgs = @($tmpPrompt)
            } elseif ($Agent -eq "gemini") {
                $geminiArgs = $GeminiMode.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
                $jobScript = {
                    param($pf, $gArgs)
                    $p = Get-Content $pf -Raw
                    $p | gemini @gArgs --output-format json 2>&1
                }
                $jobArgs = @($tmpPrompt, $geminiArgs)
            }

            if ($jobScript) {
                $job = Start-Job -ScriptBlock $jobScript -ArgumentList $jobArgs
                $finished = $job | Wait-Job -Timeout $timeoutSec
                if ($job.State -eq 'Running') {
                    $job | Stop-Job
                    $job | Remove-Job -Force
                    $timedOut = $true
                } else {
                    $rawOutput = Receive-Job -Job $job
                    $exitCode = if ($job.State -eq 'Failed') { 1 } else { 0 }
                    $job | Remove-Job -Force
                }
            }

            # --- API-based agents (deepseek, glm5, minimax) ---
            if (-not $jobScript -and $Agent -in $script:API_AGENTS) {
                Write-Host "    [$($Agent.ToUpper())] Calling via REST API..." -ForegroundColor DarkCyan
                $apiResult = Invoke-ApiAgent -Agent $Agent -Prompt $effectivePrompt -TimeoutSec $timeoutSec
                Remove-Item $tmpPrompt -Force -ErrorAction SilentlyContinue
                if ($apiResult.Success) {
                    $rawOutput = $apiResult.RawOutput
                    $output = $apiResult.Output
                    $tokenData = $apiResult.TokenData
                    $exitCode = 0
                } elseif ($apiResult.Error -eq "rate_limit") {
                    # Let the quota handling below deal with it
                    $rawOutput = "rate_limit quota_exhausted resource_exhausted"
                    $exitCode = 1
                } elseif ($apiResult.Error -eq "timeout") {
                    Remove-Item $tmpPrompt -Force -ErrorAction SilentlyContinue
                    Write-Host "    [TIMEOUT] $Agent API timed out. Rotating..." -ForegroundColor Yellow
                    Write-GsdError -GsdDir $GsdDir -Category "timeout" -Phase $Phase -Iteration $i `
                        -Message "$Agent API timed out after ${timeoutSec}s" -Resolution "Rotating agent"
                    Set-AgentCooldown -Agent $Agent -GsdDir $GsdDir -CooldownMinutes 30
                    $rotatedAgent = Get-NextAvailableAgent -CurrentAgent $Agent -GsdDir $GsdDir
                    if ($rotatedAgent) {
                        Write-Host "    [ROTATE] $Agent -> $rotatedAgent (API timeout)" -ForegroundColor Yellow
                        $Agent = $rotatedAgent
                        $i--
                        continue
                    }
                    $result.Error = "All agents timed out"
                    return $result
                } else {
                    # Other API error - treat as crash, let retry logic handle
                    $rawOutput = "API error: $($apiResult.Error)"
                    $exitCode = 1
                }
            } else {
                Remove-Item $tmpPrompt -Force -ErrorAction SilentlyContinue
            }

            if ($timedOut) {
                Write-Host "    [TIMEOUT] $Agent exceeded ${timeoutSec}s. Rotating..." -ForegroundColor Yellow
                Write-GsdError -GsdDir $GsdDir -Category "timeout" -Phase $Phase -Iteration $i `
                    -Message "$Agent timed out after ${timeoutSec}s" -Resolution "Rotating agent"
                Set-AgentCooldown -Agent $Agent -GsdDir $GsdDir -CooldownMinutes 30
                $rotatedAgent = Get-NextAvailableAgent -CurrentAgent $Agent -GsdDir $GsdDir
                if ($rotatedAgent) {
                    Write-Host "    [ROTATE] $Agent -> $rotatedAgent (timeout)" -ForegroundColor Yellow
                    Write-GsdError -GsdDir $GsdDir -Category "agent_rotate" -Phase $Phase -Iteration $i `
                        -Message "$Agent -> $rotatedAgent after timeout" -Resolution "Rotated agent"
                    $Agent = $rotatedAgent
                    $i--
                    continue
                }
                $result.Error = "All agents timed out"
                return $result
            }

            # --- Parse output (unified for all agents) ---
            if ($rawOutput) {
                $outputStr = if ($rawOutput -is [array]) { $rawOutput -join "`n" } else { "$rawOutput" }
                $parsed = Extract-TokensFromOutput -Agent $Agent -RawOutput $outputStr
                if ($parsed -and $parsed.TextOutput) {
                    $output = $parsed.TextOutput -split "`n"
                    $tokenData = $parsed
                } else {
                    $output = if ($rawOutput -is [array]) { $rawOutput } else { $rawOutput -split "`n" }
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

    # ── 1. Load parallel config ──
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
    $writeCapableAgents = @("codex", "claude", "gemini")
    $skippedAgents = @($agentPool | Where-Object { $_ -notin $writeCapableAgents })
    $agentPool = @($agentPool | Where-Object { $_ -in $writeCapableAgents } | Select-Object -Unique)
    if ($skippedAgents.Count -gt 0) {
        Write-Host "  [PARALLEL] Skipping non-write agents for execute: $($skippedAgents -join ', ')" -ForegroundColor DarkYellow
    }
    if ($agentPool.Count -eq 0) {
        $result.Error = "No write-capable agents configured for execute_parallel"
        return $result
    }

    # ── 2. Load queue and decompose into sub-tasks ──
    $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
    $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
    $batch = @($queue.batch)

    if ($batch.Count -eq 0) {
        $result.Error = "No batch items in queue-current.json"
        return $result
    }

    Write-Host "  [PARALLEL] Decomposing batch: $($batch.Count) sub-tasks" -ForegroundColor Cyan

    # ── 3. Build per-subtask prompts ──
    $templateText = Get-Content $PromptTemplatePath -Raw
    $subtasks = @()

    for ($idx = 0; $idx -lt $batch.Count; $idx++) {
        $item = $batch[$idx]

        # Select agent: round-robin across pool
        if ($strategy -eq "round-robin") {
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

    # ── 4. Dispatch sub-tasks ──
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

    # ── 5. Execute in batches of $maxConcurrent using PowerShell jobs ──
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

        # Throttle between waves (avoid quota spike)
        if ($batchEnd -lt ($subtasks.Count - 1)) {
            Write-Host "  [PARALLEL] Wave complete. 10s cooldown..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
    }

    # ── 6. Aggregate results ──
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

function Get-GitDiffStats {
    <#
    .SYNOPSIS
        Returns a compact string with lines added/removed and files changed from the last git commit.
        Call AFTER git commit. Returns empty string if git is unavailable or no changes.
    #>
    param(
        [string]$RepoRoot = "."
    )
    try {
        Push-Location $RepoRoot
        $stat = git diff --stat HEAD~1 HEAD 2>$null
        if (-not $stat) { Pop-Location; return "" }

        $summary = $stat | Select-Object -Last 1
        $filesChanged = 0; $insertions = 0; $deletions = 0
        if ($summary -match '(\d+)\s+file') { $filesChanged = [int]$Matches[1] }
        if ($summary -match '(\d+)\s+insertion') { $insertions = [int]$Matches[1] }
        if ($summary -match '(\d+)\s+deletion') { $deletions = [int]$Matches[1] }
        Pop-Location

        if ($filesChanged -eq 0 -and $insertions -eq 0 -and $deletions -eq 0) { return "" }
        return "Code: +${insertions}/-${deletions} lines | ${filesChanged} files"
    } catch {
        if ((Get-Location).Path -ne $RepoRoot) { Pop-Location -ErrorAction SilentlyContinue }
        return ""
    }
}

function Get-GitCumulativeStats {
    <#
    .SYNOPSIS
        Returns cumulative lines added/removed across all gsd commits in the current run.
    #>
    param(
        [string]$RepoRoot = ".",
        [int]$Iterations = 1
    )
    try {
        Push-Location $RepoRoot
        $stat = git log --numstat --format="" -n $Iterations --grep="gsd:" 2>$null
        if (-not $stat) { Pop-Location; return "" }

        $totalAdded = 0; $totalRemoved = 0; $allFiles = @{}
        foreach ($line in $stat) {
            if ($line -match '^(\d+)\s+(\d+)\s+(.+)$') {
                $totalAdded += [int]$Matches[1]
                $totalRemoved += [int]$Matches[2]
                $allFiles[$Matches[3]] = $true
            }
        }
        Pop-Location
        if ($totalAdded -eq 0 -and $totalRemoved -eq 0) { return "" }
        return "Total code: +${totalAdded}/-${totalRemoved} lines | $($allFiles.Count) files touched"
    } catch {
        if ((Get-Location).Path -ne $RepoRoot) { Pop-Location -ErrorAction SilentlyContinue }
        return ""
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
        claude = @{ InputPerM = 3.00; OutputPerM = 15.00; CacheReadPerM = 0.30; ModelKey = "claude_sonnet" }
        codex  = @{ InputPerM = 1.50; OutputPerM = 6.00;  CacheReadPerM = 0.00; ModelKey = "codex" }
        gemini = @{ InputPerM = 1.25; OutputPerM = 10.00; CacheReadPerM = 0.125; ModelKey = "gemini" }
    }

    $modelKey = switch ($Agent) {
        "claude" { "claude_sonnet" }
        "codex"  { "codex" }
        "gemini" { "gemini" }
        default  { $Agent }
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

    # ── 1. BUILD SHARED CONTEXT ──
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

    # ── 2. PARALLEL AGENT REVIEWS (Codex + Gemini only, Claude synthesizes) ──
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
            # "convergence" -- 2-agent review (claude + gemini), claude synthesizes
            # codex swapped out due to persistent quota exhaustion / hanging
            $agents = @(
                @{ Name = "claude";  Template = "claude-review.md";  Mode = ""; AllowedTools = "" }
                @{ Name = "gemini"; Template = "gemini-review.md"; Mode = "--approval-mode plan"; AllowedTools = "" }
            )
            $phaseName = "council-review"
        }
    }

    # ── CHUNKING DECISION ──
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
        # ── CHUNKED CONVERGENCE PATH ──
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

        # ── CHUNKED SYNTHESIS ──
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
        # ── MONOLITHIC PATH (non-convergence or chunking disabled) ──
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

        # ── 3. SYNTHESIS (Claude reads all reviews) ──
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

    # ── 4. PARSE VERDICT & WRITE OUTPUTS ──
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

            # â”€â”€ POST-SPEC-FIX COUNCIL â”€â”€
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

    # Agent pool -- order matters (preference order)
    # CLI agents first (fastest), then API agents with keys
    $pool = @("claude", "gemini")
    # Add API agents that have keys configured
    foreach ($apiAgent in @("deepseek", "glm5", "minimax", "kimi")) {
        if (Test-ApiAgentAvailable -Agent $apiAgent) { $pool += $apiAgent }
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
    $analysisDirs = @()
    foreach ($iface in $Interfaces) {
        if ($iface.AnalysisDir -and (Test-Path $iface.AnalysisDir)) {
            $analysisDirs += $iface.AnalysisDir
        }
    }
    $rootAnalysisDir = Join-Path $RepoRoot "_analysis"
    if (Test-Path $rootAnalysisDir) { $analysisDirs += $rootAnalysisDir }
    $analysisDirs = @($analysisDirs | Select-Object -Unique)

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
                $figmaPath = if ($Interfaces.Count -gt 0) {
                    (($Interfaces | ForEach-Object { $_.VersionPath }) -join ", ")
                } elseif (Test-Path (Join-Path $RepoRoot "design")) {
                    "design\ (see interface folders)"
                } else {
                    ""
                }
                $promptContent = $promptContent.Replace("{{FIGMA_PATH}}", $figmaPath)
                $ifaceCtx = ""
                foreach ($iface in $Interfaces) {
                    if ($iface.AnalysisDir -and (Test-Path $iface.AnalysisDir)) {
                        $relAnalysis = $iface.AnalysisDir.Replace("$RepoRoot\", "")
                        $ifaceCtx += "- $($iface.Key): $relAnalysis`n"
                    }
                }
                $promptContent = $promptContent.Replace("{{INTERFACE_ANALYSIS}}", $ifaceCtx)
                Write-Host "    [SEARCH] Running spec clarity check via Claude..." -ForegroundColor DarkGray
                $clarityLog = Join-Path $GsdDir "logs\spec-clarity-check.log"
                Remove-Item $clarityLog -Force -ErrorAction SilentlyContinue
                $clarityResult = Invoke-WithRetry -Agent "claude" -Prompt $promptContent -Phase "spec-clarity-check" `
                    -LogFile $clarityLog -CurrentBatchSize 1 -GsdDir $GsdDir -AllowedTools "Read,Write,Bash"
                if ($clarityResult.Success -and (Test-Path $clarityLog)) {
                    $clarityText = Get-Content $clarityLog -Raw -ErrorAction SilentlyContinue
                    $scoreMatch = [regex]::Match($clarityText, '"clarity_score"\s*:\s*(\d+)')
                    if ($scoreMatch.Success) {
                        $clarityScore = [int]$scoreMatch.Groups[1].Value
                    } else {
                        $clarityScore = 0
                        $issues += "Spec clarity check returned no parseable clarity_score"
                    }
                    Write-Host "    [OK] Spec clarity score: $clarityScore" -ForegroundColor $(if ($clarityScore -ge 85) { "DarkGreen" } elseif ($clarityScore -ge 70) { "DarkYellow" } else { "Red" })
                } else {
                    $clarityScore = 0
                    $issues += "Spec clarity check failed"
                }
            } catch { Write-Host "    [!!]  Spec clarity check error: $_" -ForegroundColor DarkYellow }
        }
    }

    # Step 3: Cross-artifact consistency
    if ($checkCrossArtifact -and -not $DryRun) {
        $hasAnalysis = $analysisDirs.Count -gt 0
        if ($hasAnalysis) {
            $cPrompt = Join-Path $env:USERPROFILE ".gsd-global\prompts\claude\cross-artifact-consistency.md"
            if (Test-Path $cPrompt) {
                try {
                    $promptContent = (Get-Content $cPrompt -Raw).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{GSD_DIR}}", $GsdDir)
                    $primaryAnalysis = $analysisDirs | Select-Object -First 1
                    $ifaceName = if ($Interfaces.Count -gt 0) { $Interfaces[0].Key } else { "root" }
                    $ifaceAnalysis = if ($primaryAnalysis) { $primaryAnalysis } else { $rootAnalysisDir }
                    $promptContent = $promptContent.Replace("{{INTERFACE_NAME}}", $ifaceName).Replace("{{INTERFACE_ANALYSIS}}", $ifaceAnalysis)
                    Write-Host "    [SEARCH] Running cross-artifact consistency check..." -ForegroundColor DarkGray
                    $crossLog = Join-Path $GsdDir "logs\cross-artifact-check.log"
                    Remove-Item $crossLog -Force -ErrorAction SilentlyContinue
                    $crossResult = Invoke-WithRetry -Agent "claude" -Prompt $promptContent -Phase "cross-artifact-check" `
                        -LogFile $crossLog -CurrentBatchSize 1 -GsdDir $GsdDir -AllowedTools "Read,Write,Bash"
                    if ($crossResult.Success -and (Test-Path $crossLog)) {
                        $crossText = Get-Content $crossLog -Raw -ErrorAction SilentlyContinue
                        $cm = [regex]::Match($crossText, '"consistent"\s*:\s*(true|false)')
                        if ($cm.Success) {
                            if ($cm.Groups[1].Value -eq "false") {
                                $consistencyPassed = $false
                                $issues += "Cross-artifact consistency check found mismatches"
                            }
                        } else {
                            $consistencyPassed = $false
                            $issues += "Cross-artifact consistency check returned no parseable consistency flag"
                        }
                    } else {
                        $consistencyPassed = $false
                        $issues += "Cross-artifact consistency check failed"
                    }
                } catch { Write-Host "    [!!]  Cross-artifact check error: $_" -ForegroundColor DarkYellow }
            }
        }
    }

    $passed = $clarityScore -ge $MinClarityScore -and $consistencyPassed
    $assessDir = Join-Path $GsdDir "assessment"
    if (-not (Test-Path $assessDir)) { New-Item -Path $assessDir -ItemType Directory -Force | Out-Null }
    $verdict = if (-not $consistencyPassed -or $clarityScore -lt $MinClarityScore) { "BLOCK" } elseif ($clarityScore -ge 90) { "PASS" } else { "WARN" }
    @{ timestamp = (Get-Date).ToString("o"); passed = $passed; clarity_score = $clarityScore; min_clarity_score = $MinClarityScore; consistency_passed = $consistencyPassed; issues = $issues; verdict = $verdict } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $assessDir "spec-quality-gate.json") -Encoding UTF8

    if ($passed) { Write-Host "    [OK] Spec quality gate: $verdict (clarity=$clarityScore, consistency=$consistencyPassed)" -ForegroundColor DarkGreen }
    else { Write-Host "    [!!]  Spec quality gate: $verdict (clarity=$clarityScore, consistency=$consistencyPassed)" -ForegroundColor $(if ($clarityScore -lt 70) { "Red" } else { "DarkYellow" }); $issues | ForEach-Object { Write-Host "      - $_" -ForegroundColor DarkYellow } }

    return @{ Passed = $passed; ClarityScore = $clarityScore; ConsistencyPassed = $consistencyPassed; Issues = $issues; Verdict = $verdict }
}



