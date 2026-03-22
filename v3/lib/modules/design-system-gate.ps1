<#
.SYNOPSIS
    GSD V3 Design System Gate - FREE frontend design drift detection.
.DESCRIPTION
    Runs between Local Validation and Review to catch design system violations
    before spending tokens on expensive LLM review. Pure regex/file scanning,
    zero LLM calls.

    Checks:
    1. Hardcoded Color Scan - hex, rgb(), rgba(), hsl() outside CSS variables
    2. Theme Provider Check - ThemeProvider/FluentProvider wrapping app tree
    3. Design Token Completeness - tokens defined in design files vs CSS custom props
    4. CSS Variable Usage Ratio - var(--*) vs hardcoded values (target: 80%)
    5. Responsive Design Check - Tailwind responsive prefixes in components
    6. Dark Mode Support - .dark classes and dark: prefixes if design specifies it
#>

# ============================================================
# CONSTANTS
# ============================================================

$script:AllowedRawColors = @(
    '#000', '#fff', '#000000', '#ffffff',
    'transparent', 'inherit', 'currentColor'
)

$script:ScanExtensions = @('.css', '.scss', '.tsx', '.jsx', '.ts')

$script:ExcludeDirPatterns = @(
    '*\node_modules\*', '*\bin\*', '*\obj\*',
    '*\dist\*', '*\build\*', '*\.gsd\*',
    '*\.next\*', '*\coverage\*', '*\.git\*'
)

# ============================================================
# HELPER: Get scannable frontend files
# ============================================================

function Get-FrontendFiles {
    param(
        [string]$RepoRoot,
        [string[]]$Extensions
    )

    $files = @()
    foreach ($ext in $Extensions) {
        $found = Get-ChildItem -Path $RepoRoot -Filter "*$ext" -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $path = $_.FullName
                $excluded = $false
                foreach ($pattern in $script:ExcludeDirPatterns) {
                    if ($path -like $pattern) { $excluded = $true; break }
                }
                if ($_.Name -like '*.min.*' -or $_.Name -like '*.bundle.*') { $excluded = $true }
                -not $excluded
            }
        if ($found) { $files += $found }
    }
    return $files
}

# ============================================================
# HELPER: Get line number from string index
# ============================================================

function Get-LineNumber {
    param([string]$Content, [int]$Index)
    if ($Index -le 0) { return 1 }
    return ($Content.Substring(0, [Math]::Min($Index, $Content.Length)) -split "`n").Count
}

# ============================================================
# HELPER: Get line content from string index
# ============================================================

function Get-LineContent {
    param([string]$Content, [int]$Index)
    $lineStart = $Content.LastIndexOf("`n", [Math]::Max(0, $Index - 1)) + 1
    $lineEnd = $Content.IndexOf("`n", $Index)
    if ($lineEnd -lt 0) { $lineEnd = $Content.Length }
    $line = $Content.Substring($lineStart, $lineEnd - $lineStart).Trim()
    return $line.Substring(0, [Math]::Min(200, $line.Length))
}

# ============================================================
# CHECK 1: Hardcoded Color Scan
# ============================================================

