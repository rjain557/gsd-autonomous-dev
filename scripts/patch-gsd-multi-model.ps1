<#
.SYNOPSIS
    GSD Multi-Model LLM Integration -- Kimi K2.5, DeepSeek, GLM-5, MiniMax
    Run AFTER patch-gsd-quality-gates.ps1.

.DESCRIPTION
    Adds 4 new OpenAI-compatible REST API providers to the GSD engine, expanding
    the agent pool from 3 (Claude/Codex/Gemini CLIs) to 7 providers. This
    dramatically reduces quota exhaustion downtime by giving the rotation system
    more agents to fail over to.

    New agents:
        Kimi K2.5   (Moonshot AI)  -- $0.60/$2.50 per M tokens
        DeepSeek V3 (DeepSeek)     -- $0.28/$0.42 per M tokens
        GLM-5       (Zhipu AI)     -- $1.00/$3.20 per M tokens
        MiniMax M2.5 (MiniMax)     -- $0.29/$1.20 per M tokens

    Changes:
        1. Creates model-registry.json (central agent config)
        2. Appends Invoke-OpenAICompatibleAgent + Test-IsOpenAICompatAgent to resilience.ps1
        3. Patches Invoke-WithRetry dispatch (both versions) for REST agents
        4. Patches Invoke-AgentFallback (both versions) for REST agents
        5. Patches Extract-TokensFromOutput for openai-compat JSON envelope
        6. Patches Get-TokenPrice with new model pricing
        7. Patches Get-NextAvailableAgent for registry-driven pool
        8. Reduces QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE from 3 to 1
        9. Patches Wait-ForQuotaReset quota probe for REST agents
       10. Patches council for configurable reviewer pool expansion
       11. Patches supervisor for cooldown-aware diagnosis routing
       12. Updates token-cost-calculator.ps1 pricing
       13. Adds REST agent API key checks to Test-PreFlight
       13B. Patches enhanced Get-FailureDiagnosis for REST agent error handling
       13C. Patches original Get-FailureDiagnosis for REST agent error handling

    New files:
        %USERPROFILE%\.gsd-global\config\model-registry.json
        %USERPROFILE%\.gsd-global\prompts\council\openai-compat-review.md

    Env vars (optional, warn-only if missing):
        KIMI_API_KEY, DEEPSEEK_API_KEY, GLM_API_KEY, MINIMAX_API_KEY

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
    17. patch-false-converge-fix.ps1
    18. patch-gsd-parallel-execute.ps1
    19. patch-gsd-resilience-hardening.ps1
    20. patch-gsd-quality-gates.ps1
    21. patch-gsd-multi-model.ps1    <- this file
#>

param(
    [string]$UserHome = $env:USERPROFILE
)

$ErrorActionPreference = "Stop"
$GsdGlobalDir = Join-Path $UserHome ".gsd-global"
$resiliencePath = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
$supervisorPath = Join-Path $GsdGlobalDir "lib\modules\supervisor.ps1"
$calculatorPath = Join-Path $GsdGlobalDir "scripts\token-cost-calculator.ps1"
$agentMapPath   = Join-Path $GsdGlobalDir "config\agent-map.json"
$registryPath   = Join-Path $GsdGlobalDir "config\model-registry.json"
$councilPromptDir = Join-Path $GsdGlobalDir "prompts\council"

