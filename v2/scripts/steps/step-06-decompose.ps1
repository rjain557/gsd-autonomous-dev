# ===============================================================
# Step 06: Requirement Decomposer
# Agent: Codex | Breaks oversize requirements into sub-requirements
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = "",
    [array]$OversizeRequirements = @()
)

$stepId = "06-requirement-decomposer"
Write-Host "`n=== STEP 6: Requirement Decomposer ===" -ForegroundColor Cyan

# Check if decomposition is needed
if ($OversizeRequirements.Count -eq 0) {
    # Check forecast file for oversize list
    $forecastPath = Join-Path $GsdDir "requirements\token-forecast.json"
    if (Test-Path $forecastPath) {
        try {
            $forecast = Get-Content $forecastPath -Raw | ConvertFrom-Json
            $OversizeRequirements = if ($forecast.oversize_requirements) { @($forecast.oversize_requirements) } else { @() }
        } catch {}
    }
}

if ($OversizeRequirements.Count -eq 0) {
    Write-Host "  No oversize requirements. Skipping decomposition." -ForegroundColor Green
    Send-StepNotification -StepId $stepId -Status "skipped" -Details "All requirements within token limits"
    return @{ Success = $true; Skipped = $true; StepId = $stepId }
}

Write-Host "  Oversize requirements: $($OversizeRequirements.Count)" -ForegroundColor DarkGray
Write-Host "  IDs: $($OversizeRequirements -join ', ')" -ForegroundColor DarkGray

# Build model limits string
$modelLimits = $Config.token_forecasting.model_limits | ConvertTo-Json -Compress

# Load and resolve prompt
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\06-requirement-decomposer.md"
$prompt = Get-Content $promptPath -Raw -Encoding UTF8
$prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
$prompt = $prompt.Replace("{{MODEL_LIMITS}}", $modelLimits)
$prompt = $prompt.Replace("{{OVERSIZE_REQUIREMENTS}}", ($OversizeRequirements -join ", "))
$prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

# Get assigned agent
$agent = Get-StepAgent -StepId $stepId -AgentMap $AgentMap
Write-Host "  Agent: $agent" -ForegroundColor DarkGray

# Invoke
$result = Invoke-Agent -Agent $agent -Prompt $prompt -StepId $stepId `
    -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 20

if (-not $result.Success) {
    Write-Host "  [XX] Decomposition failed: $($result.Error)" -ForegroundColor Red
    return @{ Success = $false; Error = $result.Error; StepId = $stepId }
}

# Validate updated master
$masterPath = Join-Path $GsdDir "requirements\requirements-master.json"
if (Test-Path $masterPath) {
    try {
        $master = Get-Content $masterPath -Raw | ConvertFrom-Json
        $decomposed = ($master.requirements | Where-Object { $_.status -eq "decomposed" }).Count
        $newSubs = ($master.requirements | Where-Object { $_.id -match '[a-z]$' }).Count
        $totalActive = ($master.requirements | Where-Object { $_.status -eq "active" }).Count

        Write-Host "  Results: $decomposed decomposed -> $newSubs sub-requirements | $totalActive active total" -ForegroundColor Green
        Send-StepNotification -StepId $stepId -Status "complete" `
            -Details "$decomposed decomposed into $newSubs subs, $totalActive active"

        return @{
            Success = $true
            Decomposed = $decomposed
            NewSubRequirements = $newSubs
            TotalActive = $totalActive
            StepId = $stepId
        }
    }
    catch {
        Write-Host "  [WARN] Could not validate decomposition" -ForegroundColor DarkYellow
        return @{ Success = $true; StepId = $stepId }
    }
}

return @{ Success = $true; StepId = $stepId }
