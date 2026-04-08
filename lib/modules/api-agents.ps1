# ===============================================================
# GSD API Agents - Direct REST API invocation for non-CLI models
# Provides Invoke-ApiAgent for deepseek, zhipu/glm, minimax, kimi
# ===============================================================

function Get-ApiAgentKey {
    param([string[]]$Names)

    foreach ($scope in @("Process", "User", "Machine")) {
        foreach ($name in $Names) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if ($value) { return $value }
        }
    }

    return $null
}

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
            $apiKey = Get-ApiAgentKey -Names @("DEEPSEEK_API_KEY")
            if (-not $apiKey) {
                $result.Error = "DEEPSEEK_API_KEY not set"
                return $result
            }
            $uri = "https://api.deepseek.com/chat/completions"
            $model = "deepseek-chat"
            $result = Invoke-ChatCompletionApi -Uri $uri -ApiKey $apiKey -Model $model -Prompt $Prompt -TimeoutSec $TimeoutSec -Agent $Agent
        }
        "glm5" {
            $apiKey = Get-ApiAgentKey -Names @("GLM_API_KEY", "ZHIPU_API_KEY")
            if (-not $apiKey) {
                $result.Error = "GLM_API_KEY not set"
                return $result
            }
            $uri = "https://api.z.ai/api/paas/v4/chat/completions"
            $model = "glm-5"
            $result = Invoke-ChatCompletionApi -Uri $uri -ApiKey $apiKey -Model $model -Prompt $Prompt -TimeoutSec $TimeoutSec -Agent $Agent
        }
        "minimax" {
            $apiKey = Get-ApiAgentKey -Names @("MINIMAX_API_KEY")
            if (-not $apiKey) {
                $result.Error = "MINIMAX_API_KEY not set"
                return $result
            }
            $uri = "https://api.minimax.io/v1/chat/completions"
            $model = "MiniMax-M2.5"
            $result = Invoke-ChatCompletionApi -Uri $uri -ApiKey $apiKey -Model $model -Prompt $Prompt -TimeoutSec $TimeoutSec -Agent $Agent
        }
        "kimi" {
            $apiKey = Get-ApiAgentKey -Names @("KIMI_API_KEY", "MOONSHOT_API_KEY")
            if (-not $apiKey) {
                $result.Error = "KIMI_API_KEY not set"
                return $result
            }
            $uri = "https://api.moonshot.ai/v1/chat/completions"
            $model = "kimi-k2.5"
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
            $k = Get-ApiAgentKey -Names @("DEEPSEEK_API_KEY")
            return [bool]$k
        }
        "glm5" {
            $k = Get-ApiAgentKey -Names @("GLM_API_KEY", "ZHIPU_API_KEY")
            return [bool]$k
        }
        "minimax" {
            $k = Get-ApiAgentKey -Names @("MINIMAX_API_KEY")
            return [bool]$k
        }
        "kimi" {
            $k = Get-ApiAgentKey -Names @("KIMI_API_KEY", "MOONSHOT_API_KEY")
            return [bool]$k
        }
        default { return $false }
    }
}

# List of all API-based agents
$script:API_AGENTS = @("deepseek", "glm5", "minimax", "kimi")

Write-Host "  API agents module loaded (deepseek, glm5, minimax, kimi)." -ForegroundColor DarkGray