if (-not (Test-Path $resiliencePath)) {
    Write-Host "[XX] Resilience module not found. Run the installer chain first." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Multi-Model LLM Integration" -ForegroundColor Cyan
Write-Host "  Kimi K2.5 | DeepSeek V3 | GLM-5 | MiniMax M2.5" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

$changeCount = 0

# ================================================================
# LINE ENDING NORMALIZATION
# The installed resilience.ps1 may have mixed CRLF/LF line endings
# from prior patches. Normalize to LF for reliable anchor matching.
# ================================================================

function Read-NormalizedContent([string]$Path) {
    $raw = [System.IO.File]::ReadAllText($Path)
    return $raw -replace "`r`n", "`n"
}

function Write-NormalizedContent([string]$Path, [string]$Content) {
    # Write as UTF-8 without BOM, with LF line endings (consistent)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function NormContains([string]$Content, [string]$Search) {
    # Normalize search string line endings to match LF-normalized content
    return $Content.Contains(($Search -replace "`r`n", "`n"))
}

function NormReplace([string]$Content, [string]$Old, [string]$New) {
    # Normalize both old/new strings to LF before replacing
    $nOld = $Old -replace "`r`n", "`n"
    $nNew = $New -replace "`r`n", "`n"
    return $Content.Replace($nOld, $nNew)
}

# ================================================================
# STEP 1: Create model-registry.json
# ================================================================

Write-Host "[STEP 1] Creating model-registry.json..." -ForegroundColor Yellow

if (Test-Path $registryPath) {
    Write-Host "  [SKIP] model-registry.json already exists" -ForegroundColor DarkGray
} else {
    $registry = [ordered]@{
        version = "1.0.0"
        description = "Central registry for all LLM agents. CLI agents use native CLIs; openai-compat agents use REST API."
        agents = [ordered]@{
            claude = [ordered]@{
                type = "cli"
                cli_cmd = "claude"
                role = @("review", "plan", "synthesize", "execute")
            }
            codex = [ordered]@{
                type = "cli"
                cli_cmd = "codex"
                role = @("execute", "review")
            }
            gemini = [ordered]@{
                type = "cli"
                cli_cmd = "gemini"
                role = @("research", "spec-fix", "review")
            }
            kimi = [ordered]@{
                type = "openai-compat"
                endpoint = "https://api.moonshot.ai/v1/chat/completions"
                api_key_env = "KIMI_API_KEY"
                model_id = "kimi-k2.5"
                max_tokens = 8192
                temperature = 0.3
                role = @("review", "research")
                supports_tools = $false
                enabled = $true
            }
            deepseek = [ordered]@{
                type = "openai-compat"
                endpoint = "https://api.deepseek.com/v1/chat/completions"
                api_key_env = "DEEPSEEK_API_KEY"
                model_id = "deepseek-chat"
                max_tokens = 8192
                temperature = 0.3
                role = @("review", "research")
                supports_tools = $false
                enabled = $true
            }
            glm5 = [ordered]@{
                type = "openai-compat"
                endpoint = "https://api.z.ai/api/paas/v4/chat/completions"
                api_key_env = "GLM_API_KEY"
                model_id = "glm-5"
                max_tokens = 8192
                temperature = 0.3
                role = @("review", "research")
                supports_tools = $false
                enabled = $true
            }
            minimax = [ordered]@{
                type = "openai-compat"
                endpoint = "https://api.minimax.io/v1/chat/completions"
                api_key_env = "MINIMAX_API_KEY"
                model_id = "MiniMax-M2.5"
                max_tokens = 8192
                temperature = 0.3
                role = @("review", "research")
                supports_tools = $false
                enabled = $true
            }
        }
        rotation_pool_default = @("claude", "codex", "gemini", "kimi", "deepseek", "glm5", "minimax")
    }

    $registry | ConvertTo-Json -Depth 5 | Set-Content $registryPath -Encoding UTF8
    Write-Host "  [OK] Created model-registry.json (7 agents: 3 CLI + 4 REST)" -ForegroundColor Green
    $changeCount++
}

# ================================================================
# STEP 2: Update agent-map.json
# ================================================================

Write-Host "[STEP 2] Updating agent-map.json pools..." -ForegroundColor Yellow

if (-not (Test-Path $agentMapPath)) {
    Write-Host "  [SKIP] agent-map.json not found" -ForegroundColor DarkYellow
} else {
    $agentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json
    $changed = $false

    # Expand council.reviewers only.
    # REST agents are text-only helpers and must not be treated as write-capable execute agents.
    if ($agentMap.council -and $agentMap.council.reviewers) {
        $reviewers = @($agentMap.council.reviewers)
        $newAgents = @("kimi", "deepseek", "glm5", "minimax")
        foreach ($a in $newAgents) {
            if ($reviewers -notcontains $a) {
                $reviewers += $a
                $changed = $true
            }
        }
        $agentMap.council.reviewers = $reviewers
    }

    if ($changed) {
        $agentMap | ConvertTo-Json -Depth 10 | Set-Content $agentMapPath -Encoding UTF8
        Write-Host "  [OK] Updated council.reviewers with REST reviewer pool" -ForegroundColor Green
        $changeCount++
    } else {
        Write-Host "  [SKIP] Pools already contain new agents" -ForegroundColor DarkGray
    }
}

# ================================================================
# STEP 3: Append Invoke-OpenAICompatibleAgent to resilience.ps1
# ================================================================

Write-Host "[STEP 3] Appending REST API adapter functions..." -ForegroundColor Yellow

$content = Read-NormalizedContent $resiliencePath

if ($content.Contains('function Invoke-OpenAICompatibleAgent')) {
    Write-Host "  [SKIP] Invoke-OpenAICompatibleAgent already exists" -ForegroundColor DarkGray
} else {
    $restAdapterCode = @'

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
            # Endpoint unreachable — fail fast, don't retry
            return "connection_failed: endpoint unreachable for $AgentName ($($cfg.endpoint)) - $errMsg"
        } else {
            return "error: $errMsg"
        }
    }
}

'@
    Add-Content -Path $resiliencePath -Value $restAdapterCode -Encoding UTF8
    Write-Host "  [OK] Appended Test-IsOpenAICompatAgent + Invoke-OpenAICompatibleAgent" -ForegroundColor Green
    $changeCount++

    # Re-read after append
    $content = Read-NormalizedContent $resiliencePath
}

# ================================================================
# STEP 4: Patch Invoke-WithRetry -- Enhanced version (add openai-compat dispatch)
# ================================================================

Write-Host "[STEP 4] Patching enhanced Invoke-WithRetry dispatch..." -ForegroundColor Yellow

