<#
.SYNOPSIS
    GSD V3 Bug Fix Entry Point
.DESCRIPTION
    Post-launch bug fix. Scoped pipeline, 5 iterations max, ~$0.32/bug.
    Usage:
      pwsh -File gsd-fix.ps1 -RepoRoot "C:\repos\project" -Description "Login fails with + in email"
      pwsh -File gsd-fix.ps1 -RepoRoot "C:\repos\project" -File bugs.md
      pwsh -File gsd-fix.ps1 -RepoRoot "C:\repos\project" -BugDir ./bugs/login-issue/
      pwsh -File gsd-fix.ps1 -RepoRoot "C:\repos\project" -Description "Popup broken" -Interface browser
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$Description = "",
    [string]$File = "",
    [string]$BugDir = "",
    [string]$Interface = "unknown",
    [string]$NtfyTopic = "auto"
)

$ErrorActionPreference = "Stop"

$v3Dir = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Bug Fix" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# Load modules
$modulesDir = Join-Path $v3Dir "lib/modules"
. (Join-Path $modulesDir "api-client.ps1")
. (Join-Path $modulesDir "cost-tracker.ps1")
. (Join-Path $modulesDir "local-validator.ps1")
. (Join-Path $modulesDir "resilience.ps1")
. (Join-Path $modulesDir "supervisor.ps1")
. (Join-Path $modulesDir "traceability-updater.ps1")
. (Join-Path $modulesDir "phase-orchestrator.ps1")

# Load config
$Config = Get-Content (Join-Path $v3Dir "config/global-config.json") -Raw | ConvertFrom-Json
$AgentMap = Get-Content (Join-Path $v3Dir "config/agent-map.json") -Raw | ConvertFrom-Json

# Parse bug input
$bugDescription = ""
$bugArtifacts = @{}

if ($Description) {
    $bugDescription = $Description
}
elseif ($File -and (Test-Path $File)) {
    $bugDescription = Get-Content $File -Raw -Encoding UTF8
}
elseif ($BugDir -and (Test-Path $BugDir)) {
    # Scan bug directory for artifacts
    $bugFiles = Get-ChildItem -Path $BugDir -File -ErrorAction SilentlyContinue

    $screenshots = @()
    $logs = @()
    $descFile = $null

    foreach ($f in $bugFiles) {
        $ext = $f.Extension.ToLower()
        if ($ext -in @(".png", ".jpg", ".gif", ".bmp", ".webp")) {
            $screenshots += $f.FullName
        }
        elseif ($ext -in @(".log", ".txt")) {
            $logs += $f.FullName
        }
        elseif ($ext -eq ".md") {
            $descFile = $f.FullName
        }
    }

    if ($descFile) {
        $bugDescription = Get-Content $descFile -Raw -Encoding UTF8
    }
    else {
        $bugDescription = "Bug reported from directory: $BugDir"
    }

    $bugArtifacts = @{ screenshots = $screenshots; logs = $logs }
}
else {
    Write-Host "  [XX] Provide -Description, -File, or -BugDir" -ForegroundColor Red
    exit 1
}

# Generate bug ID
$existingBugs = @()
$matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
if (Test-Path $matrixPath) {
    $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
    $existingBugs = @($matrix.requirements | Where-Object { $_.req_id -like "BUG-*" })
}
$bugNum = $existingBugs.Count + 1
$bugId = "BUG-$($bugNum.ToString('000'))"

Write-Host "  Bug ID: $bugId" -ForegroundColor Yellow
Write-Host "  Interface: $Interface" -ForegroundColor DarkGray
Write-Host "  Description: $($bugDescription.Substring(0, [math]::Min(100, $bugDescription.Length)))..." -ForegroundColor DarkGray

# Copy artifacts to .gsd
if ($bugArtifacts.Count -gt 0) {
    $artifactDir = Join-Path $GsdDir "supervisor/bug-artifacts/$bugId"
    if (-not (Test-Path $artifactDir)) { New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null }

    foreach ($ss in $bugArtifacts.screenshots) {
        Copy-Item $ss -Destination $artifactDir -Force
    }
    foreach ($log in $bugArtifacts.logs) {
        Copy-Item $log -Destination $artifactDir -Force
    }
    Write-Host "  Artifacts copied to $artifactDir" -ForegroundColor DarkGray
}

# Write error context
$errorContextPath = Join-Path $GsdDir "supervisor/error-context.md"
$errorContext = "# Bug Report: $bugId`n`n"
$errorContext += "## Description`n`n$bugDescription`n`n"
$errorContext += "## Interface`n`n$Interface`n`n"

# Inline first 20 lines of log files
foreach ($log in $bugArtifacts.logs) {
    if (Test-Path $log) {
        $logContent = Get-Content $log -TotalCount 20 -Encoding UTF8 -ErrorAction SilentlyContinue
        $errorContext += "## Log: $(Split-Path $log -Leaf)`n`n``````n$($logContent -join "`n")`n```````n`n"
    }
}
Set-Content $errorContextPath -Value $errorContext -Encoding UTF8

# Add bug to requirements matrix
Add-BugRequirement -GsdDir $GsdDir -BugId $bugId -Description $bugDescription `
    -Interface $Interface -Artifacts $bugArtifacts

# Build scope filter
$scope = "source:bug_report"
if ($Interface -ne "unknown") {
    $scope = "source:bug_report AND interface:$Interface"
}

# Run bug fix pipeline
$result = Start-V3Pipeline `
    -RepoRoot $RepoRoot `
    -Mode "bug_fix" `
    -Config $Config `
    -AgentMap $AgentMap `
    -Scope $scope `
    -NtfyTopic $NtfyTopic

if ($result.Success) {
    Write-Host "`n  Bug $bugId fixed! Cost: `$$([math]::Round($result.TotalCost, 2))" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "`n  Bug fix stopped: $($result.Error)" -ForegroundColor Yellow
    exit 1
}
