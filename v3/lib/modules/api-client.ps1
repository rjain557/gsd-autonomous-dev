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
# PS5.1 JSON FIX: ConvertTo-Json corrupts PSObject-wrapped strings to {"value":"..."}.
# This helper unwraps all strings in a hashtable/array tree before serialization.
# ============================================================
function ConvertTo-CleanJson {
    param([object]$InputObject, [int]$Depth = 5, [switch]$Compress)
    # Recursively unwrap PSObject strings
    function Unwrap($obj) {
        if ($null -eq $obj) { return $null }
        if ($obj -is [string]) { return [string]"$obj" }
        if ($obj -is [int] -or $obj -is [long] -or $obj -is [double] -or $obj -is [bool] -or $obj -is [decimal]) { return $obj }
        if ($obj -is [array] -or $obj -is [System.Collections.IList]) {
            $arr = [System.Collections.ArrayList]::new($obj.Count)
            foreach ($item in $obj) { [void]$arr.Add((Unwrap $item)) }
            return ,@($arr)
        }
        if ($obj -is [hashtable] -or $obj -is [System.Collections.IDictionary]) {
            $clean = @{}
            foreach ($key in $obj.Keys) { $clean[$key] = Unwrap $obj[$key] }
            return $clean
        }
        # PSCustomObject
        if ($obj -is [psobject]) {
            $clean = @{}
            foreach ($prop in $obj.PSObject.Properties) {
                if ($prop.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider','PSIsContainer','Mode','BaseName')) {
                    $clean[$prop.Name] = Unwrap $prop.Value
                }
            }
            return $clean
        }
        return "$obj"
    }
    $cleaned = Unwrap $InputObject
    if ($Compress) {
        return $cleaned | ConvertTo-Json -Depth $Depth -Compress
    } else {
        return $cleaned | ConvertTo-Json -Depth $Depth
    }
}

# ============================================================
# CONFIGURATION
# ============================================================

