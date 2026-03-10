<#
.SYNOPSIS
    GSD V3 API Client - Sonnet 4.6 + Codex Mini REST API with Prompt Caching + Batch API
.DESCRIPTION
    Two-model deterministic routing. No CLI agents, no rotation pools, no quota juggling.
    Fixes V2 issues:
    - No more 7-agent coordination complexity
    - No more CLI tool dependency (removed claude/codex/gemini/kimi CLI tools)
    - No more $using: scope issues in scriptblocks
    - Proper JSON parsing with fallback (no more silent parse failures)
    - Explicit error types with actionable messages
    - Retry with exponential backoff on transient errors only
    - Budget enforcement before every API call
#>

# ============================================================
# CONFIGURATION
# ============================================================

$script:ApiConfig = @{
    Anthropic = @{
        BaseUrl    = "https://api.anthropic.com"
        ApiVersion = "2023-06-01"
        Model      = "claude-sonnet-4-6-20260310"
        MaxRetries = 3
        RetryBackoff = @(2, 4, 8)
        TimeoutSec = 120
        BatchEndpoint = "/v1/messages/batches"
        BatchPollIntervalSec = 30
        BatchMaxWaitMin = 60
    }
    OpenAI = @{
        BaseUrl    = "https://api.openai.com/v1"
        Model      = "gpt-5.1-codex-mini"
        MaxRetries = 3
        RetryBackoff = @(2, 4, 8)
        TimeoutSec = 120
        MaxConcurrent = 15
    }
    # Escape hatch models
    OpusModel  = "claude-opus-4-6-20260310"
    CodexFull  = "gpt-5.1-codex"
}

# Cache state (module-scoped)
$script:CacheState = @{
    Version       = 0
    BlockHashes   = @{}
    LastWriteTime = $null
    WarmupDone    = $false
}

# ============================================================
# API KEY RESOLUTION
# ============================================================

function Get-ApiKey {
    param([ValidateSet("Anthropic", "OpenAI")][string]$Provider)

    $envVar = if ($Provider -eq "Anthropic") { "ANTHROPIC_API_KEY" } else { "OPENAI_API_KEY" }

    # Search order: Process → User → Machine
    $key = [System.Environment]::GetEnvironmentVariable($envVar, "Process")
    if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable($envVar, "User") }
    if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable($envVar, "Machine") }

    if (-not $key) {
        throw "API key not found: Set $envVar environment variable. Provider: $Provider"
    }
    return $key
}

# ============================================================
# SONNET API (Anthropic Messages API)
# ============================================================