$oldEnhancedDispatchEnd = @'
                } else {
                    $output = $rawOutput
                }
            }

            # Calculate call duration from wall clock if not in JSON data
'@

$newEnhancedDispatchEnd = @'
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
'@

if ($content.Contains('elseif (Test-IsOpenAICompatAgent -AgentName $Agent)')) {
    Write-Host "  [SKIP] Enhanced Invoke-WithRetry already patched" -ForegroundColor DarkGray
} elseif (NormContains $content $oldEnhancedDispatchEnd) {
    $content = NormReplace $content $oldEnhancedDispatchEnd $newEnhancedDispatchEnd
    Write-Host "  [OK] Patched enhanced Invoke-WithRetry dispatch" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for enhanced Invoke-WithRetry" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 5: Patch Invoke-WithRetry -- Original version (add openai-compat dispatch)
# ================================================================

Write-Host "[STEP 5] Patching original Invoke-WithRetry dispatch..." -ForegroundColor Yellow

$oldOriginalDispatchEnd = @'
exit `$LASTEXITCODE
"@
                }

                Set-Content -Path $wrapperScript -Value $wrapperContent -Encoding UTF8
'@

$newOriginalDispatchEnd = @'
exit `$LASTEXITCODE
"@
                } elseif (Test-IsOpenAICompatAgent -AgentName $Agent) {
                    # OpenAI-compatible REST agent -- direct PowerShell call, no subprocess needed
                    $wrapperContent = @"
. "$env:USERPROFILE\.gsd-global\lib\modules\resilience.ps1"
`$output = Invoke-OpenAICompatibleAgent -AgentName '$($Agent -replace "'","''")' -Prompt (Get-Content '$($promptTempFile -replace "'","''")' -Raw -Encoding UTF8)
`$output | Out-File -FilePath '$($outputTempFile -replace "'","''")' -Encoding UTF8
exit 0
"@
                }

                Set-Content -Path $wrapperScript -Value $wrapperContent -Encoding UTF8
'@

if ($content.Contains("Test-IsOpenAICompatAgent -AgentName `$Agent") -or $content.Contains('# OpenAI-compatible REST agent -- direct PowerShell call')) {
    Write-Host "  [SKIP] Original Invoke-WithRetry already patched" -ForegroundColor DarkGray
} elseif (NormContains $content $oldOriginalDispatchEnd) {
    $content = NormReplace $content $oldOriginalDispatchEnd $newOriginalDispatchEnd
    Write-Host "  [OK] Patched original Invoke-WithRetry dispatch" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for original Invoke-WithRetry" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 6: Patch Invoke-AgentFallback -- Enhanced version
# ================================================================

Write-Host "[STEP 6] Patching enhanced Invoke-AgentFallback..." -ForegroundColor Yellow

$oldFallbackEnhanced = @'
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
'@

$newFallbackEnhanced = @'
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
'@

if ($content.Contains('Test-IsOpenAICompatAgent -AgentName $FallbackAgent')) {
    Write-Host "  [SKIP] Enhanced Invoke-AgentFallback already patched" -ForegroundColor DarkGray
} elseif (NormContains $content $oldFallbackEnhanced) {
    $content = NormReplace $content $oldFallbackEnhanced $newFallbackEnhanced
    Write-Host "  [OK] Patched enhanced Invoke-AgentFallback" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for enhanced Invoke-AgentFallback" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 7: Patch Extract-TokensFromOutput (add openai-compat parsing)
# ================================================================

Write-Host "[STEP 7] Patching Extract-TokensFromOutput..." -ForegroundColor Yellow

$oldExtractEnd = @'
                NumTurns = 0
            }
        }
    } catch {
        # Any parse failure -> return null, caller uses raw output
        return $null
    }
'@

$newExtractEnd = @'
                NumTurns = 0
            }
        }
        elseif ($RawOutput -match '"type"\s*:\s*"openai-compat-result"') {
            # Synthetic envelope from Invoke-OpenAICompatibleAgent
            $parsed = $RawOutput | ConvertFrom-Json -ErrorAction Stop
            $textOutput = if ($parsed.result) { $parsed.result } else { "" }
            $inputTokens  = if ($parsed.usage.input_tokens)  { [int]$parsed.usage.input_tokens }  else { 0 }
            $outputTokens = if ($parsed.usage.output_tokens) { [int]$parsed.usage.output_tokens } else { 0 }
            $cachedTokens = if ($parsed.usage.cached_tokens) { [int]$parsed.usage.cached_tokens } else { 0 }
            $durationMs   = if ($parsed.duration_ms)         { [int]$parsed.duration_ms }         else { 0 }

            if ($inputTokens -eq 0 -and $outputTokens -eq 0) { return $null }

            $pricing = Get-TokenPrice -Agent $Agent
            $costUsd = ($inputTokens / 1000000.0) * $pricing.InputPerM +
                       ($outputTokens / 1000000.0) * $pricing.OutputPerM

            return @{
                Tokens     = @{ input = $inputTokens; output = $outputTokens; cached = $cachedTokens }
                CostUsd    = [math]::Round($costUsd, 6)
                TextOutput = $textOutput
                DurationMs = $durationMs
                NumTurns   = 1
            }
        }
    } catch {
        # Any parse failure -> return null, caller uses raw output
        return $null
    }
