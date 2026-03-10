# ===============================================================
# Step 03: Requirements Reconciliation
# Agent: Codex | Dedup, merge, flag conflicts
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = ""
)

$stepId = "03-requirements-reconciliation"
Write-Host "`n=== STEP 3: Requirements Reconciliation ===" -ForegroundColor Cyan

# Count source files
$reqsDir = Join-Path $GsdDir "requirements"
$sourceFiles = Get-ChildItem -Path $reqsDir -Filter "*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "requirements-master.json" -and
                   $_.Name -ne "dependency-graph.json" -and
                   $_.Name -ne "waves.json" -and
                   $_.Name -ne "token-forecast.json" -and
                   $_.Name -ne "token-feedback.jsonl" }

if ($sourceFiles.Count -eq 0) {
    Write-Host "  [XX] No requirement files found to reconcile" -ForegroundColor Red
    return @{ Success = $false; Error = "no_source_files"; StepId = $stepId }
}

Write-Host "  Source files: $($sourceFiles.Count)" -ForegroundColor DarkGray

# Load and resolve prompt
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\03-requirements-reconciliation.md"
$prompt = Get-Content $promptPath -Raw -Encoding UTF8
$prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
$prompt = $prompt.Replace("{{TOTAL_SOURCE_FILES}}", "$($sourceFiles.Count)")
$prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

# Get assigned agent
$agent = Get-StepAgent -StepId $stepId -AgentMap $AgentMap
Write-Host "  Agent: $agent" -ForegroundColor DarkGray

# Invoke
$result = Invoke-Agent -Agent $agent -Prompt $prompt -StepId $stepId `
    -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 20

if (-not $result.Success) {
    Write-Host "  [XX] Reconciliation failed: $($result.Error)" -ForegroundColor Red
    return @{ Success = $false; Error = $result.Error; StepId = $stepId }
}

# Validate output
$masterPath = Join-Path $GsdDir "requirements\requirements-master.json"
if (Test-Path $masterPath) {
    try {
        $master = Get-Content $masterPath -Raw | ConvertFrom-Json
        $totalReqs = $master.requirements.Count
        $conflicts = if ($master.conflicts) { $master.conflicts.Count } else { 0 }
        $merged = if ($master.merge_log) { $master.merge_log.Count } else { 0 }

        Write-Host "  Results: $totalReqs requirements | $merged merges | $conflicts conflicts" -ForegroundColor Green
        Send-StepNotification -StepId $stepId -Status "complete" `
            -Details "$totalReqs reqs, $merged merged, $conflicts conflicts"

        return @{
            Success = $true
            TotalRequirements = $totalReqs
            Conflicts = $conflicts
            Merges = $merged
            StepId = $stepId
        }
    }
    catch {
        Write-Host "  [WARN] Could not parse master requirements" -ForegroundColor DarkYellow
        return @{ Success = $true; StepId = $stepId }
    }
}
else {
    Write-Host "  [XX] requirements-master.json not created" -ForegroundColor Red
    return @{ Success = $false; Error = "no_master_output"; StepId = $stepId }
}