function Test-HardcodedColors {
    param(
        [string]$RepoRoot,
        [System.IO.FileInfo[]]$Files
    )

    $violations = @()
    $hexPattern = '#[0-9a-fA-F]{3,8}\b'
    $rgbPattern = 'rgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+'
    $hslPattern = 'hsla?\(\s*\d+(?:\.\d+)?\s*(?:deg|rad|turn)?\s*,\s*\d+(?:\.\d+)?%'

    foreach ($file in $Files) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $relativePath = $file.FullName
        if ($file.FullName.StartsWith($RepoRoot)) {
            $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        }

        $allMatches = @()
        $allMatches += [regex]::Matches($content, $hexPattern) | ForEach-Object { @{ Match = $_; Type = 'hex' } }
        $allMatches += [regex]::Matches($content, $rgbPattern) | ForEach-Object { @{ Match = $_; Type = 'rgb/rgba' } }
        $allMatches += [regex]::Matches($content, $hslPattern) | ForEach-Object { @{ Match = $_; Type = 'hsl/hsla' } }

        foreach ($item in $allMatches) {
            $m = $item.Match
            $value = $m.Value

            # Skip allowed raw colors
            $isAllowed = $false
            foreach ($allowed in $script:AllowedRawColors) {
                if ($value -eq $allowed) { $isAllowed = $true; break }
            }
            if ($isAllowed) { continue }

            # Get the line content for context checks
            $lineContent = Get-LineContent -Content $content -Index $m.Index

            # Skip CSS variable definitions (--var-name: #hex is OK)
            if ($lineContent -match '^\s*--[\w-]+\s*:') { continue }

            # Skip lines that are already using var()
            if ($lineContent -match 'var\(--') { continue }

            # Skip comments
            if ($lineContent -match '^\s*(//|/\*|\*)') { continue }

            # Skip SVG fill/stroke with simple colors (common pattern)
            # Keep the violation but mark as info severity

            $lineNum = Get-LineNumber -Content $content -Index $m.Index
            $severity = 'warning'

            # Blocking if in a component file (.tsx/.jsx) with inline style
            if ($file.Extension -in @('.tsx', '.jsx') -and $lineContent -match 'style\s*=') {
                $severity = 'blocking'
            }

            $violations += @{
                check      = 'hardcoded-color'
                severity   = $severity
                file       = $relativePath
                line       = $lineNum
                message    = "Hardcoded $($item.Type) color: $value"
                suggestion = "Replace with a CSS variable, e.g., var(--color-name)"
                value      = $value
            }
        }
    }

    return $violations
}

# ============================================================
# CHECK 2: Theme Provider Check
# ============================================================

function Test-ThemeProvider {
    param(
        [string]$RepoRoot,
        [System.IO.FileInfo[]]$Files
    )

    $violations = @()

    # Find App.tsx, main.tsx, App.jsx, main.jsx, index.tsx, _app.tsx (Next.js)
    $entryFiles = $Files | Where-Object {
        $_.Name -match '^(App|main|index|_app)\.(tsx|jsx)$'
    }

    if ($entryFiles.Count -eq 0) {
        # No React entry files found -- not a React project or non-standard structure
        return $violations
    }

    $themeProviderPatterns = @(
        'ThemeProvider',
        'FluentProvider',
        'MuiThemeProvider',
        'ChakraProvider',
        'MantineProvider',
        'StyledThemeProvider',
        'ThemeContext\.Provider',
        'CssVarsProvider',
        'NextThemesProvider',
        'ColorModeProvider'
    )

    $hasThemeProvider = $false
    $checkedFile = $null

    foreach ($file in $entryFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        foreach ($pattern in $themeProviderPatterns) {
            if ($content -match $pattern) {
                $hasThemeProvider = $true
                $checkedFile = $file
                break
            }
        }
        if ($hasThemeProvider) { break }
    }

    if (-not $hasThemeProvider -and $entryFiles.Count -gt 0) {
        $relativePath = $entryFiles[0].FullName
        if ($entryFiles[0].FullName.StartsWith($RepoRoot)) {
            $relativePath = $entryFiles[0].FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        }

        $violations += @{
            check      = 'theme-provider'
            severity   = 'warning'
            file       = $relativePath
            line       = 1
            message    = "No ThemeProvider found wrapping the app tree"
            suggestion = "Add a ThemeProvider (or equivalent) in your root component to centralize theme management"
        }
    }

    return $violations
}

# ============================================================
# CHECK 3: Design Token Completeness
# ============================================================