'@

if ($content.Contains('openai-compat-result')) {
    Write-Host "  [SKIP] Extract-TokensFromOutput already patched" -ForegroundColor DarkGray
} elseif (NormContains $content $oldExtractEnd) {
    $content = NormReplace $content $oldExtractEnd $newExtractEnd
    Write-Host "  [OK] Patched Extract-TokensFromOutput for openai-compat" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for Extract-TokensFromOutput" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 8: Patch Get-TokenPrice (add new model pricing)
# ================================================================

Write-Host "[STEP 8] Patching Get-TokenPrice..." -ForegroundColor Yellow

# 8A: Expand fallback hashtable
$oldFallback = @'
    $fallback = @{
        claude = @{ InputPerM = 3.00; OutputPerM = 15.00; CacheReadPerM = 0.30; ModelKey = "claude_sonnet" }
        codex  = @{ InputPerM = 1.50; OutputPerM = 6.00;  CacheReadPerM = 0.00; ModelKey = "codex" }
        gemini = @{ InputPerM = 1.25; OutputPerM = 10.00; CacheReadPerM = 0.125; ModelKey = "gemini" }
    }
'@

$newFallback = @'
    $fallback = @{
        claude   = @{ InputPerM = 3.00; OutputPerM = 15.00; CacheReadPerM = 0.30;  ModelKey = "claude_sonnet" }
        codex    = @{ InputPerM = 1.50; OutputPerM = 6.00;  CacheReadPerM = 0.00;  ModelKey = "codex" }
        gemini   = @{ InputPerM = 1.25; OutputPerM = 10.00; CacheReadPerM = 0.125; ModelKey = "gemini" }
        kimi     = @{ InputPerM = 0.60; OutputPerM = 2.50;  CacheReadPerM = 0.10;  ModelKey = "kimi" }
        deepseek = @{ InputPerM = 0.28; OutputPerM = 0.42;  CacheReadPerM = 0.028; ModelKey = "deepseek" }
        glm5     = @{ InputPerM = 1.00; OutputPerM = 3.20;  CacheReadPerM = 0.10;  ModelKey = "glm5" }
        minimax  = @{ InputPerM = 0.29; OutputPerM = 1.20;  CacheReadPerM = 0.03;  ModelKey = "minimax" }
    }
'@

if ($content.Contains('kimi     = @{ InputPerM')) {
    Write-Host "  [SKIP] Get-TokenPrice fallback already has new models" -ForegroundColor DarkGray
} elseif (NormContains $content $oldFallback) {
    $content = NormReplace $content $oldFallback $newFallback
    Write-Host "  [OK] Expanded Get-TokenPrice fallback hashtable" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for Get-TokenPrice fallback" -ForegroundColor DarkYellow
}

# 8B: Expand modelKey switch
$oldModelKeySwitch = @'
    $modelKey = switch ($Agent) {
        "claude" { "claude_sonnet" }
        "codex"  { "codex" }
        "gemini" { "gemini" }
        default  { $Agent }
    }
'@

$newModelKeySwitch = @'
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
'@

if ($content.Contains('"kimi"     { "kimi" }')) {
    Write-Host "  [SKIP] Get-TokenPrice switch already has new models" -ForegroundColor DarkGray
} elseif (NormContains $content $oldModelKeySwitch) {
    $content = NormReplace $content $oldModelKeySwitch $newModelKeySwitch
    Write-Host "  [OK] Expanded Get-TokenPrice modelKey switch" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for Get-TokenPrice modelKey switch" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 9: Patch Get-NextAvailableAgent (registry-driven pool)
# ================================================================

Write-Host "[STEP 9] Patching Get-NextAvailableAgent pool..." -ForegroundColor Yellow

$oldPool = @'
    # Agent pool -- order matters (preference order)
    $pool = @("claude", "codex", "gemini")
'@

$newPool = @'
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
'@

if ($content.Contains('rotation_pool_default')) {
    Write-Host "  [SKIP] Get-NextAvailableAgent already reads from registry" -ForegroundColor DarkGray
} elseif (NormContains $content $oldPool) {
    $content = NormReplace $content $oldPool $newPool
    Write-Host "  [OK] Patched Get-NextAvailableAgent for registry-driven pool" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for Get-NextAvailableAgent pool" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 10: Reduce rotation threshold from 3 to 1
# ================================================================

Write-Host "[STEP 10] Reducing rotation threshold..." -ForegroundColor Yellow

$oldThreshold = '$script:QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE = 3'
$newThreshold = '$script:QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE = 1   # Multi-model: rotate immediately on first quota hit'

if ($content.Contains('QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE = 1')) {
    Write-Host "  [SKIP] Threshold already set to 1" -ForegroundColor DarkGray
} elseif (NormContains $content $oldThreshold) {
    $content = NormReplace $content $oldThreshold $newThreshold
    Write-Host "  [OK] Reduced QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE from 3 to 1" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for QUOTA_CONSECUTIVE_FAILS_BEFORE_ROTATE" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 11: Patch Wait-ForQuotaReset (add REST agent probe)
# ================================================================

Write-Host "[STEP 11] Patching Wait-ForQuotaReset quota probe..." -ForegroundColor Yellow

$oldProbe = @'
                } elseif ($Agent -eq "gemini") {
                    $testOutput = "Reply with just the word READY" | gemini --approval-mode plan 2>&1
                } else {
                    $testOutput = claude -p "Reply with just the word READY" 2>&1
                }
'@

$newProbe = @'
                } elseif ($Agent -eq "gemini") {
                    $testOutput = "Reply with just the word READY" | gemini --approval-mode plan 2>&1
                } elseif (Test-IsOpenAICompatAgent -AgentName $Agent) {
                    $testOutput = Invoke-OpenAICompatibleAgent -AgentName $Agent -Prompt "Reply with just the word READY" -TimeoutSeconds 30
                } else {
                    $testOutput = claude -p "Reply with just the word READY" 2>&1
                }
'@

if ($content.Contains('Test-IsOpenAICompatAgent -AgentName $Agent') -and $content.Contains('Reply with just the word READY" -TimeoutSeconds 30')) {
    Write-Host "  [SKIP] Wait-ForQuotaReset already has REST probe" -ForegroundColor DarkGray
} elseif (NormContains $content $oldProbe) {
    $content = NormReplace $content $oldProbe $newProbe
    Write-Host "  [OK] Patched Wait-ForQuotaReset for REST agent probe" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for Wait-ForQuotaReset probe" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 12: Patch council -- dynamic reviewer pool expansion
# ================================================================

Write-Host "[STEP 12] Patching council for configurable reviewer pool..." -ForegroundColor Yellow

# Build council anchors programmatically to preserve Unicode box-drawing chars (U+2500)
$boxDash = [char]0x2500
$oldCouncilChunking = "        }`n    }`n`n    # ${boxDash}${boxDash} CHUNKING DECISION ${boxDash}${boxDash}"

$councilExpansionBlock = @'

    # ── MULTI-MODEL: Dynamic reviewer pool expansion from agent-map.json ──
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

'@
$newCouncilChunking = "        }`n    }`n" + ($councilExpansionBlock -replace "`r`n", "`n") + "`n    # ${boxDash}${boxDash} CHUNKING DECISION ${boxDash}${boxDash}"

if ($content.Contains('# ── MULTI-MODEL: Dynamic reviewer pool expansion')) {
    Write-Host "  [SKIP] Council dynamic pool already patched" -ForegroundColor DarkGray
} elseif (NormContains $content $oldCouncilChunking) {
    $content = NormReplace $content $oldCouncilChunking $newCouncilChunking
    Write-Host "  [OK] Patched council for dynamic reviewer pool expansion" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for council chunking decision" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 13: Patch preflight -- add REST agent API key checks
# ================================================================

Write-Host "[STEP 13] Patching Test-PreFlight for REST agent checks..." -ForegroundColor Yellow

$oldPreflightResults = @'
    # -- Results --
    Write-Host ""
    if ($errors.Count -gt 0) {
        Write-Host "  [XX] Pre-flight FAILED:" -ForegroundColor Red
'@

$newPreflightResults = @'
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
'@

if ($content.Contains('REST agent API key checks')) {
    Write-Host "  [SKIP] Test-PreFlight already has REST checks" -ForegroundColor DarkGray
} elseif (NormContains $content $oldPreflightResults) {
    $content = NormReplace $content $oldPreflightResults $newPreflightResults
    Write-Host "  [OK] Patched Test-PreFlight for REST agent key checks" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for Test-PreFlight results section" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 13B: Patch Get-FailureDiagnosis -- handle REST agents (enhanced version)
# ================================================================

Write-Host "[STEP 13B] Patching enhanced Get-FailureDiagnosis for REST agents..." -ForegroundColor Yellow

$oldDiagEnhancedElse = @'
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
'@

$newDiagEnhancedElse = @'
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
'@

if ($content.Contains("Test-IsOpenAICompatAgent -AgentName `$Agent") -and $content.Contains("`$Agent rate-limited")) {
    Write-Host "  [SKIP] Enhanced Get-FailureDiagnosis already patched" -ForegroundColor DarkGray
} elseif (NormContains $content $oldDiagEnhancedElse) {
    $content = NormReplace $content $oldDiagEnhancedElse $newDiagEnhancedElse
    Write-Host "  [OK] Patched enhanced Get-FailureDiagnosis for REST agents" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for enhanced Get-FailureDiagnosis" -ForegroundColor DarkYellow
}

# ================================================================
# STEP 13C: Patch Get-FailureDiagnosis -- handle REST agents (original version)
# ================================================================

Write-Host "[STEP 13C] Patching original Get-FailureDiagnosis for REST agents..." -ForegroundColor Yellow

$oldDiagOriginalElse = @'
    } else {
        $diagnosis = "Unknown agent '$Agent' exit code $ExitCode"
    }

    return @{ Diagnosis = $diagnosis; Action = $action; FallbackAgent = $fallbackAgent; FallbackMode = $fallbackMode }
}
'@

$newDiagOriginalElse = @'
    } elseif ((Get-Command Test-IsOpenAICompatAgent -ErrorAction SilentlyContinue) -and (Test-IsOpenAICompatAgent -AgentName $Agent)) {
        if ($OutputText -match "rate_limit|429|too.many.requests") {
            $diagnosis = "$Agent rate-limited (HTTP 429)"
        } elseif ($OutputText -match "quota_exhausted|402|payment|insufficient") {
            $diagnosis = "$Agent quota exhausted"
        } elseif ($OutputText -match "unauthorized|401|invalid.*key|auth") {
            $diagnosis = "$Agent authentication failed (check API key)"
            $action = "fail"
        } elseif ($OutputText -match "server_error|500|502|503|504") {
            $diagnosis = "$Agent server error (transient)"
        } elseif (-not $OutputText -or $OutputText.Trim().Length -eq 0) {
            $diagnosis = "$Agent produced no output"
        } else {
            $diagnosis = "$Agent exit code $ExitCode"
        }
        if ($Phase -match "research|review|verify|plan|council") {
            $action = "fallback"
            $fallbackAgent = "claude"
        } else {
            $action = "retry"
        }
    } else {
        $diagnosis = "Unknown agent '$Agent' exit code $ExitCode"
    }

    return @{ Diagnosis = $diagnosis; Action = $action; FallbackAgent = $fallbackAgent; FallbackMode = $fallbackMode }
}
'@

if ($content.Contains('$Agent rate-limited (HTTP 429)') -and $content.Contains('return @{ Diagnosis = $diagnosis; Action = $action;')) {
    Write-Host "  [SKIP] Original Get-FailureDiagnosis already patched" -ForegroundColor DarkGray
} elseif (NormContains $content $oldDiagOriginalElse) {
    $content = NormReplace $content $oldDiagOriginalElse $newDiagOriginalElse
    Write-Host "  [OK] Patched original Get-FailureDiagnosis for REST agents" -ForegroundColor Green
    $changeCount++
} else {
    Write-Host "  [!!] Anchor not found for original Get-FailureDiagnosis" -ForegroundColor DarkYellow
}

# ================================================================
# Write resilience.ps1 back
# ================================================================

Write-NormalizedContent $resiliencePath $content
Write-Host ""
Write-Host "  [SAVED] resilience.ps1 updated" -ForegroundColor Green

# ================================================================
# STEP 14: Patch supervisor.ps1 -- cooldown-aware diagnosis routing
# ================================================================

Write-Host "[STEP 14] Patching supervisor for cooldown-aware routing..." -ForegroundColor Yellow

if (-not (Test-Path $supervisorPath)) {
    Write-Host "  [SKIP] supervisor.ps1 not found" -ForegroundColor DarkYellow
} else {
    $supContent = Read-NormalizedContent $supervisorPath

    $oldSupervisorDiag = @'
    # Use Invoke-WithRetry if available, otherwise direct call
    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
        $result = Invoke-WithRetry -Agent "claude" -Prompt $prompt -Phase "supervisor-diagnosis" `
            -LogFile $diagLogFile -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2 `
            -AllowedTools "Read,Write,Bash"
    } else {
        $output = claude -p $prompt --allowedTools "Read,Write,Bash" 2>&1
'@

    $newSupervisorDiag = @'
    # Prefer claude for diagnosis; fall back to available agent if claude is in cooldown
    $diagAgent = "claude"
    if (Get-Command Get-NextAvailableAgent -ErrorAction SilentlyContinue) {
        $cooldownPath = Join-Path $GsdDir "supervisor\agent-cooldowns.json"
        if (Test-Path $cooldownPath) {
            try {
                $cdState = Get-Content $cooldownPath -Raw | ConvertFrom-Json
                if ($cdState.claude) {
                    $claudeCooldownUntil = [datetime]$cdState.claude
                    if ((Get-Date) -lt $claudeCooldownUntil) {
                        $altAgent = Get-NextAvailableAgent -CurrentAgent "" -GsdDir $GsdDir
                        if ($altAgent) {
                            $diagAgent = $altAgent
                            Write-Host "  [SUPERVISOR] Claude in cooldown. Using $diagAgent for diagnosis." -ForegroundColor Yellow
                        }
                    }
                }
            } catch { }
        }
    }

    # Use Invoke-WithRetry if available, otherwise direct call
    if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
        $result = Invoke-WithRetry -Agent $diagAgent -Prompt $prompt -Phase "supervisor-diagnosis" `
            -LogFile $diagLogFile -CurrentBatchSize 1 -GsdDir $GsdDir -MaxAttempts 2 `
            -AllowedTools "Read,Write,Bash"
    } else {
        $output = claude -p $prompt --allowedTools "Read,Write,Bash" 2>&1
'@

    if ($supContent.Contains('$diagAgent = "claude"')) {
        Write-Host "  [SKIP] Supervisor already patched for cooldown-aware routing" -ForegroundColor DarkGray
    } elseif (NormContains $supContent $oldSupervisorDiag) {
        $supContent = NormReplace $supContent $oldSupervisorDiag $newSupervisorDiag
        Write-NormalizedContent $supervisorPath $supContent
        Write-Host "  [OK] Patched supervisor for cooldown-aware diagnosis routing" -ForegroundColor Green
        $changeCount++
    } else {
        Write-Host "  [!!] Anchor not found in supervisor.ps1" -ForegroundColor DarkYellow
    }
}

# ================================================================
# STEP 15: Update token-cost-calculator.ps1
# ================================================================

Write-Host "[STEP 15] Updating token-cost-calculator.ps1 pricing..." -ForegroundColor Yellow

if (-not (Test-Path $calculatorPath)) {
    Write-Host "  [SKIP] token-cost-calculator.ps1 not found" -ForegroundColor DarkYellow
} else {
    $calcContent = Read-NormalizedContent $calculatorPath

    # 15A: Expand $FallbackPricing.models
    $oldCalcFallback = @'
        gemini        = @{ Name = "Gemini 3.1 Pro";                  InputPerM = 2.00;  OutputPerM = 12.00; CacheReadPerM = 0.50  }
    }
}
'@

    $newCalcFallback = @'
        gemini        = @{ Name = "Gemini 3.1 Pro";                  InputPerM = 2.00;  OutputPerM = 12.00; CacheReadPerM = 0.50  }
        kimi          = @{ Name = "Kimi K2.5 (Moonshot)";            InputPerM = 0.60;  OutputPerM = 2.50;  CacheReadPerM = 0.10  }
        deepseek      = @{ Name = "DeepSeek V3";                     InputPerM = 0.28;  OutputPerM = 0.42;  CacheReadPerM = 0.028 }
        glm5          = @{ Name = "GLM-5 (Zhipu AI)";               InputPerM = 1.00;  OutputPerM = 3.20;  CacheReadPerM = 0.10  }
        minimax       = @{ Name = "MiniMax M2.5";                    InputPerM = 0.29;  OutputPerM = 1.20;  CacheReadPerM = 0.03  }
    }
}
'@

    if ($calcContent.Contains('Kimi K2.5')) {
        Write-Host "  [SKIP] FallbackPricing already has new models" -ForegroundColor DarkGray
    } elseif (NormContains $calcContent $oldCalcFallback) {
        $calcContent = NormReplace $calcContent $oldCalcFallback $newCalcFallback
        Write-Host "  [OK] Expanded FallbackPricing.models with 4 new providers" -ForegroundColor Green
        $changeCount++
    } else {
        Write-Host "  [!!] Anchor not found for FallbackPricing.models" -ForegroundColor DarkYellow
    }

    # 15B: Expand $modelLookups
    $oldCalcLookups = @'
        @{ CacheKey = "gemini";        LiteLLMKeys = @("gemini-3.1-pro-preview","gemini-3-pro-preview","gemini-2.5-pro"); NamePrefix = "Gemini 3.1 Pro" }
    )