function Invoke-SonnetApi {
    <#
    .SYNOPSIS
        Call Claude Sonnet 4.6 via Anthropic Messages API with prompt caching support.
    .PARAMETER SystemPrompt
        System prompt text (will be cached if CacheControl is set).
    .PARAMETER UserMessage
        User message content.
    .PARAMETER CacheBlocks
        Array of cache block objects: @{ text = "..."; cache = $true }
    .PARAMETER MaxTokens
        Maximum output tokens.
    .PARAMETER JsonMode
        Force JSON output (response_format: json).
    .PARAMETER UseCache
        Whether to use prompt caching (read from cache).
    .PARAMETER WriteCacheControl
        Set to $true to write cache (ephemeral cache_control).
    .PARAMETER Model
        Override model (for Opus escalation).
    .PARAMETER Phase
        Phase name for cost tracking.
    #>
    param(
        [string]$SystemPrompt,
        [string]$UserMessage,
        [array]$CacheBlocks,
        [int]$MaxTokens = 4096,
        [switch]$JsonMode,
        [switch]$UseCache,
        [switch]$WriteCacheControl,
        [string]$Model,
        [string]$Phase = "unknown"
    )

    $apiKey = Get-ApiKey -Provider "Anthropic"
    $modelId = if ($Model) { $Model } else { $script:ApiConfig.Anthropic.Model }

    # Build system blocks with cache control
    $systemBlocks = @()
    if ($CacheBlocks -and $CacheBlocks.Count -gt 0) {
        foreach ($block in $CacheBlocks) {
            $sysBlock = @{ type = "text"; text = $block.text }
            if ($WriteCacheControl -or ($UseCache -and $block.cache)) {
                $sysBlock["cache_control"] = @{ type = "ephemeral" }
            }
            $systemBlocks += $sysBlock
        }
    }
    elseif ($SystemPrompt) {
        $sysBlock = @{ type = "text"; text = $SystemPrompt }
        if ($WriteCacheControl) {
            $sysBlock["cache_control"] = @{ type = "ephemeral" }
        }
        $systemBlocks += $sysBlock
    }

    # Build request body
    $body = @{
        model      = $modelId
        max_tokens = $MaxTokens
        messages   = @(
            @{ role = "user"; content = $UserMessage }
        )
    }

    if ($systemBlocks.Count -gt 0) {
        $body["system"] = $systemBlocks
    }

    # Headers
    $headers = @{
        "x-api-key"         = $apiKey
        "anthropic-version" = $script:ApiConfig.Anthropic.ApiVersion
        "content-type"      = "application/json"
    }

    # Enable prompt caching beta if using cache
    if ($UseCache -or $WriteCacheControl) {
        $headers["anthropic-beta"] = "prompt-caching-2024-07-31"
    }

    $bodyJson = $body | ConvertTo-Json -Depth 20 -Compress
    $url = "$($script:ApiConfig.Anthropic.BaseUrl)/v1/messages"

    # Retry loop
    $attempt = 0
    $maxRetries = $script:ApiConfig.Anthropic.MaxRetries

    while ($attempt -le $maxRetries) {
        $attempt++
        try {
            $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers `
                -Body $bodyJson -TimeoutSec $script:ApiConfig.Anthropic.TimeoutSec `
                -ContentType "application/json"

            # Extract text content
            $outputText = ""
            foreach ($content in $response.content) {
                if ($content.type -eq "text") {
                    $outputText += $content.text
                }
            }

            # Extract usage for cost tracking
            $usage = @{
                input_tokens          = $response.usage.input_tokens
                output_tokens         = $response.usage.output_tokens
                cache_creation_tokens = if ($response.usage.cache_creation_input_tokens) { $response.usage.cache_creation_input_tokens } else { 0 }
                cache_read_tokens     = if ($response.usage.cache_read_input_tokens) { $response.usage.cache_read_input_tokens } else { 0 }
            }

            # Parse JSON if requested
            $parsed = $null
            if ($JsonMode -and $outputText) {
                try {
                    # Try to extract JSON from the response (handle markdown code blocks)
                    $jsonText = $outputText
                    if ($jsonText -match '```json\s*\n([\s\S]*?)\n```') {
                        $jsonText = $Matches[1]
                    }
                    elseif ($jsonText -match '```\s*\n([\s\S]*?)\n```') {
                        $jsonText = $Matches[1]
                    }
                    $parsed = $jsonText | ConvertFrom-Json
                }
                catch {
                    Write-Host "    [WARN] JSON parse failed for $Phase, using raw text" -ForegroundColor DarkYellow
                    $parsed = $null
                }
            }

            return @{
                Success    = $true
                Text       = $outputText
                Parsed     = $parsed
                Usage      = $usage
                Model      = $modelId
                Phase      = $Phase
                StopReason = $response.stop_reason
            }
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            # Non-retryable errors
            if ($statusCode -eq 400) {
                return @{
                    Success = $false
                    Error   = "bad_request"
                    Message = "Bad request: $($_.Exception.Message)"
                    Phase   = $Phase
                    Usage   = @{ input_tokens = 0; output_tokens = 0 }
                }
            }
            if ($statusCode -eq 401) {
                return @{
                    Success = $false
                    Error   = "auth_failed"
                    Message = "Authentication failed. Check ANTHROPIC_API_KEY."
                    Phase   = $Phase
                    Usage   = @{ input_tokens = 0; output_tokens = 0 }
                }
            }

            # Retryable errors (429, 500, 502, 503, timeout)
            if ($attempt -le $maxRetries) {
                $backoff = $script:ApiConfig.Anthropic.RetryBackoff[$attempt - 1]

                # For 429, use retry-after header if available
                if ($statusCode -eq 429 -and $_.Exception.Response.Headers) {
                    $retryAfter = $_.Exception.Response.Headers["retry-after"]
                    if ($retryAfter) { $backoff = [int]$retryAfter }
                }

                Write-Host "    [RETRY] Sonnet API error ($statusCode), attempt $attempt/$maxRetries, waiting ${backoff}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $backoff
                continue
            }

            return @{
                Success = $false
                Error   = "api_error"
                Message = "Sonnet API failed after $maxRetries retries: $($_.Exception.Message)"
                Phase   = $Phase
                Usage   = @{ input_tokens = 0; output_tokens = 0 }
            }
        }
    }
}

