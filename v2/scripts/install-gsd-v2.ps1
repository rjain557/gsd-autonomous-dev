# ===============================================================
# GSD v2.0 Installer
# Installs the v2 pipeline alongside v1.5 (non-destructive)
# Usage: powershell -ExecutionPolicy Bypass -File install-gsd-v2.ps1
# ===============================================================

[CmdletBinding()]
param(
    [string]$SourceDir = $PSScriptRoot,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD v2.0 Installer" -ForegroundColor Cyan
Write-Host "============================================`n" -ForegroundColor Cyan

# Resolve paths
$gsdGlobalDir = Join-Path $env:USERPROFILE ".gsd-global"
$v2TargetDir = Join-Path $gsdGlobalDir "v2"

# Source directory is the v2 folder in the repo
$v2SourceDir = Split-Path $SourceDir -Parent
if (-not (Test-Path (Join-Path $v2SourceDir "scripts\pipeline.ps1"))) {
    # Try parent
    $v2SourceDir = Split-Path $v2SourceDir -Parent
    $v2SourceDir = Join-Path $v2SourceDir "v2"
}

if (-not (Test-Path (Join-Path $v2SourceDir "scripts\pipeline.ps1"))) {
    Write-Host "  [XX] Cannot find v2 source directory" -ForegroundColor Red
    Write-Host "  Expected: pipeline.ps1 in scripts/ under $v2SourceDir" -ForegroundColor Red
    exit 1
}

Write-Host "  Source: $v2SourceDir" -ForegroundColor DarkGray
Write-Host "  Target: $v2TargetDir" -ForegroundColor DarkGray

# Check v1.5 exists
if (-not (Test-Path $gsdGlobalDir)) {
    Write-Host "  [WARN] v1.5 not installed. Installing v2 standalone." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $gsdGlobalDir -Force | Out-Null
}

# Check if v2 already installed
if ((Test-Path $v2TargetDir) -and -not $Force) {
    Write-Host "  [WARN] v2 already installed. Use -Force to overwrite." -ForegroundColor Yellow
    $response = Read-Host "  Overwrite? (y/N)"
    if ($response -ne "y") {
        Write-Host "  Aborted." -ForegroundColor DarkGray
        exit 0
    }
}

# Install v2
Write-Host "`n  Installing v2 files..." -ForegroundColor Cyan

# Copy directory structure
$dirs = @(
    "scripts",
    "scripts\steps",
    "prompts",
    "prompts\shared",
    "lib\modules",
    "config",
    "docs"
)

foreach ($dir in $dirs) {
    $targetDir = Join-Path $v2TargetDir $dir
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
}

# Copy files
$fileMappings = @(
    @{ From = "scripts\pipeline.ps1"; To = "scripts\pipeline.ps1" },
    @{ From = "scripts\supervisor-wrapper.ps1"; To = "scripts\supervisor-wrapper.ps1" },
    @{ From = "config\global-config.json"; To = "config\global-config.json" },
    @{ From = "config\agent-map.json"; To = "config\agent-map.json" },
    @{ From = "lib\modules\agent-router.ps1"; To = "lib\modules\agent-router.ps1" },
    @{ From = "lib\modules\wave-executor.ps1"; To = "lib\modules\wave-executor.ps1" },
    @{ From = "lib\modules\notifications.ps1"; To = "lib\modules\notifications.ps1" },
    @{ From = "lib\modules\resilience.ps1"; To = "lib\modules\resilience.ps1" }
)

foreach ($mapping in $fileMappings) {
    $src = Join-Path $v2SourceDir $mapping.From
    $dst = Join-Path $v2TargetDir $mapping.To
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $dst -Force
        Write-Host "    [OK] $($mapping.To)" -ForegroundColor DarkGreen
    } else {
        Write-Host "    [!!] Missing: $($mapping.From)" -ForegroundColor DarkYellow
    }
}

# Copy step scripts
$stepFiles = Get-ChildItem -Path (Join-Path $v2SourceDir "scripts\steps") -Filter "*.ps1" -ErrorAction SilentlyContinue
foreach ($stepFile in $stepFiles) {
    Copy-Item -Path $stepFile.FullName -Destination (Join-Path $v2TargetDir "scripts\steps\$($stepFile.Name)") -Force
    Write-Host "    [OK] scripts/steps/$($stepFile.Name)" -ForegroundColor DarkGreen
}

# Copy prompts
$promptFiles = Get-ChildItem -Path (Join-Path $v2SourceDir "prompts") -Filter "*.md" -ErrorAction SilentlyContinue
foreach ($promptFile in $promptFiles) {
    Copy-Item -Path $promptFile.FullName -Destination (Join-Path $v2TargetDir "prompts\$($promptFile.Name)") -Force
    Write-Host "    [OK] prompts/$($promptFile.Name)" -ForegroundColor DarkGreen
}

# Copy shared prompts
$sharedPromptFiles = Get-ChildItem -Path (Join-Path $v2SourceDir "prompts\shared") -Filter "*.md" -ErrorAction SilentlyContinue
foreach ($sharedFile in $sharedPromptFiles) {
    Copy-Item -Path $sharedFile.FullName -Destination (Join-Path $v2TargetDir "prompts\shared\$($sharedFile.Name)") -Force
    Write-Host "    [OK] prompts/shared/$($sharedFile.Name)" -ForegroundColor DarkGreen
}

# Create CLI wrapper
$binDir = Join-Path $gsdGlobalDir "bin"
if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }

$wrapperContent = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.gsd-global\v2\scripts\supervisor-wrapper.ps1" -RepoRoot "%CD%" %*
"@
Set-Content -Path (Join-Path $binDir "gsd-v2.cmd") -Value $wrapperContent -Encoding ASCII

# Pipeline-only wrapper (no supervisor)
$directContent = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.gsd-global\v2\scripts\pipeline.ps1" -RepoRoot "%CD%" %*
"@
Set-Content -Path (Join-Path $binDir "gsd-v2-direct.cmd") -Value $directContent -Encoding ASCII

Write-Host "    [OK] bin/gsd-v2.cmd (with supervisor)" -ForegroundColor DarkGreen
Write-Host "    [OK] bin/gsd-v2-direct.cmd (without supervisor)" -ForegroundColor DarkGreen

# Write version file
Set-Content -Path (Join-Path $v2TargetDir "VERSION") -Value "2.0.0`nInstalled: $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -Encoding UTF8

# Summary
Write-Host "`n============================================" -ForegroundColor Green
Write-Host "  GSD v2.0 Installation Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Commands available (restart terminal first):" -ForegroundColor DarkGray
Write-Host "    gsd-v2           Run pipeline with supervisor (recommended)" -ForegroundColor White
Write-Host "    gsd-v2-direct    Run pipeline without supervisor" -ForegroundColor White
Write-Host ""
Write-Host "  Usage:" -ForegroundColor DarkGray
Write-Host "    cd C:\repos\my-project" -ForegroundColor White
Write-Host "    gsd-v2" -ForegroundColor White
Write-Host ""
Write-Host "  v1.5 commands (gsd-converge, gsd-blueprint) still work." -ForegroundColor DarkGray
Write-Host ""
