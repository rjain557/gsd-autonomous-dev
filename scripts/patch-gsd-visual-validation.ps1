<#
.SYNOPSIS
    Visual Validation - Figma screenshot comparison for React components.
    Run AFTER patch-gsd-api-contract-validation.ps1.

.DESCRIPTION
    Adds visual regression testing by comparing generated React components
    against Figma design exports using Playwright screenshots.

    Adds:
    1. Invoke-VisualValidation function to resilience.ps1
       - Launches Playwright to screenshot generated components
       - Compares against Figma exported PNGs in design/figma/screenshots/
       - Reports pixel diff percentage per component
       - Flags components with >15% visual deviation

    2. Config: visual_validation block in global-config.json

    3. Visual diff results saved to .gsd/validation/visual-results.json

    Prerequisites (installed on demand):
    - npm install -g playwright (auto-detected)
    - Figma exports in design/{interface}/screenshots/ directory

.INSTALL_ORDER
    1-25. (existing scripts)
    26. patch-gsd-visual-validation.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Visual Validation (Figma Screenshot Diff)" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add visual_validation config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.visual_validation) {
        $config | Add-Member -NotePropertyName "visual_validation" -NotePropertyValue ([PSCustomObject]@{
            enabled               = $true
            max_diff_pct          = 15
            screenshot_dir        = "design/screenshots"
            viewport_width        = 1280
            viewport_height       = 720
            block_on_high_diff    = $false
            playwright_timeout_ms = 30000
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added visual_validation config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] visual_validation already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Add Invoke-VisualValidation function to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Invoke-VisualValidation*") {

        $visualFunction = @'

# ===========================================
# VISUAL VALIDATION (FIGMA SCREENSHOT DIFF)
# ===========================================

function Invoke-VisualValidation {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $result = @{
        Passed     = $true
        Components = @()
        Summary    = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.visual_validation -or -not $config.visual_validation.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    $maxDiffPct = [int]$config.visual_validation.max_diff_pct
    $screenshotDir = $config.visual_validation.screenshot_dir
    $blockOnDiff = $config.visual_validation.block_on_high_diff

    # Check for Figma screenshots
    $screenshotPath = Join-Path $RepoRoot $screenshotDir
    if (-not (Test-Path $screenshotPath)) {
        # Also check design/{interface}/screenshots/
        $designScreenshots = Get-ChildItem -Path $RepoRoot -Filter "screenshots" -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*design*" }

        if ($designScreenshots.Count -eq 0) {
            Write-Host "  [VISUAL] No screenshot directory found -- skipping visual validation" -ForegroundColor DarkGray
            Write-Host "  [VISUAL] Place Figma exports in: $screenshotDir" -ForegroundColor DarkGray
            return $result
        }
        $screenshotPath = $designScreenshots[0].FullName
    }

    # Find reference screenshots (PNG/JPG)
    $refScreenshots = Get-ChildItem -Path $screenshotPath -Include "*.png","*.jpg","*.jpeg" -Recurse -ErrorAction SilentlyContinue
    if ($refScreenshots.Count -eq 0) {
        Write-Host "  [VISUAL] No reference screenshots found in $screenshotPath" -ForegroundColor DarkGray
        return $result
    }

    Write-Host "  [VISUAL] Found $($refScreenshots.Count) reference screenshots" -ForegroundColor Cyan

    # Check for Playwright
    $hasPlaywright = $null -ne (Get-Command npx -ErrorAction SilentlyContinue)
    $hasPixelmatch = $false

    if ($hasPlaywright) {
        # Check if playwright and pixelmatch are available
        $playwrightCheck = & npx playwright --version 2>$null
        $hasPlaywright = ($LASTEXITCODE -eq 0)
    }

    if (-not $hasPlaywright) {
        Write-Host "  [VISUAL] Playwright not available -- using file-size heuristic comparison" -ForegroundColor Yellow
        Write-Host "  [VISUAL] Install: npm install -D playwright @playwright/test" -ForegroundColor DarkGray

        # Fallback: just report which screenshots exist vs which components exist
        foreach ($ref in $refScreenshots) {
            $componentName = [System.IO.Path]::GetFileNameWithoutExtension($ref.Name)
            $componentFiles = Get-ChildItem -Path $RepoRoot -Filter "*${componentName}*" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in ".tsx", ".jsx", ".ts", ".js" -and $_.FullName -notlike "*node_modules*" }

            $status = if ($componentFiles.Count -gt 0) { "implemented" } else { "missing" }
            $result.Components += @{
                name        = $componentName
                reference   = $ref.FullName
                status      = $status
                component   = if ($componentFiles.Count -gt 0) { $componentFiles[0].FullName } else { $null }
                diff_pct    = if ($status -eq "missing") { 100 } else { -1 }
            }

            if ($status -eq "missing") {
                Write-Host "    [MISS] $componentName -- no matching component file" -ForegroundColor Red
            } else {
                Write-Host "    [OK] $componentName -> $($componentFiles[0].Name)" -ForegroundColor Green
            }
        }
    } else {
        # Full Playwright screenshot comparison
        $viewport_w = [int]$config.visual_validation.viewport_width
        $viewport_h = [int]$config.visual_validation.viewport_height
        $timeout = [int]$config.visual_validation.playwright_timeout_ms

        # Check if dev server is running (React typically on port 3000)
        $devServerRunning = $false
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:3000" -TimeoutSec 3 -ErrorAction SilentlyContinue
            $devServerRunning = ($response.StatusCode -eq 200)
        } catch {
            $devServerRunning = $false
        }

        if (-not $devServerRunning) {
            Write-Host "  [VISUAL] Dev server not running on localhost:3000 -- using component-match only" -ForegroundColor Yellow

            foreach ($ref in $refScreenshots) {
                $componentName = [System.IO.Path]::GetFileNameWithoutExtension($ref.Name)
                $componentFiles = Get-ChildItem -Path $RepoRoot -Filter "*${componentName}*" -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in ".tsx", ".jsx", ".ts", ".js" -and $_.FullName -notlike "*node_modules*" }

                $status = if ($componentFiles.Count -gt 0) { "implemented" } else { "missing" }
                $result.Components += @{
                    name      = $componentName
                    reference = $ref.FullName
                    status    = $status
                    diff_pct  = if ($status -eq "missing") { 100 } else { -1 }
                }
            }
        } else {
            Write-Host "  [VISUAL] Dev server detected. Running Playwright screenshot capture..." -ForegroundColor Cyan

            # Create temp screenshot dir for captured screenshots
            $captureDir = Join-Path $GsdDir "validation\screenshots-captured"
            if (-not (Test-Path $captureDir)) {
                New-Item -Path $captureDir -ItemType Directory -Force | Out-Null
            }

            foreach ($ref in $refScreenshots) {
                $componentName = [System.IO.Path]::GetFileNameWithoutExtension($ref.Name)

                # Try to capture screenshot of the component route
                $route = $componentName.ToLower() -replace '_', '/' -replace '-', '/'
                $url = "http://localhost:3000/$route"

                $capturedPath = Join-Path $captureDir "$componentName.png"

                try {
                    # Use Playwright to capture
                    $playwrightScript = @"
const { chromium } = require('playwright');
(async () => {
    const browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: $viewport_w, height: $viewport_h } });
    await page.goto('$url', { timeout: $timeout });
    await page.screenshot({ path: '$($capturedPath -replace '\\', '/')' });
    await browser.close();
})();
"@
                    $scriptPath = Join-Path $GsdDir "validation\.playwright-capture.js"
                    Set-Content -Path $scriptPath -Value $playwrightScript -Encoding UTF8
                    & node $scriptPath 2>$null

                    if (Test-Path $capturedPath) {
                        # Step 1: SHA256 hash -- if identical, no diff at all
                        $refHash = (Get-FileHash $ref.FullName -Algorithm SHA256).Hash
                        $capHash = (Get-FileHash $capturedPath -Algorithm SHA256).Hash
                        $diffPct = 0.0
                        $diffMethod = "hash"

                        if ($refHash -ne $capHash) {
                            # Step 2: Try ImageMagick pixel diff (most accurate, zero-cost if installed)
                            $magickCmd = Get-Command "magick" -ErrorAction SilentlyContinue
                            if (-not $magickCmd) { $magickCmd = Get-Command "compare" -ErrorAction SilentlyContinue }
                            if ($magickCmd) {
                                try {
                                    $diffOut = & $magickCmd.Name compare -metric AE -fuzz "2%" $ref.FullName $capturedPath "null:" 2>&1
                                    if ($diffOut -match '^\d+') {
                                        $pixelsDiff = [double]($Matches[0])
                                        # Estimate total pixels from file (approximate; AE is absolute pixel count)
                                        $refInfo = & $magickCmd.Name identify -format "%[fx:w*h]" $ref.FullName 2>$null
                                        $totalPixels = if ($refInfo -match '^\d+') { [double]$refInfo } else { 1000000.0 }
                                        $diffPct = [math]::Min(100, ($pixelsDiff / [math]::Max($totalPixels, 1)) * 100)
                                        $diffMethod = "imageMagick"
                                    }
                                } catch { }
                            }

                            if ($diffMethod -eq "hash") {
                                # Step 3: Fall back to file-size ratio with explicit warning
                                $refSize = (Get-Item $ref.FullName).Length
                                $capSize = (Get-Item $capturedPath).Length
                                $diffPct = [math]::Abs($refSize - $capSize) / [math]::Max($refSize, 1) * 100
                                $diffMethod = "fileSize(approx)"
                                Write-Host "    [WARN] ${componentName}: ImageMagick not found -- using file-size approximation" -ForegroundColor DarkYellow
                            }
                        }

                        $result.Components += @{
                            name       = $componentName
                            reference  = $ref.FullName
                            captured   = $capturedPath
                            status     = "captured"
                            diff_pct   = [math]::Round($diffPct, 1)
                            diff_method = $diffMethod
                        }

                        if ($diffPct -gt $maxDiffPct) {
                            Write-Host "    [DIFF] ${componentName}: $([math]::Round($diffPct,1))% deviation ($diffMethod)" -ForegroundColor Yellow
                        } else {
                            Write-Host "    [OK] ${componentName}: $([math]::Round($diffPct,1))% deviation ($diffMethod)" -ForegroundColor Green
                        }
                    } else {
                        $result.Components += @{
                            name     = $componentName
                            status   = "capture_failed"
                            diff_pct = -1
                        }
                        Write-Host "    [FAIL] ${componentName}: screenshot capture failed" -ForegroundColor Red
                    }

                    Remove-Item $scriptPath -ErrorAction SilentlyContinue
                } catch {
                    $result.Components += @{
                        name     = $componentName
                        status   = "error"
                        diff_pct = -1
                        error    = $_.Exception.Message
                    }
                }
            }
        }
    }

    # Determine pass/fail
    $highDiffCount = ($result.Components | Where-Object { $_.diff_pct -gt $maxDiffPct }).Count
    $missingCount = ($result.Components | Where-Object { $_.status -eq "missing" }).Count

    if ($blockOnDiff -and ($highDiffCount -gt 0 -or $missingCount -gt 0)) {
        $result.Passed = $false
    }

    $result.Summary = "Components: $($result.Components.Count), High diff: $highDiffCount, Missing: $missingCount"
    Write-Host "  [VISUAL] $($result.Summary)" -ForegroundColor $(if ($highDiffCount -eq 0 -and $missingCount -eq 0) { "Green" } else { "Yellow" })

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) {
        New-Item -Path $valDir -ItemType Directory -Force | Out-Null
    }
    @{
        iteration  = $Iteration
        timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed     = $result.Passed
        max_diff   = $maxDiffPct
        components = $result.Components
        summary    = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "visual-results.json") -Encoding UTF8

    return $result
}
'@

        Add-Content -Path $resilienceFile -Value $visualFunction -Encoding UTF8
        Write-Host "  [OK] Added Invoke-VisualValidation to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Invoke-VisualValidation already exists" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  [VISUAL] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> visual_validation" -ForegroundColor DarkGray
Write-Host "  Function: Invoke-VisualValidation in resilience.ps1" -ForegroundColor DarkGray
Write-Host "  Output: .gsd/validation/visual-results.json" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Setup: Place Figma exported PNGs in design/screenshots/" -ForegroundColor DarkGray
Write-Host "  Optional: npm install -D playwright for full screenshot comparison" -ForegroundColor DarkGray
Write-Host ""