'@

    $newCalcLookups = @'
        @{ CacheKey = "gemini";        LiteLLMKeys = @("gemini-3.1-pro-preview","gemini-3-pro-preview","gemini-2.5-pro"); NamePrefix = "Gemini 3.1 Pro" }
        @{ CacheKey = "kimi";          LiteLLMKeys = @("moonshot-v1-128k","moonshot-v1-32k","kimi-k2.5"); NamePrefix = "Kimi K2.5" }
        @{ CacheKey = "deepseek";      LiteLLMKeys = @("deepseek-chat","deepseek-coder"); NamePrefix = "DeepSeek" }
        @{ CacheKey = "glm5";          LiteLLMKeys = @("glm-5","glm-4","glm-4-0520"); NamePrefix = "GLM" }
        @{ CacheKey = "minimax";       LiteLLMKeys = @("minimax-m2.5","minimax-m2","abab6.5s-chat"); NamePrefix = "MiniMax" }
    )
'@

    if ($calcContent.Contains('CacheKey = "kimi"')) {
        Write-Host "  [SKIP] modelLookups already has new models" -ForegroundColor DarkGray
    } elseif (NormContains $calcContent $oldCalcLookups) {
        $calcContent = NormReplace $calcContent $oldCalcLookups $newCalcLookups
        Write-Host "  [OK] Expanded modelLookups with 4 new LiteLLM entries" -ForegroundColor Green
        $changeCount++
    } else {
        Write-Host "  [!!] Anchor not found for modelLookups" -ForegroundColor DarkYellow
    }

    Write-NormalizedContent $calculatorPath $calcContent
    Write-Host "  [SAVED] token-cost-calculator.ps1 updated" -ForegroundColor Green
}

