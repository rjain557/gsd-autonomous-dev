<#
.SYNOPSIS
    GSD Resilience Hardening -- Token Tracking, Auth Detection, Quota Recovery
    Run AFTER patch-gsd-parallel-execute.ps1.

.DESCRIPTION
    Fixes four resilience gaps in the autonomous operation pipeline:

    P1: Token costs only tracked on success -- adds per-attempt tracking for
        quota, auth, and crash failures + probe cost tracking + cost estimation
        when agents return error text instead of JSON.

    P2: Auth regex misclassifies 403 rate limits -- removes 403 from auth
        detection, adds rate-limit exclusion guard, routes Gemini 403
        (Resource Exhausted) to proper quota backoff.

    P3: No cumulative quota wait cap -- adds 2-hour total wait cap across
        all retries so the pipeline doesn't sleep for 14+ hours.

    P4: No agent rotation on quota exhaustion -- after 3 consecutive quota
        failures on the same agent, automatically rotates to a different
        agent from the pool (codex/claude/gemini).

    New runtime file:
        .gsd\supervisor\agent-cooldowns.json  (auto-created, tracks agent cooldowns)

.INSTALL_ORDER
    1. install-gsd-global.ps1
    2. install-gsd-blueprint.ps1
    3. patch-gsd-partial-repo.ps1
    4. patch-gsd-resilience.ps1
    5. patch-gsd-hardening.ps1
    6. patch-gsd-final-validation.ps1
    7. patch-gsd-council.ps1
    8. patch-gsd-figma-make.ps1
    9-15. final-patch-1 through final-patch-7
    16. patch-gsd-supervisor.ps1
    17. patch-gsd-parallel-execute.ps1
    18. patch-gsd-resilience-hardening.ps1    <- this file
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$resiliencePath = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"

if (-not (Test-Path $resiliencePath)) {
    Write-Host "[XX] Resilience module not found. Run patch-gsd-resilience.ps1 first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Resilience Hardening -- Token Tracking, Auth, Quota" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ========================================================
# Read resilience.ps1 for in-place modifications
# ========================================================

$content = Get-Content $resiliencePath -Raw
$changeCount = 0

# ========================================================
# Fix 2A: Auth regex in watchdog path -- remove 403, add exclusion
# ========================================================

Write-Host "[FIX 2A] Fixing auth regex in watchdog path (remove 403)..." -ForegroundColor Yellow

$oldAuthWatchdog = '$isAuthError = $outputText -match "(unauthorized|auth.*fail|invalid.*key|401|403)"'
$newAuthWatchdog = @'
$isAuthError = $outputText -match "(unauthorized|auth.*fail|invalid.*key|401)" -and
               $outputText -notmatch "(rate|quota|resource.exhausted|too.many|throttl)"
'@

if ($content.Contains($oldAuthWatchdog)) {
    $content = $content.Replace($oldAuthWatchdog, $newAuthWatchdog)
    $changeCount++
    Write-Host "   [OK] Watchdog auth regex updated" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Watchdog auth regex already patched or not found" -ForegroundColor DarkGray
}

# ========================================================
# Fix 2B: Auth regex in Invoke-WithRetry -- remove 403, add exclusion
# ========================================================

Write-Host "[FIX 2B] Fixing auth regex in Invoke-WithRetry (remove 403)..." -ForegroundColor Yellow

$oldAuthRetry = 'if ($outputText -match "(unauthorized|invalid.*key|auth.*fail|401|403)") {'
$newAuthRetry = @'
if ($outputText -match "(unauthorized|invalid.*key|auth.*fail|401)" -and
    $outputText -notmatch "(rate|quota|resource.exhausted|too.many|throttl)") {
'@

if ($content.Contains($oldAuthRetry)) {
    $content = $content.Replace($oldAuthRetry, $newAuthRetry)
    $changeCount++
    Write-Host "   [OK] Invoke-WithRetry auth regex updated" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Invoke-WithRetry auth regex already patched or not found" -ForegroundColor DarkGray
}

# ========================================================
# Fix 2C: Add 403+resource.exhausted to quota detection
# ========================================================

Write-Host "[FIX 2C] Adding 403+resource.exhausted to Test-IsQuotaError..." -ForegroundColor Yellow

$oldQuotaDetect = @'
    if ($ErrorOutput -match "(rate.limit|too.many.requests|429|throttl|slow.down)") {
        return "rate_limit"
    }
    return "none"
'@

$newQuotaDetect = @'
    if ($ErrorOutput -match "(rate.limit|too.many.requests|429|throttl|slow.down|403.*resource.exhausted)") {
        return "rate_limit"
    }
    # Catch bare 403 that looks like rate limiting (not auth)
    if ($ErrorOutput -match "403" -and $ErrorOutput -match "(resource|exhausted|limit|capacity)") {
        return "rate_limit"
    }
    return "none"
'@

if ($content.Contains($oldQuotaDetect)) {
    $content = $content.Replace($oldQuotaDetect, $newQuotaDetect)
    $changeCount++
    Write-Host "   [OK] Test-IsQuotaError updated with 403 handling" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Test-IsQuotaError already patched or not found" -ForegroundColor DarkGray
}

# ========================================================
# Fix 1C: Add probe cost tracking in Wait-ForQuotaReset
# ========================================================

Write-Host "[FIX 1C] Adding probe cost tracking to Wait-ForQuotaReset..." -ForegroundColor Yellow

$oldProbeBlock = @'
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
'@

$newProbeBlock = @'
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
'@

if ($content.Contains($oldProbeBlock)) {
    $content = $content.Replace($oldProbeBlock, $newProbeBlock)
    $changeCount++
    Write-Host "   [OK] Probe cost tracking added to Wait-ForQuotaReset" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Wait-ForQuotaReset probe block already patched or not found" -ForegroundColor DarkGray
}

# ========================================================
# Fix 1D: Add 'estimated' field to Save-TokenUsage entry
# ========================================================

Write-Host "[FIX 1D] Adding 'estimated' field to Save-TokenUsage..." -ForegroundColor Yellow

$oldSaveEntry = @'
            num_turns = $TokenData.NumTurns
        }
'@

$newSaveEntry = @'
            num_turns = $TokenData.NumTurns
            estimated = if ($TokenData.Estimated) { $true } else { $false }
        }