function Test-DesignTokenCompleteness {
    param(
        [string]$RepoRoot,
        [System.IO.FileInfo[]]$Files
    )

    $violations = @()

    # Look for design token sources
    $tokenPaths = @(
        (Join-Path $RepoRoot 'design\_analysis\design-tokens.json'),
        (Join-Path $RepoRoot '_analysis\design-tokens.json'),
        (Join-Path $RepoRoot 'design\_analysis\03-design-system.md'),
        (Join-Path $RepoRoot '_analysis\03-design-system.md'),
        (Join-Path $RepoRoot 'design\tokens\tokens.json'),
        (Join-Path $RepoRoot 'src\styles\tokens.json')
    )

    $tokenFile = $null
    $tokenContent = $null
    foreach ($tp in $tokenPaths) {
        if (Test-Path $tp) {
            $tokenContent = Get-Content $tp -Raw -ErrorAction SilentlyContinue
            $tokenFile = $tp
            break
        }
    }

    if (-not $tokenFile -or -not $tokenContent) {
        # No design tokens defined -- skip this check
        return $violations
    }

    # Extract expected CSS custom property names from the token file
    $expectedTokens = @()

    if ($tokenFile -like '*.json') {
        # Parse JSON token names -- look for keys that map to values
        try {
            $json = $tokenContent | ConvertFrom-Json
            # Flatten token names from JSON structure
            $props = $json.PSObject.Properties
            foreach ($prop in $props) {
                $name = $prop.Name
                # Convert camelCase/dot notation to CSS variable format
                $cssVar = "--$($name -replace '\.', '-' -replace '([a-z])([A-Z])', '$1-$2')".ToLower()
                $expectedTokens += $cssVar
            }
        } catch {
            # JSON parse failed -- skip
            return $violations
        }
    }
    elseif ($tokenFile -like '*.md') {
        # Extract token references from markdown -- look for --var-name patterns
        $mdMatches = [regex]::Matches($tokenContent, '--[\w][\w-]*')
        foreach ($m in $mdMatches) {
            if ($m.Value -notin $expectedTokens) {
                $expectedTokens += $m.Value
            }
        }
    }

    if ($expectedTokens.Count -eq 0) { return $violations }

    # Find CSS files that should define these tokens (index.css, globals.css, variables.css, theme.css)
    $cssDefFiles = $Files | Where-Object {
        $_.Name -match '^(index|globals|variables|theme|tokens|App)\.(css|scss)$'
    }

    if ($cssDefFiles.Count -eq 0) { return $violations }

    # Read all CSS definition files and collect defined custom properties
    $definedTokens = @()
    foreach ($cssFile in $cssDefFiles) {
        $cssContent = Get-Content $cssFile.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $cssContent) { continue }

        $defMatches = [regex]::Matches($cssContent, '--[\w][\w-]*(?=\s*:)')
        foreach ($dm in $defMatches) {
            if ($dm.Value -notin $definedTokens) {
                $definedTokens += $dm.Value
            }
        }
    }

    # Check for missing tokens
    $missingTokens = $expectedTokens | Where-Object { $_ -notin $definedTokens }

    if ($missingTokens.Count -gt 0) {
        $relativePath = $tokenFile
        if ($tokenFile.StartsWith($RepoRoot)) {
            $relativePath = $tokenFile.Substring($RepoRoot.Length).TrimStart('\', '/')
        }

        # Report up to 20 missing tokens individually, then summarize
        $reported = 0
        foreach ($missing in $missingTokens) {
            if ($reported -ge 20) {
                $violations += @{
                    check      = 'design-token-completeness'
                    severity   = 'info'
                    file       = $relativePath
                    line       = 0
                    message    = "... and $($missingTokens.Count - 20) more missing tokens"
                    suggestion = "Define all design tokens as CSS custom properties in your global stylesheet"
                }
                break
            }

            $violations += @{
                check      = 'design-token-completeness'
                severity   = 'warning'
                file       = $relativePath
                line       = 0
                message    = "Design token '$missing' defined in token file but not found in CSS"
                suggestion = "Add '$missing' to your global CSS (index.css/globals.css) as a custom property"
            }
            $reported++
        }
    }

    return $violations
}

# ============================================================
# CHECK 4: CSS Variable Usage Ratio
# ============================================================

