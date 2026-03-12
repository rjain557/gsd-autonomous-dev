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

# Auto-log to file while keeping console output (timestamped per run)
$v3Dir = Split-Path $PSScriptRoot -Parent
$logDir = Join-Path $v3Dir "../logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$transcriptFile = Join-Path $logDir "v3-pipeline-$timestamp.log"
# Also maintain a symlink-like "latest" log for easy tailing
$latestLog = Join-Path $v3Dir "../v3-pipeline-live.log"
try { Stop-Transcript -EA SilentlyContinue } catch {}
Start-Transcript -Path $transcriptFile | Out-Null
# Write the current log path to latest pointer
Set-Content $latestLog -Value "# Latest log: $transcriptFile`n# Started: $(Get-Date)" -Encoding UTF8
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

# Run feature update pipeline with crash protection
try {
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
    }
    else {
        Write-Host "`n  Feature update stopped: $($result.Error)" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "`n  [FATAL] Pipeline crashed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    $errFile = Join-Path $GsdDir "logs/fatal-crash.log"
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') FATAL: $($_.Exception.Message)`n$($_.ScriptStackTrace)" | Add-Content $errFile
}
finally {
    try { Stop-Transcript -EA SilentlyContinue } catch {}
}