'@

if ($content.Contains($oldSaveEntry)) {
    $content = $content.Replace($oldSaveEntry, $newSaveEntry)
    $changeCount++
    Write-Host "   [OK] 'estimated' field added to token-usage entries" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Save-TokenUsage entry already patched or not found" -ForegroundColor DarkGray
}

# ========================================================
# Fix 1A + 3B: Replace quota handling block in Invoke-WithRetry
#   - Add token tracking at quota error path
#   - Add cumulative wait tracking
#   - Add agent rotation logic
# ========================================================

Write-Host "[FIX 1A/3B] Replacing quota handler with tracked + capped + rotation version..." -ForegroundColor Yellow

$oldQuotaHandler = @'
            # -- Check for quota errors --
            $quotaType = Test-IsQuotaError $outputText
            if ($quotaType -ne "none") {
                Write-GsdError -GsdDir $GsdDir -Category "quota" -Phase $Phase -Iteration $i `
                    -Message "$Agent $quotaType" -Resolution "Waiting for reset"

                # Engine status: sleeping for quota backoff
                if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                    Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -SleepReason "quota_backoff" -LastError "$Agent $quotaType"
                }

                $quotaOk = Wait-ForQuotaReset -QuotaType $quotaType -Agent $Agent -GsdDir $GsdDir
                if ($quotaOk) {
                    # Engine status: recovered from quota backoff
                    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                        Update-EngineStatus -GsdDir $GsdDir -State "running" -RecoveredFromError $true
                    }
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

            if ($isCrash -and $i -lt $MaxAttempts) {
'@

$newQuotaHandler = @'
            # -- Check for quota errors (with token tracking + cumulative cap + agent rotation) --
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

                # CHECK: Should we rotate to a different agent instead of waiting?
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

                # CHECK: Have we exceeded the cumulative wait cap?
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
                    # Engine status: recovered from quota backoff
                    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
                        Update-EngineStatus -GsdDir $GsdDir -State "running" -RecoveredFromError $true
                    }
                    $consecutiveQuotaFails[$Agent] = 0
                    $i--
                    continue
                } else {
                    # Quota didn't reset -- try rotating agent before giving up
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

'@

if ($content.Contains($oldQuotaHandler)) {
    $content = $content.Replace($oldQuotaHandler, $newQuotaHandler)
    $changeCount++
    Write-Host "   [OK] Quota handler replaced with tracked/capped/rotation version" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Quota handler block already patched or not found" -ForegroundColor DarkGray
}

# ========================================================
# Fix 3B: Add cumulative wait tracking variables before retry loop
# ========================================================

Write-Host "[FIX 3B] Adding cumulative quota wait tracking variables..." -ForegroundColor Yellow

$oldRetryLoopInit = @'
    $result = @{ Success = $false; Attempts = 0; FinalBatchSize = $CurrentBatchSize; Error = $null }

    for ($i = $Attempt; $i -le $MaxAttempts; $i++) {
'@

$newRetryLoopInit = @'
    $result = @{ Success = $false; Attempts = 0; FinalBatchSize = $CurrentBatchSize; Error = $null }

    # Cumulative quota wait tracking (Fix P3)
    $totalQuotaWaitMinutes = 0
    $consecutiveQuotaFails = @{}  # Per-agent: @{ "codex" = 3; "gemini" = 1 }

    for ($i = $Attempt; $i -le $MaxAttempts; $i++) {
'@

# This pattern appears twice (watchdog + enhanced Invoke-WithRetry). Replace both.
$matchCount = ([regex]::Matches($content, [regex]::Escape($oldRetryLoopInit))).Count
if ($matchCount -gt 0) {
    $content = $content.Replace($oldRetryLoopInit, $newRetryLoopInit)
    $changeCount++
    Write-Host "   [OK] Added cumulative wait variables ($matchCount instance(s))" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Retry loop init already patched or not found" -ForegroundColor DarkGray
}

# ========================================================
# Write modified resilience.ps1
# ========================================================

Write-Host ""
Write-Host "[SAVE] Writing $changeCount in-place modifications..." -ForegroundColor Yellow

Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
Write-Host "   [OK] resilience.ps1 updated ($changeCount modifications)" -ForegroundColor DarkGreen

# ========================================================
# Fix 3A: Add configuration constants (append)
# ========================================================

Write-Host ""
Write-Host "[FIX 3A] Adding quota cap + rotation config constants..." -ForegroundColor Yellow

$configConstants = @'

# -- Resilience Hardening config (P3/P4) --
$script:QUOTA_CUMULATIVE_MAX_MINUTES = 120          # Give up after 2 hours TOTAL quota waiting per invoke
$script:QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE = 3   # Try different agent after 3 consecutive quota hits
'@

if (-not $content.Contains('QUOTA_CUMULATIVE_MAX_MINUTES')) {
    Add-Content -Path $resiliencePath -Value $configConstants -Encoding UTF8
    Write-Host "   [OK] Config constants added" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Config constants already present" -ForegroundColor DarkGray
}

# ========================================================
# Fix 1B + 4A: Append new functions
# ========================================================

Write-Host "[FIX 1B/4A] Appending new functions (token estimation, agent rotation)..." -ForegroundColor Yellow

$newFunctions = @'

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
    $pool = @("claude", "codex", "gemini")

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
'@

if (-not $content.Contains('function New-EstimatedTokenData')) {
    Add-Content -Path $resiliencePath -Value $newFunctions -Encoding UTF8
    Write-Host "   [OK] New-EstimatedTokenData function added" -ForegroundColor DarkGreen
    Write-Host "   [OK] Get-NextAvailableAgent function added" -ForegroundColor DarkGreen
    Write-Host "   [OK] Set-AgentCooldown function added" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Hardening functions already present" -ForegroundColor DarkGray
}

# ========================================================
# DONE
# ========================================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Resilience Hardening Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  FIXES APPLIED:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  P1: Token costs tracked on ALL attempts (success + failure + probes)" -ForegroundColor White
Write-Host "      - Quota, auth, and crash failures now logged to token-usage.jsonl" -ForegroundColor DarkGray
Write-Host "      - Cost estimated from prompt size when agent returns no JSON" -ForegroundColor DarkGray
Write-Host "      - Quota probe calls tracked (phase: quota-probe)" -ForegroundColor DarkGray
Write-Host "      - New 'estimated' field distinguishes real vs estimated costs" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  P2: Auth regex no longer misclassifies 403 as auth failure" -ForegroundColor White
Write-Host "      - Gemini 403 (Resource Exhausted) routes to quota backoff" -ForegroundColor DarkGray
Write-Host "      - Rate-limit exclusion guard prevents false AUTH_ERROR" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  P3: Cumulative quota wait capped at 120 minutes" -ForegroundColor White
Write-Host "      - No more 14-hour sleep loops" -ForegroundColor DarkGray
Write-Host "      - Set QUOTA_CUMULATIVE_MAX_MINUTES to change (default: 120)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  P4: Agent rotation after 3 consecutive quota failures" -ForegroundColor White
Write-Host "      - codex exhausted -> auto-switch to claude or gemini" -ForegroundColor DarkGray
Write-Host "      - 30-min cooldown per exhausted agent" -ForegroundColor DarkGray
Write-Host "      - Set QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE to change (default: 3)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  NEW CONFIG CONSTANTS:" -ForegroundColor Yellow
Write-Host "    `$script:QUOTA_CUMULATIVE_MAX_MINUTES = 120" -ForegroundColor Cyan
Write-Host "    `$script:QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE = 3" -ForegroundColor Cyan
Write-Host ""
Write-Host "  ROLLBACK:" -ForegroundColor Yellow
Write-Host "    Disable rotation: set QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE = 999" -ForegroundColor DarkGray
Write-Host "    Disable wait cap: set QUOTA_CUMULATIVE_MAX_MINUTES = 99999" -ForegroundColor DarkGray
Write-Host "    Token tracking has no off-switch (always on)" -ForegroundColor DarkGray
Write-Host ""