function Test-CssVariableRatio {
    param(
        [string]$RepoRoot,
        [System.IO.FileInfo[]]$Files
    )

    $violations = @()
    $totalVarUsages = 0
    $totalHardcoded = 0

    # Only scan component files (tsx, jsx) and CSS/SCSS
    $componentFiles = $Files | Where-Object { $_.Extension -in @('.tsx', '.jsx', '.css', '.scss') }

    foreach ($file in $componentFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Count var(--*) usages
        $varMatches = [regex]::Matches($content, 'var\(--[\w-]+')
        $totalVarUsages += $varMatches.Count

        # Count hardcoded color values (hex, rgb, hsl) outside variable definitions and comments
        $lines = $content -split "`n"
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            # Skip comments and variable definitions
            if ($trimmed -match '^\s*(//|/\*|\*)') { continue }
            if ($trimmed -match '^\s*--[\w-]+\s*:') { continue }
            if ($trimmed -match 'var\(--') { continue }

            $hexCount = ([regex]::Matches($trimmed, '#[0-9a-fA-F]{3,8}\b')).Count
            $rgbCount = ([regex]::Matches($trimmed, 'rgba?\(')).Count
            $hslCount = ([regex]::Matches($trimmed, 'hsla?\(')).Count

            # Subtract allowed colors
            foreach ($allowed in $script:AllowedRawColors) {
                if ($trimmed -match [regex]::Escape($allowed)) { $hexCount-- }
            }
            if ($hexCount -lt 0) { $hexCount = 0 }

            $totalHardcoded += ($hexCount + $rgbCount + $hslCount)
        }
    }

    $totalReferences = $totalVarUsages + $totalHardcoded
    $ratio = if ($totalReferences -gt 0) { [Math]::Round(($totalVarUsages / $totalReferences) * 100, 1) } else { 100 }

    $stats = @{
        cssVarUsages    = $totalVarUsages
        hardcodedValues = $totalHardcoded
        totalReferences = $totalReferences
        ratio           = $ratio
    }

    if ($totalReferences -gt 0 -and $ratio -lt 80) {
        $violations += @{
            check      = 'css-variable-ratio'
            severity   = 'warning'
            file       = '(project-wide)'
            line       = 0
            message    = "CSS variable usage ratio is ${ratio}% (target: 80%). Found $totalVarUsages var() vs $totalHardcoded hardcoded values."
            suggestion = "Replace hardcoded color/spacing values with CSS custom properties for consistency"
        }
    }

    return @{ violations = $violations; stats = $stats }
}

# ============================================================
# CHECK 5: Responsive Design Check
# ============================================================

function Test-ResponsiveDesign {
    param(
        [string]$RepoRoot,
        [System.IO.FileInfo[]]$Files
    )

    $violations = @()

    # Detect if project uses Tailwind
    $tailwindConfig = @(
        (Join-Path $RepoRoot 'tailwind.config.js'),
        (Join-Path $RepoRoot 'tailwind.config.ts'),
        (Join-Path $RepoRoot 'tailwind.config.cjs'),
        (Join-Path $RepoRoot 'tailwind.config.mjs')
    )

    $usesTailwind = $false
    foreach ($tc in $tailwindConfig) {
        if (Test-Path $tc) { $usesTailwind = $true; break }
    }

    if (-not $usesTailwind) {
        # Also check package.json for tailwindcss dependency
        $pkgJson = Join-Path $RepoRoot 'package.json'
        if (Test-Path $pkgJson) {
            $pkg = Get-Content $pkgJson -Raw -ErrorAction SilentlyContinue
            if ($pkg -and $pkg -match 'tailwindcss') { $usesTailwind = $true }
        }
    }

    if (-not $usesTailwind) { return $violations }

    $responsivePrefixes = 'sm:|md:|lg:|xl:|2xl:'
    $componentFiles = $Files | Where-Object { $_.Extension -in @('.tsx', '.jsx') }

    foreach ($file in $componentFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Skip test files, stories, and utility files
        if ($file.Name -match '\.(test|spec|stories|story)\.(tsx|jsx)$') { continue }
        if ($file.Name -match '^(index|types|constants|utils)\.(tsx|jsx)$') { continue }

        # Check if file has className with Tailwind classes
        $hasClasses = $content -match 'className\s*='
        if (-not $hasClasses) { continue }

        # Check for responsive prefixes
        $hasResponsive = $content -match $responsivePrefixes
        if (-not $hasResponsive) {
            $relativePath = $file.FullName
            if ($file.FullName.StartsWith($RepoRoot)) {
                $relativePath = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
            }

            $violations += @{
                check      = 'responsive-design'
                severity   = 'info'
                file       = $relativePath
                line       = 0
                message    = "Component uses Tailwind classes but has no responsive prefixes (sm:, md:, lg:, xl:)"
                suggestion = "Consider adding responsive breakpoint classes for mobile-friendly layout"
            }
        }
    }

    return $violations
}

