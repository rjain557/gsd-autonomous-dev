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

# ============================================================
# CENTRALIZED LOGGING — logs stored in ~/.gsd-global/logs/{repo-name}/
# Each pipeline run gets a run log, each iteration gets its own log
# Iteration counter is persistent per-repo (survives across runs)
# ============================================================

$repoName = Split-Path $RepoRoot -Leaf
$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }

# Also keep local logs dir for backwards compatibility
$localLogDir = Join-Path $v3Dir "../logs"
if (-not (Test-Path $localLogDir)) { New-Item -ItemType Directory -Path $localLogDir -Force | Out-Null }

# Persistent iteration counter per repo (never resets between runs)
$iterCounterFile = Join-Path $globalLogDir "iteration-counter.json"
if (Test-Path $iterCounterFile) {
    $iterCounter = Get-Content $iterCounterFile -Raw | ConvertFrom-Json
    $globalIterationStart = $iterCounter.next_iteration
} else {
    $globalIterationStart = 1
    @{ next_iteration = 1; repo = $repoName; repo_root = $RepoRoot; created = (Get-Date -Format "o") } |
        ConvertTo-Json | Set-Content $iterCounterFile -Encoding UTF8
}

# If user specified StartIteration, use that; otherwise use the persistent counter
if ($StartIteration -gt 1) {
    $globalIterationStart = $StartIteration
}

# Pipeline run log (one per pipeline start)
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$runId = "run-$timestamp"
$runLogFile = Join-Path $globalLogDir "$runId.log"

# Also write to local logs for backwards compat
$localTranscript = Join-Path $localLogDir "v3-pipeline-$timestamp.log"

# Per-iteration log directory
$iterLogDir = Join-Path $globalLogDir "iterations"
if (-not (Test-Path $iterLogDir)) { New-Item -ItemType Directory -Path $iterLogDir -Force | Out-Null }

# Latest log pointer (both local and global)
$latestLog = Join-Path $v3Dir "../v3-pipeline-live.log"
$globalLatestLog = Join-Path $globalLogDir "latest.log"

try { Stop-Transcript -EA SilentlyContinue } catch {}
Start-Transcript -Path $localTranscript | Out-Null

# Write run log header
$runHeader = @{
    run_id          = $runId
    repo            = $repoName
    repo_root       = $RepoRoot
    started_at      = (Get-Date -Format "o")
    global_iteration_start = $globalIterationStart
    mode            = "feature_update"
    scope           = $Scope
    log_file        = $runLogFile
    local_log       = $localTranscript
    iteration_log_dir = $iterLogDir
}
$runHeader | ConvertTo-Json | Set-Content $runLogFile -Encoding UTF8

# Update latest pointers
Set-Content $latestLog -Value "# Latest log: $localTranscript`n# Started: $(Get-Date)`n# Run ID: $runId`n# Global iter start: $globalIterationStart" -Encoding UTF8
Copy-Item $latestLog $globalLatestLog -Force -ErrorAction SilentlyContinue

Write-Host "  [LOG] Central: $globalLogDir" -ForegroundColor DarkGray
Write-Host "  [LOG] Run: $runId | Global iteration: $globalIterationStart" -ForegroundColor DarkGray

# Export for phase-orchestrator to use
$env:GSD_GLOBAL_LOG_DIR = $globalLogDir
$env:GSD_ITER_LOG_DIR = $iterLogDir
$env:GSD_GLOBAL_ITER_START = $globalIterationStart
$env:GSD_ITER_COUNTER_FILE = $iterCounterFile
$env:GSD_RUN_ID = $runId
$env:GSD_REPO_NAME = $repoName

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
