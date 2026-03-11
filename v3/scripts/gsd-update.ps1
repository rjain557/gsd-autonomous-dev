<#
.SYNOPSIS
    GSD V3 Feature Update Entry Point
.DESCRIPTION
    Post-launch feature additions from updated specs. Preserves satisfied requirements.
    Usage:
      pwsh -File gsd-update.ps1 -RepoRoot "C:\repos\project"
      pwsh -File gsd-update.ps1 -RepoRoot "C:\repos\project" -Scope "source:v02_spec"
      pwsh -File gsd-update.ps1 -RepoRoot "C:\repos\project" -Scope "id:REQ-201,REQ-202"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Scope = "",
    [string]$NtfyTopic = "auto",
    [int]$StartIteration = 1
)

$ErrorActionPreference = "Stop"

$v3Dir = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

# Always clear stale lock file on startup
$lockFile = Join-Path $GsdDir ".gsd-lock.json"
if (Test-Path $lockFile) {
    Remove-Item $lockFile -Force
    Write-Host "  [LOCK] Cleared stale lock file" -ForegroundColor Yellow
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Feature Update" -ForegroundColor Cyan
$scopeLabel = if ($Scope) { $Scope } else { "all new" }
Write-Host "  Scope: $scopeLabel" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

# Load modules
$modulesDir = Join-Path $v3Dir "lib/modules"
. (Join-Path $modulesDir "api-client.ps1")
. (Join-Path $modulesDir "cost-tracker.ps1")
. (Join-Path $modulesDir "local-validator.ps1")
. (Join-Path $modulesDir "resilience.ps1")
. (Join-Path $modulesDir "supervisor.ps1")
. (Join-Path $modulesDir "phase-orchestrator.ps1")

# Load config
$Config = Get-Content (Join-Path $v3Dir "config/global-config.json") -Raw | ConvertFrom-Json
$AgentMap = Get-Content (Join-Path $v3Dir "config/agent-map.json") -Raw | ConvertFrom-Json

# Verify requirements matrix exists
$matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
if (-not (Test-Path $matrixPath)) {
    Write-Host "  [XX] No requirements matrix found. Run gsd-blueprint first." -ForegroundColor Red
    exit 1
}

# Show current state
$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
$currentTotal = $matrix.requirements.Count
$currentSatisfied = ($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
$healthPct = if ($currentTotal -gt 0) { [math]::Round(($currentSatisfied / $currentTotal) * 100) } else { 0 }
Write-Host "  Current: $currentSatisfied/$currentTotal satisfied (${healthPct}%)" -ForegroundColor DarkGray

# Run feature update pipeline
$result = Start-V3Pipeline `
    -RepoRoot $RepoRoot `
    -Mode "feature_update" `
    -Config $Config `
    -AgentMap $AgentMap `
    -Scope $Scope `
    -NtfyTopic $NtfyTopic `
    -StartIteration $StartIteration

if ($result.Success) {
    Write-Host "`n  Feature update complete! Cost: `$$([math]::Round($result.TotalCost, 2))" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`n  Feature update stopped: $($result.Error)" -ForegroundColor Yellow
    exit 1
}
