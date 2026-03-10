# ===============================================================
# Step 07a: Research (Wave-Parallel)
# Agents: ALL 7 round-robin | Per-requirement research in dependency waves
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = ""
)

$stepId = "07a-research"
Write-Host "`n=== STEP 7a: Research (Wave-Parallel) ===" -ForegroundColor Cyan

# Ensure output directory
$researchDir = Join-Path $GsdDir "research"
if (-not (Test-Path $researchDir)) { New-Item -ItemType Directory -Path $researchDir -Force | Out-Null }

# Load requirements and waves
$masterPath = Join-Path $GsdDir "requirements\requirements-master.json"
$wavesPath = Join-Path $GsdDir "requirements\waves.json"

if (-not (Test-Path $masterPath) -or -not (Test-Path $wavesPath)) {
    Write-Host "  [XX] Missing requirements-master.json or waves.json" -ForegroundColor Red
    return @{ Success = $false; Error = "missing_inputs"; StepId = $stepId }
}

$master = Get-Content $masterPath -Raw | ConvertFrom-Json
$wavesData = Get-Content $wavesPath -Raw | ConvertFrom-Json

# Filter to active requirements only
$activeReqs = $master.requirements | Where-Object { $_.status -eq "active" }
Write-Host "  Active requirements: $($activeReqs.Count)" -ForegroundColor DarkGray
Write-Host "  Waves: $($wavesData.waves.Count)" -ForegroundColor DarkGray

# Load prompt template
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\07a-research.md"
$promptTemplate = Get-Content $promptPath -Raw -Encoding UTF8

# Build prompt builder scriptblock
$promptBuilder = {
    param($req, $context)

    $prompt = $using:promptTemplate
    $prompt = $prompt.Replace("{{REQ_ID}}", $req.id)
    $prompt = $prompt.Replace("{{REQ_DESCRIPTION}}", $req.description)
    $prompt = $prompt.Replace("{{REQ_ACCEPTANCE}}", ($req.acceptance_criteria -join "`n- "))
    $prompt = $prompt.Replace("{{WAVE_NUMBER}}", "$($context.WaveNumber)")
    $prompt = $prompt.Replace("{{TOTAL_WAVES}}", "$($context.TotalWaves)")
    $prompt = $prompt.Replace("{{GSD_DIR}}", $context.GsdDir)
    $prompt = $prompt.Replace("{{REPO_ROOT}}", $context.RepoRoot)
    $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $using:InterfaceContext)

    # Inject prior wave results summary
    $priorSummary = ""
    if ($context.PriorWaveResults -and $context.PriorWaveResults.Count -gt 0) {
        $priorSummary = "Prior wave research is available at:`n"
        foreach ($key in $context.PriorWaveResults.Keys) {
            $priorSummary += "- $($context.GsdDir)/research/$key.json`n"
        }
    }
    $prompt = $prompt.Replace("{{PRIOR_WAVE_RESULTS}}", $priorSummary)

    return $prompt
}

# Extract wave arrays (just the req IDs)
$waveArrays = @()
foreach ($wave in $wavesData.waves) {
    $waveArrays += , @($wave.requirements)
}

# Execute wave-parallel research
$waveResult = Invoke-WaveParallel `
    -Requirements $activeReqs `
    -Waves $waveArrays `
    -StepId $stepId `
    -PromptBuilder $promptBuilder `
    -AgentMap $AgentMap `
    -GsdDir $GsdDir `
    -RepoRoot $RepoRoot `
    -MaxConcurrent 7 `
    -CooldownSeconds 10

# Log token feedback for future calibration
$feedbackPath = Join-Path $GsdDir "requirements\token-feedback.jsonl"
foreach ($reqId in $waveResult.Results.Keys) {
    $r = $waveResult.Results[$reqId]
    if ($r.TokenData) {
        $entry = @{
            req_id = $reqId
            phase = "research"
            actual_tokens = $r.TokenData.Tokens
            timestamp = (Get-Date -Format "o")
        } | ConvertTo-Json -Compress
        Add-Content -Path $feedbackPath -Value $entry -Encoding UTF8
    }
}

Write-Host "`n  Research complete: $($waveResult.Completed)/$($waveResult.TotalRequirements)" -ForegroundColor $(
    if ($waveResult.Failed.Count -eq 0) { "Green" } else { "Yellow" }
)

Send-StepNotification -StepId $stepId -Status $(if ($waveResult.Failed.Count -eq 0) { "complete" } else { "partial" }) `
    -Details "$($waveResult.Completed)/$($waveResult.TotalRequirements) researched"

return @{
    Success = ($waveResult.Completed -gt 0)
    Completed = $waveResult.Completed
    Failed = $waveResult.Failed
    TotalRequirements = $waveResult.TotalRequirements
    StepId = $stepId
}
