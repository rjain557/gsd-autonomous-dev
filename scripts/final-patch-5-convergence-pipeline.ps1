<#
.SYNOPSIS
    Final Integration Sub-Patch 5/6: sync the installed convergence pipeline
    from the canonical repository source file.
#>

param([string]$UserHome = $env:USERPROFILE)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SourcePath = Join-Path $RepoRoot "scripts\convergence-loop.ps1"
$TargetDir = Join-Path $UserHome ".gsd-global\scripts"
$TargetPath = Join-Path $TargetDir "convergence-loop.ps1"

Write-Host "[SYNC] Sub-patch 5/6: convergence pipeline -> canonical source..." -ForegroundColor Yellow

if (-not (Test-Path $SourcePath)) {
    Write-Host "  [XX] Canonical source not found: $SourcePath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

Copy-Item -Path $SourcePath -Destination $TargetPath -Force
Write-Host "   [OK] scripts\convergence-loop.ps1 synced from repo source" -ForegroundColor DarkGreen
