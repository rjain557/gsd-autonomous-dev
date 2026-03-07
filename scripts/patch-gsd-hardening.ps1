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
                Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue
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
                $rawOutput = $effectivePrompt | codex exec --full-auto --json - 2>&1
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
| Agent CLI crash | Diagnose failure, fallback to alt agent, retry 3x at same batch |
| Agent exit code error | Diagnose root cause, auto-fallback (Gemini->Codex, Codex->Claude) |
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
