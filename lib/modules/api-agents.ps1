# ===============================================================
# GSD API Agents - Direct REST API invocation for non-CLI models
# Provides Invoke-ApiAgent for deepseek, zhipu/glm, minimax, kimi
# ===============================================================

function Invoke-ApiAgent {
    <#
    .SYNOPSIS
        Calls a non-CLI LLM via REST API. Returns the same structure as CLI agents.
    .PARAMETER Agent
        Agent name: "deepseek", "glm5", "minimax", or "kimi"
    .PARAMETER Prompt
        The prompt text to send
    .PARAMETER TimeoutSec
        Max seconds to wait for response (default: 600)
    #>
    param(
        [string]$Agent,
        [string]$Prompt,
        [int]$TimeoutSec = 600
    )

    $result = @{
        Success = $false
        Output = $null
        RawOutput = $null
        Error = $null
        TokenData = $null
    }

    switch ($Agent) {
        "deepseek" {
            $apiKey = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
            if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "Process") }
            if (-not $apiKey) {
                $result.Error = "DEEPSEEK_API_KEY not set"
                return $result
            }
            $uri = "https://api.deepseek.com/chat/completions"
            $model = "deepseek-chat"
            $result = Invoke-ChatCompletionApi -Uri $uri -ApiKey $apiKey -Model $model -Prompt $Prompt -TimeoutSec $TimeoutSec -Agent $Agent
        }
        "glm5" {
            $apiKey = [Environment]::GetEnvironmentVariable("ZHIPU_API_KEY", "User")
            if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable("ZHIPU_API_KEY", "Process") }
            if (-not $apiKey) {
                $result.Error = "ZHIPU_API_KEY not set"
                return $result
            }
            $uri = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
            $model = "glm-4-plus"
            $result = Invoke-ChatCompletionApi -Uri $uri -ApiKey $apiKey -Model $model -Prompt $Prompt -TimeoutSec $TimeoutSec -Agent $Agent
        }
        "minimax" {
            $apiKey = [Environment]::GetEnvironmentVariable("MINIMAX_API_KEY", "User")
            if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable("MINIMAX_API_KEY", "Process") }
            if (-not $apiKey) {
                $result.Error = "MINIMAX_API_KEY not set"
                return $result
            }
            $uri = "https://api.minimax.chat/v1/text/chatcompletion_v2"
            $model = "MiniMax-Text-01"
            $result = Invoke-ChatCompletionApi -Uri $uri -ApiKey $apiKey -Model $model -Prompt $Prompt -TimeoutSec $TimeoutSec -Agent $Agent
        }
        "kimi" {
            $apiKey = [Environment]::GetEnvironmentVariable("MOONSHOT_API_KEY", "User")
            if (-not $apiKey) { $apiKey = [Environment]::GetEnvironmentVariable("MOONSHOT_API_KEY", "Process") }
            if (-not $apiKey) {
                $result.Error = "MOONSHOT_API_KEY not set"
                return $result
            }
            $uri = "https://api.moonshot.ai/v1/chat/completions"
            $model = "moonshot-v1-128k"
            $result = Invoke-ChatCompletionApi -Uri $uri -ApiKey $apiKey -Model $model -Prompt $Prompt -TimeoutSec $TimeoutSec -Agent $Agent
        }
        default {
            $result.Error = "Unknown API agent: $Agent"
        }
    }

    return $result
}

function Invoke-ChatCompletionApi {
    <#
    .SYNOPSIS
        Generic OpenAI-compatible chat completion call (works for DeepSeek, Zhipu, MiniMax, Kimi)
    #>
    param(
        [string]$Uri,
        [string]$ApiKey,
        [string]$Model,
        [string]$Prompt,
        [int]$TimeoutSec,
        [string]$Agent
    )

    $result = @{
        Success = $false
        Output = $null
        RawOutput = $null
        Error = $null
        TokenData = $null
    }

    $body = @{
        model = $Model
        messages = @(
            @{ role = "user"; content = $Prompt }
        )
        max_tokens = 8192
        temperature = 0.3
    } | ConvertTo-Json -Depth 5

    $headers = @{
        "Authorization" = "Bearer $ApiKey"
        "Content-Type"  = "application/json"
    }

    try {
        $callStart = Get-Date
        $response = Invoke-RestMethod -Uri $Uri -Method Post -Headers $headers -Body $body -TimeoutSec $TimeoutSec -ErrorAction Stop
        $callDuration = [int]((Get-Date) - $callStart).TotalSeconds

        $content = $response.choices[0].message.content
        $result.Success = $true
        $result.Output = $content -split "`n"
        $result.RawOutput = $content

        # Extract token usage if available
        $usage = $response.usage
        if ($usage) {
            $result.TokenData = @{
                Tokens = @{
                    input  = [int]($usage.prompt_tokens)
                    output = [int]($usage.completion_tokens)
                    cached = 0
                }
                CostUsd    = 0  # Will be calculated by Save-TokenUsage
                TextOutput = $content
                DurationMs = $callDuration * 1000
                NumTurns   = 1
                Estimated  = $false
            }
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        # Detect quota/rate limit errors
        if ($errMsg -match "429|rate.limit|too.many|quota|resource.exhausted") {
            $result.Error = "rate_limit"
        }
        elseif ($errMsg -match "401|403|unauthorized|invalid.*key|auth") {
            $result.Error = "auth_error"
        }
        elseif ($errMsg -match "timeout|timed.out") {
            $result.Error = "timeout"
        }
        else {
            $result.Error = "api_error: $errMsg"
        }

        # Try to read response body for more details
        if ($_.Exception.Response) {
            try {
                $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
                if ($responseBody -match "rate|limit|quota|exhausted") {
                    $result.Error = "rate_limit"
                }
            } catch { }
        }
    }

    return $result
}

function Test-ApiAgentAvailable {
    <#
    .SYNOPSIS
        Quick check if an API agent has its key configured
    #>
    param([string]$Agent)

    switch ($Agent) {
        "deepseek" {
            $k = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "User")
            if (-not $k) { $k = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY", "Process") }
            return [bool]$k
        }
        "glm5" {
            $k = [Environment]::GetEnvironmentVariable("ZHIPU_API_KEY", "User")
            if (-not $k) { $k = [Environment]::GetEnvironmentVariable("ZHIPU_API_KEY", "Process") }
            return [bool]$k
        }
        "minimax" {
            $k = [Environment]::GetEnvironmentVariable("MINIMAX_API_KEY", "User")
            if (-not $k) { $k = [Environment]::GetEnvironmentVariable("MINIMAX_API_KEY", "Process") }
            return [bool]$k
        }
        "kimi" {
            $k = [Environment]::GetEnvironmentVariable("MOONSHOT_API_KEY", "User")
            if (-not $k) { $k = [Environment]::GetEnvironmentVariable("MOONSHOT_API_KEY", "Process") }
            return [bool]$k
        }
        default { return $false }
    }
}

# List of all API-based agents
$script:API_AGENTS = @("deepseek", "glm5", "minimax", "kimi")

Write-Host "  API agents module loaded (deepseek, glm5, minimax, kimi)." -ForegroundColor DarkGray