# ================================================================
# STEP 16: Create generic council review prompt template
# ================================================================

Write-Host "[STEP 16] Creating generic council review template..." -ForegroundColor Yellow

$genericReviewPath = Join-Path $councilPromptDir "openai-compat-review.md"

if (Test-Path $genericReviewPath) {
    Write-Host "  [SKIP] openai-compat-review.md already exists" -ForegroundColor DarkGray
} else {
    $genericReview = @'
# LLM Council Review -- Implementation Quality

You are 1 of multiple independent reviewers in a multi-agent council. Be HONEST -- do not rubber-stamp.

## Context
- Health: {{HEALTH}}% | Iteration: {{ITERATION}}
- Project: {{REPO_ROOT}}
- GSD dir: {{GSD_DIR}}

## Read
1. {{GSD_DIR}}\health\requirements-matrix.json
2. Source code (all implementation files)

## Review Focus
1. **Implementation Completeness**: Are all requirements actually implemented (not just stubbed)?
2. **Error Handling**: Try/catch patterns, null checks, validation at boundaries
3. **API Contract Adherence**: Do controllers match expected request/response shapes?
4. **Stored Procedure Patterns**: Proper parameterization, transaction scoping, error returns
5. **Frontend Patterns**: React component structure, state management, prop validation
6. **Edge Cases**: Empty collections, concurrent access, boundary values, timeout handling

## Output Format (max 2000 tokens)
Return ONLY a JSON object:
```json
{
  "vote": "approve|concern|block",
  "confidence": 0-100,
  "findings": ["finding 1", "finding 2"],
  "strengths": ["strength 1", "strength 2"],
  "summary": "1-2 sentence summary"
}
```

## Security Review (MANDATORY)
1. **SQL injection**: Any string concatenation in query building?
2. **Auth**: Every controller class has [Authorize] attribute?
3. **Secrets**: Hardcoded connection strings, API keys, or passwords?
4. **PII**: PHI/PII encrypted at rest? Excluded from logs?
5. **XSS**: Any dangerouslySetInnerHTML without DOMPurify?
6. **Tokens**: Sensitive data stored in localStorage?
7. **Audit**: INSERT/UPDATE/DELETE operations logged to audit table?
8. **Compliance**: HIPAA/SOC2/PCI/GDPR patterns per security-standards.md?

## Database Completeness Review
1. Every API endpoint has a corresponding stored procedure?
2. Every stored procedure references existing tables?
3. Seed data exists for all tables?
4. The _analysis/11-api-to-sp-map.md chain is complete (no empty cells)?

Rules:
- "block" = code will fail at runtime, has critical bugs, or has critical security violations
- "concern" = code works but has quality or security issues
- "approve" = implementation is solid and secure
- Be specific: include file paths where possible
'@
    if (-not (Test-Path $councilPromptDir)) { New-Item -Path $councilPromptDir -ItemType Directory -Force | Out-Null }
    Set-Content -Path $genericReviewPath -Value $genericReview -Encoding UTF8
    Write-Host "  [OK] Created openai-compat-review.md" -ForegroundColor Green
    $changeCount++
}