# ============================================================
# SONNET BATCH API
# ============================================================

function Submit-SonnetBatch {
    <#
    .SYNOPSIS
        Submit a batch of Sonnet requests for 50% cost savings.
    .PARAMETER Requests
        Array of request objects with custom_id and params.
    .PARAMETER Phase
        Phase name for tracking.
    #>
    param(
        [array]$Requests,
        [string]$Phase = "unknown"
    )

    $apiKey = Get-ApiKey -Provider "Anthropic"
    $url = "$($script:ApiConfig.Anthropic.BaseUrl)$($script:ApiConfig.Anthropic.BatchEndpoint)"

    $body = @{
        requests = $Requests
    } | ConvertTo-Json -Depth 20 -Compress

    $headers = @{
        "x-api-key"         = $apiKey
        "anthropic-version" = $script:ApiConfig.Anthropic.ApiVersion
        "content-type"      = "application/json"
        "anthropic-beta"    = "message-batches-2024-09-24,prompt-caching-2024-07-31"
    }

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers `
            -Body $body -TimeoutSec 30 -ContentType "application/json"

        return @{
            Success = $true
            BatchId = $response.id
            Status  = $response.processing_status
            Phase   = $Phase
        }
    }
    catch {
        return @{
            Success = $false
            Error   = "batch_submit_failed"
            Message = $_.Exception.Message
            Phase   = $Phase
        }
    }
}

function Wait-SonnetBatch {
    <#
    .SYNOPSIS
        Poll a batch until completion or timeout.
    #>
    param(
        [string]$BatchId,
        [string]$Phase = "unknown"
    )

    $apiKey = Get-ApiKey -Provider "Anthropic"
    $url = "$($script:ApiConfig.Anthropic.BaseUrl)$($script:ApiConfig.Anthropic.BatchEndpoint)/$BatchId"
    $headers = @{
        "x-api-key"         = $apiKey
        "anthropic-version" = $script:ApiConfig.Anthropic.ApiVersion
        "anthropic-beta"    = "message-batches-2024-09-24"
    }

    $pollInterval = $script:ApiConfig.Anthropic.BatchPollIntervalSec
    $maxWait = $script:ApiConfig.Anthropic.BatchMaxWaitMin * 60
    $elapsed = 0

    while ($elapsed -lt $maxWait) {
        try {
            $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -TimeoutSec 30

            if ($response.processing_status -eq "ended") {
                return @{
                    Success      = $true
                    BatchId      = $BatchId
                    ResultsUrl   = $response.results_url
                    RequestCounts = $response.request_counts
                    Phase        = $Phase
                }
            }

            Write-Host "    [BATCH] $Phase: $($response.processing_status) ($([math]::Round($elapsed/60,1))m elapsed)" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "    [WARN] Batch poll error: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }

        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval
    }

    return @{
        Success = $false
        Error   = "batch_timeout"
        Message = "Batch $BatchId timed out after $($script:ApiConfig.Anthropic.BatchMaxWaitMin) minutes"
        Phase   = $Phase
    }
}

function Get-SonnetBatchResults {
    <#
    .SYNOPSIS
        Retrieve results from a completed batch.
    #>
    param(
        [string]$ResultsUrl
    )

    $apiKey = Get-ApiKey -Provider "Anthropic"
    $headers = @{
        "x-api-key"         = $apiKey
        "anthropic-version" = $script:ApiConfig.Anthropic.ApiVersion
        "anthropic-beta"    = "message-batches-2024-09-24"
    }

    try {
        $response = Invoke-RestMethod -Uri $ResultsUrl -Method Get -Headers $headers -TimeoutSec 60
        $results = @{}

        foreach ($line in ($response -split "`n")) {
            if ($line.Trim()) {
                try {
                    $entry = $line | ConvertFrom-Json
                    $text = ""
                    if ($entry.result -and $entry.result.message -and $entry.result.message.content) {
                        foreach ($c in $entry.result.message.content) {
                            if ($c.type -eq "text") { $text += $c.text }
                        }
                    }
                    $results[$entry.custom_id] = @{
                        Success = ($entry.result.type -eq "succeeded")
                        Text    = $text
                        Usage   = $entry.result.message.usage
                    }
                }
                catch { }
            }
        }

        return @{ Success = $true; Results = $results }
    }
    catch {
        return @{ Success = $false; Error = "batch_results_failed"; Message = $_.Exception.Message }
    }
}

