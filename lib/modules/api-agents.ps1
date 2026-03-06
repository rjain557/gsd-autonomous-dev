# ===============================================================
# GSD API Agents - Direct REST API invocation for non-CLI models
# Provides Invoke-ApiAgent for deepseek, zhipu/glm, minimax, kimi
# ===============================================================

# 10b: Module loading guard - prevent re-sourcing
if ($script:API_AGENTS_LOADED) { return }
$script:API_AGENTS_LOADED = $true

# 1a: Config hashtable replaces duplicated switch blocks
$script:API_CONFIG = @{
    deepseek = @{ EnvVar = "DEEPSEEK_API_KEY"; Uri = "https://api.deepseek.com/chat/completions"; Model = "deepseek-chat" }
    glm5     = @{ EnvVar = "ZHIPU_API_KEY";    Uri = "https://open.bigmodel.cn/api/paas/v4/chat/completions"; Model = "glm-4-plus" }
    minimax  = @{ EnvVar = "MINIMAX_API_KEY";   Uri = "https://api.minimax.chat/v1/text/chatcompletion_v2"; Model = "MiniMax-Text-01" }
    kimi     = @{ EnvVar = "MOONSHOT_API_KEY";  Uri = "https://api.moonshot.ai/v1/chat/completions"; Model = "moonshot-v1-128k" }
}

# 1b: Cached API key lookups - re-check only on miss
$script:API_KEY_CACHE = @{}

function Resolve-ApiKey {
    param([string]$EnvVar)
    if ($script:API_KEY_CACHE[$EnvVar]) { return $script:API_KEY_CACHE[$EnvVar] }
    $key = [Environment]::GetEnvironmentVariable($EnvVar, "User")
    if (-not $key) { $key = [Environment]::GetEnvironmentVariable($EnvVar, "Process") }
    if ($key) { $script:API_KEY_CACHE[$EnvVar] = $key }
    return $key
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

    $config = $script:API_CONFIG[$Agent]
    if (-not $config) {
        $result.Error = "Unknown API agent: $Agent"
        return $result
    }

    $apiKey = Resolve-ApiKey -EnvVar $config.EnvVar
    if (-not $apiKey) {
        $result.Error = "$($config.EnvVar) not set"
        return $result
    }

    $result = Invoke-ChatCompletionApi -Uri $config.Uri -ApiKey $apiKey -Model $config.Model -Prompt $Prompt -TimeoutSec $TimeoutSec -Agent $Agent
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

    # 1c: Add system message with model identity for provider optimizations
    $body = @{
        model = $Model
        messages = @(
            @{ role = "system"; content = "You are $Agent, an AI coding assistant integrated into the GSD autonomous development pipeline. Respond precisely and concisely." }
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

    $config = $script:API_CONFIG[$Agent]
    if (-not $config) { return $false }
    return [bool](Resolve-ApiKey -EnvVar $config.EnvVar)
}

# List of all API-based agents
$script:API_AGENTS = @("deepseek", "glm5", "minimax", "kimi")

Write-Host "  API agents module loaded (deepseek, glm5, minimax, kimi)." -ForegroundColor DarkGray
