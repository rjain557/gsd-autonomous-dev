# ===============================================================
# Step 04: Dependency Graph Builder
# Agent: Claude | Builds DAG + waves from requirements
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = ""
)

$stepId = "04-dependency-graph"
Write-Host "`n=== STEP 4: Dependency Graph Builder ===" -ForegroundColor Cyan

# Get total requirements count
$masterPath = Join-Path $GsdDir "requirements\requirements-master.json"
$totalReqs = 0
if (Test-Path $masterPath) {
    try {
        $master = Get-Content $masterPath -Raw | ConvertFrom-Json
        $totalReqs = $master.requirements.Count
    } catch {}
}

Write-Host "  Total requirements: $totalReqs" -ForegroundColor DarkGray

# Load and resolve prompt
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\04-dependency-graph.md"
$prompt = Get-Content $promptPath -Raw -Encoding UTF8
$prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
$prompt = $prompt.Replace("{{TOTAL_REQUIREMENTS}}", "$totalReqs")
$prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

# Get assigned agent
$agent = Get-StepAgent -StepId $stepId -AgentMap $AgentMap
Write-Host "  Agent: $agent" -ForegroundColor DarkGray

# Invoke
$result = Invoke-Agent -Agent $agent -Prompt $prompt -StepId $stepId `
    -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 15

if (-not $result.Success) {
    Write-Host "  [XX] Dependency graph failed: $($result.Error)" -ForegroundColor Red
    return @{ Success = $false; Error = $result.Error; StepId = $stepId }
}

# Validate outputs
$graphPath = Join-Path $GsdDir "requirements\dependency-graph.json"
$wavesPath = Join-Path $GsdDir "requirements\waves.json"

$graphOk = Test-Path $graphPath
$wavesOk = Test-Path $wavesPath

if ($graphOk -and $wavesOk) {
    try {
        $waves = Get-Content $wavesPath -Raw | ConvertFrom-Json
        $totalWaves = $waves.waves.Count
        $criticalPathLen = if ($waves.summary.critical_path_length) { $waves.summary.critical_path_length } else { $totalWaves }

        Write-Host "  Results: $totalWaves waves | Critical path: $criticalPathLen steps" -ForegroundColor Green
        Send-StepNotification -StepId $stepId -Status "complete" `
            -Details "$totalWaves waves, critical path $criticalPathLen"

        return @{
            Success = $true
            TotalWaves = $totalWaves
            CriticalPathLength = $criticalPathLen
            StepId = $stepId
        }
    }
    catch {
        Write-Host "  [WARN] Could not parse waves" -ForegroundColor DarkYellow
        return @{ Success = $true; StepId = $stepId }
    }
}
else {
    $missing = @()
    if (-not $graphOk) { $missing += "dependency-graph.json" }
    if (-not $wavesOk) { $missing += "waves.json" }
    Write-Host "  [XX] Missing outputs: $($missing -join ', ')" -ForegroundColor Red
    return @{ Success = $false; Error = "missing_outputs: $($missing -join ', ')"; StepId = $stepId }
}
