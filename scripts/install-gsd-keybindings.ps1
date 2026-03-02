<#
.SYNOPSIS
    Adds GSD keyboard shortcuts to VS Code keybindings.json
    
    Ctrl+Shift+G then B  ->  Blueprint: Full Pipeline
    Ctrl+Shift+G then C  ->  GSD: Convergence Loop
    Ctrl+Shift+G then S  ->  GSD: Status Check

.USAGE
    powershell -ExecutionPolicy Bypass -File install-gsd-keybindings.ps1
#>

$ErrorActionPreference = "Stop"

$keybindingsPath = Join-Path $env:APPDATA "Code\User\keybindings.json"
$keybindingsDir = Split-Path $keybindingsPath -Parent

if (-not (Test-Path $keybindingsDir)) {
    New-Item -ItemType Directory -Path $keybindingsDir -Force | Out-Null
}

$gsdBindings = @(
    @{
        key = "ctrl+shift+g b"
        command = "workbench.action.tasks.runTask"
        args = "Blueprint: Full Pipeline"
    }
    @{
        key = "ctrl+shift+g c"
        command = "workbench.action.tasks.runTask"
        args = "GSD: Convergence Loop"
    }
    @{
        key = "ctrl+shift+g s"
        command = "workbench.action.tasks.runTask"
        args = "GSD: Status Check"
    }
)

Write-Host ""
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  GSD VS Code Keyboard Shortcuts Installer" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

# Load existing keybindings or start fresh
$existing = @()
if (Test-Path $keybindingsPath) {
    try {
        $raw = Get-Content $keybindingsPath -Raw
        # Strip single-line comments (// ...) for JSON parsing
        $cleaned = ($raw -split "`n" | Where-Object { $_.Trim() -notmatch "^\s*//" }) -join "`n"
        # Strip trailing commas before ] (common in hand-edited JSON)
        $cleaned = $cleaned -replace ",\s*\]", "]"
        $existing = $cleaned | ConvertFrom-Json
        if ($null -eq $existing) { $existing = @() }
        Write-Host "  [OK] Loaded existing keybindings ($($existing.Count) entries)" -ForegroundColor Green
    } catch {
        Write-Host "  [!!] Could not parse existing keybindings.json" -ForegroundColor Yellow
        Write-Host "       Backing up to keybindings.json.bak" -ForegroundColor Yellow
        Copy-Item $keybindingsPath "$keybindingsPath.bak" -Force
        $existing = @()
    }
} else {
    Write-Host "  [OK] No existing keybindings.json - creating new" -ForegroundColor Green
}

# Remove any existing GSD bindings to avoid duplicates
$existingList = [System.Collections.ArrayList]@($existing)
$removed = 0
$gsdKeys = $gsdBindings | ForEach-Object { $_.key }
$filtered = @()
foreach ($binding in $existingList) {
    if ($binding.key -in $gsdKeys -and $binding.command -eq "workbench.action.tasks.runTask") {
        $removed++
    } else {
        $filtered += $binding
    }
}
if ($removed -gt 0) {
    Write-Host "  [OK] Removed $removed existing GSD bindings (will replace)" -ForegroundColor DarkGray
}

# Add GSD bindings
$final = @()
$final += $filtered
foreach ($b in $gsdBindings) {
    $final += [PSCustomObject]@{
        key = $b.key
        command = $b.command
        args = $b.args
    }
}

# Write keybindings.json
$json = $final | ConvertTo-Json -Depth 4
Set-Content -Path $keybindingsPath -Value $json -Encoding UTF8

Write-Host ""
Write-Host "  SHORTCUTS INSTALLED:" -ForegroundColor White
Write-Host ""
Write-Host "    Ctrl+Shift+G then B   Blueprint: Full Pipeline" -ForegroundColor Cyan
Write-Host "    Ctrl+Shift+G then C   GSD: Convergence Loop" -ForegroundColor Green
Write-Host "    Ctrl+Shift+G then S   GSD: Status Check" -ForegroundColor Yellow
Write-Host ""
Write-Host "  File: $keybindingsPath" -ForegroundColor DarkGray
Write-Host ""
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "  [OK] Keyboard shortcuts installed" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Restart VS Code or press Ctrl+Shift+P -> 'Open Keyboard" -ForegroundColor DarkGray
Write-Host "  Shortcuts (JSON)' to verify." -ForegroundColor DarkGray
Write-Host ""
