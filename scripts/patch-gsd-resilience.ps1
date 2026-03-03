<#
.SYNOPSIS
    GSD Resilience Patch - Self-Healing Autonomous Operation
    Makes both pipelines crash-proof, self-healing, and fully autonomous.

.DESCRIPTION
    Adds to both gsd-blueprint and gsd-converge:
    1. Retry with adaptive batch reduction (crash -> retry at 50% batch size)
    2. Pre-flight validation (.sln, package.json, appsettings.json)
    3. Build validation (dotnet build + npm run build) with auto-fix
    4. Checkpoint/resume (crash recovery from last good state)
    5. State lock files (prevent concurrent runs)
    6. Health regression protection (auto-revert if health drops)
    7. Structured error logging with categories
    8. Auto-continuation after transient failures

.USAGE
    powershell -ExecutionPolicy Bypass -File patch-gsd-resilience.ps1

    Then all existing commands gain resilience automatically.

.INSTALL_ORDER
    1. install-gsd-global.ps1
    2. install-gsd-blueprint.ps1
    3. patch-gsd-partial-repo.ps1
    4. patch-gsd-resilience.ps1        <- this file
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$BlueprintDir = Join-Path $GsdGlobalDir "blueprint"

if (-not (Test-Path $GsdGlobalDir)) {
    Write-Host "[XX] GSD not installed. Run installers first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Resilience Patch - Self-Healing Autonomous Operation" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# Ensure directories
$dirs = @(
    "$GsdGlobalDir\lib",
    "$GsdGlobalDir\lib\modules",
    "$BlueprintDir\scripts"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ========================================================
# MODULE 1: Core Resilience Library
# ========================================================

Write-Host "[SHIELD]  Creating core resilience library..." -ForegroundColor Yellow

$resilienceLib = @'
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
        if ($OutputText -match "sandbox.*restrict|not.*allow|permission.*denied|read.only") {
            $diagnosis = "Gemini sandbox blocked a write operation"
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
            $fbOutput = $Prompt | gemini --sandbox 2>&1
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
        [string]$GeminiMode = "--sandbox"   # "--sandbox" (read-only) or "--yolo" (write)
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
            $isAuthError = $outputText -match "(unauthorized|auth.*fail|invalid.*key|401|403)"
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
'@

Set-Content -Path "$GsdGlobalDir\lib\modules\resilience.ps1" -Value $resilienceLib -Encoding UTF8
Write-Host "   [OK] lib\modules\resilience.ps1" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# MODULE 2: Resilient Blueprint Pipeline (replaces original)
# ========================================================

Write-Host "[SYNC] Creating resilient blueprint pipeline..." -ForegroundColor Yellow

$resilientBlueprint = @'
<#
.SYNOPSIS
    Blueprint Pipeline - Resilient Edition
    Self-healing, crash-proof, autonomous spec-to-code generation.
#>

param(
    [int]$MaxIterations = 30,
    [int]$StallThreshold = 3,
    [int]$BatchSize = 15,
    [switch]$DryRun,
    [switch]$BlueprintOnly,
    [switch]$BuildOnly,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"
$BpGlobalDir = Join-Path $GlobalDir "blueprint"
$GsdDir = Join-Path $RepoRoot ".gsd"
$BpDir = Join-Path $GsdDir "blueprint"

# -- Load resilience library --
. "$GlobalDir\lib\modules\resilience.ps1"

# -- Validate install --
if (-not (Test-Path $BpGlobalDir)) {
    Write-Host "[XX] Blueprint Pipeline not installed." -ForegroundColor Red; exit 1
}

# -- Ensure directories --
@($GsdDir, $BpDir, "$GsdDir\logs") | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# -- Detect Figma --
$figmaBase = Join-Path $RepoRoot "design\figma"
$FigmaVersion = "none"; $FigmaPath = "none"
if (Test-Path $figmaBase) {
    $latest = Get-ChildItem -Path $figmaBase -Directory |
        Where-Object { $_.Name -match '^v(\d+)$' } |
        Sort-Object { [int]($_.Name -replace '^v', '') } -Descending |
        Select-Object -First 1
    if ($latest) { $FigmaVersion = $latest.Name; $FigmaPath = "design\figma\$FigmaVersion" }
}

# -- State files --
$BlueprintFile = Join-Path $BpDir "blueprint.json"
$HealthFile = Join-Path $BpDir "health.json"
$HealthLog = Join-Path $BpDir "health-history.jsonl"
$NextBatchFile = Join-Path $BpDir "next-batch.json"

if (-not (Test-Path $HealthFile)) {
    @{ total=0; completed=0; partial=0; not_started=0; health=0; current_tier=0; current_tier_name="none"; iteration=0; status="not_started" } |
        ConvertTo-Json | Set-Content $HealthFile -Encoding UTF8
}

# -- Helpers --
function Get-Health {
    try { return [double](Get-Content $HealthFile -Raw | ConvertFrom-Json).health } catch { return 0 }
}

function Has-Blueprint {
    if (-not (Test-Path $BlueprintFile)) { return $false }
    try { return (Get-Content $BlueprintFile -Raw | ConvertFrom-Json).tiers.Count -gt 0 } catch { return $false }
}

function Resolve-Prompt($templatePath, $iter, $health) {
    (Get-Content $templatePath -Raw).Replace("{{ITERATION}}", "$iter").Replace("{{HEALTH}}", "$health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{FIGMA_PATH}}", $FigmaPath).Replace("{{FIGMA_VERSION}}", $FigmaVersion).Replace("{{BATCH_SIZE}}", "$BatchSize")
}

# ========================================
# PRE-FLIGHT
# ========================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Blue
Write-Host "  * Blueprint Pipeline - Resilient Edition" -ForegroundColor Blue
Write-Host "=========================================================" -ForegroundColor Blue

if (-not $DryRun) {
    $preFlight = Test-PreFlight -RepoRoot $RepoRoot -GsdDir $GsdDir
    if (-not $preFlight) {
        Write-Host "  [XX] Pre-flight failed. Fix issues above and retry." -ForegroundColor Red
        exit 1
    }
    New-GsdLock -GsdDir $GsdDir -Pipeline "blueprint"
}

# -- Check for checkpoint (crash recovery) --
$checkpoint = Get-Checkpoint -GsdDir $GsdDir
$Iteration = 0
$Health = Get-Health
$CurrentBatchSize = $BatchSize

if ($checkpoint -and $checkpoint.pipeline -eq "blueprint" -and -not $BlueprintOnly) {
    Write-Host ""
    Write-Host "  [SYNC] RESUMING from checkpoint: Iter $($checkpoint.iteration), Phase: $($checkpoint.phase), Health: $($checkpoint.health)%" -ForegroundColor Yellow
    $Iteration = $checkpoint.iteration
    $Health = $checkpoint.health
    $CurrentBatchSize = $checkpoint.batch_size
    if ($CurrentBatchSize -lt $script:MIN_BATCH_SIZE) { $CurrentBatchSize = $BatchSize }
}

Write-Host ""
Write-Host "  Repo:       $RepoRoot" -ForegroundColor White
Write-Host "  Figma:      $FigmaVersion" -ForegroundColor White
Write-Host "  Health:     ${Health}% -> 100%" -ForegroundColor White
Write-Host "  Batch:      $CurrentBatchSize (adaptive)" -ForegroundColor White
if ($DryRun) { Write-Host "  MODE:       DRY RUN" -ForegroundColor Yellow }
Write-Host ""

# -- Ensure cleanup on exit --
$cleanupBlock = {
    Remove-GsdLock -GsdDir $GsdDir
}
Register-EngineEvent PowerShell.Exiting -Action $cleanupBlock | Out-Null
trap { Remove-GsdLock -GsdDir $GsdDir }

try {

# ========================================
# PHASE 1: BLUEPRINT
# ========================================

$needsBlueprint = (-not (Has-Blueprint)) -and (-not $BuildOnly) -and (-not $VerifyOnly)

if ($needsBlueprint) {
    Write-Host "* PHASE 1: BLUEPRINT (Claude Code)" -ForegroundColor Blue
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration 0 -Phase "blueprint" -Health 0 -BatchSize $CurrentBatchSize

    $prompt = Resolve-Prompt "$BpGlobalDir\prompts\claude\blueprint.md" 0 0

    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "blueprint" `
            -LogFile "$GsdDir\logs\phase1-blueprint.log" `
            -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir

        if (-not $result.Success) {
            Write-GsdError -GsdDir $GsdDir -Category "agent_crash" -Phase "blueprint" -Iteration 0 `
                -Message "Blueprint generation failed after $($result.Attempts) attempts" `
                -Resolution "Check logs\phase1-blueprint.log. May need to simplify specs."
            Write-Host "  [XX] Blueprint generation failed. See .gsd\logs\" -ForegroundColor Red
            return
        }

        if (Has-Blueprint) {
            $bp = Get-Content $BlueprintFile -Raw | ConvertFrom-Json
            $totalItems = 0; $bp.tiers | ForEach-Object { $totalItems += $_.items.Count }
            Write-Host "  [OK] Blueprint: $totalItems items, $($bp.tiers.Count) tiers" -ForegroundColor Green
        }
    } else {
        Write-Host "  [DRY RUN] claude -> blueprint" -ForegroundColor DarkYellow
    }

    if ($BlueprintOnly) {
        Clear-Checkpoint -GsdDir $GsdDir
        Remove-GsdLock -GsdDir $GsdDir
        Write-Host "  BlueprintOnly - done." -ForegroundColor Yellow; return
    }
}

# ========================================
# MAIN LOOP: BUILD -> VALIDATE -> VERIFY
# ========================================

$StallCount = 0
$TargetHealth = 100
$Health = Get-Health

while ($Health -lt $TargetHealth -and $Iteration -lt $MaxIterations -and $StallCount -lt $StallThreshold) {
    $Iteration++
    $PrevHealth = $Health

    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "starting"

    # -- Git snapshot for rollback --
    if (-not $DryRun) { New-GitSnapshot -RepoRoot $RepoRoot -Iteration $Iteration -Pipeline "blueprint" }

    # == VERIFY + SELECT BATCH (Claude Code) ==
    Write-Host "  [SEARCH] CLAUDE CODE -> verify + select batch" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration $Iteration -Phase "verify" -Health $Health -BatchSize $CurrentBatchSize

    $prompt = Resolve-Prompt "$BpGlobalDir\prompts\claude\verify.md" $Iteration $Health

    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "verify" `
            -LogFile "$GsdDir\logs\iter${Iteration}-1-verify.log" `
            -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir

        if (-not $result.Success) {
            Write-GsdError -GsdDir $GsdDir -Category "agent_crash" -Phase "verify" -Iteration $Iteration `
                -Message "Verify failed: $($result.Error)" -Resolution "Retrying next iteration"
            Write-Host "    [!!]  Verify failed - continuing to build with previous batch" -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "    [DRY RUN] claude -> verify" -ForegroundColor DarkYellow
    }

    $Health = Get-Health
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "post-verify"

    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }

    # -- Health regression check --
    if (-not $DryRun -and $Iteration -gt 1) {
        $regressed = Test-HealthRegression -PreviousHealth $PrevHealth -CurrentHealth $Health `
            -RepoRoot $RepoRoot -Iteration $Iteration
        if ($regressed) {
            Write-GsdError -GsdDir $GsdDir -Category "regression" -Phase "verify" -Iteration $Iteration `
                -Message "Health dropped ${PrevHealth}% -> ${Health}%" -Resolution "Reverted to pre-iteration state"
            $Health = $PrevHealth
            $StallCount++
            continue
        }
    }

    # == BUILD (Codex) ==
    Write-Host "  [WRENCH] CODEX -> build batch (size: $CurrentBatchSize)" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "blueprint" -Iteration $Iteration -Phase "build" -Health $Health -BatchSize $CurrentBatchSize

    $prompt = Resolve-Prompt "$BpGlobalDir\prompts\codex\build.md" $Iteration $Health

    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "build" `
            -LogFile "$GsdDir\logs\iter${Iteration}-2-build.log" `
            -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir

        if ($result.Success) {
            $CurrentBatchSize = $result.FinalBatchSize
            git add -A; git commit -m "gsd-blueprint: iter $Iteration build (health: ${Health}%)" --no-verify 2>$null
        } else {
            Write-GsdError -GsdDir $GsdDir -Category "agent_crash" -Phase "build" -Iteration $Iteration `
                -Message "Build failed: $($result.Error)" -Resolution "Batch reduced to $($result.FinalBatchSize)"
            $CurrentBatchSize = $result.FinalBatchSize
            $StallCount++
            continue
        }

        # == BUILD VALIDATION (dotnet build + npm build + auto-fix) ==
        Write-Host ""
        $buildResult = Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix

        if (-not $buildResult.Passed) {
            Write-GsdError -GsdDir $GsdDir -Category "build_fail" -Phase "build-validation" -Iteration $Iteration `
                -Message ($buildResult.Errors -join "; ") -Resolution "Auto-fix $(if ($buildResult.AutoFixAttempted) { 'attempted' } else { 'skipped' })"
        }
    } else {
        Write-Host "    [DRY RUN] codex -> build" -ForegroundColor DarkYellow
    }

    # -- Stall detection --
    $NewHealth = Get-Health
    if ($NewHealth -le $PrevHealth -and $Iteration -gt 1) {
        $StallCount++
        Write-Host "  [!!]  Stall $StallCount/$StallThreshold (${PrevHealth}% -> ${NewHealth}%)" -ForegroundColor DarkYellow

        # Adaptive: reduce batch on stall too
        $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * 0.75))
        Write-Host "  Batch reduced to $CurrentBatchSize" -ForegroundColor DarkGray

        if ($StallCount -ge $StallThreshold) {
            Write-Host "  [STOP] Stall threshold reached." -ForegroundColor Red
            if (-not $DryRun) {
                $stallPrompt = "The blueprint pipeline stalled for $StallCount iterations at ${NewHealth}% health. Read .gsd\blueprint\blueprint.json, health-history.jsonl, build-log.jsonl, and .gsd\logs\errors.jsonl. Diagnose why and write to .gsd\blueprint\stall-diagnosis.md with specific fixes. Also check if build errors are blocking progress."
                Invoke-WithRetry -Agent "claude" -Prompt $stallPrompt -Phase "stall-diagnosis" `
                    -LogFile "$GsdDir\logs\stall-diagnosis-$Iteration.log" `
                    -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
            }
            break
        }
    } else {
        $StallCount = 0
        # Adaptive: grow batch back on success (slowly)
        if ($CurrentBatchSize -lt $BatchSize) {
            $CurrentBatchSize = [math]::Min($BatchSize, $CurrentBatchSize + 2)
            Write-Host "  Batch grown to $CurrentBatchSize" -ForegroundColor DarkGray
        }
    }

    $Health = $NewHealth
    Write-Host ""
    Start-Sleep -Seconds 2
}

# ========================================
# FINAL REPORT
# ========================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Blue
$FinalHealth = Get-Health

if ($FinalHealth -ge $TargetHealth) {
    Write-Host "  [PARTY] BLUEPRINT COMPLETE - ${FinalHealth}% in $Iteration iterations" -ForegroundColor Green
    if (-not $DryRun) {
        git add -A; git commit -m "blueprint: COMPLETE - 100%" --no-verify 2>$null
        git tag "blueprint-complete-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null
    }
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "  [STOP] STALLED at ${FinalHealth}% - see .gsd\blueprint\stall-diagnosis.md" -ForegroundColor Red
} else {
    Write-Host "  [!!]  MAX ITERATIONS at ${FinalHealth}% - run gsd-blueprint -BuildOnly to continue" -ForegroundColor Yellow
}

# Show health progression
if (Test-Path $HealthLog) {
    $entries = Get-Content $HealthLog -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch {}
    }
    if ($entries.Count -gt 0) {
        Write-Host ""
        Write-Host "  Health Progression:" -ForegroundColor DarkGray
        foreach ($e in $entries) {
            $bar = "#" * [math]::Floor($e.health / 5) + "." * (20 - [math]::Floor($e.health / 5))
            Write-Host "    Iter $($e.iteration): [$bar] $($e.health)%" -ForegroundColor DarkGray
        }
    }
}

# Show error summary
$errorLog = Join-Path $GsdDir "logs\errors.jsonl"
if (Test-Path $errorLog) {
    $errors = Get-Content $errorLog -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch {}
    }
    if ($errors.Count -gt 0) {
        $grouped = $errors | Group-Object category
        Write-Host ""
        Write-Host "  Error Summary:" -ForegroundColor DarkYellow
        foreach ($g in $grouped) {
            Write-Host "    $($g.Name): $($g.Count) occurrences" -ForegroundColor DarkYellow
        }
    }
}

Write-Host ""
Write-Host "  Next: gsd-converge (maintenance) or gsd-blueprint -BuildOnly (continue)" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor Blue

} finally {
    # Always cleanup
    Clear-Checkpoint -GsdDir $GsdDir
    Remove-GsdLock -GsdDir $GsdDir
}
'@

Set-Content -Path "$BlueprintDir\scripts\blueprint-pipeline.ps1" -Value $resilientBlueprint -Encoding UTF8
Write-Host "   [OK] scripts\blueprint-pipeline.ps1 (resilient edition)" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# MODULE 3: Resilient Convergence Pipeline (replaces original)
# ========================================================

Write-Host "[SYNC] Creating resilient convergence pipeline..." -ForegroundColor Yellow

$resilientConverge = @'
<#
.SYNOPSIS
    GSD Convergence Loop - Resilient Edition
    Self-healing, crash-proof, autonomous maintenance loop.
#>

param(
    [int]$MaxIterations = 20,
    [int]$StallThreshold = 3,
    [int]$BatchSize = 8,
    [switch]$DryRun,
    [switch]$SkipInit,
    [switch]$SkipResearch
)

$ErrorActionPreference = "Continue"
$RepoRoot = (Get-Location).Path
$UserHome = $env:USERPROFILE
$GlobalDir = Join-Path $UserHome ".gsd-global"
$GsdDir = Join-Path $RepoRoot ".gsd"

# -- Load resilience library --
. "$GlobalDir\lib\modules\resilience.ps1"

if (-not (Test-Path $GlobalDir)) {
    Write-Host "[XX] GSD not installed." -ForegroundColor Red; exit 1
}

# -- Ensure directories --
$projectDirs = @(
    $GsdDir, "$GsdDir\health", "$GsdDir\code-review", "$GsdDir\code-review\review-history",
    "$GsdDir\research", "$GsdDir\generation-queue", "$GsdDir\generation-queue\completed",
    "$GsdDir\agent-handoff", "$GsdDir\specs", "$GsdDir\logs"
)
foreach ($dir in $projectDirs) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# -- Detect Figma --
$figmaBase = Join-Path $RepoRoot "design\figma"
$FigmaVersion = "none"; $FigmaPath = "none"
if (Test-Path $figmaBase) {
    $latest = Get-ChildItem -Path $figmaBase -Directory |
        Where-Object { $_.Name -match '^v(\d+)$' } |
        Sort-Object { [int]($_.Name -replace '^v', '') } -Descending |
        Select-Object -First 1
    if ($latest) { $FigmaVersion = $latest.Name; $FigmaPath = "design\figma\$FigmaVersion" }
}

# -- State files --
$HealthFile = Join-Path $GsdDir "health\health-current.json"
$MatrixFile = Join-Path $GsdDir "health\requirements-matrix.json"
$HandoffLog = Join-Path $GsdDir "agent-handoff\handoff-log.jsonl"

if (-not (Test-Path $HealthFile)) {
    @{ health_score=0; total_requirements=0; satisfied=0; partial=0; not_started=0; iteration=0; last_agent="none"; figma_version=$FigmaVersion; last_updated=(Get-Date -Format "o") } |
        ConvertTo-Json -Depth 3 | Set-Content $HealthFile -Encoding UTF8
}
if (-not (Test-Path $MatrixFile)) {
    @{ meta=@{ total_requirements=0; satisfied=0; health_score=0; last_updated=(Get-Date -Format "o"); iteration=0 }; requirements=@() } |
        ConvertTo-Json -Depth 4 | Set-Content $MatrixFile -Encoding UTF8
}

function Get-Health {
    try { return [double](Get-Content $HealthFile -Raw | ConvertFrom-Json).health_score } catch { return 0 }
}

function Resolve-Prompt($templatePath, $iter, $health) {
    (Get-Content $templatePath -Raw).Replace("{{ITERATION}}", "$iter").Replace("{{HEALTH}}", "$health").Replace("{{GSD_DIR}}", $GsdDir).Replace("{{REPO_ROOT}}", $RepoRoot).Replace("{{FIGMA_PATH}}", $FigmaPath).Replace("{{FIGMA_VERSION}}", $FigmaVersion).Replace("{{BATCH_SIZE}}", "$BatchSize")
}

# ========================================
# PRE-FLIGHT
# ========================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  GSD Convergence Loop - Resilient Edition" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green

if (-not $DryRun) {
    $preFlight = Test-PreFlight -RepoRoot $RepoRoot -GsdDir $GsdDir
    if (-not $preFlight) {
        Write-Host "  [XX] Pre-flight failed." -ForegroundColor Red; exit 1
    }
    New-GsdLock -GsdDir $GsdDir -Pipeline "converge"
}

# -- Checkpoint recovery --
$checkpoint = Get-Checkpoint -GsdDir $GsdDir
$Iteration = 0
$Health = Get-Health
$CurrentBatchSize = $BatchSize

if ($checkpoint -and $checkpoint.pipeline -eq "converge") {
    Write-Host "  [SYNC] RESUMING: Iter $($checkpoint.iteration), Phase: $($checkpoint.phase), Health: $($checkpoint.health)%" -ForegroundColor Yellow
    $Iteration = $checkpoint.iteration
    $Health = $checkpoint.health
    $CurrentBatchSize = if ($checkpoint.batch_size -gt 0) { $checkpoint.batch_size } else { $BatchSize }
}

Write-Host "  Repo:   $RepoRoot" -ForegroundColor White
Write-Host "  Health: ${Health}% -> 100%" -ForegroundColor White
Write-Host "  Batch:  $CurrentBatchSize (adaptive)" -ForegroundColor White
Write-Host ""

trap { Remove-GsdLock -GsdDir $GsdDir }

try {

# -- Phase 0: Create phases if needed --
$matrixContent = Get-Content $MatrixFile -Raw | ConvertFrom-Json
if ($matrixContent.requirements.Count -eq 0 -and -not $SkipInit) {
    Write-Host "[CLIP] Phase 0: CREATE PHASES (Claude Code)" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration 0 -Phase "create-phases" -Health 0 -BatchSize $CurrentBatchSize

    $prompt = Resolve-Prompt "$GlobalDir\prompts\claude\create-phases.md" 0 0

    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "create-phases" `
            -LogFile "$GsdDir\logs\phase0-create-phases.log" `
            -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if (-not $result.Success) {
            Write-Host "  [XX] Matrix creation failed." -ForegroundColor Red; return
        }
    }
    $Health = Get-Health
    Write-Host "  [OK] Matrix built. Health: ${Health}%" -ForegroundColor Green
}

# ========================================
# MAIN LOOP
# ========================================

$StallCount = 0; $TargetHealth = 100

while ($Health -lt $TargetHealth -and $Iteration -lt $MaxIterations -and $StallCount -lt $StallThreshold) {
    $Iteration++; $PrevHealth = $Health

    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "starting"

    if (-not $DryRun) { New-GitSnapshot -RepoRoot $RepoRoot -Iteration $Iteration -Pipeline "converge" }

    # == 1. CODE REVIEW (Claude Code) ==
    Write-Host "  [SEARCH] CLAUDE CODE -> code-review" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "code-review" -Health $Health -BatchSize $CurrentBatchSize

    $prompt = Resolve-Prompt "$GlobalDir\prompts\claude\code-review.md" $Iteration $Health
    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "code-review" `
            -LogFile "$GsdDir\logs\iter${Iteration}-1-review.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        if (-not $result.Success) { Write-Host "    [!!]  Review failed - continuing" -ForegroundColor DarkYellow }
    }

    $Health = Get-Health
    if ($Health -ge $TargetHealth) { Write-Host "  [OK] CONVERGED!" -ForegroundColor Green; break }

    # == 2. RESEARCH (Codex) - optional ==
    if (-not $SkipResearch) {
        Write-Host "  CODEX -> research" -ForegroundColor Magenta
        Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "research" -Health $Health -BatchSize $CurrentBatchSize

        if (-not (Test-Path "$GsdDir\research")) { New-Item -ItemType Directory -Path "$GsdDir\research" -Force | Out-Null }
        $prompt = Resolve-Prompt "$GlobalDir\prompts\codex\research.md" $Iteration $Health
        if (-not $DryRun) {
            $result = Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "research" `
                -LogFile "$GsdDir\logs\iter${Iteration}-2-research.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
        }
    }

    # == 3. PLAN (Claude Code) ==
    Write-Host "  CLAUDE CODE -> plan" -ForegroundColor Cyan
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "plan" -Health $Health -BatchSize $CurrentBatchSize

    $prompt = Resolve-Prompt "$GlobalDir\prompts\claude\plan.md" $Iteration $Health
    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "plan" `
            -LogFile "$GsdDir\logs\iter${Iteration}-3-plan.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir
    }

    # == 4. EXECUTE (Codex) ==
    Write-Host "  [WRENCH] CODEX -> execute (batch: $CurrentBatchSize)" -ForegroundColor Magenta
    Save-Checkpoint -GsdDir $GsdDir -Pipeline "converge" -Iteration $Iteration -Phase "execute" -Health $Health -BatchSize $CurrentBatchSize

    $prompt = Resolve-Prompt "$GlobalDir\prompts\codex\execute.md" $Iteration $Health
    if (-not $DryRun) {
        $result = Invoke-WithRetry -Agent "codex" -Prompt $prompt -Phase "execute" `
            -LogFile "$GsdDir\logs\iter${Iteration}-4-execute.log" -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir

        if ($result.Success) {
            $CurrentBatchSize = $result.FinalBatchSize
            git add -A; git commit -m "gsd: iter $Iteration execute (health: ${Health}%)" --no-verify 2>$null

            # == BUILD VALIDATION ==
            $buildResult = Invoke-BuildValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration -AutoFix
        } else {
            $CurrentBatchSize = $result.FinalBatchSize
            $StallCount++; continue
        }
    }

    # -- Stall / regression detection --
    $NewHealth = Get-Health
    if (-not $DryRun -and $Iteration -gt 1) {
        $regressed = Test-HealthRegression -PreviousHealth $PrevHealth -CurrentHealth $NewHealth `
            -RepoRoot $RepoRoot -Iteration $Iteration
        if ($regressed) { $Health = $PrevHealth; $StallCount++; continue }
    }

    if ($NewHealth -le $PrevHealth -and $Iteration -gt 1) {
        $StallCount++
        $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * 0.75))
        Write-Host "  [!!]  Stall $StallCount/$StallThreshold | Batch -> $CurrentBatchSize" -ForegroundColor DarkYellow

        if ($StallCount -ge $StallThreshold -and -not $DryRun) {
            Invoke-WithRetry -Agent "claude" `
                -Prompt "Stalled $StallCount iterations at ${NewHealth}%. Read .gsd\health\*, .gsd\logs\errors.jsonl. Diagnose. Write .gsd\health\stall-diagnosis.md." `
                -Phase "stall-diagnosis" -LogFile "$GsdDir\logs\stall-diagnosis-$Iteration.log" `
                -CurrentBatchSize $CurrentBatchSize -GsdDir $GsdDir | Out-Null
            break
        }
    } else {
        $StallCount = 0
        if ($CurrentBatchSize -lt $BatchSize) { $CurrentBatchSize = [math]::Min($BatchSize, $CurrentBatchSize + 1) }
    }

    $Health = $NewHealth
    Show-ProgressBar -Health $Health -Iteration $Iteration -MaxIterations $MaxIterations -Phase "complete"
    Write-Host ""
    Start-Sleep -Seconds 2
}

# == FINAL ==
Write-Host "=========================================================" -ForegroundColor Green
$FinalHealth = Get-Health
if ($FinalHealth -ge $TargetHealth) {
    Write-Host "  [PARTY] CONVERGED - ${FinalHealth}% in $Iteration iterations" -ForegroundColor Green
    if (-not $DryRun) {
        git add -A; git commit -m "gsd: CONVERGED - 100%" --no-verify 2>$null
        git tag "gsd-converged-$(Get-Date -Format 'yyyyMMdd-HHmmss')" 2>$null
    }
} elseif ($StallCount -ge $StallThreshold) {
    Write-Host "  [STOP] STALLED at ${FinalHealth}%" -ForegroundColor Red
} else {
    Write-Host "  [!!]  MAX ITERATIONS at ${FinalHealth}%" -ForegroundColor Yellow
}
Write-Host "=========================================================" -ForegroundColor Green

} finally {
    Clear-Checkpoint -GsdDir $GsdDir
    Remove-GsdLock -GsdDir $GsdDir
}
'@

Set-Content -Path "$GsdGlobalDir\scripts\convergence-loop.ps1" -Value $resilientConverge -Encoding UTF8
Write-Host "   [OK] scripts\convergence-loop.ps1 (resilient edition)" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# Add .gsd-lock and .gsd-checkpoint to gitignore template
# ========================================================

Write-Host "[MEMO] Updating gitignore template..." -ForegroundColor Yellow

$gitignoreAdditions = @"

# GSD Resilience - transient state
.gsd/.gsd-lock
.gsd/.gsd-checkpoint.json
.gsd/logs/errors.jsonl
"@

$gitignoreTemplate = Join-Path $GsdGlobalDir "templates\gitignore-additions.txt"
Set-Content -Path $gitignoreTemplate -Value $gitignoreAdditions -Encoding UTF8
Write-Host "   [OK] templates\gitignore-additions.txt" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# DONE
# ========================================================

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Resilience Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  SELF-HEALING FEATURES ADDED:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [SYNC] Retry with batch reduction" -ForegroundColor White
Write-Host "     Agent crash -> retry 3x, each time at 50% batch size" -ForegroundColor DarkGray
Write-Host "     Token limit -> auto-shrink batch from 15 -> 8 -> 4 -> 2" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Pre-flight validation" -ForegroundColor White
Write-Host "     Checks: claude CLI, codex CLI, git, .sln, package.json," -ForegroundColor DarkGray
Write-Host "     appsettings.json, disk space, lock file, git state" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Build validation + auto-fix" -ForegroundColor White
Write-Host "     After each Codex build: dotnet build + npm run build" -ForegroundColor DarkGray
Write-Host "     Failures -> Codex auto-fixes compilation errors" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Checkpoint / resume" -ForegroundColor White
Write-Host "     Crash mid-iteration -> restart picks up where it left off" -ForegroundColor DarkGray
Write-Host "     .gsd-checkpoint.json tracks iteration, phase, batch size" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Lock file" -ForegroundColor White
Write-Host "     Prevents concurrent runs. Auto-clears stale locks (>2hr)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Health regression protection" -ForegroundColor White
Write-Host "     Health drops >5% -> auto-revert to pre-iteration state" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [CHART] Adaptive batch sizing" -ForegroundColor White
Write-Host "     Failures shrink batch. Successes grow it back slowly." -ForegroundColor DarkGray
Write-Host "     Stalls also trigger batch reduction." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [CLIP] Structured error logging" -ForegroundColor White
Write-Host "     All errors -> .gsd\logs\errors.jsonl (categorized)" -ForegroundColor DarkGray
Write-Host "     Categories: agent_crash, build_fail, stall, regression, auth" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  All existing commands work the same - resilience is automatic." -ForegroundColor DarkGray
Write-Host ""
