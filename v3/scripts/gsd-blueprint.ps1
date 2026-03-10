<#
.SYNOPSIS
    GSD V3 Greenfield Pipeline Entry Point
.DESCRIPTION
    Builds a new project from spec (pre-1.0). Full pipeline, all phases active.
    Usage: pwsh -File gsd-blueprint.ps1 -RepoRoot "C:\repos\my-project"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$NtfyTopic = "auto",
    [int]$StartIteration = 1,
    [switch]$SkipSpecGate,
    [switch]$VerifyApi
)

$ErrorActionPreference = "Stop"

# Resolve paths
$v3Dir = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Greenfield Blueprint" -ForegroundColor Cyan
Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
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
$configPath = Join-Path $v3Dir "config/global-config.json"
$Config = Get-Content $configPath -Raw | ConvertFrom-Json

$agentMapPath = Join-Path $v3Dir "config/agent-map.json"
$AgentMap = Get-Content $agentMapPath -Raw | ConvertFrom-Json

# Optional API connectivity test
if ($VerifyApi) {
    $connected = Test-ApiConnectivity
    if (-not $connected) {
        Write-Host "  [XX] API connectivity test failed. Aborting." -ForegroundColor Red
        exit 1
    }
}

# Run pipeline
$result = Start-V3Pipeline `
    -RepoRoot $RepoRoot `
    -Mode "greenfield" `
    -Config $Config `
    -AgentMap $AgentMap `
    -NtfyTopic $NtfyTopic `
    -StartIteration $StartIteration

if ($result.Success) {
    Write-Host "`n  Blueprint complete! Cost: `$$([math]::Round($result.TotalCost, 2))" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`n  Blueprint stopped: $($result.Error)" -ForegroundColor Yellow
    exit 1
}