# ============================================================
# CHECK 6: Dark Mode Support
# ============================================================

function Test-DarkModeSupport {
    param(
        [string]$RepoRoot,
        [System.IO.FileInfo[]]$Files
    )

    $violations = @()

    # Check if design system specifies dark mode
    $designSpecPaths = @(
        (Join-Path $RepoRoot 'design\_analysis\03-design-system.md'),
        (Join-Path $RepoRoot '_analysis\03-design-system.md'),
        (Join-Path $RepoRoot 'design\_analysis\design-tokens.json'),
        (Join-Path $RepoRoot '_analysis\design-tokens.json')
    )

    $requiresDarkMode = $false
    foreach ($dp in $designSpecPaths) {
        if (Test-Path $dp) {
            $specContent = Get-Content $dp -Raw -ErrorAction SilentlyContinue
            if ($specContent -and $specContent -match '(?i)dark\s*(mode|theme)') {
                $requiresDarkMode = $true
                break
            }
        }
    }

    if (-not $requiresDarkMode) { return $violations }

    # Check CSS files for .dark class definitions or prefers-color-scheme
    $cssFiles = $Files | Where-Object { $_.Extension -in @('.css', '.scss') }
    $hasDarkCss = $false
    foreach ($file in $cssFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content -match '\.dark\s*\{' -or $content -match 'prefers-color-scheme:\s*dark' -or $content -match '\[data-theme\s*=\s*[''"]dark[''"]') {
            $hasDarkCss = $true
            break
        }
    }

    # Check Tailwind files for dark: prefix usage
    $hasDarkTailwind = $false
    $twFiles = $Files | Where-Object { $_.Extension -in @('.tsx', '.jsx') }
    foreach ($file in $twFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        if ($content -match 'dark:') {
            $hasDarkTailwind = $true
            break
        }
    }

    if (-not $hasDarkCss -and -not $hasDarkTailwind) {
        $violations += @{
            check      = 'dark-mode-support'
            severity   = 'warning'
            file       = '(project-wide)'
            line       = 0
            message    = "Design system specifies dark mode but no .dark CSS classes, prefers-color-scheme, or Tailwind dark: prefixes found"
            suggestion = "Implement dark mode using .dark class toggle, prefers-color-scheme media query, or Tailwind dark: prefix"
        }
    }

    return $violations
}

# ============================================================
# MAIN FUNCTION: Invoke-DesignSystemGate
# ============================================================