$script:ApiConfig = @{
    Anthropic = @{
        BaseUrl    = "https://api.anthropic.com"
        ApiVersion = "2023-06-01"
        Model      = "claude-sonnet-4-6"
        MaxRetries = 3
        RetryBackoff = @(2, 4, 8)
        TimeoutSec = 300  # Sonnet needs 300s for large plan/research phases (44K+ tokens)
        BatchEndpoint = "/v1/messages/batches"
        BatchPollIntervalSec = 30
        BatchMaxWaitMin = 60
    }
    OpenAI = @{
        BaseUrl    = "https://api.openai.com/v1"
        Model      = "gpt-5.1-codex-mini"
        MaxRetries = 1
        RetryBackoff = @(3)
        TimeoutSec = 240  # Codex needs 240s for large fill phases (16K+ token output, 180s still times out)
        MaxConcurrent = 2
        InterCallDelaySec = 3  # Delay between sequential calls to avoid rate limits
    }
    # Fallback model: DeepSeek (OpenAI-compatible, used when primary hits sustained 429)
    DeepSeek = @{
        BaseUrl    = "https://api.deepseek.com/v1"
        Model      = "deepseek-chat"
        ApiKeyEnv  = "DEEPSEEK_API_KEY"
        MaxRetries = 3
        RetryBackoff = @(2, 5, 10)
        TimeoutSec = 120
        InterCallDelaySec = 1
        MaxOutputTokens = 8192  # DeepSeek limit: max_tokens must be in [1, 8192]
    }
    # Additional fallback models (OpenAI-compatible chat/completions)
    Kimi = @{
        BaseUrl    = "https://api.moonshot.ai/v1"
        Model      = "moonshot-v1-8k"
        ApiKeyEnv  = "KIMI_API_KEY"
        MaxRetries = 2
        RetryBackoff = @(3, 8)
        TimeoutSec = 120
        InterCallDelaySec = 1
    }
    MiniMax = @{
        BaseUrl    = "https://api.minimax.io/v1"
        Model      = "MiniMax-Text-01"
        ApiKeyEnv  = "MINIMAX_API_KEY"
        MaxRetries = 2
        RetryBackoff = @(3, 8)
        TimeoutSec = 120
        InterCallDelaySec = 1
    }
    # Gemini (Google Generative Language API - non-OpenAI format)
    Gemini = @{
        BaseUrl    = "https://generativelanguage.googleapis.com/v1beta"
        Model      = "gemini-2.5-flash"
        ApiKeyEnv  = "GEMINI_API_KEY"
        MaxRetries = 3
        RetryBackoff = @(2, 4, 8)
        TimeoutSec = 300
        InterCallDelaySec = 1
    }
    # GLM5 / Zhipu (OpenAI-compatible, needs VPN from US)
    GLM5 = @{
        BaseUrl    = "https://open.bigmodel.cn/api/paas/v4"
        Model      = "glm-4-flash"
        ApiKeyEnv  = "GLM_API_KEY"
        MaxRetries = 2
        RetryBackoff = @(3, 8)
        TimeoutSec = 120
        InterCallDelaySec = 1
    }
    # Escape hatch models
    OpusModel  = "claude-opus-4-6"
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

    Write-Host "    [DEBUG] ${Phase}: Starting JSON serialization..." -ForegroundColor Magenta
    $jsonStart = Get-Date
    $bodyJson = ConvertTo-CleanJson -InputObject $body -Depth 5 -Compress
    $jsonElapsed = ((Get-Date) - $jsonStart).TotalSeconds
    Write-Host "    [DEBUG] ${Phase}: JSON done in $($jsonElapsed.ToString('F1'))s, body size: $($bodyJson.Length) chars" -ForegroundColor Magenta

    # Pre-flight: estimate input tokens and warn/truncate if approaching context window
    # Rule of thumb: 1 token ≈ 4 chars for English text
    $estimatedInputTokens = [math]::Round($bodyJson.Length / 4)
    $contextWindow = 200000
    $safeLimit = $contextWindow - $MaxTokens - 5000  # Reserve space for output + overhead
    if ($estimatedInputTokens -gt $safeLimit) {
        Write-Host "    [WARN] ${Phase}: Estimated input ~$($estimatedInputTokens)t approaching context limit ($safeLimit). Risk of token_limit error." -ForegroundColor Red
        if ($estimatedInputTokens -gt $contextWindow) {
            Write-Host "    [ERROR] ${Phase}: Input ($estimatedInputTokens tokens est.) EXCEEDS context window ($contextWindow). Aborting call." -ForegroundColor Red
            return @{
                Success = $false
                Error   = "input_too_large"
                Message = "${Phase}: Estimated input tokens ($estimatedInputTokens) exceed context window ($contextWindow). Reduce input payload."
                Phase   = $Phase
                Usage   = @{ input_tokens = 0; output_tokens = 0 }
            }
        }
    }

    $url = "$($script:ApiConfig.Anthropic.BaseUrl)/v1/messages"

    # Retry loop
    $attempt = 0
    $maxRetries = $script:ApiConfig.Anthropic.MaxRetries

    while ($attempt -le $maxRetries) {
        $attempt++
        try {
            # Hard timeout via polling loop -- Wait-Job -Timeout is unreliable on Windows
            $hardTimeout = if ($script:ApiConfig.Anthropic.TimeoutSec) { $script:ApiConfig.Anthropic.TimeoutSec } else { 120 }
            Write-Host "    [DEBUG] ${Phase}: Attempt $attempt/$($maxRetries+1) - Starting API job (timeout: ${hardTimeout}s)..." -ForegroundColor Magenta
            $job = Start-Job -ScriptBlock {
                param($u, $h, $b, $t)
                try {
                    Invoke-RestMethod -Uri $u -Method Post -Headers $h -Body ([System.Text.Encoding]::UTF8.GetBytes($b)) -TimeoutSec $t -ContentType "application/json; charset=utf-8"
                } catch {
                    # Capture response body for better error reporting
                    $errBody = ""
                    try {
                        if ($_.Exception.Response) {
                            $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                            $errBody = $reader.ReadToEnd()
                            $reader.Close()
                        }
                    } catch {}
                    throw "$($_.Exception.Message) |BODY| $errBody"
                }
            } -ArgumentList $url, $headers, $bodyJson, $hardTimeout
            $deadline = (Get-Date).AddSeconds($hardTimeout + 30)
            while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            if ($job.State -eq 'Running') {
                # Kill child processes then the job
                try { $jobPid = $job.ChildJobs[0].Process.Id; if ($jobPid) { Stop-Process -Id $jobPid -Force -EA SilentlyContinue } } catch {}
                $job | Stop-Job -PassThru | Remove-Job -Force
                throw [System.TimeoutException]::new("Anthropic API call exceeded hard timeout of $($hardTimeout + 30)s")
            }
            Write-Host "    [DEBUG] ${Phase}: Job completed (state: $($job.State)). Receiving output..." -ForegroundColor Magenta
            try {
                $response = $job | Receive-Job
            } finally {
                if ($job) { $job | Remove-Job -Force -EA SilentlyContinue }
                $job = $null
            }
            Write-Host "    [DEBUG] ${Phase}: API response received." -ForegroundColor Magenta

            # Extract text content (avoid string += O(n²) allocation)
            $textParts = [System.Collections.ArrayList]::new()
            foreach ($content in $response.content) {
                if ($content.type -eq "text") {
                    [void]$textParts.Add($content.text)
                }
            }
            $outputText = $textParts -join ""
            $textParts = $null

            # Extract usage for cost tracking
            $usage = @{
                input_tokens          = $response.usage.input_tokens
                output_tokens         = $response.usage.output_tokens
                cache_creation_tokens = if ($response.usage.cache_creation_input_tokens) { $response.usage.cache_creation_input_tokens } else { 0 }
                cache_read_tokens     = if ($response.usage.cache_read_input_tokens) { $response.usage.cache_read_input_tokens } else { 0 }
            }

            # Check stop_reason -- if "max_tokens", output was truncated (likely broken JSON)
            $stopReason = $response.stop_reason
            if ($stopReason -eq "max_tokens") {
                Write-Host "    [WARN] ${Phase}: Output truncated (max_tokens). Increase MaxTokens or reduce input." -ForegroundColor Yellow
            }

            # Parse JSON if requested
            $parsed = $null
            if ($JsonMode -and $outputText) {
                try {
                    $jsonText = $outputText.Trim()
                    # Strip markdown code fences if present
                    if ($jsonText.StartsWith('```')) {
                        $firstNl = $jsonText.IndexOf("`n")
                        if ($firstNl -gt 0) {
                            $jsonText = $jsonText.Substring($firstNl + 1)
                        }
                        # Remove trailing fence
                        $lastFence = $jsonText.LastIndexOf('```')
                        if ($lastFence -gt 0) {
                            $jsonText = $jsonText.Substring(0, $lastFence)
                        }
                        $jsonText = $jsonText.Trim()
                    }
                    $parsed = $jsonText | ConvertFrom-Json
                }
                catch {
                    Write-Host "    [ERROR] JSON parse failed for ${Phase}: $($_.Exception.Message)" -ForegroundColor Red
                    if ($stopReason -eq "max_tokens") {
                        Write-Host "    [ERROR] This is likely because output was truncated (stop_reason=max_tokens)" -ForegroundColor Red
                    }
                    # Return failure instead of silently passing null downstream
                    return @{
                        Success    = $false
                        Error      = "json_parse_failed"
                        Message    = "JSON parse failed for ${Phase}: $($_.Exception.Message)"
                        Text       = $outputText
                        Parsed     = $null
                        Usage      = $usage
                        Model      = $modelId
                        Phase      = $Phase
                        StopReason = $stopReason
                    }
                }
            }

            $response = $null  # Free large response object
            return @{
                Success    = $true
                Text       = $outputText
                Parsed     = $parsed
                Usage      = $usage
                Model      = $modelId
                Phase      = $Phase
                StopReason = $stopReason
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

                $errDetail = if ($statusCode) { "HTTP $statusCode" } else { $_.Exception.Message.Substring(0, [Math]::Min(100, $_.Exception.Message.Length)) }
                Write-Host "    [RETRY] Sonnet API error ($errDetail), attempt $attempt/$maxRetries, waiting ${backoff}s..." -ForegroundColor DarkYellow
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

    $body = ConvertTo-CleanJson -InputObject @{
        requests = $Requests
    } -Depth 5 -Compress

    $headers = @{
        "x-api-key"         = $apiKey
        "anthropic-version" = $script:ApiConfig.Anthropic.ApiVersion
        "content-type"      = "application/json"
        "anthropic-beta"    = "message-batches-2024-09-24,prompt-caching-2024-07-31"
    }

    try {
        $response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30 -ContentType "application/json; charset=utf-8"

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

            Write-Host "    [BATCH] ${Phase}: $($response.processing_status) ($([math]::Round($elapsed/60,1))m elapsed)" -ForegroundColor DarkGray
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

        # Validate per-request success rates
        $totalResults = $results.Count
        $failedResults = @($results.Values | Where-Object { -not $_.Success }).Count
        $failPct = if ($totalResults -gt 0) { [math]::Round(($failedResults / $totalResults) * 100, 1) } else { 0 }

        if ($failedResults -gt 0) {
            Write-Host "    [BATCH] Results: $($totalResults - $failedResults)/$totalResults succeeded ($failPct% failed)" -ForegroundColor $(
                if ($failPct -gt 10) { "Red" } else { "Yellow" }
            )
        }

        return @{
            Success       = ($failPct -le 50)  # Fail batch if >50% of requests failed
            Results       = $results
            TotalResults  = $totalResults
            FailedCount   = $failedResults
            FailPercent   = $failPct
        }
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
        Call GPT-5.1 Codex Mini via OpenAI Responses API (/v1/responses).
        Note: Codex models only support the Responses API, NOT Chat Completions.
    .PARAMETER SystemPrompt
        System prompt with coding conventions (sent as 'instructions').
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

    # Build Responses API body
    $bodyObj = @{
        model             = $modelId
        input             = @(
            @{ role = "user"; content = $UserMessage }
        )
        max_output_tokens = $MaxTokens
    }

    # System prompt goes in 'instructions' field for Responses API
    if ($SystemPrompt) {
        $bodyObj["instructions"] = "$SystemPrompt"
    }

    $body = ConvertTo-CleanJson -InputObject $bodyObj -Depth 5 -Compress

    $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    }

    # Responses API endpoint (NOT chat/completions)
    $url = "$($script:ApiConfig.OpenAI.BaseUrl)/responses"

    # Inter-call delay to avoid rate limits
    $interCallDelay = if ($script:ApiConfig.OpenAI.InterCallDelaySec) { $script:ApiConfig.OpenAI.InterCallDelaySec } else { 0 }
    if ($interCallDelay -gt 0) { Start-Sleep -Seconds $interCallDelay }

    # Retry loop
    $attempt = 0
    $maxRetries = $script:ApiConfig.OpenAI.MaxRetries

    while ($attempt -le $maxRetries) {
        $attempt++
        try {
            # Hard timeout via polling loop -- Wait-Job -Timeout is unreliable on Windows
            $hardTimeout = if ($script:ApiConfig.OpenAI.TimeoutSec) { $script:ApiConfig.OpenAI.TimeoutSec } else { 120 }
            $job = Start-Job -ScriptBlock {
                param($u, $h, $b, $t)
                Invoke-RestMethod -Uri $u -Method Post -Headers $h -Body $b -TimeoutSec $t -ContentType "application/json"
            } -ArgumentList $url, $headers, $body, $hardTimeout
            $deadline = (Get-Date).AddSeconds($hardTimeout + 30)
            while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            if ($job.State -eq 'Running') {
                try { $jobPid = $job.ChildJobs[0].Process.Id; if ($jobPid) { Stop-Process -Id $jobPid -Force -EA SilentlyContinue } } catch {}
                $job | Stop-Job -PassThru | Remove-Job -Force
                throw [System.TimeoutException]::new("Codex Mini API call exceeded hard timeout of $($hardTimeout + 30)s")
            }
            try {
                $response = $job | Receive-Job
            } finally {
                if ($job) { $job | Remove-Job -Force -EA SilentlyContinue }
                $job = $null
            }

            # Extract text from Responses API output structure (avoid string += O(n²) allocation)
            $textParts = [System.Collections.ArrayList]::new()
            foreach ($outputItem in $response.output) {
                if ($outputItem.type -eq "message" -and $outputItem.content) {
                    foreach ($contentItem in $outputItem.content) {
                        if ($contentItem.type -eq "output_text") {
                            [void]$textParts.Add($contentItem.text)
                        }
                    }
                }
            }
            $outputText = $textParts -join ""
            $textParts = $null

            $usage = @{
                input_tokens  = $response.usage.input_tokens
                output_tokens = $response.usage.output_tokens
            }

            # Determine finish reason from response status
            $finishReason = if ($response.status -eq "completed") { "stop" }
                elseif ($response.status -eq "incomplete" -and $response.incomplete_details) { "max_tokens" }
                else { $response.status }

            if ($finishReason -eq "max_tokens") {
                Write-Host "    [WARN] ${Phase}: Codex Mini output truncated (max_output_tokens)" -ForegroundColor Yellow
            }

            $response = $null  # Free large response object
            return @{
                Success      = $true
                Text         = $outputText
                Usage        = $usage
                Model        = $modelId
                Phase        = $Phase
                FinishReason = $finishReason
            }
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            # Non-retryable errors: 400, 401, 403, 404
            if ($statusCode -in @(400, 401, 403, 404)) {
                $errType = switch ($statusCode) {
                    401 { "auth_failed" }
                    403 { "forbidden" }
                    404 { "model_not_found" }
                    default { "bad_request" }
                }
                # Try to read error body for details
                $errMsg = $_.Exception.Message
                try {
                    if ($_.Exception.Response) {
                        $stream = $_.Exception.Response.GetResponseStream()
                        $reader = [System.IO.StreamReader]::new($stream)
                        $errBody = $reader.ReadToEnd()
                        if ($errBody) { $errMsg = $errBody }
                    }
                } catch {}
                return @{
                    Success = $false
                    Error   = $errType
                    Message = "Codex API ($statusCode): $errMsg"
                    Phase   = $Phase
                    Model   = $modelId
                    Usage   = @{ input_tokens = 0; output_tokens = 0 }
                }
            }

            # Capture error body for diagnosis (especially 429 rate limit details)
            $errBody = ""
            # Method 1: ErrorDetails.Message (PowerShell 7 preserves API error body here)
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errBody = $_.ErrorDetails.Message
            }
            # Method 2: GetResponseStream (fallback)
            if (-not $errBody) {
                try {
                    if ($_.Exception.Response) {
                        $stream = $_.Exception.Response.GetResponseStream()
                        $reader = [System.IO.StreamReader]::new($stream)
                        $errBody = $reader.ReadToEnd()
                    }
                } catch {}
            }

            if ($attempt -le $maxRetries) {
                $backoff = $script:ApiConfig.OpenAI.RetryBackoff[$attempt - 1]

                # Respect retry-after header from OpenAI (429 responses)
                if ($statusCode -eq 429 -and $_.Exception.Response.Headers) {
                    $retryAfter = $_.Exception.Response.Headers["retry-after"]
                    if ($retryAfter) { $backoff = [math]::Max([int]$retryAfter, $backoff) }
                }

                $errDetail = if ($errBody) { $errBody.Substring(0, [Math]::Min(200, $errBody.Length)) } else { $_.Exception.Message.Substring(0, [Math]::Min(100, $_.Exception.Message.Length)) }
                Write-Host "    [RETRY] Codex API error ($statusCode), attempt $attempt/$maxRetries, waiting ${backoff}s..." -ForegroundColor DarkYellow
                Write-Host "    [DETAIL] $errDetail" -ForegroundColor DarkGray
                Start-Sleep -Seconds $backoff
                continue
            }

            # --- FALLBACK CHAIN: Codex Mini -> DeepSeek -> Kimi -> MiniMax ---
            $fallbackModels = @("DeepSeek", "Kimi", "MiniMax")
            foreach ($fbName in $fallbackModels) {
                $fbConfig = $script:ApiConfig[$fbName]
                if (-not $fbConfig) { continue }
                $fbKey = [System.Environment]::GetEnvironmentVariable($fbConfig.ApiKeyEnv, "User")
                if (-not $fbKey) { $fbKey = [System.Environment]::GetEnvironmentVariable($fbConfig.ApiKeyEnv, "Process") }
                if (-not $fbKey) { continue }
                Write-Host "    [FALLBACK] Codex Mini failed ($statusCode). Trying $fbName..." -ForegroundColor Cyan
                $fallbackResult = Invoke-OpenAICompatFallback -Config $fbConfig -ApiKey $fbKey -SystemPrompt $SystemPrompt -UserMessage $UserMessage -MaxTokens $MaxTokens -Phase $Phase -ModelName $fbName
                if ($fallbackResult.Success) { return $fallbackResult }
                Write-Host "    [FALLBACK] $fbName failed: $($fallbackResult.Message)" -ForegroundColor Red
            }

            return @{
                Success = $false
                Error   = "api_error"
                Message = "Codex API failed after $maxRetries retries: $($_.Exception.Message)"
                Phase   = $Phase
                Model   = $modelId
                Usage   = @{ input_tokens = 0; output_tokens = 0 }
            }
        }
    }
}

function Invoke-OpenAICompatFallback {
    <#
    .SYNOPSIS
        Generic OpenAI-compatible chat/completions fallback for any model (DeepSeek, Kimi, MiniMax).
    #>
    param(
        [hashtable]$Config,
        [string]$ApiKey,
        [string]$SystemPrompt,
        [string]$UserMessage,
        [int]$MaxTokens = 16384,
        [string]$Phase = "execute",
        [string]$ModelName = "fallback"
    )

    $modelId = $Config.Model
    $url = "$($Config.BaseUrl)/chat/completions"
    $headers = @{ "Authorization" = "Bearer $ApiKey"; "Content-Type" = "application/json" }

    $messages = @()
    if ($SystemPrompt) { $messages += @{ role = "system"; content = "$SystemPrompt" } }
    $messages += @{ role = "user"; content = "$UserMessage" }

    # Respect per-model max output token limits
    $effectiveMaxTokens = $MaxTokens
    if ($Config.MaxOutputTokens -and $MaxTokens -gt $Config.MaxOutputTokens) {
        $effectiveMaxTokens = $Config.MaxOutputTokens
    }

    $body = ConvertTo-CleanJson -InputObject @{
        model      = $modelId
        messages   = $messages
        max_tokens = $effectiveMaxTokens
    } -Depth 5 -Compress

    $maxRetries = $Config.MaxRetries
    for ($attempt = 1; $attempt -le ($maxRetries + 1); $attempt++) {
        try {
            # Hard timeout via background job
            $hardTimeout = if ($Config.TimeoutSec) { $Config.TimeoutSec } else { 120 }
            $job = Start-Job -ScriptBlock {
                param($u, $h, $b, $t)
                Invoke-RestMethod -Uri $u -Method Post -Headers $h -Body $b -TimeoutSec $t -ContentType "application/json"
            } -ArgumentList $url, $headers, $body, $hardTimeout
            $deadline = (Get-Date).AddSeconds($hardTimeout + 30)
            while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            if ($job.State -eq 'Running') {
                try { $jobPid = $job.ChildJobs[0].Process.Id; if ($jobPid) { Stop-Process -Id $jobPid -Force -EA SilentlyContinue } } catch {}
                $job | Stop-Job -PassThru | Remove-Job -Force
                throw [System.TimeoutException]::new("$ModelName API call exceeded hard timeout of $($hardTimeout + 30)s")
            }
            try {
                $response = $job | Receive-Job
            } finally {
                if ($job) { $job | Remove-Job -Force -EA SilentlyContinue }
                $job = $null
            }

            $outputText = $response.choices[0].message.content
            $usage = @{
                input_tokens  = $response.usage.prompt_tokens
                output_tokens = $response.usage.completion_tokens
            }
            $response = $null  # Free large response object

            Write-Host "    [FALLBACK] $ModelName success ($($usage.output_tokens) tokens)" -ForegroundColor Green

            return @{
                Success    = $true
                Text       = $outputText
                Parsed     = $null
                Usage      = $usage
                Model      = $modelId
                Phase      = "$Phase-$($ModelName.ToLower())-fallback"
                StopReason = $response.choices[0].finish_reason
            }
        }
        catch {
            if ($attempt -le $maxRetries) {
                $backoff = $Config.RetryBackoff[$attempt - 1]
                Write-Host "    [FALLBACK] $ModelName error, attempt $attempt/$maxRetries, waiting ${backoff}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $backoff
                continue
            }
            return @{
                Success = $false
                Error   = "api_error"
                Message = "$ModelName failed after $maxRetries retries: $($_.Exception.Message)"
                Phase   = "$Phase-$($ModelName.ToLower())-fallback"
                Model   = $modelId
                Usage   = @{ input_tokens = 0; output_tokens = 0 }
            }
        }
    }
}

# ============================================================
# GEMINI API (Google Generative Language API)
# ============================================================

function Invoke-GeminiApi {
    <#
    .SYNOPSIS
        Call Gemini via Google Generative Language API.
    .PARAMETER SystemPrompt
        System prompt text (sent as systemInstruction).
    .PARAMETER UserMessage
        User message content.
    .PARAMETER MaxTokens
        Maximum output tokens.
    .PARAMETER Phase
        Phase name for cost tracking.
    .PARAMETER JsonMode
        Force JSON output (responseMimeType: application/json).
    #>
    param(
        [string]$SystemPrompt,
        [string]$UserMessage,
        [int]$MaxTokens = 16384,
        [string]$Phase = "execute",
        [switch]$JsonMode
    )

    $geminiConfig = $script:ApiConfig.Gemini
    $apiKey = [System.Environment]::GetEnvironmentVariable($geminiConfig.ApiKeyEnv, "User")
    if (-not $apiKey) { $apiKey = [System.Environment]::GetEnvironmentVariable($geminiConfig.ApiKeyEnv, "Process") }
    if (-not $apiKey) { $apiKey = [System.Environment]::GetEnvironmentVariable($geminiConfig.ApiKeyEnv, "Machine") }
    if (-not $apiKey) {
        return @{
            Success = $false
            Error   = "missing_api_key"
            Message = "Gemini API key not found: Set $($geminiConfig.ApiKeyEnv) environment variable."
            Phase   = $Phase
            Usage   = @{ input_tokens = 0; output_tokens = 0 }
        }
    }

    $modelId = $geminiConfig.Model
    $url = "$($geminiConfig.BaseUrl)/models/${modelId}:generateContent?key=$apiKey"

    # Build request body
    $bodyObj = @{
        contents = @(
            @{
                role  = "user"
                parts = @( @{ text = "$UserMessage" } )
            }
        )
        generationConfig = @{
            maxOutputTokens = $MaxTokens
        }
    }

    if ($SystemPrompt) {
        $bodyObj["systemInstruction"] = @{
            parts = @( @{ text = "$SystemPrompt" } )
        }
    }

    if ($JsonMode) {
        $bodyObj.generationConfig["responseMimeType"] = "application/json"
    }

    $body = ConvertTo-CleanJson -InputObject $bodyObj -Depth 6 -Compress

    $headers = @{
        "Content-Type" = "application/json"
    }

    # Retry loop
    $attempt = 0
    $maxRetries = $geminiConfig.MaxRetries

    while ($attempt -le $maxRetries) {
        $attempt++
        try {
            $hardTimeout = if ($geminiConfig.TimeoutSec) { $geminiConfig.TimeoutSec } else { 300 }
            Write-Host "    [DEBUG] ${Phase}: Gemini attempt $attempt/$($maxRetries+1) (timeout: ${hardTimeout}s)..." -ForegroundColor Magenta
            $job = Start-Job -ScriptBlock {
                param($u, $h, $b, $t)
                try {
                    Invoke-RestMethod -Uri $u -Method Post -Headers $h -Body ([System.Text.Encoding]::UTF8.GetBytes($b)) -TimeoutSec $t -ContentType "application/json; charset=utf-8"
                } catch {
                    $errBody = ""
                    try {
                        if ($_.Exception.Response) {
                            $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                            $errBody = $reader.ReadToEnd()
                            $reader.Close()
                        }
                    } catch {}
                    throw "$($_.Exception.Message) |BODY| $errBody"
                }
            } -ArgumentList $url, $headers, $body, $hardTimeout
            $deadline = (Get-Date).AddSeconds($hardTimeout + 30)
            while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            if ($job.State -eq 'Running') {
                try { $jobPid = $job.ChildJobs[0].Process.Id; if ($jobPid) { Stop-Process -Id $jobPid -Force -EA SilentlyContinue } } catch {}
                $job | Stop-Job -PassThru | Remove-Job -Force
                throw [System.TimeoutException]::new("Gemini API call exceeded hard timeout of $($hardTimeout + 30)s")
            }
            try {
                $response = $job | Receive-Job
            } finally {
                if ($job) { $job | Remove-Job -Force -EA SilentlyContinue }
                $job = $null
            }

            # Extract text from Gemini response: candidates[0].content.parts[0].text
            $outputText = ""
            if ($response.candidates -and $response.candidates.Count -gt 0) {
                $candidate = $response.candidates[0]
                if ($candidate.content -and $candidate.content.parts) {
                    foreach ($part in $candidate.content.parts) {
                        if ($part.text) { $outputText += $part.text }
                    }
                }
            }

            # Extract usage from usageMetadata
            $usage = @{
                input_tokens  = if ($response.usageMetadata.promptTokenCount) { $response.usageMetadata.promptTokenCount } else { 0 }
                output_tokens = if ($response.usageMetadata.candidatesTokenCount) { $response.usageMetadata.candidatesTokenCount } else { 0 }
            }

            # Check finish reason
            $finishReason = if ($response.candidates -and $response.candidates[0].finishReason) { $response.candidates[0].finishReason } else { "STOP" }
            if ($finishReason -eq "MAX_TOKENS") {
                Write-Host "    [WARN] ${Phase}: Gemini output truncated (MAX_TOKENS)" -ForegroundColor Yellow
            }

            Write-Host "    [GEMINI] $Phase success ($($usage.output_tokens) tokens)" -ForegroundColor Green
            $response = $null  # Free large response object

            return @{
                Success      = $true
                Text         = $outputText
                Parsed       = $null
                Usage        = $usage
                Model        = $modelId
                Phase        = $Phase
                StopReason   = $finishReason
            }
        }
        catch {
            if ($attempt -le $maxRetries) {
                $backoff = $geminiConfig.RetryBackoff[$attempt - 1]
                $errDetail = $_.Exception.Message.Substring(0, [Math]::Min(150, $_.Exception.Message.Length))
                Write-Host "    [RETRY] Gemini API error ($errDetail), attempt $attempt/$maxRetries, waiting ${backoff}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $backoff
                continue
            }

            return @{
                Success = $false
                Error   = "api_error"
                Message = "Gemini API failed after $maxRetries retries: $($_.Exception.Message)"
                Phase   = $Phase
                Model   = $modelId
                Usage   = @{ input_tokens = 0; output_tokens = 0 }
            }
        }
    }
}

# ============================================================
# 7-MODEL ROUND-ROBIN DISPATCHER
# ============================================================

$script:RoundRobinIndex = 0

function Get-NextExecuteModel {
    <#
    .SYNOPSIS
        Returns the next model from the weighted round-robin pool for execute phase.
        Models with higher weight get more consecutive slots.
    .DESCRIPTION
        Weighted pool:
          codex-mini: 3 slots, deepseek: 2 slots, kimi: 1, minimax: 1,
          claude-sonnet: 1, gemini: 1, glm5: 1
        Only includes models whose API key is available.
    .OUTPUTS
        Hashtable with Name, Config, and ApiKey (or $null if no models available).
    #>

    # Define weighted model pool (model name -> weight)
    $weightedPool = [ordered]@{
        "codex-mini"     = 3
        "deepseek"       = 2
        "kimi"           = 1
        "minimax"        = 1
        "claude-sonnet"  = 1
        "gemini"         = 1
        "glm5"           = 1
    }

    # Map model names to API key env vars
    $keyMap = @{
        "codex-mini"    = "OPENAI_API_KEY"
        "deepseek"      = "DEEPSEEK_API_KEY"
        "kimi"          = "KIMI_API_KEY"
        "minimax"       = "MINIMAX_API_KEY"
        "claude-sonnet" = "ANTHROPIC_API_KEY"
        "gemini"        = "GEMINI_API_KEY"
        "glm5"          = "GLM_API_KEY"
    }

    # Build expanded slot array (only models with valid API keys)
    $slots = [System.Collections.ArrayList]::new()
    foreach ($modelName in $weightedPool.Keys) {
        $envVar = $keyMap[$modelName]
        $key = [System.Environment]::GetEnvironmentVariable($envVar, "User")
        if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable($envVar, "Process") }
        if (-not $key) { $key = [System.Environment]::GetEnvironmentVariable($envVar, "Machine") }
        if (-not $key) {
            Write-Host "    [DISPATCH] Skipping $modelName (no $envVar)" -ForegroundColor DarkGray
            continue
        }

        $weight = $weightedPool[$modelName]
        for ($w = 0; $w -lt $weight; $w++) {
            [void]$slots.Add(@{ Name = $modelName; ApiKey = $key })
        }
    }

    if ($slots.Count -eq 0) {
        Write-Host "    [DISPATCH] No execute models available (no API keys set)" -ForegroundColor Red
        return $null
    }

    # Pick next slot using round-robin counter
    $idx = $script:RoundRobinIndex % $slots.Count
    $script:RoundRobinIndex++
    $selected = $slots[$idx]

    Write-Host "    [DISPATCH] Round-robin -> $($selected.Name) (slot $($idx+1)/$($slots.Count))" -ForegroundColor Cyan

    return $selected
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
        [int]$MaxConcurrent = 2,
        [int]$MaxTokens = 16384,
        [string]$Phase = "execute"
    )

    $results = @{}
    $totalUsage = @{ input_tokens = 0; output_tokens = 0 }
    $consecutive429 = 0
    $circuitBroken = $false

    # Process in batches of MaxConcurrent
    for ($i = 0; $i -lt $Items.Count; $i += $MaxConcurrent) {
        if ($circuitBroken) { break }

        $batch = $Items[$i..([math]::Min($i + $MaxConcurrent - 1, $Items.Count - 1))]

        # Execute sequentially within batch (PowerShell 5.1 compatible)
        # For true parallelism, use runspaces or ForEach-Object -Parallel (PS 7+)
        foreach ($idx in 0..($batch.Count - 1)) {
            $item = $batch[$idx]

            # Circuit breaker: if 3+ consecutive 429s, wait 60s then retry one more; if still 429, abort all remaining
            if ($consecutive429 -ge 3) {
                Write-Host "    [RATE-LIMIT] $consecutive429 consecutive 429 errors. Waiting 60s before retry..." -ForegroundColor Red
                Start-Sleep -Seconds 60
                $consecutive429 = 0  # Reset counter, give it one more shot
            }

            # Route to appropriate model based on item.Model flag
            $result = $null
            if ($item.Model -eq "deepseek-fallback") {
                # Truncation-escalated req: use DeepSeek (larger output window than Codex Mini)
                $dsConfig = $script:ApiConfig.DeepSeek
                $dsKey = [System.Environment]::GetEnvironmentVariable($dsConfig.ApiKeyEnv, "User")
                if (-not $dsKey) { $dsKey = [System.Environment]::GetEnvironmentVariable($dsConfig.ApiKeyEnv, "Process") }
                if ($dsKey) {
                    Write-Host "    [ROUTE] $($item.Id) -> DeepSeek (truncation escalation)" -ForegroundColor Cyan
                    $result = Invoke-OpenAICompatFallback -Config $dsConfig -ApiKey $dsKey `
                        -SystemPrompt $item.SystemPrompt -UserMessage $item.UserMessage `
                        -MaxTokens $MaxTokens -Phase $Phase -ModelName "DeepSeek"
                }
            }
            elseif ($item.Model -eq "claude-fallback") {
                # Truncation-escalated req: use Claude Sonnet (200K context, large output)
                Write-Host "    [ROUTE] $($item.Id) -> Claude Sonnet (truncation escalation)" -ForegroundColor Cyan
                $result = Invoke-SonnetApi -SystemPrompt $item.SystemPrompt `
                    -UserMessage $item.UserMessage -MaxTokens $MaxTokens -Phase "$Phase-claude-escalation"
            }
            elseif ($item.Model -eq "gemini") {
                # Route to Gemini API
                Write-Host "    [ROUTE] $($item.Id) -> Gemini (round-robin)" -ForegroundColor Cyan
                $result = Invoke-GeminiApi -SystemPrompt $item.SystemPrompt `
                    -UserMessage $item.UserMessage -MaxTokens $MaxTokens -Phase "$Phase-gemini"
            }
            elseif ($item.Model -eq "glm5") {
                # Route to GLM5 via OpenAI-compatible fallback
                $glmConfig = $script:ApiConfig.GLM5
                $glmKey = [System.Environment]::GetEnvironmentVariable($glmConfig.ApiKeyEnv, "User")
                if (-not $glmKey) { $glmKey = [System.Environment]::GetEnvironmentVariable($glmConfig.ApiKeyEnv, "Process") }
                if (-not $glmKey) { $glmKey = [System.Environment]::GetEnvironmentVariable($glmConfig.ApiKeyEnv, "Machine") }
                if ($glmKey) {
                    Write-Host "    [ROUTE] $($item.Id) -> GLM5 (round-robin)" -ForegroundColor Cyan
                    $result = Invoke-OpenAICompatFallback -Config $glmConfig -ApiKey $glmKey `
                        -SystemPrompt $item.SystemPrompt -UserMessage $item.UserMessage `
                        -MaxTokens $MaxTokens -Phase "$Phase-glm5" -ModelName "GLM5"
                } else {
                    Write-Host "    [ROUTE] $($item.Id) -> GLM5 skipped (no GLM_API_KEY), falling back to Codex Mini" -ForegroundColor DarkYellow
                }
            }
            elseif ($item.Model -eq "claude-sonnet") {
                # Route to Claude Sonnet (round-robin execute slot)
                Write-Host "    [ROUTE] $($item.Id) -> Claude Sonnet (round-robin)" -ForegroundColor Cyan
                $result = Invoke-SonnetApi -SystemPrompt $item.SystemPrompt `
                    -UserMessage $item.UserMessage -MaxTokens $MaxTokens -Phase "$Phase-claude-execute"
            }

            # Default: use Codex Mini
            if (-not $result) {
                $result = Invoke-CodexMiniApi `
                    -SystemPrompt $item.SystemPrompt `
                    -UserMessage $item.UserMessage `
                    -MaxTokens $MaxTokens `
                    -Phase $Phase `
                    -Model $item.Model
            }

            $results[$item.Id] = $result

            if ($result.Success) {
                $consecutive429 = 0  # Reset on success
            }
            elseif ($result.Error -eq "api_error" -and $result.Message -match "429") {
                $consecutive429++
                if ($consecutive429 -ge 6) {
                    Write-Host "    [CIRCUIT-BREAK] 6 consecutive 429 errors. Aborting remaining $($Items.Count - $results.Count) items." -ForegroundColor Red
                    $circuitBroken = $true
                    break
                }
            }
            elseif ($result.Error -eq "model_not_found") {
                Write-Host "    [ABORT] Model not found. Aborting all remaining items." -ForegroundColor Red
                $circuitBroken = $true
                break
            }
            else {
                $consecutive429 = 0  # Non-429 error resets the counter
            }

            if ($result.Usage) {
                $totalUsage.input_tokens += $result.Usage.input_tokens
                $totalUsage.output_tokens += $result.Usage.output_tokens
            }

            $status = if ($result.Success) { "OK" } else { "FAIL" }
            $tokenCount = if ($result.Usage) { $result.Usage.output_tokens } else { 0 }
            Write-Host "    [$status] $($item.Id) ($tokenCount tokens)" -ForegroundColor $(if ($result.Success) { "Green" } else { "Red" })
        }
    }

    return @{
        Results    = $results
        TotalUsage = $totalUsage
        Completed  = @($results.Values | Where-Object { $_.Success }).Count
        Failed     = @($results.Values | Where-Object { -not $_.Success }).Count
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
    # Cache TTL: 4 hours (pipeline runs can take hours; 5-min TTL caused constant rewrites)
    return ($elapsed.TotalMinutes -lt 240)
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
