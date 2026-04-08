# ===============================================================
# Step 05: Token Forecaster
# Agent: Gemini | Estimates token usage per requirement per phase
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = ""
)

$stepId = "05-token-forecaster"
Write-Host "`n=== STEP 5: Token Forecaster ===" -ForegroundColor Cyan

# Build model limits string from config
$modelLimits = $Config.token_forecasting.model_limits | ConvertTo-Json -Compress

# Load and resolve prompt
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\05-token-forecaster.md"
$prompt = Get-Content $promptPath -Raw -Encoding UTF8
$prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
$prompt = $prompt.Replace("{{MODEL_LIMITS}}", $modelLimits)
$prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

# Get assigned agent
$agent = Get-StepAgent -StepId $stepId -AgentMap $AgentMap
Write-Host "  Agent: $agent" -ForegroundColor DarkGray

# Invoke
$result = Invoke-Agent -Agent $agent -Prompt $prompt -StepId $stepId `
    -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 15

if (-not $result.Success) {
    Write-Host "  [XX] Token forecasting failed: $($result.Error)" -ForegroundColor Red
    return @{ Success = $false; Error = $result.Error; StepId = $stepId }
}

# Validate output
$forecastPath = Join-Path $GsdDir "requirements\token-forecast.json"
if (Test-Path $forecastPath) {
    try {
        $forecast = Get-Content $forecastPath -Raw | ConvertFrom-Json
        $oversize = if ($forecast.oversize_requirements) { $forecast.oversize_requirements.Count } else { 0 }
        $withinLimits = if ($forecast.summary.within_limits) { $forecast.summary.within_limits } else { 0 }

        Write-Host "  Results: $withinLimits within limits | $oversize oversize" -ForegroundColor $(
            if ($oversize -gt 0) { "Yellow" } else { "Green" }
        )

        Send-StepNotification -StepId $stepId -Status "complete" `
            -Details "$withinLimits OK, $oversize need decomposition"

        return @{
            Success = $true
            WithinLimits = $withinLimits
            Oversize = $oversize
            OversizeIds = $forecast.oversize_requirements
            StepId = $stepId
        }
    }
    catch {
        Write-Host "  [WARN] Could not parse forecast" -ForegroundColor DarkYellow
        return @{ Success = $true; Oversize = 0; StepId = $stepId }
    }
}
else {
    Write-Host "  [WARN] No forecast file generated" -ForegroundColor DarkYellow
    return @{ Success = $true; Oversize = 0; StepId = $stepId }
}