# ================================================================
# SUMMARY
# ================================================================

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  Multi-Model Integration Complete" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Changes applied: $changeCount" -ForegroundColor Green
Write-Host ""
Write-Host "  Agent Pool (7 providers):" -ForegroundColor White
Write-Host "    CLI:  claude, codex, gemini" -ForegroundColor DarkGray
Write-Host "    REST: kimi, deepseek, glm5, minimax" -ForegroundColor DarkGray
Write-Host ""

# Check API key status
$envChecks = @(
    @{ Name = "Kimi K2.5";     Var = "KIMI_API_KEY" }
    @{ Name = "DeepSeek V3";   Var = "DEEPSEEK_API_KEY" }
    @{ Name = "GLM-5";         Var = "GLM_API_KEY" }
    @{ Name = "MiniMax M2.5";  Var = "MINIMAX_API_KEY" }
)

Write-Host "  API Key Status:" -ForegroundColor White
foreach ($check in $envChecks) {
    $val = [System.Environment]::GetEnvironmentVariable($check.Var)
    if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($check.Var, 'User') }
    if (-not $val) { $val = [System.Environment]::GetEnvironmentVariable($check.Var, 'Machine') }
    if ($val) {
        Write-Host "    [OK] $($check.Var) -> $($check.Name)" -ForegroundColor Green
    } else {
        Write-Host "    [--] $($check.Var) not set -> $($check.Name) disabled" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "  Rotation: Immediate (1 failure = rotate)" -ForegroundColor White
Write-Host "  Config:   $registryPath" -ForegroundColor DarkGray
Write-Host ""