function Invoke-DesignSystemGate {
    <#
    .SYNOPSIS
        Run design system gate checks on a frontend project.
    .DESCRIPTION
        Zero-cost (no LLM) design drift detection. Runs between Local Validation
        and Review to catch design system violations before expensive review.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER GsdDir
        Path to the .gsd directory. Defaults to RepoRoot/.gsd.
    .PARAMETER Config
        Global configuration object.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$GsdDir,

        [object]$Config
    )

    # Default GsdDir
    if (-not $GsdDir) {
        $GsdDir = Join-Path $RepoRoot '.gsd'
    }

    # Normalize paths
    $RepoRoot = $RepoRoot.TrimEnd('\', '/')

    Write-Host "  [DESIGN-GATE] Starting design system gate..." -ForegroundColor Cyan

    # Result structure
    $result = @{
        passed     = $true
        violations = @()
        warnings   = @()
        stats      = @{
            filesScanned     = 0
            checksRun        = 0
            checksPassed     = 0
            checksFailed     = 0
            cssVariableRatio = 100
        }
    }

    # ── Gather frontend files ──
    $allFiles = @(Get-FrontendFiles -RepoRoot $RepoRoot -Extensions $script:ScanExtensions)

    if ($allFiles.Count -eq 0) {
        Write-Host "  [DESIGN-GATE] No frontend files found -- skipping (auto-pass)" -ForegroundColor DarkGray
        $result.stats.checksRun = 0
        Save-DesignGateReport -GsdDir $GsdDir -Result $result
        return $result
    }

    $result.stats.filesScanned = $allFiles.Count
    Write-Host "  [DESIGN-GATE] Scanning $($allFiles.Count) frontend files..." -ForegroundColor DarkCyan

    # ── Check 1: Hardcoded Colors ──
    $result.stats.checksRun++
    Write-Host "  [DESIGN-GATE] Check 1/6: Hardcoded color scan..." -ForegroundColor DarkCyan
    try {
        $colorViolations = @(Test-HardcodedColors -RepoRoot $RepoRoot -Files $allFiles)
        if ($colorViolations.Count -gt 0) {
            $result.violations += $colorViolations
            $result.stats.checksFailed++
            $blockingCount = ($colorViolations | Where-Object { $_.severity -eq 'blocking' }).Count
            if ($blockingCount -gt 0) { $result.passed = $false }
            Write-Host "    Found $($colorViolations.Count) hardcoded colors ($blockingCount blocking)" -ForegroundColor Yellow
        } else {
            $result.stats.checksPassed++
            Write-Host "    No hardcoded colors found" -ForegroundColor Green
        }
    } catch {
        Write-Host "    Error in hardcoded color scan: $_" -ForegroundColor DarkYellow
        $result.warnings += "Hardcoded color scan error: $_"
    }

    # ── Check 2: Theme Provider ──
    $result.stats.checksRun++
    Write-Host "  [DESIGN-GATE] Check 2/6: Theme provider check..." -ForegroundColor DarkCyan
    try {
        $themeViolations = @(Test-ThemeProvider -RepoRoot $RepoRoot -Files $allFiles)
        if ($themeViolations.Count -gt 0) {
            $result.violations += $themeViolations
            $result.stats.checksFailed++
            Write-Host "    No theme provider detected in app root" -ForegroundColor Yellow
        } else {
            $result.stats.checksPassed++
            Write-Host "    Theme provider OK" -ForegroundColor Green
        }
    } catch {
        Write-Host "    Error in theme provider check: $_" -ForegroundColor DarkYellow
        $result.warnings += "Theme provider check error: $_"
    }

    # ── Check 3: Design Token Completeness ──
    $result.stats.checksRun++
    Write-Host "  [DESIGN-GATE] Check 3/6: Design token completeness..." -ForegroundColor DarkCyan
    try {
        $tokenViolations = @(Test-DesignTokenCompleteness -RepoRoot $RepoRoot -Files $allFiles)
        if ($tokenViolations.Count -gt 0) {
            $result.violations += $tokenViolations
            $result.stats.checksFailed++
            Write-Host "    Found $($tokenViolations.Count) missing design tokens" -ForegroundColor Yellow
        } else {
            $result.stats.checksPassed++
            Write-Host "    Design tokens complete (or no token file found)" -ForegroundColor Green
        }
    } catch {
        Write-Host "    Error in token completeness check: $_" -ForegroundColor DarkYellow
        $result.warnings += "Token completeness check error: $_"
    }

    # ── Check 4: CSS Variable Usage Ratio ──
    $result.stats.checksRun++
    Write-Host "  [DESIGN-GATE] Check 4/6: CSS variable usage ratio..." -ForegroundColor DarkCyan
    try {
        $ratioResult = Test-CssVariableRatio -RepoRoot $RepoRoot -Files $allFiles
        $ratioViolations = @($ratioResult.violations)
        $result.stats.cssVariableRatio = $ratioResult.stats.ratio

        if ($ratioViolations.Count -gt 0) {
            $result.violations += $ratioViolations
            $result.stats.checksFailed++
            Write-Host "    CSS variable ratio: $($ratioResult.stats.ratio)% (below 80% target)" -ForegroundColor Yellow
        } else {
            $result.stats.checksPassed++
            Write-Host "    CSS variable ratio: $($ratioResult.stats.ratio)% (OK)" -ForegroundColor Green
        }

        # Merge detailed stats
        $result.stats.cssVarUsages = $ratioResult.stats.cssVarUsages
        $result.stats.hardcodedValues = $ratioResult.stats.hardcodedValues
    } catch {
        Write-Host "    Error in CSS variable ratio check: $_" -ForegroundColor DarkYellow
        $result.warnings += "CSS variable ratio check error: $_"
    }

    # ── Check 5: Responsive Design ──
    $result.stats.checksRun++
    Write-Host "  [DESIGN-GATE] Check 5/6: Responsive design check..." -ForegroundColor DarkCyan
    try {
        $responsiveViolations = @(Test-ResponsiveDesign -RepoRoot $RepoRoot -Files $allFiles)
        if ($responsiveViolations.Count -gt 0) {
            $result.violations += $responsiveViolations
            $result.stats.checksFailed++
            Write-Host "    Found $($responsiveViolations.Count) components without responsive classes" -ForegroundColor Yellow
        } else {
            $result.stats.checksPassed++
            Write-Host "    Responsive design OK (or project does not use Tailwind)" -ForegroundColor Green
        }
    } catch {
        Write-Host "    Error in responsive design check: $_" -ForegroundColor DarkYellow
        $result.warnings += "Responsive design check error: $_"
    }

    # ── Check 6: Dark Mode Support ──
    $result.stats.checksRun++
    Write-Host "  [DESIGN-GATE] Check 6/6: Dark mode support..." -ForegroundColor DarkCyan
    try {
        $darkModeViolations = @(Test-DarkModeSupport -RepoRoot $RepoRoot -Files $allFiles)
        if ($darkModeViolations.Count -gt 0) {
            $result.violations += $darkModeViolations
            $result.stats.checksFailed++
            Write-Host "    Dark mode required but not implemented" -ForegroundColor Yellow
        } else {
            $result.stats.checksPassed++
            Write-Host "    Dark mode OK (or not required)" -ForegroundColor Green
        }
    } catch {
        Write-Host "    Error in dark mode check: $_" -ForegroundColor DarkYellow
        $result.warnings += "Dark mode check error: $_"
    }

    # ── Summary ──
    $blockingCount = ($result.violations | Where-Object { $_.severity -eq 'blocking' }).Count
    $warningCount = ($result.violations | Where-Object { $_.severity -eq 'warning' }).Count
    $infoCount = ($result.violations | Where-Object { $_.severity -eq 'info' }).Count

    if ($blockingCount -gt 0) {
        $result.passed = $false
    }

    $summaryParts = @()
    if ($blockingCount -gt 0) { $summaryParts += "$blockingCount blocking" }
    if ($warningCount -gt 0) { $summaryParts += "$warningCount warnings" }
    if ($infoCount -gt 0) { $summaryParts += "$infoCount info" }

    if ($summaryParts.Count -gt 0) {
        $summaryText = $summaryParts -join ', '
        $color = if ($blockingCount -gt 0) { 'Red' } else { 'Yellow' }
        Write-Host "  [DESIGN-GATE] Result: $summaryText" -ForegroundColor $color
    } else {
        Write-Host "  [DESIGN-GATE] Result: All checks passed" -ForegroundColor Green
    }

    # ── Save report ──
    Save-DesignGateReport -GsdDir $GsdDir -Result $result

    return $result
}

# ============================================================
# HELPER: Save report to .gsd/design-system/
# ============================================================

function Save-DesignGateReport {
    param(
        [string]$GsdDir,
        [hashtable]$Result
    )

    try {
        $reportDir = Join-Path $GsdDir 'design-system'
        if (-not (Test-Path $reportDir)) {
            New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
        }

        $report = @{
            timestamp  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            passed     = $Result.passed
            stats      = $Result.stats
            violations = $Result.violations | Select-Object -First 100
            warnings   = $Result.warnings
            summary    = @{
                total    = $Result.violations.Count
                blocking = ($Result.violations | Where-Object { $_.severity -eq 'blocking' }).Count
                warning  = ($Result.violations | Where-Object { $_.severity -eq 'warning' }).Count
                info     = ($Result.violations | Where-Object { $_.severity -eq 'info' }).Count
            }
        }

        $reportPath = Join-Path $reportDir 'design-gate-report.json'
        $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8
        Write-Host "  [DESIGN-GATE] Report saved to: $reportPath" -ForegroundColor DarkGray
    } catch {
        Write-Host "  [DESIGN-GATE] Warning: Could not save report: $_" -ForegroundColor DarkYellow
    }
}
