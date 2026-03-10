# ===============================================================
# Step 07b: Plan (Wave-Parallel)
# Agents: Tier 1 (Claude, Codex, Gemini) round-robin | Tier 2 rests
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = ""
)

$stepId = "07b-plan"
Write-Host "`n=== STEP 7b: Plan (Wave-Parallel) ===" -ForegroundColor Cyan

# Ensure output directory
$plansDir = Join-Path $GsdDir "plans"
if (-not (Test-Path $plansDir)) { New-Item -ItemType Directory -Path $plansDir -Force | Out-Null }

# Load requirements and waves
$masterPath = Join-Path $GsdDir "requirements\requirements-master.json"
$wavesPath = Join-Path $GsdDir "requirements\waves.json"

$master = Get-Content $masterPath -Raw | ConvertFrom-Json
$wavesData = Get-Content $wavesPath -Raw | ConvertFrom-Json

$activeReqs = $master.requirements | Where-Object { $_.status -eq "active" }
Write-Host "  Active requirements: $($activeReqs.Count)" -ForegroundColor DarkGray

# Load prompt template
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\07b-plan.md"
$promptTemplate = Get-Content $promptPath -Raw -Encoding UTF8

# Build prompt builder — includes research output for each requirement
$promptBuilder = {
    param($req, $context)

    $prompt = $using:promptTemplate
    $prompt = $prompt.Replace("{{REQ_ID}}", $req.id)
    $prompt = $prompt.Replace("{{REQ_ACCEPTANCE}}", ($req.acceptance_criteria -join "`n- "))
    $prompt = $prompt.Replace("{{GSD_DIR}}", $context.GsdDir)
    $prompt = $prompt.Replace("{{REPO_ROOT}}", $context.RepoRoot)
    $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $using:InterfaceContext)

    # Inject research output
    $researchPath = Join-Path $context.GsdDir "research\$($req.id).json"
    $researchOutput = ""
    if (Test-Path $researchPath) {
        $researchOutput = Get-Content $researchPath -Raw -Encoding UTF8
    } else {
        $researchOutput = "(No research output available for this requirement)"
    }
    $prompt = $prompt.Replace("{{RESEARCH_OUTPUT}}", $researchOutput)

    return $prompt
}

# Extract wave arrays
$waveArrays = @()
foreach ($wave in $wavesData.waves) {
    $waveArrays += , @($wave.requirements)
}

# Execute wave-parallel planning (Tier 1 only, max 3 concurrent)
$waveResult = Invoke-WaveParallel `
    -Requirements $activeReqs `
    -Waves $waveArrays `
    -StepId $stepId `
    -PromptBuilder $promptBuilder `
    -AgentMap $AgentMap `
    -GsdDir $GsdDir `
    -RepoRoot $RepoRoot `
    -MaxConcurrent 3 `
    -CooldownSeconds 10

Write-Host "`n  Planning complete: $($waveResult.Completed)/$($waveResult.TotalRequirements)" -ForegroundColor $(
    if ($waveResult.Failed.Count -eq 0) { "Green" } else { "Yellow" }
)

Send-StepNotification -StepId $stepId -Status $(if ($waveResult.Failed.Count -eq 0) { "complete" } else { "partial" }) `
    -Details "$($waveResult.Completed)/$($waveResult.TotalRequirements) planned"

return @{
    Success = ($waveResult.Completed -gt 0)
    Completed = $waveResult.Completed
    Failed = $waveResult.Failed
    TotalRequirements = $waveResult.TotalRequirements
    StepId = $stepId
}
