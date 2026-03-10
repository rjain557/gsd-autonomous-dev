# ===============================================================
# Step 02: Requirements Derivation
# Agents: Gemini + Tier 2 (parallel per artifact) | Claude rests
# ===============================================================

param(
    [Parameter(Mandatory)][string]$GsdDir,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][PSObject]$AgentMap,
    [Parameter(Mandatory)][PSObject]$Config,
    [string]$InterfaceContext = "",
    [PSObject]$Interfaces = $null
)

$stepId = "02-requirements-derivation"
Write-Host "`n=== STEP 2: Requirements Derivation ===" -ForegroundColor Cyan

# Ensure output directory
$reqsDir = Join-Path $GsdDir "requirements"
if (-not (Test-Path $reqsDir)) { New-Item -ItemType Directory -Path $reqsDir -Force | Out-Null }

# Load prompt template
$promptPath = Join-Path $PSScriptRoot "..\..\prompts\02-requirements-derivation.md"
$promptTemplate = Get-Content $promptPath -Raw -Encoding UTF8

# Discover artifacts to process
$artifacts = @()

# Phase A, B, D, E docs
$docsPath = Join-Path $RepoRoot $Config.sdlc_docs.path
if (Test-Path $docsPath) {
    foreach ($phase in @("Phase-A", "Phase-B", "Phase-D", "Phase-E")) {
        $phaseFiles = Get-ChildItem -Path $docsPath -Filter "$phase*" -Recurse -ErrorAction SilentlyContinue
        if ($phaseFiles.Count -gt 0) {
            $phaseLetter = $phase.Split('-')[1].ToLower()
            $artifacts += @{
                Type = $phase
                Path = ($phaseFiles | Select-Object -First 1).FullName
                OutputFile = "phase-$phaseLetter.json"
                Prefix = switch ($phaseLetter) { "a" { "BA" } "b" { "TA" } "d" { "API" } "e" { "OPS" } }
                InterfaceName = "shared"
            }
        }
    }
}

# Figma interfaces
if ($Interfaces) {
    foreach ($iface in $Interfaces) {
        if ($iface.AnalysisPath -and (Test-Path $iface.AnalysisPath)) {
            $ifaceName = $iface.Type.ToLower()
            $prefix = switch ($ifaceName) {
                "web" { "WEB" }
                "mcp" { "MCP" }
                "browser" { "BRW" }
                "mobile" { "MOB" }
                "agent" { "AGT" }
                default { $ifaceName.ToUpper().Substring(0,3) }
            }
            $artifacts += @{
                Type = "Figma"
                Path = $iface.AnalysisPath
                OutputFile = "figma-$ifaceName.json"
                Prefix = $prefix
                InterfaceName = $ifaceName
            }
        }
    }
}

if ($artifacts.Count -eq 0) {
    Write-Host "  [WARN] No artifacts found to derive requirements from" -ForegroundColor DarkYellow
    return @{ Success = $false; Error = "no_artifacts"; StepId = $stepId }
}

Write-Host "  Found $($artifacts.Count) artifacts to process" -ForegroundColor DarkGray

# Get agents for parallel dispatch
$agents = Get-WaveAgents -StepId $stepId -RequirementCount $artifacts.Count -AgentMap $AgentMap

# Process each artifact (parallel via background jobs)
$jobs = @()
for ($i = 0; $i -lt $artifacts.Count; $i++) {
    $artifact = $artifacts[$i]
    $agent = $agents[$i]

    # Resolve prompt for this artifact
    $prompt = $promptTemplate
    $prompt = $prompt.Replace("{{ARTIFACT_TYPE}}", $artifact.Type)
    $prompt = $prompt.Replace("{{ARTIFACT_PATH}}", $artifact.Path)
    $prompt = $prompt.Replace("{{INTERFACE_NAME}}", $artifact.InterfaceName)
    $prompt = $prompt.Replace("{{GSD_DIR}}", $GsdDir)
    $prompt = $prompt.Replace("{{OUTPUT_FILENAME}}", $artifact.OutputFile)
    $prompt = $prompt.Replace("{{PREFIX}}", $artifact.Prefix)
    $prompt = $prompt.Replace("{{INTERFACE_CONTEXT}}", $InterfaceContext)

    Write-Host "  [$agent] $($artifact.Type) -> $($artifact.OutputFile)" -ForegroundColor DarkGray

    $result = Invoke-Agent -Agent $agent -Prompt $prompt -StepId $stepId `
        -GsdDir $GsdDir -RepoRoot $RepoRoot -TimeoutMinutes 20

    if ($result.Success) {
        Write-Host "    [OK] $($artifact.OutputFile)" -ForegroundColor Green
    } else {
        Write-Host "    [FAIL] $($artifact.OutputFile): $($result.Error)" -ForegroundColor Red
    }

    $jobs += @{
        Artifact = $artifact
        Agent = $agent
        Result = $result
    }
}

# Summarize
$succeeded = ($jobs | Where-Object { $_.Result.Success }).Count
$failed = ($jobs | Where-Object { -not $_.Result.Success }).Count

Write-Host "`n  Derivation complete: $succeeded succeeded, $failed failed" -ForegroundColor $(
    if ($failed -eq 0) { "Green" } else { "Yellow" }
)

Send-StepNotification -StepId $stepId -Status $(if ($failed -eq 0) { "complete" } else { "partial" }) `
    -Details "$succeeded/$($artifacts.Count) artifacts processed"

return @{
    Success = ($succeeded -gt 0)
    Succeeded = $succeeded
    Failed = $failed
    TotalArtifacts = $artifacts.Count
    StepId = $stepId
}
