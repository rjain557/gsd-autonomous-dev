<#
.SYNOPSIS
    Final Integration Sub-Patch 4/6: sync the installed blueprint pipeline
    from the canonical repository source file.
#>

param([string]$UserHome = $env:USERPROFILE)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SourcePath = Join-Path $RepoRoot "blueprint\scripts\blueprint-pipeline.ps1"
$TargetDir = Join-Path $UserHome ".gsd-global\blueprint\scripts"
$TargetPath = Join-Path $TargetDir "blueprint-pipeline.ps1"

Write-Host "[SYNC] Sub-patch 4/6: blueprint pipeline -> canonical source..." -ForegroundColor Yellow

if (-not (Test-Path $SourcePath)) {
    Write-Host "  [XX] Canonical source not found: $SourcePath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

Copy-Item -Path $SourcePath -Destination $TargetPath -Force
Write-Host "   [OK] blueprint\scripts\blueprint-pipeline.ps1 synced from repo source" -ForegroundColor DarkGreen