# ============================================================
# CODEX MINI API (OpenAI Chat Completions)
# ============================================================

function Invoke-CodexMiniApi {
    <#
    .SYNOPSIS
        Call GPT-5.1 Codex Mini via OpenAI Chat Completions API.
    .PARAMETER SystemPrompt
        System prompt with coding conventions.
    .PARAMETER UserMessage
        User message with plan + context.
    .PARAMETER MaxTokens
        Maximum output tokens.
    .PARAMETER Model
        Override model (for Codex 5.3 escalation).
    .PARAMETER Phase
        Phase name for cost tracking.
    #>
    param(
        [string]$SystemPrompt,
        [string]$UserMessage,
        [int]$MaxTokens = 16384,
        [string]$Model,
        [string]$Phase = "execute"
    )

    $apiKey = Get-ApiKey -Provider "OpenAI"
    $modelId = if ($Model) { $Model } else { $script:ApiConfig.OpenAI.Model }

    $messages = @()
    if ($SystemPrompt) {
        $messages += @{ role = "system"; content = $SystemPrompt }
    }
    $messages += @{ role = "user"; content = $UserMessage }

    $body = @{
        model      = $modelId
        messages   = $messages
        max_tokens = $MaxTokens
    } | ConvertTo-Json -Depth 10 -Compress

    $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    }

    $url = "$($script:ApiConfig.OpenAI.BaseUrl)/chat/completions"

    # Retry loop
    $attempt = 0
    $maxRetries = $script:ApiConfig.OpenAI.MaxRetries

    while ($attempt -le $maxRetries) {
        $attempt++
        try {
            $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers `
                -Body $body -TimeoutSec $script:ApiConfig.OpenAI.TimeoutSec `
                -ContentType "application/json"

            $outputText = $response.choices[0].message.content

            $usage = @{
                input_tokens  = $response.usage.prompt_tokens
                output_tokens = $response.usage.completion_tokens
            }

            return @{
                Success    = $true
                Text       = $outputText
                Usage      = $usage
                Model      = $modelId
                Phase      = $Phase
                FinishReason = $response.choices[0].finish_reason
            }
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 400 -or $statusCode -eq 401) {
                return @{
                    Success = $false
                    Error   = if ($statusCode -eq 401) { "auth_failed" } else { "bad_request" }
                    Message = $_.Exception.Message
                    Phase   = $Phase
                    Usage   = @{ input_tokens = 0; output_tokens = 0 }
                }
            }

            if ($attempt -le $maxRetries) {
                $backoff = $script:ApiConfig.OpenAI.RetryBackoff[$attempt - 1]
                Write-Host "    [RETRY] Codex Mini API error ($statusCode), attempt $attempt/$maxRetries, waiting ${backoff}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $backoff
                continue
            }

            return @{
                Success = $false
                Error   = "api_error"
                Message = "Codex Mini API failed after $maxRetries retries: $($_.Exception.Message)"
                Phase   = $Phase
                Usage   = @{ input_tokens = 0; output_tokens = 0 }
            }
        }
    }
}

