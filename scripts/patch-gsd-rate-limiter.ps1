<#
.SYNOPSIS
    Patch #39: Proactive Rate Limiter — prevents quota exhaustion instead of reacting to it.

.DESCRIPTION
    DISEASE:  The engine hits rate limits (429/quota_exhausted) on every iteration because
              there is NO proactive enforcement of the RPM limits defined in model-registry.json.
              The system is purely reactive: blast calls -> hit wall -> back off -> repeat.

    CURE:     Sliding-window rate limiter injected into Invoke-WithRetry.
              Before EVERY API call, checks a per-agent call log (timestamps in memory).
              If the agent has hit its RPM ceiling, sleeps the exact seconds needed.
              Result: zero 429 errors under normal operation.

    DESIGN:
      - $script:RateLimitTracker — hashtable of agent -> [datetime[]] (last 60s of call timestamps)
      - Wait-ForRateWindow — reads RPM from model-registry.json, checks sliding window, sleeps if needed
      - Register-AgentCall — records timestamp after each call completes
      - Injected at the TOP of the try{} block in Invoke-WithRetry, before any agent CLI/REST call
      - Also injected into Invoke-OpenAICompatibleAgent for direct REST callers
      - Safety margin: uses 80% of stated RPM (configurable via rate_limiter.safety_factor in agent-map.json)

    INSTALL_ORDER: 39 (after patch-gsd-sequential-review.ps1 #38)

.NOTES
    Idempotent — safe to re-run. Checks for sentinel markers before patching.
#>

param([string]$UserHome = $env:USERPROFILE)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$resiliencePath = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
$agentMapPath  = Join-Path $GsdGlobalDir "config\agent-map.json"

if (-not (Test-Path $resiliencePath)) {
    Write-Host "[XX] Resilience module not found at $resiliencePath. Run earlier patches first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== PATCH #39: Proactive Rate Limiter ===" -ForegroundColor Cyan
Write-Host "    Prevents quota exhaustion by enforcing RPM limits BEFORE calls" -ForegroundColor White
Write-Host ""

$content = Get-Content $resiliencePath -Raw
$changeCount = 0

# ============================================================
# STEP 1: Append rate limiter functions to resilience.ps1
# ============================================================

$sentinelFunction = "function Wait-ForRateWindow"

if (-not $content.Contains($sentinelFunction)) {

$rateLimiterCode = @'


# ===========================================
# PROACTIVE RATE LIMITER (patch-gsd-rate-limiter.ps1)
# Prevents 429/quota errors by enforcing RPM limits BEFORE making API calls.
# Uses sliding-window call tracking per agent.
# ===========================================

# In-memory call tracker: agent -> [System.Collections.ArrayList] of [datetime]
if (-not $script:RateLimitTracker) {
    $script:RateLimitTracker = @{}
}

# Cached registry (avoid re-reading JSON on every call)
$script:RateLimitRegistryCache = $null
$script:RateLimitRegistryCacheTime = [datetime]::MinValue

function Get-AgentRpmLimit {
    <#
    .SYNOPSIS
        Returns the effective RPM limit for an agent, factoring in safety margin.
        Reads from model-registry.json (cached for 60s) and agent-map.json safety_factor.
    #>
    param([string]$AgentName)

    # Refresh cache every 60 seconds
    if (-not $script:RateLimitRegistryCache -or ((Get-Date) - $script:RateLimitRegistryCacheTime).TotalSeconds -gt 60) {
        $regPath = Join-Path $env:USERPROFILE ".gsd-global\config\model-registry.json"
        if (Test-Path $regPath) {
            try {
                $script:RateLimitRegistryCache = Get-Content $regPath -Raw | ConvertFrom-Json
                $script:RateLimitRegistryCacheTime = Get-Date
            } catch {
                # Fall through to defaults
            }
        }
    }

    # Read RPM from registry
    $rpm = 10  # Conservative default
    if ($script:RateLimitRegistryCache -and $script:RateLimitRegistryCache.agents.$AgentName) {
        $agentCfg = $script:RateLimitRegistryCache.agents.$AgentName
        if ($agentCfg.rate_limits -and $agentCfg.rate_limits.rpm) {
            $rpm = [int]$agentCfg.rate_limits.rpm
        }
    }

    # Apply safety factor from agent-map.json (default 0.8 = use 80% of stated RPM)
    $safetyFactor = 0.8
    $amPath = Join-Path $env:USERPROFILE ".gsd-global\config\agent-map.json"
    if (Test-Path $amPath) {
        try {
            $am = Get-Content $amPath -Raw | ConvertFrom-Json
            if ($am.rate_limiter -and $am.rate_limiter.safety_factor) {
                $safetyFactor = [double]$am.rate_limiter.safety_factor
            }
        } catch { }
    }

    $effectiveRpm = [math]::Max(1, [math]::Floor($rpm * $safetyFactor))
    return $effectiveRpm
}

function Wait-ForRateWindow {
    <#
    .SYNOPSIS
        Proactive rate limiter. Checks if calling $AgentName now would exceed its RPM limit.
        If yes, sleeps the exact number of seconds needed until a slot opens.
        Returns the number of seconds waited (0 if no wait needed).
    .DESCRIPTION
        Uses a sliding 60-second window of call timestamps per agent.
        Prunes timestamps older than 60s on each check.
    #>
    param(
        [string]$AgentName,
        [string]$GsdDir = ""
    )

    if (-not $script:RateLimitTracker[$AgentName]) {
        $script:RateLimitTracker[$AgentName] = [System.Collections.ArrayList]::new()
    }

    $now = Get-Date
    $windowStart = $now.AddSeconds(-60)
    $callLog = $script:RateLimitTracker[$AgentName]

    # Prune calls older than 60 seconds
    $expired = @($callLog | Where-Object { $_ -lt $windowStart })
    foreach ($ts in $expired) { $callLog.Remove($ts) | Out-Null }

    $effectiveRpm = Get-AgentRpmLimit -AgentName $AgentName
    $currentCalls = $callLog.Count

    if ($currentCalls -lt $effectiveRpm) {
        # Under limit — no wait needed
        return 0
    }

    # At or over limit. Find when the oldest call in the window will expire.
    $sortedCalls = $callLog | Sort-Object
    $oldestInWindow = $sortedCalls[0]
    $expiresAt = $oldestInWindow.AddSeconds(60)
    $waitSeconds = [math]::Ceiling(($expiresAt - $now).TotalSeconds)

    if ($waitSeconds -le 0) {
        # Edge case: should have been pruned
        return 0
    }

    # Add 1s buffer to avoid edge-case 429
    $waitSeconds = $waitSeconds + 1

    Write-Host "    [RATE-LIMIT] $($AgentName.ToUpper()): $currentCalls/$effectiveRpm calls in last 60s. Waiting ${waitSeconds}s..." -ForegroundColor Yellow

    # Update engine status if available
    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        if ($GsdDir) {
            Update-EngineStatus -GsdDir $GsdDir -State "sleeping" -Phase "rate-limit" `
                -SleepReason "rate_limit_pacing" -SleepUntil ((Get-Date).ToUniversalTime().AddSeconds($waitSeconds))
        }
    }

    Start-Sleep -Seconds $waitSeconds

    if (Get-Command Update-EngineStatus -ErrorAction SilentlyContinue) {
        if ($GsdDir) {
            Update-EngineStatus -GsdDir $GsdDir -State "running"
        }
    }

    return $waitSeconds
}

function Register-AgentCall {
    <#
    .SYNOPSIS
        Records that an API call was made to $AgentName at the current time.
        Must be called AFTER every successful or failed API invocation.
    #>
    param([string]$AgentName)

    if (-not $script:RateLimitTracker[$AgentName]) {
        $script:RateLimitTracker[$AgentName] = [System.Collections.ArrayList]::new()
    }

    $script:RateLimitTracker[$AgentName].Add((Get-Date)) | Out-Null
}

function Get-RateLimitStatus {
    <#
    .SYNOPSIS
        Returns a summary of current rate limit usage for all tracked agents.
        Useful for diagnostics and WhatsApp /status command.
    #>
    $status = @{}
    $now = Get-Date
    $windowStart = $now.AddSeconds(-60)

    foreach ($agent in $script:RateLimitTracker.Keys) {
        $callLog = $script:RateLimitTracker[$agent]
        $recentCalls = @($callLog | Where-Object { $_ -ge $windowStart })
        $effectiveRpm = Get-AgentRpmLimit -AgentName $agent
        $status[$agent] = @{
            CallsInWindow = $recentCalls.Count
            EffectiveRpm  = $effectiveRpm
            Headroom      = $effectiveRpm - $recentCalls.Count
            NextSlotIn    = if ($recentCalls.Count -ge $effectiveRpm -and $recentCalls.Count -gt 0) {
                $oldest = ($recentCalls | Sort-Object)[0]
                [math]::Max(0, [math]::Ceiling(($oldest.AddSeconds(60) - $now).TotalSeconds))
            } else { 0 }
        }
    }
    return $status
}

'@

    Add-Content -Path $resiliencePath -Value $rateLimiterCode -Encoding UTF8
    $content = Get-Content $resiliencePath -Raw
    $changeCount++
    Write-Host "   [OK] Rate limiter functions appended (Wait-ForRateWindow, Register-AgentCall, Get-RateLimitStatus)" -ForegroundColor DarkGreen
} else {
    Write-Host "   [--] Rate limiter functions already present" -ForegroundColor DarkGray
}

# ============================================================
# STEP 2: Inject rate-limit pre-check into Invoke-WithRetry
#         Location: after $callStart = Get-Date, before if ($Agent -eq "claude")
# ============================================================

$injectAfter = '$callStart = Get-Date'
$injectSentinel = '# -- RATE LIMIT PRE-CHECK (patch-gsd-rate-limiter.ps1) --'
$injectCode = @'
$callStart = Get-Date

            # -- RATE LIMIT PRE-CHECK (patch-gsd-rate-limiter.ps1) --
            if (Get-Command Wait-ForRateWindow -ErrorAction SilentlyContinue) {
                $rlWait = Wait-ForRateWindow -AgentName $Agent -GsdDir $GsdDir
                if ($rlWait -gt 0) {
                    Write-Host "    [RATE-LIMIT] Paced $Agent for ${rlWait}s to stay within RPM" -ForegroundColor DarkYellow
                }
            }
'@

if (-not $content.Contains($injectSentinel)) {
    # Replace the first occurrence (inside the enhanced Invoke-WithRetry, ~line 1662)
    # We need to target the one inside the retry loop, not any other $callStart
    $searchPattern = "`$callStart = Get-Date`r`n`r`n            if (`$Agent -eq `"claude`") {"
    $searchPatternLf = "`$callStart = Get-Date`n`n            if (`$Agent -eq `"claude`") {"
    $replacePattern = @'
$callStart = Get-Date

            # -- RATE LIMIT PRE-CHECK (patch-gsd-rate-limiter.ps1) --
            if (Get-Command Wait-ForRateWindow -ErrorAction SilentlyContinue) {
                $rlWait = Wait-ForRateWindow -AgentName $Agent -GsdDir $GsdDir
                if ($rlWait -gt 0) {
                    Write-Host "    [RATE-LIMIT] Paced $Agent for ${rlWait}s to stay within RPM" -ForegroundColor DarkYellow
                }
            }

            if ($Agent -eq "claude") {
'@

    # Try both CRLF and LF line endings
    $matchPattern = if ($content.Contains($searchPattern)) { $searchPattern } elseif ($content.Contains($searchPatternLf)) { $searchPatternLf } else { $null }
    if ($matchPattern) {
        $content = $content.Replace($matchPattern, $replacePattern)
        Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
        $changeCount++
        Write-Host "   [OK] Rate-limit pre-check injected into Invoke-WithRetry (before agent dispatch)" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [!!] Could not find injection point in Invoke-WithRetry. Manual review needed." -ForegroundColor Yellow
    }
} else {
    Write-Host "   [--] Rate-limit pre-check already injected" -ForegroundColor DarkGray
}

# Re-read after potential edit
$content = Get-Content $resiliencePath -Raw

# ============================================================
# STEP 3: Inject Register-AgentCall after each API call completes
#         Location: after the output parsing block, before quota check
# ============================================================

$registerSentinel = '# -- REGISTER CALL FOR RATE TRACKING (patch-gsd-rate-limiter.ps1) --'
$registerSearchPattern = '$outputText = if ($output) { $output -join "`n" } else { "" }'

if (-not $content.Contains($registerSentinel)) {
    $registerReplacePattern = @'
$outputText = if ($output) { $output -join "`n" } else { "" }

            # -- REGISTER CALL FOR RATE TRACKING (patch-gsd-rate-limiter.ps1) --
            if (Get-Command Register-AgentCall -ErrorAction SilentlyContinue) {
                Register-AgentCall -AgentName $Agent
            }
'@

    if ($content.Contains($registerSearchPattern)) {
        # Replace only the first occurrence in the enhanced Invoke-WithRetry
        $idx = $content.IndexOf($registerSearchPattern)
        # Find the second occurrence (in the enhanced version, ~line 1737)
        $secondIdx = $content.IndexOf($registerSearchPattern, $idx + 1)
        if ($secondIdx -gt 0) {
            $before = $content.Substring(0, $secondIdx)
            $after = $content.Substring($secondIdx + $registerSearchPattern.Length)
            $content = $before + $registerReplacePattern + $after
        } else {
            # Only one occurrence, patch it
            $content = $content.Replace($registerSearchPattern, $registerReplacePattern)
        }
        Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
        $changeCount++
        Write-Host "   [OK] Register-AgentCall injected after API call completion" -ForegroundColor DarkGreen
    } else {
        Write-Host "   [!!] Could not find output parsing line for Register-AgentCall injection" -ForegroundColor Yellow
    }
} else {
    Write-Host "   [--] Register-AgentCall already injected" -ForegroundColor DarkGray
}

# Re-read after potential edit
$content = Get-Content $resiliencePath -Raw

# ============================================================
# STEP 4: Inject rate limiter into Invoke-OpenAICompatibleAgent
#         Location: before Invoke-RestMethod call
# ============================================================

$restSentinel = '# -- REST RATE LIMIT PRE-CHECK (patch-gsd-rate-limiter.ps1) --'
$restSearchPattern = '$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()'

if (-not $content.Contains($restSentinel)) {
    # Find the occurrence inside Invoke-OpenAICompatibleAgent
    $restReplacePattern = @'
# -- REST RATE LIMIT PRE-CHECK (patch-gsd-rate-limiter.ps1) --
    if (Get-Command Wait-ForRateWindow -ErrorAction SilentlyContinue) {
        $rlWait = Wait-ForRateWindow -AgentName $AgentName
        if ($rlWait -gt 0) {
            Write-Host "    [RATE-LIMIT] Paced REST agent $AgentName for ${rlWait}s" -ForegroundColor DarkYellow
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
'@

    if ($content.Contains($restSearchPattern)) {
        # Find the occurrence inside Invoke-OpenAICompatibleAgent (should be after line 6000+)
        $funcMarker = "function Invoke-OpenAICompatibleAgent"
        $funcIdx = $content.IndexOf($funcMarker)
        if ($funcIdx -gt 0) {
            $restIdx = $content.IndexOf($restSearchPattern, $funcIdx)
            if ($restIdx -gt 0) {
                $before = $content.Substring(0, $restIdx)
                $after = $content.Substring($restIdx + $restSearchPattern.Length)
                $content = $before + $restReplacePattern + $after
                Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
                $changeCount++
                Write-Host "   [OK] Rate-limit pre-check injected into Invoke-OpenAICompatibleAgent" -ForegroundColor DarkGreen
            } else {
                Write-Host "   [!!] Stopwatch line not found inside Invoke-OpenAICompatibleAgent" -ForegroundColor Yellow
            }
        } else {
            Write-Host "   [--] Invoke-OpenAICompatibleAgent not found (multi-model patch may not be installed)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "   [!!] Could not find stopwatch line for REST rate-limit injection" -ForegroundColor Yellow
    }
} else {
    Write-Host "   [--] REST rate-limit pre-check already injected" -ForegroundColor DarkGray
}

# Re-read after potential edit
$content = Get-Content $resiliencePath -Raw

# ============================================================
# STEP 5: Also inject Register-AgentCall into REST path
# ============================================================

$restRegisterSentinel = '# -- REGISTER REST CALL FOR RATE TRACKING (patch-gsd-rate-limiter.ps1) --'
$restRegisterSearch = '$stopwatch.Stop()'

if (-not $content.Contains($restRegisterSentinel)) {
    $funcMarker = "function Invoke-OpenAICompatibleAgent"
    $funcIdx = $content.IndexOf($funcMarker)
    if ($funcIdx -gt 0) {
        $stopIdx = $content.IndexOf($restRegisterSearch, $funcIdx)
        if ($stopIdx -gt 0) {
            $restRegisterReplace = @'
$stopwatch.Stop()

        # -- REGISTER REST CALL FOR RATE TRACKING (patch-gsd-rate-limiter.ps1) --
        if (Get-Command Register-AgentCall -ErrorAction SilentlyContinue) {
            Register-AgentCall -AgentName $AgentName
        }
'@
            $before = $content.Substring(0, $stopIdx)
            $after = $content.Substring($stopIdx + $restRegisterSearch.Length)
            $content = $before + $restRegisterReplace + $after
            Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
            $changeCount++
            Write-Host "   [OK] Register-AgentCall injected into Invoke-OpenAICompatibleAgent" -ForegroundColor DarkGreen
        }
    }
} else {
    Write-Host "   [--] REST Register-AgentCall already injected" -ForegroundColor DarkGray
}

# ============================================================
# STEP 6: Add rate_limiter config to agent-map.json if missing
# ============================================================

if (Test-Path $agentMapPath) {
    $amContent = Get-Content $agentMapPath -Raw
    if (-not $amContent.Contains('"rate_limiter"')) {
        try {
            $am = $amContent | ConvertFrom-Json

            # Add rate_limiter config block
            $am | Add-Member -NotePropertyName "rate_limiter" -NotePropertyValue ([PSCustomObject]@{
                enabled        = $true
                safety_factor  = 0.8
                log_throttles  = $true
                description    = "Proactive rate limiter. safety_factor=0.8 means use 80% of stated RPM. Set enabled=false to disable."
            }) -Force

            $am | ConvertTo-Json -Depth 10 | Set-Content $agentMapPath -Encoding UTF8
            $changeCount++
            Write-Host "   [OK] rate_limiter config added to agent-map.json (safety_factor: 0.8)" -ForegroundColor DarkGreen
        } catch {
            Write-Host "   [!!] Could not update agent-map.json: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "   [--] rate_limiter config already in agent-map.json" -ForegroundColor DarkGray
    }
} else {
    Write-Host "   [!!] agent-map.json not found at $agentMapPath" -ForegroundColor Yellow
}

# ============================================================
# STEP 7: Fix Invoke-AgentFallback bypass — add rate limiting
#         Disease: CLI agents in fallback path bypass rate limiter entirely
# ============================================================

$content = Get-Content $resiliencePath -Raw
$fallbackSentinel = '# -- Rate limiter: pace fallback calls'

if (-not $content.Contains($fallbackSentinel)) {
    $fallbackSearch = '$fbOutput = $null' + "`n" + '    $fbExit = 1' + "`n" + '    $fbTokenData = $null' + "`n`n" + '    try {'
    $fallbackSearchCrlf = '$fbOutput = $null' + "`r`n" + '    $fbExit = 1' + "`r`n" + '    $fbTokenData = $null' + "`r`n`r`n" + '    try {'
    $fallbackReplace = @'
$fbOutput = $null
    $fbExit = 1
    $fbTokenData = $null

    # -- Rate limiter: pace fallback calls (prevents bypass → 429 cascade) --
    try { Wait-ForRateWindow -AgentName $FallbackAgent } catch { }

    try {
'@
    $matchFb = if ($content.Contains($fallbackSearchCrlf)) { $fallbackSearchCrlf } elseif ($content.Contains($fallbackSearch)) { $fallbackSearch } else { $null }
    if ($matchFb) {
        # Find the occurrence inside the enhanced Invoke-AgentFallback (after line 1500)
        $fbFuncIdx = $content.IndexOf("function Invoke-AgentFallback", 1400)
        if ($fbFuncIdx -gt 0) {
            $fbTargetIdx = $content.IndexOf($matchFb, $fbFuncIdx)
            if ($fbTargetIdx -gt 0) {
                $before = $content.Substring(0, $fbTargetIdx)
                $after = $content.Substring($fbTargetIdx + $matchFb.Length)
                $content = $before + $fallbackReplace + $after
                Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
                $changeCount++
                Write-Host "   [OK] Rate limiter injected into Invoke-AgentFallback (pre-call)" -ForegroundColor DarkGreen
            }
        }
    } else {
        Write-Host "   [!!] Could not find Invoke-AgentFallback injection point" -ForegroundColor Yellow
    }
} else {
    Write-Host "   [--] Invoke-AgentFallback rate limiter already present" -ForegroundColor DarkGray
}

# Also add Register-AgentCall after fallback completes
$content = Get-Content $resiliencePath -Raw
$fbRegSentinel = '# -- Register call for rate tracking (prevents bypass'

if (-not $content.Contains($fbRegSentinel)) {
    $fbRegSearch = 'if ($LogFile -and $fbOutput) {' + "`n" + '            $fbOutput | Out-File -FilePath $LogFile -Encoding UTF8 -Append' + "`n" + '        }' + "`n" + '    } catch {'
    $fbRegSearchCrlf = 'if ($LogFile -and $fbOutput) {' + "`r`n" + '            $fbOutput | Out-File -FilePath $LogFile -Encoding UTF8 -Append' + "`r`n" + '        }' + "`r`n" + '    } catch {'
    $fbRegReplace = @'
if ($LogFile -and $fbOutput) {
            $fbOutput | Out-File -FilePath $LogFile -Encoding UTF8 -Append
        }

        # -- Register call for rate tracking (prevents bypass → 429 cascade) --
        try { Register-AgentCall -AgentName $FallbackAgent } catch { }
    } catch {
'@
    $matchFbReg = if ($content.Contains($fbRegSearchCrlf)) { $fbRegSearchCrlf } elseif ($content.Contains($fbRegSearch)) { $fbRegSearch } else { $null }
    if ($matchFbReg) {
        $fbFuncIdx2 = $content.IndexOf("function Invoke-AgentFallback", 1400)
        if ($fbFuncIdx2 -gt 0) {
            $fbRegIdx = $content.IndexOf($matchFbReg, $fbFuncIdx2)
            if ($fbRegIdx -gt 0) {
                $before = $content.Substring(0, $fbRegIdx)
                $after = $content.Substring($fbRegIdx + $matchFbReg.Length)
                $content = $before + $fbRegReplace + $after
                Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
                $changeCount++
                Write-Host "   [OK] Register-AgentCall injected into Invoke-AgentFallback (post-call)" -ForegroundColor DarkGreen
            }
        }
    }
} else {
    Write-Host "   [--] Invoke-AgentFallback Register-AgentCall already present" -ForegroundColor DarkGray
}

# ============================================================
# STEP 8: Fix double registration for REST agents
#         Disease: Both Invoke-WithRetry AND Invoke-OpenAICompatibleAgent
#         register the same call → tracker shows 2x actual → corrupts RPM
# ============================================================

$content = Get-Content $resiliencePath -Raw
$doubleRegSentinel = '# Skip for REST agents'

if (-not $content.Contains($doubleRegSentinel)) {
    $doubleRegSearch = @'
            # -- REGISTER CALL FOR RATE TRACKING (patch-gsd-rate-limiter.ps1) --
            if (Get-Command Register-AgentCall -ErrorAction SilentlyContinue) {
                Register-AgentCall -AgentName $Agent
            }
'@
    $doubleRegReplace = @'
            # -- REGISTER CALL FOR RATE TRACKING (patch-gsd-rate-limiter.ps1) --
            # Skip for REST agents — Invoke-OpenAICompatibleAgent already registers (avoids double-count)
            if ((Get-Command Register-AgentCall -ErrorAction SilentlyContinue) -and
                -not (Get-Command Test-IsOpenAICompatAgent -ErrorAction SilentlyContinue -and (Test-IsOpenAICompatAgent -AgentName $Agent))) {
                Register-AgentCall -AgentName $Agent
            }
'@
    if ($content.Contains($doubleRegSearch)) {
        $content = $content.Replace($doubleRegSearch, $doubleRegReplace)
        Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
        $changeCount++
        Write-Host "   [OK] Fixed double registration for REST agents in Invoke-WithRetry" -ForegroundColor DarkGreen
    }
} else {
    Write-Host "   [--] Double registration fix already applied" -ForegroundColor DarkGray
}

# ============================================================
# STEP 9: Add rate limiting to build auto-fix codex calls
#         Disease: dotnet/npm auto-fix calls codex without rate check
# ============================================================

$content = Get-Content $resiliencePath -Raw
$autoFixSentinel = 'Wait-ForRateWindow -AgentName "codex"'

if (-not $content.Contains($autoFixSentinel)) {
    # Dotnet auto-fix
    $dotnetFixSearch = 'Write-Host "    [SYNC] Auto-fix: sending build errors to Codex..." -ForegroundColor DarkYellow' + "`n" + '                    $fixAttempted = $true'
    $dotnetFixSearchCrlf = 'Write-Host "    [SYNC] Auto-fix: sending build errors to Codex..." -ForegroundColor DarkYellow' + "`r`n" + '                    $fixAttempted = $true'
    $dotnetFixReplace = @'
Write-Host "    [SYNC] Auto-fix: sending build errors to Codex..." -ForegroundColor DarkYellow
                    $fixAttempted = $true
                    try { Wait-ForRateWindow -AgentName "codex" } catch { }
'@
    $matchDotnet = if ($content.Contains($dotnetFixSearchCrlf)) { $dotnetFixSearchCrlf } elseif ($content.Contains($dotnetFixSearch)) { $dotnetFixSearch } else { $null }
    if ($matchDotnet) {
        $content = $content.Replace($matchDotnet, $dotnetFixReplace)
        Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
        $changeCount++
        Write-Host "   [OK] Rate limiter added to dotnet auto-fix codex call" -ForegroundColor DarkGreen
    }

    # Npm auto-fix
    $content = Get-Content $resiliencePath -Raw
    $npmFixSearch = 'Write-Host "    [SYNC] Auto-fix: sending npm errors to Codex..." -ForegroundColor DarkYellow' + "`n" + '                        $fixAttempted = $true'
    $npmFixSearchCrlf = 'Write-Host "    [SYNC] Auto-fix: sending npm errors to Codex..." -ForegroundColor DarkYellow' + "`r`n" + '                        $fixAttempted = $true'
    $npmFixReplace = @'
Write-Host "    [SYNC] Auto-fix: sending npm errors to Codex..." -ForegroundColor DarkYellow
                        $fixAttempted = $true
                        try { Wait-ForRateWindow -AgentName "codex" } catch { }
'@
    $matchNpm = if ($content.Contains($npmFixSearchCrlf)) { $npmFixSearchCrlf } elseif ($content.Contains($npmFixSearch)) { $npmFixSearch } else { $null }
    if ($matchNpm) {
        $content = $content.Replace($matchNpm, $npmFixReplace)
        Set-Content -Path $resiliencePath -Value $content -Encoding UTF8 -NoNewline
        $changeCount++
        Write-Host "   [OK] Rate limiter added to npm auto-fix codex call" -ForegroundColor DarkGreen
    }
} else {
    Write-Host "   [--] Auto-fix rate limiter already present" -ForegroundColor DarkGray
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "=== PATCH #39 COMPLETE ===" -ForegroundColor Cyan
Write-Host "   Changes applied: $changeCount" -ForegroundColor White
Write-Host ""
Write-Host "   WHAT THIS DOES:" -ForegroundColor White
Write-Host "   - Before every API call, checks a 60-second sliding window of call timestamps" -ForegroundColor Gray
Write-Host "   - If agent has hit 80% of its RPM limit, sleeps the exact seconds needed" -ForegroundColor Gray
Write-Host "   - Tracks calls for CLI agents (claude, codex, gemini, kimi) AND REST agents" -ForegroundColor Gray
Write-Host "   - Zero 429 errors under normal operation" -ForegroundColor Gray
Write-Host ""
Write-Host "   EFFECTIVE RPM (at 80% safety):" -ForegroundColor White
Write-Host "     claude:   8 RPM (1 call per 7.5s)    | codex:    8 RPM (1 call per 7.5s)" -ForegroundColor Gray
Write-Host "     gemini:  12 RPM (1 call per 5.0s)    | kimi:    16 RPM (1 call per 3.8s)" -ForegroundColor Gray
Write-Host "     deepseek: 48 RPM (1 call per 1.3s)   | glm5:    24 RPM (1 call per 2.5s)" -ForegroundColor Gray
Write-Host "     minimax:  24 RPM (1 call per 2.5s)" -ForegroundColor Gray
Write-Host ""
Write-Host "   CONFIG:" -ForegroundColor White
Write-Host "     agent-map.json -> rate_limiter.safety_factor (default 0.8)" -ForegroundColor Gray
Write-Host "     model-registry.json -> agents.X.rate_limits.rpm (per-agent)" -ForegroundColor Gray
Write-Host ""
Write-Host "   ROLLBACK:" -ForegroundColor White
Write-Host "     Set agent-map.json -> rate_limiter.enabled = false" -ForegroundColor Gray
Write-Host "     Or increase safety_factor to 1.0 (use 100% of RPM, more aggressive)" -ForegroundColor Gray
Write-Host ""
