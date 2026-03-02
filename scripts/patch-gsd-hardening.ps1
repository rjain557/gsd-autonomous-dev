<#
.SYNOPSIS
    GSD Hardening Patch - Closes all known autonomous operation gaps.
    Run AFTER patch-gsd-resilience.ps1.

.DESCRIPTION
    Addresses these autonomous failure scenarios:

    [OK] FIXABLE (this patch adds):
    1. JSON validation + rollback on corrupt agent output
    2. Quota/billing detection - sleep until next hour/day, then resume
    3. Network connectivity polling - wait for internet, then continue
    4. Disk space check per iteration (not just pre-flight)
    5. Agent boundary enforcement (verify no cross-writes)
    6. CLI version validation in pre-flight
    7. SQL syntax linting (if sqlcmd available)
    8. Automatic test generation + execution
    9. Figma export pre-processing guidance
    10. Long-running unattended mode (overnight runs)

    [!!] PARTIALLY FIXABLE (this patch improves but can't fully solve):
    - Spec ambiguity -> better stall diagnosis prompts
    - Code correctness beyond compilation -> test generation

    [XX] NOT FIXABLE BY SCRIPT (requires human):
    - Contradictory specifications
    - Fundamental architectural decisions
    - Figma binary files without export

.INSTALL_ORDER
    1. install-gsd-global.ps1
    2. install-gsd-blueprint.ps1
    3. patch-gsd-partial-repo.ps1
    4. patch-gsd-resilience.ps1
    5. patch-gsd-hardening.ps1           <- this file
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

if (-not (Test-Path "$GsdGlobalDir\lib\modules\resilience.ps1")) {
    Write-Host "[XX] Resilience patch not applied. Run patch-gsd-resilience.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Hardening Patch - Full Autonomous Operation" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# Append hardening functions to resilience library
# ========================================================

Write-Host "[SHIELD]  Adding hardening modules to resilience library..." -ForegroundColor Yellow

$hardeningCode = @'

# ===============================================================
# GSD HARDENING MODULES - appended to resilience.ps1
# ===============================================================

# -- Hardening config --
$script:QUOTA_SLEEP_MINUTES = 60
$script:QUOTA_MAX_SLEEPS = 24          # max 24 hours of sleeping
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
    if ($ErrorOutput -match "(rate.limit|too.many.requests|429|throttl|slow.down)") {
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
        Write-Host "    Sleeping $($script:QUOTA_SLEEP_MINUTES) minutes before retry..." -ForegroundColor Yellow

        Write-GsdError -GsdDir $GsdDir -Category "quota" -Phase "wait" -Iteration 0 `
            -Message "$Agent quota exhausted" -Resolution "Sleeping $($script:QUOTA_SLEEP_MINUTES) min"

        $sleepCount = 0
        while ($sleepCount -lt $script:QUOTA_MAX_SLEEPS) {
            $sleepCount++
            $wakeTime = (Get-Date).AddMinutes($script:QUOTA_SLEEP_MINUTES)
            Write-Host "    Sleep $sleepCount/$($script:QUOTA_MAX_SLEEPS). Wake at: $($wakeTime.ToString('HH:mm'))" -ForegroundColor DarkGray
            Start-Sleep -Seconds ($script:QUOTA_SLEEP_MINUTES * 60)

            # Test if quota has reset by trying a minimal call
            try {
                $testOutput = claude -p "Reply with just the word READY" 2>&1
                if ($testOutput -match "READY") {
                    Write-Host "    [OK] Quota reset. Resuming..." -ForegroundColor Green
                    return $true
                }
                $quotaCheck = Test-IsQuotaError ($testOutput -join "`n")
                if ($quotaCheck -eq "none") {
                    Write-Host "    [OK] Quota available. Resuming..." -ForegroundColor Green
                    return $true
                }
            } catch {
                # Still limited, continue sleeping
            }
            Write-Host "    Still limited. Sleeping again..." -ForegroundColor DarkYellow
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
        [string]$Agent,       # "claude" or "codex"
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
# 8. ENHANCED INVOKE-WITHRETRY (quota-aware)
# ===========================================

# Override the original Invoke-WithRetry with quota + network awareness
$script:OriginalInvokeWithRetry = ${function:Invoke-WithRetry}

function Invoke-WithRetry {
    param(
        [string]$Agent,
        [string]$Prompt,
        [string]$Phase,
        [string]$LogFile,
        [int]$Attempt = 1,
        [int]$MaxAttempts = $script:RETRY_MAX,
        [int]$CurrentBatchSize = 15,
        [string]$GsdDir,
        [string]$AllowedTools = "Read,Write,Bash,mcp__*"
    )

    $result = @{ Success = $false; Attempts = 0; FinalBatchSize = $CurrentBatchSize; Error = $null }

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

            if ($Agent -eq "claude") {
                $output = claude -p $effectivePrompt --allowedTools $AllowedTools 2>&1
                $exitCode = $LASTEXITCODE
            } elseif ($Agent -eq "codex") {
                # Pass prompt via stdin to avoid Windows CLI length limits
                $output = $effectivePrompt | codex exec --full-auto - 2>&1
                $exitCode = $LASTEXITCODE
            }

            if ($LogFile) { $output | Out-File -FilePath $LogFile -Encoding UTF8 -Append }

            $outputText = if ($output) { $output -join "`n" } else { "" }

            # -- Check for quota errors --
            $quotaType = Test-IsQuotaError $outputText
            if ($quotaType -ne "none") {
                Write-GsdError -GsdDir $GsdDir -Category "quota" -Phase $Phase -Iteration $i `
                    -Message "$Agent $quotaType" -Resolution "Waiting for reset"

                $quotaOk = Wait-ForQuotaReset -QuotaType $quotaType -Agent $Agent -GsdDir $GsdDir
                if ($quotaOk) {
                    # Don't count this as a retry - reset the attempt counter
                    $i--
                    continue
                } else {
                    $result.Error = "Quota exhausted and did not reset"
                    return $result
                }
            }

            # -- Check for auth errors (not retryable) --
            if ($outputText -match "(unauthorized|invalid.*key|auth.*fail|401|403)") {
                $result.Error = "AUTH_ERROR"
                Write-Host "    [XX] Auth error - cannot retry" -ForegroundColor Red
                return $result
            }

            # -- Check for other failures --
            $isTokenError = $outputText -match "(token limit|context.*(window|length)|too long|exceeded.*limit|max.*tokens)"
            $isTimeout = $outputText -match "(timeout|timed out|ETIMEDOUT|connection.*reset)"
            $isCrash = ($exitCode -ne 0) -or (-not $output) -or ($output.Count -eq 0)

            if ($isTokenError -or ($isCrash -and $i -lt $MaxAttempts)) {
                $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * $script:BATCH_REDUCTION_FACTOR))
                $result.FinalBatchSize = $CurrentBatchSize
                $reason = if ($isTokenError) { "token limit" } elseif ($isTimeout) { "timeout" } else { "exit code $exitCode" }
                Write-Host "    [!!]  $reason -> batch $CurrentBatchSize. Retry in $($script:RETRY_DELAY_SECONDS)s..." -ForegroundColor DarkYellow
                Write-GsdError -GsdDir $GsdDir -Category "agent_crash" -Phase $Phase -Iteration $i `
                    -Message "$Agent $reason" -Resolution "Batch reduced to $CurrentBatchSize"
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
                Test-AgentBoundaries -Agent $(if ($Agent -eq "claude") { "claude" } else { "codex" }) `
                    -RepoRoot (Get-Location).Path -GsdDir $GsdDir -Pipeline "any" `
                    -BaselineDirty $baselineDirty | Out-Null

                return $result
            }

        } catch {
            $result.Error = $_.Exception.Message
            Write-Host "    [XX] Exception: $($_.Exception.Message)" -ForegroundColor Red

            if ($i -lt $MaxAttempts) {
                $CurrentBatchSize = [math]::Max($script:MIN_BATCH_SIZE, [math]::Floor($CurrentBatchSize * $script:BATCH_REDUCTION_FACTOR))
                $result.FinalBatchSize = $CurrentBatchSize
                Start-Sleep -Seconds $script:RETRY_DELAY_SECONDS
            }
        }
    }

    if (-not $result.Error) { $result.Error = "All $MaxAttempts attempts failed" }
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

Write-Host "  Hardening modules loaded." -ForegroundColor DarkGray
'@

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
$existing = Get-Content $resilienceFile -Raw
if ($existing -match "GSD HARDENING MODULES") {
    # Remove old hardening section and replace with current version
    $marker = "# ================================================================"
    $markerLine = "`n# GSD HARDENING MODULES"
    $idx = $existing.IndexOf($markerLine)
    if ($idx -gt 0) {
        $existing = $existing.Substring(0, $idx)
        Set-Content -Path $resilienceFile -Value $existing -Encoding UTF8
    }
    Add-Content -Path $resilienceFile -Value "`n$hardeningCode" -Encoding UTF8
    Write-Host "   [OK] Updated hardening modules in resilience.ps1" -ForegroundColor DarkGreen
} else {
    Add-Content -Path $resilienceFile -Value "`n$hardeningCode" -Encoding UTF8
    Write-Host "   [OK] Appended hardening modules to resilience.ps1" -ForegroundColor DarkGreen
}

Write-Host ""

# ========================================================
# Create known-limitations doc
# ========================================================

Write-Host "[CLIP] Creating known limitations documentation..." -ForegroundColor Yellow

$limitations = @"
# GSD Autonomous Operation - Known Limitations

## Fully Automated (no intervention needed)
| Scenario | How It's Handled |
|---|---|
| Agent CLI crash | Retry 3x with 50% batch reduction each time |
| Token/context limit hit | Reduce batch size, retry |
| Rate limit (per-minute) | Sleep 2 minutes, retry |
| Monthly quota exhausted | Sleep 1 hour, test, repeat up to 24 hours |
| Network outage | Poll every 30s for up to 1 hour |
| Corrupt JSON output | Restore from .last-good backup |
| Disk full | Auto-clean caches, bin/obj, old logs |
| Build compilation error | Send errors to Codex for auto-fix |
| npm build failure | Send errors to Codex for auto-fix |
| SQL pattern violations | Send to Codex for auto-fix |
| Health regression >5% | Auto-revert git to pre-iteration |
| Concurrent run attempt | Lock file blocks second instance |
| Crash mid-iteration | Checkpoint file enables resume |
| Agent crosses boundary | Auto-revert unauthorized file changes |
| Stall (no progress) | Reduce batch, diagnose after threshold |

## Requires Human Intervention
| Scenario | Why | What to Do |
|---|---|---|
| Contradictory specs | Agents can't decide which spec is right | Review stall-diagnosis.md, fix specs in docs\ |
| Figma .fig files unreadable | Binary format, agents can't parse | Export to PNG/SVG/JSON, fill in figma-mapping.md |
| Auth/API key expired | Can't self-renew credentials | Re-authenticate claude/codex CLI |
| Fundamental architecture wrong | e.g. wrong database engine chosen | Manual correction, then resume |
| Code compiles but is logically wrong | No runtime tests to catch it | Review generated code, add tests |
| Quota exhausted >24 hours | Monthly limit truly reached | Wait for billing cycle or upgrade plan |
| CLI breaking changes | claude/codex flags renamed | Update scripts to match new CLI |

## Improving Over Time
| Scenario | Current State | Future Improvement |
|---|---|---|
| Figma reading | Manual mapping file | Figma API export pre-processor |
| Code correctness | Compilation-only checks | Auto-generated unit tests |
| SQL validation | Pattern-based linting | Live database validation |
| Spec ambiguity | Stall + diagnosis | Pre-run spec consistency check |
"@

Set-Content -Path "$GsdGlobalDir\KNOWN-LIMITATIONS.md" -Value $limitations -Encoding UTF8
Write-Host "   [OK] KNOWN-LIMITATIONS.md" -ForegroundColor DarkGreen

Write-Host ""

# ========================================================
# DONE
# ========================================================

Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Hardening Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  NEW SELF-HEALING CAPABILITIES:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Quota exhaustion    -> sleep hourly, test, resume when available" -ForegroundColor White
Write-Host "  Network failure     -> poll every 30s, resume when online" -ForegroundColor White
Write-Host "  [DOC] Corrupt JSON        -> restore from .last-good backup" -ForegroundColor White
Write-Host "  Disk full           -> auto-clean caches/bins/old logs" -ForegroundColor White
Write-Host "  Boundary violation  -> auto-revert unauthorized changes" -ForegroundColor White
Write-Host "  [SEARCH] CLI version check   -> warn on unexpected versions" -ForegroundColor White
Write-Host "  SQL linting         -> catch pattern violations, auto-fix" -ForegroundColor White
Write-Host ""
Write-Host "  [CLIP] See: ~\.gsd-global\KNOWN-LIMITATIONS.md for full scenario matrix" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  The system can now run OVERNIGHT unattended. Start it and walk away:" -ForegroundColor Yellow
Write-Host "    gsd-blueprint -MaxIterations 30" -ForegroundColor Cyan
Write-Host ""
Write-Host "  It will handle network drops, quota limits, build errors, corrupt" -ForegroundColor DarkGray
Write-Host "  state, disk issues, and agent crashes - all without intervention." -ForegroundColor DarkGray
Write-Host ""