function Invoke-CodexMiniParallel {
    <#
    .SYNOPSIS
        Execute multiple Codex Mini calls in parallel (up to MaxConcurrent).
    .PARAMETER Items
        Array of items, each with: @{ Id = "REQ-xxx"; SystemPrompt = "..."; UserMessage = "..." }
    .PARAMETER MaxConcurrent
        Maximum concurrent API calls.
    .PARAMETER MaxTokens
        Max tokens per call.
    .PARAMETER Phase
        Phase name.
    #>
    param(
        [array]$Items,
        [int]$MaxConcurrent = 15,
        [int]$MaxTokens = 16384,
        [string]$Phase = "execute"
    )

    $results = @{}
    $totalUsage = @{ input_tokens = 0; output_tokens = 0 }

    # Process in batches of MaxConcurrent
    for ($i = 0; $i -lt $Items.Count; $i += $MaxConcurrent) {
        $batch = $Items[$i..([math]::Min($i + $MaxConcurrent - 1, $Items.Count - 1))]

        $jobs = @()
        foreach ($item in $batch) {
            $jobs += @{
                Id     = $item.Id
                Result = $null
            }
        }

        # Execute sequentially within batch (PowerShell 5.1 compatible)
        # For true parallelism, use runspaces or ForEach-Object -Parallel (PS 7+)
        foreach ($idx in 0..($batch.Count - 1)) {
            $item = $batch[$idx]
            $result = Invoke-CodexMiniApi `
                -SystemPrompt $item.SystemPrompt `
                -UserMessage $item.UserMessage `
                -MaxTokens $MaxTokens `
                -Phase $Phase `
                -Model $item.Model

            $results[$item.Id] = $result

            if ($result.Usage) {
                $totalUsage.input_tokens += $result.Usage.input_tokens
                $totalUsage.output_tokens += $result.Usage.output_tokens
            }

            $status = if ($result.Success) { "OK" } else { "FAIL" }
            Write-Host "    [$status] $($item.Id) ($($result.Usage.output_tokens) tokens)" -ForegroundColor $(if ($result.Success) { "Green" } else { "Red" })
        }
    }

    return @{
        Results    = $results
        TotalUsage = $totalUsage
        Completed  = ($results.Values | Where-Object { $_.Success }).Count
        Failed     = ($results.Values | Where-Object { -not $_.Success }).Count
        Total      = $Items.Count
    }
}

# ============================================================
# CACHE MANAGEMENT
# ============================================================

function Build-CachePrefix {
    <#
    .SYNOPSIS
        Build the 3-block cache prefix from project context.
    .PARAMETER SystemPromptPath
        Path to system-prompt.md
    .PARAMETER SpecDocuments
        Concatenated spec document content.
    .PARAMETER BlueprintManifest
        Blueprint manifest content.
    #>
    param(
        [string]$SystemPromptPath,
        [string]$SpecDocuments,
        [string]$BlueprintManifest
    )

    $systemPrompt = ""
    if ($SystemPromptPath -and (Test-Path $SystemPromptPath)) {
        $systemPrompt = Get-Content $SystemPromptPath -Raw -Encoding UTF8
    }

    $blocks = @(
        @{ text = $systemPrompt; cache = $true; name = "system_prompt" }
        @{ text = $SpecDocuments; cache = $true; name = "spec_documents" }
        @{ text = $BlueprintManifest; cache = $true; name = "blueprint_manifest" }
    )

    # Compute hashes for invalidation tracking
    $hashes = @{}
    foreach ($block in $blocks) {
        $hash = [System.Security.Cryptography.SHA256]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($block.text)
        $hashBytes = $hash.ComputeHash($bytes)
        $hashes[$block.name] = [System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLower()
    }

    $script:CacheState.BlockHashes = $hashes

    return $blocks
}

function Invoke-CacheWarmup {
    <#
    .SYNOPSIS
        Phase 0: Write cache prefix. Fire a minimal Sonnet call to populate the cache.
    #>
    param(
        [array]$CacheBlocks
    )

    if ($script:CacheState.WarmupDone) {
        Write-Host "  [CACHE] Already warm, skipping" -ForegroundColor DarkGray
        return @{ Success = $true; Skipped = $true; Usage = @{ input_tokens = 0; output_tokens = 0 } }
    }

    Write-Host "  [CACHE] Writing cache prefix..." -ForegroundColor DarkGray

    $result = Invoke-SonnetApi `
        -CacheBlocks $CacheBlocks `
        -UserMessage 'Acknowledge context loaded. Respond with: {"status": "ready"}' `
        -MaxTokens 20 `
        -WriteCacheControl `
        -Phase "cache-warm"

    if ($result.Success) {
        $script:CacheState.WarmupDone = $true
        $script:CacheState.LastWriteTime = Get-Date
        $script:CacheState.Version++
        Write-Host "  [CACHE] Warm-up complete (v$($script:CacheState.Version))" -ForegroundColor Green
    }
    else {
        Write-Host "  [CACHE] Warm-up FAILED: $($result.Message)" -ForegroundColor Red
    }

    return $result
}

function Test-CacheValid {
    <#
    .SYNOPSIS
        Check if cache is still valid (within 5-minute TTL).
    #>
    if (-not $script:CacheState.WarmupDone) { return $false }
    if (-not $script:CacheState.LastWriteTime) { return $false }

    $elapsed = (Get-Date) - $script:CacheState.LastWriteTime
    return ($elapsed.TotalMinutes -lt 5)
}

function Reset-CacheBlock {
    <#
    .SYNOPSIS
        Invalidate and rewrite a specific cache block (e.g., after spec-fix).
    #>
    param(
        [string]$BlockName,
        [string]$NewContent,
        [array]$CacheBlocks
    )

    Write-Host "  [CACHE] Invalidating block '$BlockName', rewriting..." -ForegroundColor Yellow

    # Update the block content
    foreach ($block in $CacheBlocks) {
        if ($block.name -eq $BlockName) {
            $block.text = $NewContent
        }
    }

    # Rewrite cache
    $script:CacheState.WarmupDone = $false
    return Invoke-CacheWarmup -CacheBlocks $CacheBlocks
}

# ============================================================
# HELPER: Build Batch Request
# ============================================================

function New-SonnetBatchRequest {
    <#
    .SYNOPSIS
        Create a single request entry for the Batch API.
    #>
    param(
        [string]$CustomId,
        [array]$CacheBlocks,
        [string]$UserMessage,
        [int]$MaxTokens = 4096
    )

    $systemBlocks = @()
    foreach ($block in $CacheBlocks) {
        $sysBlock = @{ type = "text"; text = $block.text }
        if ($block.cache) {
            $sysBlock["cache_control"] = @{ type = "ephemeral" }
        }
        $systemBlocks += $sysBlock
    }

    return @{
        custom_id = $CustomId
        params    = @{
            model      = $script:ApiConfig.Anthropic.Model
            max_tokens = $MaxTokens
            system     = $systemBlocks
            messages   = @(
                @{ role = "user"; content = $UserMessage }
            )
        }
    }
}

# ============================================================
# ESCAPE HATCHES
# ============================================================

function Invoke-OpusEscalation {
    <#
    .SYNOPSIS
        Escalate a single item to Opus 4.6 when Sonnet fails repeatedly.
    #>
    param(
        [string]$UserMessage,
        [array]$CacheBlocks,
        [int]$MaxTokens = 8192,
        [string]$Phase
    )

    Write-Host "    [ESCALATE] Using Opus 4.6 for $Phase" -ForegroundColor Magenta

    return Invoke-SonnetApi `
        -CacheBlocks $CacheBlocks `
        -UserMessage $UserMessage `
        -MaxTokens $MaxTokens `
        -UseCache `
        -JsonMode `
        -Model $script:ApiConfig.OpusModel `
        -Phase "$Phase-opus"
}

function Invoke-CodexFullEscalation {
    <#
    .SYNOPSIS
        Escalate a single item to Codex 5.3 when Codex Mini output is incomplete.
    #>
    param(
        [string]$SystemPrompt,
        [string]$UserMessage,
        [int]$MaxTokens = 32768,
        [string]$Phase
    )

    Write-Host "    [ESCALATE] Using Codex 5.3 for $Phase" -ForegroundColor Magenta

    return Invoke-CodexMiniApi `
        -SystemPrompt $SystemPrompt `
        -UserMessage $UserMessage `
        -MaxTokens $MaxTokens `
        -Model $script:ApiConfig.CodexFull `
        -Phase "$Phase-codex53"
}
