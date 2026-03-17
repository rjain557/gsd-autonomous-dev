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

$v3Dir = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

# ============================================================
# CENTRALIZED LOGGING — same as gsd-update.ps1
# ============================================================
$repoName = Split-Path $RepoRoot -Leaf
$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }

$localLogDir = Join-Path $v3Dir "../logs"
if (-not (Test-Path $localLogDir)) { New-Item -ItemType Directory -Path $localLogDir -Force | Out-Null }

# Persistent iteration counter per repo
$iterCounterFile = Join-Path $globalLogDir "iteration-counter.json"
if (Test-Path $iterCounterFile) {
    $iterCounter = Get-Content $iterCounterFile -Raw | ConvertFrom-Json
    $globalIterationStart = $iterCounter.next_iteration
} else {
    $globalIterationStart = 1
    @{ next_iteration = 1; repo = $repoName; repo_root = $RepoRoot; created = (Get-Date -Format "o") } |
        ConvertTo-Json | Set-Content $iterCounterFile -Encoding UTF8
}
if ($StartIteration -gt 1) { $globalIterationStart = $StartIteration }

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$runId = "run-$timestamp"
$localTranscript = Join-Path $localLogDir "v3-pipeline-$timestamp.log"

$iterLogDir = Join-Path $globalLogDir "iterations"
if (-not (Test-Path $iterLogDir)) { New-Item -ItemType Directory -Path $iterLogDir -Force | Out-Null }

$latestLog = Join-Path $v3Dir "../v3-pipeline-live.log"
try { Stop-Transcript -EA SilentlyContinue } catch {}
Start-Transcript -Path $localTranscript | Out-Null
Set-Content $latestLog -Value "# Latest log: $localTranscript`n# Started: $(Get-Date)`n# Run ID: $runId`n# Mode: greenfield" -Encoding UTF8

$env:GSD_GLOBAL_LOG_DIR = $globalLogDir
$env:GSD_ITER_LOG_DIR = $iterLogDir
$env:GSD_GLOBAL_ITER_START = $globalIterationStart
$env:GSD_ITER_COUNTER_FILE = $iterCounterFile
$env:GSD_RUN_ID = $runId
$env:GSD_REPO_NAME = $repoName

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Greenfield Blueprint" -ForegroundColor Cyan
Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Log: $localTranscript" -ForegroundColor DarkGray
Write-Host "  Global iter: $globalIterationStart" -ForegroundColor DarkGray
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

# Run pipeline with crash protection
try {
    $result = Start-V3Pipeline `
        -RepoRoot $RepoRoot `
        -Mode "greenfield" `
        -Config $Config `
        -AgentMap $AgentMap `
        -NtfyTopic $NtfyTopic `
        -StartIteration $StartIteration

    if ($result.Success) {
        Write-Host "`n  Blueprint complete! Cost: `$$([math]::Round($result.TotalCost, 2))" -ForegroundColor Green
    }
    else {
        Write-Host "`n  Blueprint stopped: $($result.Error)" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "`n  [FATAL] Pipeline crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
}
finally {
    try { Stop-Transcript -EA SilentlyContinue } catch {}
}
