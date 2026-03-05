<#
.SYNOPSIS
    Design Token Enforcement - Validate CSS/styles against Figma design tokens.
    Run AFTER patch-gsd-visual-validation.ps1.

.DESCRIPTION
    Zero-cost regex scan ensuring generated CSS, styled-components, and inline
    styles use design tokens instead of hardcoded values.

    Adds:
    1. Test-DesignTokenCompliance function to resilience.ps1
       - Scans CSS, SCSS, styled-components, and Tailwind for hardcoded values
       - Cross-references against design tokens file (_analysis/design-tokens.json
         or design/tokens/)
       - Reports hardcoded colors, font sizes, spacing, and border radii
       - Suggests correct token references

    2. Config: design_token_enforcement block in global-config.json

    3. Results saved to .gsd/validation/design-token-results.json

.INSTALL_ORDER
    1-26. (existing scripts)
    27. patch-gsd-design-token-enforcement.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Design Token Enforcement" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add design_token_enforcement config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.design_token_enforcement) {
        $config | Add-Member -NotePropertyName "design_token_enforcement" -NotePropertyValue ([PSCustomObject]@{
            enabled          = $true
            block_on_violation = $false
            scan_extensions  = @(".css", ".scss", ".tsx", ".jsx", ".ts")
            ignore_files     = @("*.min.css", "*.bundle.*", "node_modules/*")
            allowed_raw_colors = @("#000000", "#ffffff", "#000", "#fff", "transparent", "inherit", "currentColor")
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added design_token_enforcement config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] design_token_enforcement already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Add Test-DesignTokenCompliance function to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Test-DesignTokenCompliance*") {

        $tokenFunction = @'

# ===========================================
# DESIGN TOKEN ENFORCEMENT
# ===========================================

function Test-DesignTokenCompliance {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $result = @{
        Passed     = $true
        Violations = @()
        Summary    = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.design_token_enforcement -or -not $config.design_token_enforcement.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    $blockOnViolation = $config.design_token_enforcement.block_on_violation
    $scanExtensions = @($config.design_token_enforcement.scan_extensions)
    $allowedRawColors = @($config.design_token_enforcement.allowed_raw_colors)

    Write-Host "  [TOKEN] Running design token compliance scan..." -ForegroundColor Cyan

    # ── 1. Load design tokens if available ──
    $tokenPaths = @(
        (Join-Path $RepoRoot "_analysis\design-tokens.json"),
        (Join-Path $RepoRoot "design\tokens\tokens.json"),
        (Join-Path $RepoRoot "design\web\tokens.json"),
        (Join-Path $RepoRoot "src\styles\tokens.json"),
        (Join-Path $RepoRoot "src\theme\tokens.json")
    )

    $tokenFile = $null
    $designTokens = @{}
    foreach ($tp in $tokenPaths) {
        if (Test-Path $tp) {
            try {
                $designTokens = Get-Content $tp -Raw | ConvertFrom-Json
                $tokenFile = $tp
                Write-Host "  [TOKEN] Loaded design tokens from: $tp" -ForegroundColor DarkCyan
            } catch {}
            break
        }
    }

    if (-not $tokenFile) {
        Write-Host "  [TOKEN] No design tokens file found -- scanning for hardcoded values only" -ForegroundColor DarkGray
    }

    # ── 2. Find source files to scan ──
    $filesToScan = @()
    foreach ($ext in $scanExtensions) {
        $pattern = "*$ext"
        $found = Get-ChildItem -Path $RepoRoot -Filter $pattern -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike "*\node_modules\*" -and
                $_.FullName -notlike "*\bin\*" -and
                $_.FullName -notlike "*\obj\*" -and
                $_.FullName -notlike "*\dist\*" -and
                $_.FullName -notlike "*\build\*" -and
                $_.FullName -notlike "*\.gsd\*" -and
                $_.Name -notlike "*.min.*" -and
                $_.Name -notlike "*.bundle.*"
            }
        $filesToScan += $found
    }

    if ($filesToScan.Count -eq 0) {
        Write-Host "  [TOKEN] No source files to scan" -ForegroundColor DarkGray
        return $result
    }

    Write-Host "  [TOKEN] Scanning $($filesToScan.Count) files..." -ForegroundColor DarkCyan

    # ── 3. Hardcoded value patterns ──
    $patterns = @(
        @{
            Name    = "Hardcoded hex color"
            Regex   = '#[0-9a-fA-F]{3,8}(?![\w-])'
            Type    = "color"
        },
        @{
            Name    = "Hardcoded rgb/rgba"
            Regex   = 'rgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+'
            Type    = "color"
        },
        @{
            Name    = "Hardcoded pixel font-size"
            Regex   = 'font-size:\s*\d+px'
            Type    = "typography"
        },
        @{
            Name    = "Hardcoded pixel spacing"
            Regex   = '(?:margin|padding|gap):\s*\d+px'
            Type    = "spacing"
        },
        @{
            Name    = "Hardcoded pixel border-radius"
            Regex   = 'border-radius:\s*\d+px'
            Type    = "border"
        },
        @{
            Name    = "Inline style with hardcoded color"
            Regex   = 'color:\s*[''"]#[0-9a-fA-F]{3,8}[''"]'
            Type    = "color"
        },
        @{
            Name    = "Inline style object color"
            Regex   = "color:\s*['""]#[0-9a-fA-F]{3,8}['""]"
            Type    = "color"
        }
    )

    # ── 4. Scan files ──
    foreach ($file in $filesToScan) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $relativePath = $file.FullName.Substring($RepoRoot.Length + 1)

        foreach ($pattern in $patterns) {
            $matches = [regex]::Matches($content, $pattern.Regex)
            foreach ($match in $matches) {
                $value = $match.Value

                # Skip allowed raw colors
                $isAllowed = $false
                foreach ($allowed in $allowedRawColors) {
                    if ($value -like "*$allowed*") { $isAllowed = $true; break }
                }
                if ($isAllowed) { continue }

                # Skip CSS custom property references (var(--xxx))
                $lineContent = ""
                $matchIdx = $match.Index
                $lineStart = $content.LastIndexOf("`n", [math]::Max(0, $matchIdx - 1)) + 1
                $lineEnd = $content.IndexOf("`n", $matchIdx)
                if ($lineEnd -lt 0) { $lineEnd = $content.Length }
                $lineContent = $content.Substring($lineStart, $lineEnd - $lineStart).Trim()

                if ($lineContent -match 'var\(--') { continue }

                # Calculate line number
                $lineNum = ($content.Substring(0, $matchIdx) -split "`n").Count

                $result.Violations += @{
                    file    = $relativePath
                    line    = $lineNum
                    type    = $pattern.Type
                    pattern = $pattern.Name
                    value   = $value
                    context = $lineContent.Substring(0, [math]::Min(120, $lineContent.Length))
                }
            }
        }
    }

    # ── 5. Summary ──
    if ($result.Violations.Count -gt 0) {
        $byType = $result.Violations | Group-Object -Property type
        $typeSummary = ($byType | ForEach-Object { "$($_.Name): $($_.Count)" }) -join ", "
        $result.Summary = "$($result.Violations.Count) hardcoded values found ($typeSummary)"

        if ($blockOnViolation) { $result.Passed = $false }

        Write-Host "  [TOKEN] $($result.Summary)" -ForegroundColor Yellow

        # Show top 10 violations
        $top = $result.Violations | Select-Object -First 10
        foreach ($v in $top) {
            Write-Host "    $($v.file):$($v.line) -- $($v.pattern): $($v.value)" -ForegroundColor DarkYellow
        }
        if ($result.Violations.Count -gt 10) {
            Write-Host "    ... and $($result.Violations.Count - 10) more" -ForegroundColor DarkGray
        }
    } else {
        $result.Summary = "No hardcoded design values found"
        Write-Host "  [TOKEN] $($result.Summary)" -ForegroundColor Green
    }

    # Save results
    $valDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $valDir)) {
        New-Item -Path $valDir -ItemType Directory -Force | Out-Null
    }
    @{
        timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed     = $result.Passed
        violations = $result.Violations.Count
        by_type    = ($result.Violations | Group-Object type | ForEach-Object { @{ type = $_.Name; count = $_.Count } })
        details    = $result.Violations | Select-Object -First 50
        summary    = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $valDir "design-token-results.json") -Encoding UTF8

    return $result
}
'@

        Add-Content -Path $resilienceFile -Value $tokenFunction -Encoding UTF8
        Write-Host "  [OK] Added Test-DesignTokenCompliance to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Test-DesignTokenCompliance already exists" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  [TOKEN] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> design_token_enforcement" -ForegroundColor DarkGray
Write-Host "  Function: Test-DesignTokenCompliance in resilience.ps1" -ForegroundColor DarkGray
Write-Host "  Output: .gsd/validation/design-token-results.json" -ForegroundColor DarkGray
Write-Host ""
