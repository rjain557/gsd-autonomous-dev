# ===============================================================
# Step 01: Spec Quality Gate
# Agent: Claude | Checks artifacts for contradictions before deriving requirements
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = ""
)

$stepId = "01-spec-quality-gate"
Write-Host "`n=== STEP 1: Spec Quality Gate ===" -ForegroundColor Cyan

# Ensure output directory
$specsDir = Join-Path $GsdDir "specs"
if (-not (Test-Path $specsDir)) { New-Item -ItemType Directory -Path $specsDir -Force | Out-Null }

# Load and resolve prompt template
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\01-spec-quality-gate.md"
$prompt = Get-Content $promptPath -Raw -Encoding UTF8
$prompt = $prompt.Replace("{{REPO_ROOT}}", $RepoRoot)
$prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
$prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

# Append file map for spatial awareness
$fileMapPath = Join-Path $GsdDir "file-map-tree.md"
if (Test-Path $fileMapPath) {
    $prompt += "`n`n## FILE MAP`n" + (Get-Content $fileMapPath -Raw -Encoding UTF8)
}

# Get assigned agent
$agent = Get-StepAgent -StepId $stepId -AgentMap $AgentMap
Write-Host "  Agent: $agent" -ForegroundColor DarkGray

# Invoke agent
$result = Invoke-Agent -Agent $agent -Prompt $prompt -StepId $stepId `
    -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 15

if (-not $result.Success) {
    Write-Host "  [XX] Spec quality gate failed: $($result.Error)" -ForegroundColor Red
    return @{ Success = $false; Error = $result.Error; StepId = $stepId }
}

# Parse the output to find the report
$reportPath = Join-Path $GsdDir "specs\spec-quality-report.json"
if (Test-Path $reportPath) {
    try {
        $report = Get-Content $reportPath -Raw | ConvertFrom-Json
        $status = $report.overall_status
        $clarityScore = $report.clarity_score
        $criticalConflicts = $report.summary.critical_conflicts

        Write-Host "  Status: $status | Clarity: $clarityScore | Critical conflicts: $criticalConflicts" -ForegroundColor $(
            if ($status -eq "block") { "Red" }
            elseif ($status -eq "warn") { "Yellow" }
            else { "Green" }
        )

        # Gate decision
        if ($status -eq "block") {
            Write-Host "  [BLOCKED] Critical spec conflicts found. Resolve before continuing." -ForegroundColor Red
            Send-StepNotification -StepId $stepId -Status "failed" `
                -Details "Blocked: $criticalConflicts critical conflicts, clarity $clarityScore"
            return @{ Success = $false; Error = "spec_blocked"; Report = $report; StepId = $stepId }
        }

        if ($status -eq "warn") {
            Write-Host "  [WARN] Spec quality warnings. Proceeding with caution." -ForegroundColor Yellow
        }

        Send-StepNotification -StepId $stepId -Status "complete" `
            -Details "Clarity: $clarityScore | Conflicts: $($report.summary.total_conflicts)"

        return @{ Success = $true; Report = $report; StepId = $stepId }
    }
    catch {
        Write-Host "  [WARN] Could not parse spec report, proceeding anyway" -ForegroundColor DarkYellow
        return @{ Success = $true; Report = $null; StepId = $stepId }
    }
}
else {
    Write-Host "  [WARN] No spec report generated, proceeding" -ForegroundColor DarkYellow
    return @{ Success = $true; Report = $null; StepId = $stepId }
}
