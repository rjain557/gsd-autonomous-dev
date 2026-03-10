# ===============================================================
# Step 08: Iteration Planner
# Agent: Claude | Bundles requirements into iterations
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = ""
)

$stepId = "08-iteration-planner"
Write-Host "`n=== STEP 8: Iteration Planner ===" -ForegroundColor Cyan

# Ensure output directory
$iterDir = Join-Path $GsdDir "iterations"
if (-not (Test-Path $iterDir)) { New-Item -ItemType Directory -Path $iterDir -Force | Out-Null }
$execLogDir = Join-Path $iterDir "execution-log"
if (-not (Test-Path $execLogDir)) { New-Item -ItemType Directory -Path $execLogDir -Force | Out-Null }
$buildDir = Join-Path $iterDir "build-results"
if (-not (Test-Path $buildDir)) { New-Item -ItemType Directory -Path $buildDir -Force | Out-Null }
$reviewDir = Join-Path $iterDir "reviews"
if (-not (Test-Path $reviewDir)) { New-Item -ItemType Directory -Path $reviewDir -Force | Out-Null }

# Count plans
$plansDir = Join-Path $GsdDir "plans"
$planFiles = Get-ChildItem -Path $plansDir -Filter "*.json" -ErrorAction SilentlyContinue
$totalPlans = $planFiles.Count

Write-Host "  Total plans: $totalPlans" -ForegroundColor DarkGray

# Load and resolve prompt
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\08-iteration-planner.md"
$prompt = Get-Content $promptPath -Raw -Encoding UTF8
$prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
$prompt = $prompt.Replace("{{TOTAL_PLANS}}", "$totalPlans")
$prompt = $prompt.Replace("{{DEPENDENCY_GRAPH}}", (Join-Path $GsdDir "requirements\dependency-graph.json"))
$prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

# Get assigned agent
$agent = Get-StepAgent -StepId $stepId -AgentMap $AgentMap
Write-Host "  Agent: $agent" -ForegroundColor DarkGray

# Invoke
$result = Invoke-Agent -Agent $agent -Prompt $prompt -StepId $stepId `
    -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 15

if (-not $result.Success) {
    Write-Host "  [XX] Iteration planning failed: $($result.Error)" -ForegroundColor Red
    return @{ Success = $false; Error = $result.Error; StepId = $stepId }
}

# Validate output
$iterPlanPath = Join-Path $GsdDir "iterations\iteration-plan.json"
if (Test-Path $iterPlanPath) {
    try {
        $iterPlan = Get-Content $iterPlanPath -Raw | ConvertFrom-Json
        $totalIter = $iterPlan.iterations.Count
        $totalReqs = $iterPlan.total_requirements

        Write-Host "  Results: $totalIter iterations | $totalReqs requirements" -ForegroundColor Green

        # Print iteration summary
        foreach ($iter in $iterPlan.iterations) {
            $parallel = if ($iter.parallel_group) { $iter.parallel_group.Count } else { 0 }
            $sequential = if ($iter.sequential_group) { $iter.sequential_group.Count } else { 0 }
            Write-Host "    Iter $($iter.iteration): $parallel parallel + $sequential sequential | $($iter.description)" -ForegroundColor DarkGray
        }

        Send-StepNotification -StepId $stepId -Status "complete" `
            -Details "$totalIter iterations planned for $totalReqs requirements"

        return @{
            Success = $true
            TotalIterations = $totalIter
            TotalRequirements = $totalReqs
            IterationPlan = $iterPlan
            StepId = $stepId
        }
    }
    catch {
        Write-Host "  [WARN] Could not parse iteration plan" -ForegroundColor DarkYellow
        return @{ Success = $true; StepId = $stepId }
    }
}
else {
    Write-Host "  [XX] iteration-plan.json not created" -ForegroundColor Red
    return @{ Success = $false; Error = "no_iteration_plan"; StepId = $stepId }
}
