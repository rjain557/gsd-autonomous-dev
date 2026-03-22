<#
.SYNOPSIS
    GSD V3 Figma Requirement Deriver - Extracts implementation requirements from Figma analysis files.
.DESCRIPTION
    Scans for Figma analysis files in design/**/src/_analysis/ folders and derives
    concrete implementation requirements for screens, components, routes, API calls,
    and design system tokens. Pure file parsing — NO LLM calls.

    Derived requirement categories:
    - figma-screen: One per screen from 01-screen-inventory.md
    - figma-component: One per reusable component from 02-component-inventory.md
    - figma-route: One per route from 04-navigation-routing.md
    - figma-api: One per API endpoint from 06-api-contracts.md
    - figma-design-system: Design tokens, theme provider, CSS variables from 03-design-system.md
#>

# ============================================================
# CONSTANTS
# ============================================================

$script:FigmaAnalysisFiles = @{
    ScreenInventory   = '01-screen-inventory.md'
    ComponentInventory = '02-component-inventory.md'
    DesignSystem      = '03-design-system.md'
    NavigationRouting  = '04-navigation-routing.md'
    ApiContracts      = '06-api-contracts.md'
}

# ============================================================
# HELPER: Find all _analysis directories under design/
# ============================================================

function Find-FigmaAnalysisDirs {
    param([string]$RepoRoot)

    $analysisDirs = @()

    # Pattern 1: design/{interface}/src/_analysis/
    $designDir = Join-Path $RepoRoot 'design'
    if (Test-Path $designDir) {
        $found = Get-ChildItem -Path $designDir -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq '_analysis' }
        if ($found) { $analysisDirs += $found }
    }

    # Pattern 2: {interface}/_analysis/ (flat structure)
    $topDirs = Get-ChildItem -Path $RepoRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('node_modules', '.git', '.gsd', 'dist', 'build', 'bin', 'obj') }
    foreach ($dir in $topDirs) {
        $analysisPath = Join-Path $dir.FullName '_analysis'
        if (Test-Path $analysisPath) {
            $existing = $analysisDirs | Where-Object { $_.FullName -eq $analysisPath }
            if (-not $existing) {
                $analysisDirs += Get-Item $analysisPath
            }
        }
        # Also check src/_analysis/
        $srcAnalysis = Join-Path $dir.FullName 'src/_analysis'
        if (Test-Path $srcAnalysis) {
            $existing = $analysisDirs | Where-Object { $_.FullName -eq $srcAnalysis }
            if (-not $existing) {
                $analysisDirs += Get-Item $srcAnalysis
            }
        }
    }

    return $analysisDirs
}

# ============================================================
# HELPER: Infer interface name from analysis directory path
# ============================================================

function Get-InterfaceFromPath {
    param([string]$AnalysisDir, [string]$RepoRoot)

    $relative = $AnalysisDir
    if ($AnalysisDir.StartsWith($RepoRoot)) {
        $relative = $AnalysisDir.Substring($RepoRoot.Length).TrimStart('\', '/')
    }

    # design/web/src/_analysis -> web
    # design/mcp-admin/src/_analysis -> mcp-admin
    # web/_analysis -> web
    $parts = $relative -split '[/\\]'
    foreach ($part in $parts) {
        if ($part -notin @('design', 'src', '_analysis', '')) {
            return $part.ToUpper()
        }
    }
    return 'WEB'
}

# ============================================================
# PARSER: 01-screen-inventory.md
# ============================================================

function Parse-ScreenInventory {
    param([string]$FilePath, [string]$Interface)

    $reqs = @()
    if (-not (Test-Path $FilePath)) { return $reqs }

    $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) { return $reqs }

    $counter = 1

    # Strategy 1: Parse markdown tables — look for rows with | separators
    $lines = $content -split "`n"
    $inTable = $false
    $headerCols = @()

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # Detect table header row
        if ($trimmed -match '^\|.*Screen.*\|' -or $trimmed -match '^\|.*Name.*\|.*Route.*\|') {
            $inTable = $true
            $headerCols = ($trimmed -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne '' }
            continue
        }

        # Skip separator rows
        if ($trimmed -match '^\|[\s\-:]+\|') { continue }

        # Parse table data rows
        if ($inTable -and $trimmed -match '^\|') {
            $cells = ($trimmed -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne '' }
            if ($cells.Count -ge 1) {
                $screenName = $cells[0] -replace '[`*]', ''
                $route = if ($cells.Count -ge 2) { ($cells[1] -replace '[`*]', '').Trim() } else { '' }

                if ($screenName -and $screenName -notmatch '^[-\s]+$') {
                    $id = "FIGMA-$Interface-SCR-$($counter.ToString('000'))"
                    $reqs += [PSCustomObject]@{
                        id                  = $id
                        description         = "Screen '$screenName' must be implemented as a React component$(if ($route) { " at route $route" }) with all states (loading, error, empty, data)"
                        category            = 'figma-screen'
                        interface           = $Interface.ToLower()
                        priority            = 'high'
                        status              = 'not_started'
                        source              = 'figma-analysis'
                        acceptance_criteria = @(
                            "A .tsx file exists implementing the $screenName screen"
                            "The screen handles loading, error, and empty data states"
                            "The screen uses real API calls (no mock data, no hardcoded arrays)"
                            $(if ($route) { "The screen is routed at $route in App.tsx or router config" } else { "The screen is accessible via routing" })
                        )
                        figma_source        = '01-screen-inventory.md'
                        screen_name         = $screenName
                        route               = $route
                    }
                    $counter++
                }
            }
            continue
        }

        # End table on empty line or non-table content
        if ($inTable -and $trimmed -eq '') { $inTable = $false }
    }

    # Strategy 2: Parse ## or ### headers with screen names (if no table found)
    if ($reqs.Count -eq 0) {
        $headerMatches = [regex]::Matches($content, '(?m)^#{2,3}\s+(.+?)(?:\s*\{.*\})?\s*$')
        foreach ($hm in $headerMatches) {
            $screenName = $hm.Groups[1].Value.Trim() -replace '[`*]', ''
            # Skip generic headers
            if ($screenName -match '^(Screen Inventory|Overview|Summary|Introduction|Table of Contents|Notes)$') { continue }

            # Try to find a route near this header
            $afterHeader = $content.Substring($hm.Index + $hm.Length)
            $routeMatch = [regex]::Match($afterHeader, '(?m)(?:route|path|url)\s*[:=]\s*[`"'']?(/[\w\-/{}:*]+)')
            $route = if ($routeMatch.Success) { $routeMatch.Groups[1].Value } else { '' }

            $id = "FIGMA-$Interface-SCR-$($counter.ToString('000'))"
            $reqs += [PSCustomObject]@{
                id                  = $id
                description         = "Screen '$screenName' must be implemented as a React component$(if ($route) { " at route $route" }) with all states (loading, error, empty, data)"
                category            = 'figma-screen'
                interface           = $Interface.ToLower()
                priority            = 'high'
                status              = 'not_started'
                source              = 'figma-analysis'
                acceptance_criteria = @(
                    "A .tsx file exists implementing the $screenName screen"
                    "The screen handles loading, error, and empty data states"
                    "The screen uses real API calls (no mock data, no hardcoded arrays)"
                    $(if ($route) { "The screen is routed at $route in App.tsx or router config" } else { "The screen is accessible via routing" })
                )
                figma_source        = '01-screen-inventory.md'
                screen_name         = $screenName
                route               = $route
            }
            $counter++
        }
    }

    return $reqs
}

# ============================================================
# PARSER: 02-component-inventory.md
# ============================================================

function Parse-ComponentInventory {
    param([string]$FilePath, [string]$Interface)

    $reqs = @()
    if (-not (Test-Path $FilePath)) { return $reqs }

    $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) { return $reqs }

    $counter = 1
    $componentNames = @()

    # Strategy 1: Parse table rows
    $lines = $content -split "`n"
    $inTable = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^\|.*Component.*\|' -or $trimmed -match '^\|.*Name.*\|') {
            $inTable = $true
            continue
        }
        if ($trimmed -match '^\|[\s\-:]+\|') { continue }

        if ($inTable -and $trimmed -match '^\|') {
            $cells = ($trimmed -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne '' }
            if ($cells.Count -ge 1) {
                $compName = $cells[0] -replace '[`*<>]', '' -replace '\s*\(.*\)', ''
                if ($compName -and $compName -notmatch '^[-\s]+$' -and $compName -notin $componentNames) {
                    $componentNames += $compName
                }
            }
            continue
        }

        if ($inTable -and $trimmed -eq '') { $inTable = $false }
    }

    # Strategy 2: Parse ## or ### headers
    if ($componentNames.Count -eq 0) {
        $headerMatches = [regex]::Matches($content, '(?m)^#{2,3}\s+(.+?)(?:\s*\{.*\})?\s*$')
        foreach ($hm in $headerMatches) {
            $compName = $hm.Groups[1].Value.Trim() -replace '[`*<>]', '' -replace '\s*\(.*\)', ''
            if ($compName -match '^(Component Inventory|Overview|Summary|Introduction|Table of Contents|Notes|Props|Usage|API)$') { continue }
            if ($compName -notin $componentNames) {
                $componentNames += $compName
            }
        }
    }

    # Strategy 3: Look for component names in backtick code spans
    if ($componentNames.Count -eq 0) {
        $codeSpanMatches = [regex]::Matches($content, '`<?([\w]+)>?`')
        foreach ($csm in $codeSpanMatches) {
            $compName = $csm.Groups[1].Value
            # Filter: must be PascalCase (component naming convention)
            if ($compName -cmatch '^[A-Z][a-zA-Z0-9]+$' -and $compName -notin $componentNames) {
                $componentNames += $compName
            }
        }
    }

    foreach ($compName in $componentNames) {
        $id = "FIGMA-$Interface-CMP-$($counter.ToString('000'))"
        $reqs += [PSCustomObject]@{
            id                  = $id
            description         = "Component '$compName' must be implemented as a reusable React component matching Figma spec"
            category            = 'figma-component'
            interface           = $Interface.ToLower()
            priority            = 'medium'
            status              = 'not_started'
            source              = 'figma-analysis'
            acceptance_criteria = @(
                "A .tsx file exists implementing the $compName component"
                "The component accepts typed props (TypeScript interface)"
                "The component uses design tokens (no hardcoded colors/spacing)"
                "The component is exported and importable"
            )
            figma_source        = '02-component-inventory.md'
            component_name      = $compName
        }
        $counter++
    }

    return $reqs
}

# ============================================================
# PARSER: 04-navigation-routing.md
# ============================================================

function Parse-NavigationRouting {
    param([string]$FilePath, [string]$Interface)

    $reqs = @()
    if (-not (Test-Path $FilePath)) { return $reqs }

    $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) { return $reqs }

    $counter = 1
    $routePaths = @()

    # Strategy 1: Extract routes from tables
    $lines = $content -split "`n"
    $inTable = $false

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^\|.*(?:Route|Path|URL).*\|') {
            $inTable = $true
            continue
        }
        if ($trimmed -match '^\|[\s\-:]+\|') { continue }

        if ($inTable -and $trimmed -match '^\|') {
            $cells = ($trimmed -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne '' }
            foreach ($cell in $cells) {
                $cleanCell = $cell -replace '[`*]', ''
                if ($cleanCell -match '^/[\w\-/{}:*]+') {
                    $routePath = $Matches[0]
                    if ($routePath -notin $routePaths) {
                        $routePaths += $routePath
                    }
                }
            }
            continue
        }

        if ($inTable -and $trimmed -eq '') { $inTable = $false }
    }

    # Strategy 2: Extract routes from code blocks
    $codeBlockMatches = [regex]::Matches($content, '(?m)[`"'']+(\/[\w\-/{}:*]+)[`"'']+')
    foreach ($cbm in $codeBlockMatches) {
        $routePath = $cbm.Groups[1].Value
        if ($routePath -notin $routePaths -and $routePath -ne '/') {
            $routePaths += $routePath
        }
    }

    # Strategy 3: Extract routes from bullet points or plain text
    $inlineRouteMatches = [regex]::Matches($content, '(?:route|path|url|navigate)\s*[:=]\s*[`"'']?(\/[\w\-/{}:*]+)')
    foreach ($irm in $inlineRouteMatches) {
        $routePath = $irm.Groups[1].Value
        if ($routePath -notin $routePaths -and $routePath -ne '/') {
            $routePaths += $routePath
        }
    }

    foreach ($routePath in $routePaths) {
        $id = "FIGMA-$Interface-RTE-$($counter.ToString('000'))"
        $reqs += [PSCustomObject]@{
            id                  = $id
            description         = "Route '$routePath' must be implemented in App.tsx routing configuration"
            category            = 'figma-route'
            interface           = $Interface.ToLower()
            priority            = 'high'
            status              = 'not_started'
            source              = 'figma-analysis'
            acceptance_criteria = @(
                "App.tsx (or router config) contains a <Route> for $routePath"
                "The route renders a page component (not a placeholder or empty div)"
                "Navigation to $routePath works without errors"
            )
            figma_source        = '04-navigation-routing.md'
            route_path          = $routePath
        }
        $counter++
    }

    return $reqs
}

# ============================================================
# PARSER: 06-api-contracts.md
# ============================================================

function Parse-ApiContracts {
    param([string]$FilePath, [string]$Interface)

    $reqs = @()
    if (-not (Test-Path $FilePath)) { return $reqs }

    $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) { return $reqs }

    $counter = 1
    $endpoints = @()

    # Strategy 1: Match HTTP method + path patterns (GET /api/xxx, POST /api/xxx, etc.)
    $httpMethodPattern = '(?i)(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+[`"'']?(\/[\w\-/{}:.*]+)[`"'']?'
    $httpMatches = [regex]::Matches($content, $httpMethodPattern)
    foreach ($hm in $httpMatches) {
        $method = $hm.Groups[1].Value.ToUpper()
        $path = $hm.Groups[2].Value
        $key = "$method $path"
        if ($key -notin $endpoints) {
            $endpoints += $key
        }
    }

    # Strategy 2: Parse from table rows (| Method | Endpoint | ...)
    $lines = $content -split "`n"
    $inTable = $false
    $methodCol = -1
    $pathCol = -1

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^\|.*(?:Method|HTTP).*\|.*(?:Endpoint|Path|URL).*\|') {
            $inTable = $true
            $cols = ($trimmed -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne '' }
            for ($i = 0; $i -lt $cols.Count; $i++) {
                if ($cols[$i] -match '(?i)method|http') { $methodCol = $i }
                if ($cols[$i] -match '(?i)endpoint|path|url') { $pathCol = $i }
            }
            continue
        }
        if ($trimmed -match '^\|[\s\-:]+\|') { continue }

        if ($inTable -and $trimmed -match '^\|') {
            $cells = ($trimmed -split '\|' | ForEach-Object { $_.Trim() }) | Where-Object { $_ -ne '' }
            $method = if ($methodCol -ge 0 -and $methodCol -lt $cells.Count) { $cells[$methodCol] -replace '[`*]', '' } else { '' }
            $path = if ($pathCol -ge 0 -and $pathCol -lt $cells.Count) { $cells[$pathCol] -replace '[`*]', '' } else { '' }

            if ($method -match '(?i)^(GET|POST|PUT|PATCH|DELETE)$' -and $path -match '^/') {
                $key = "$($method.ToUpper()) $path"
                if ($key -notin $endpoints) {
                    $endpoints += $key
                }
            }
            continue
        }

        if ($inTable -and $trimmed -eq '') { $inTable = $false; $methodCol = -1; $pathCol = -1 }
    }

    foreach ($endpoint in $endpoints) {
        $parts = $endpoint -split '\s+', 2
        $method = $parts[0]
        $path = $parts[1]

        $id = "FIGMA-$Interface-API-$($counter.ToString('000'))"
        $reqs += [PSCustomObject]@{
            id                  = $id
            description         = "API endpoint $method $path must be called from the frontend (no mock data, no stubs)"
            category            = 'figma-api'
            interface           = $Interface.ToLower()
            priority            = 'critical'
            status              = 'not_started'
            source              = 'figma-analysis'
            acceptance_criteria = @(
                "Frontend code contains a service/hook that calls $method $path"
                "The call uses apiClient, fetch, or axios (not hardcoded mock data)"
                "No 'const mock' or '// FILL' or '// TODO' patterns in the calling code"
                "Response data is properly typed with TypeScript interfaces"
            )
            figma_source        = '06-api-contracts.md'
            http_method         = $method
            api_path            = $path
        }
        $counter++
    }

    return $reqs
}

# ============================================================
# PARSER: 03-design-system.md
# ============================================================

function Parse-DesignSystem {
    param([string]$FilePath, [string]$Interface)

    $reqs = @()
    if (-not (Test-Path $FilePath)) { return $reqs }

    $content = Get-Content $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) { return $reqs }

    $counter = 1

    # Requirement: tokens.css / theme.css file
    $id = "FIGMA-$Interface-DS-$($counter.ToString('000'))"
    $reqs += [PSCustomObject]@{
        id                  = $id
        description         = "Design tokens CSS file must exist with all CSS custom properties from the design system"
        category            = 'figma-design-system'
        interface           = $Interface.ToLower()
        priority            = 'high'
        status              = 'not_started'
        source              = 'figma-analysis'
        acceptance_criteria = @(
            "A tokens.css, theme.css, or globals.css file exists with CSS custom properties"
            "Color tokens are defined as --color-* variables"
            "Typography tokens are defined as --font-size-* variables"
            "Spacing tokens are defined as --spacing-* variables"
        )
        figma_source        = '03-design-system.md'
    }
    $counter++

    # Requirement: ThemeProvider wraps app
    $id = "FIGMA-$Interface-DS-$($counter.ToString('000'))"
    $reqs += [PSCustomObject]@{
        id                  = $id
        description         = "ThemeProvider must wrap the entire app tree in the entry point (App.tsx or main.tsx)"
        category            = 'figma-design-system'
        interface           = $Interface.ToLower()
        priority            = 'high'
        status              = 'not_started'
        source              = 'figma-analysis'
        acceptance_criteria = @(
            "App.tsx or main.tsx contains a ThemeProvider (or equivalent) wrapping the app"
            "The provider loads tokens from a central theme file"
        )
        figma_source        = '03-design-system.md'
    }
    $counter++

    # Check for dark mode mention
    if ($content -match '(?i)dark\s*(mode|theme)') {
        $id = "FIGMA-$Interface-DS-$($counter.ToString('000'))"
        $reqs += [PSCustomObject]@{
            id                  = $id
            description         = "Dark mode must be implemented with CSS variable overrides in a .dark class or prefers-color-scheme"
            category            = 'figma-design-system'
            interface           = $Interface.ToLower()
            priority            = 'medium'
            status              = 'not_started'
            source              = 'figma-analysis'
            acceptance_criteria = @(
                "CSS contains .dark { } block or prefers-color-scheme: dark media query"
                "All color tokens have dark mode overrides"
                "A toggle mechanism exists for switching themes"
            )
            figma_source        = '03-design-system.md'
        }
        $counter++
    }

    # Check for elevation/shadow definitions
    if ($content -match '(?i)(elevation|shadow|box-shadow)') {
        $id = "FIGMA-$Interface-DS-$($counter.ToString('000'))"
        $reqs += [PSCustomObject]@{
            id                  = $id
            description         = "Elevation/shadow tokens must be defined as CSS custom properties (--shadow-sm, --shadow-md, --shadow-lg)"
            category            = 'figma-design-system'
            interface           = $Interface.ToLower()
            priority            = 'medium'
            status              = 'not_started'
            source              = 'figma-analysis'
            acceptance_criteria = @(
                "Shadow tokens are defined as --shadow-* CSS custom properties"
                "Components use var(--shadow-*) instead of hardcoded box-shadow values"
            )
            figma_source        = '03-design-system.md'
        }
        $counter++
    }

    # Check for border-radius
    if ($content -match '(?i)border[- ]?radius') {
        $id = "FIGMA-$Interface-DS-$($counter.ToString('000'))"
        $reqs += [PSCustomObject]@{
            id                  = $id
            description         = "Border radius tokens must be defined as CSS custom properties (--radius-sm, --radius-md, --radius-lg)"
            category            = 'figma-design-system'
            interface           = $Interface.ToLower()
            priority            = 'medium'
            status              = 'not_started'
            source              = 'figma-analysis'
            acceptance_criteria = @(
                "Border radius tokens are defined as --radius-* CSS custom properties"
                "Components use var(--radius-*) instead of hardcoded border-radius values"
            )
            figma_source        = '03-design-system.md'
        }
        $counter++
    }

    return $reqs
}

# ============================================================
# MAIN FUNCTION: Invoke-FigmaRequirementDerivation
# ============================================================

function Invoke-FigmaRequirementDerivation {
    <#
    .SYNOPSIS
        Derives implementation requirements from Figma analysis files.
    .DESCRIPTION
        Scans for Figma analysis markdown files in the repo, parses screens,
        components, routes, API contracts, and design system specs, then merges
        derived requirements into the requirements matrix. Pure file parsing,
        zero LLM calls.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER GsdDir
        Path to the .gsd directory. Defaults to RepoRoot/.gsd.
    .PARAMETER Config
        Global configuration object.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [string]$GsdDir,

        [object]$Config
    )

    if (-not $GsdDir) {
        $GsdDir = Join-Path $RepoRoot '.gsd'
    }

    $RepoRoot = $RepoRoot.TrimEnd('\', '/')

    Write-Host "  [FIGMA-DERIVE] Scanning for Figma analysis files..." -ForegroundColor Cyan

    # ── Find analysis directories ──
    $analysisDirs = @(Find-FigmaAnalysisDirs -RepoRoot $RepoRoot)

    if ($analysisDirs.Count -eq 0) {
        Write-Host "  [FIGMA-DERIVE] No _analysis directories found -- skipping" -ForegroundColor DarkGray
        return @{
            DerivedCount = 0
            MergedCount  = 0
            Skipped      = $true
            Interfaces   = @()
        }
    }

    Write-Host "  [FIGMA-DERIVE] Found $($analysisDirs.Count) analysis directories" -ForegroundColor DarkCyan

    # ── Parse all analysis files ──
    $allDerived = @()

    foreach ($analysisDir in $analysisDirs) {
        $interface = Get-InterfaceFromPath -AnalysisDir $analysisDir.FullName -RepoRoot $RepoRoot
        Write-Host "  [FIGMA-DERIVE] Processing interface: $interface ($($analysisDir.FullName))" -ForegroundColor DarkCyan

        # Screen inventory
        $screenFile = Join-Path $analysisDir.FullName $script:FigmaAnalysisFiles.ScreenInventory
        $screens = @(Parse-ScreenInventory -FilePath $screenFile -Interface $interface)
        if ($screens.Count -gt 0) {
            Write-Host "    Screens: $($screens.Count)" -ForegroundColor DarkGray
            $allDerived += $screens
        }

        # Component inventory
        $componentFile = Join-Path $analysisDir.FullName $script:FigmaAnalysisFiles.ComponentInventory
        $components = @(Parse-ComponentInventory -FilePath $componentFile -Interface $interface)
        if ($components.Count -gt 0) {
            Write-Host "    Components: $($components.Count)" -ForegroundColor DarkGray
            $allDerived += $components
        }

        # Design system
        $dsFile = Join-Path $analysisDir.FullName $script:FigmaAnalysisFiles.DesignSystem
        $dsReqs = @(Parse-DesignSystem -FilePath $dsFile -Interface $interface)
        if ($dsReqs.Count -gt 0) {
            Write-Host "    Design system: $($dsReqs.Count)" -ForegroundColor DarkGray
            $allDerived += $dsReqs
        }

        # Navigation / routing
        $routeFile = Join-Path $analysisDir.FullName $script:FigmaAnalysisFiles.NavigationRouting
        $routes = @(Parse-NavigationRouting -FilePath $routeFile -Interface $interface)
        if ($routes.Count -gt 0) {
            Write-Host "    Routes: $($routes.Count)" -ForegroundColor DarkGray
            $allDerived += $routes
        }

        # API contracts
        $apiFile = Join-Path $analysisDir.FullName $script:FigmaAnalysisFiles.ApiContracts
        $apis = @(Parse-ApiContracts -FilePath $apiFile -Interface $interface)
        if ($apis.Count -gt 0) {
            Write-Host "    API endpoints: $($apis.Count)" -ForegroundColor DarkGray
            $allDerived += $apis
        }
    }

    if ($allDerived.Count -eq 0) {
        Write-Host "  [FIGMA-DERIVE] No requirements derived from analysis files" -ForegroundColor DarkGray
        return @{
            DerivedCount = 0
            MergedCount  = 0
            Skipped      = $false
            Interfaces   = @($analysisDirs | ForEach-Object { Get-InterfaceFromPath -AnalysisDir $_.FullName -RepoRoot $RepoRoot })
        }
    }

    Write-Host "  [FIGMA-DERIVE] Derived $($allDerived.Count) total requirements" -ForegroundColor Cyan

    # ── Merge into requirements matrix ──
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    $mergedCount = 0

    if (Test-Path $matrixPath) {
        $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
        $reqs = [System.Collections.ArrayList]@($matrix.requirements)

        foreach ($derived in $allDerived) {
            # Check for duplicate by ID
            $existing = $reqs | Where-Object { ($_.id -eq $derived.id) -or ($_.req_id -eq $derived.id) }
            if ($existing) { continue }

            # Check for semantic duplicate (same category + similar description)
            $semanticDup = $false
            foreach ($existingReq in $reqs) {
                $existingDesc = if ($existingReq.description) { $existingReq.description } else { '' }
                # For screens: check if screen name is already covered
                if ($derived.category -eq 'figma-screen' -and $derived.screen_name) {
                    if ($existingDesc -match [regex]::Escape($derived.screen_name)) {
                        $semanticDup = $true
                        break
                    }
                }
                # For routes: check if route path is already covered
                if ($derived.category -eq 'figma-route' -and $derived.route_path) {
                    if ($existingDesc -match [regex]::Escape($derived.route_path)) {
                        $semanticDup = $true
                        break
                    }
                }
                # For APIs: check if endpoint is already covered
                if ($derived.category -eq 'figma-api' -and $derived.http_method -and $derived.api_path) {
                    if ($existingDesc -match [regex]::Escape($derived.api_path) -and $existingDesc -match $derived.http_method) {
                        $semanticDup = $true
                        break
                    }
                }
            }
            if ($semanticDup) { continue }

            $reqs.Add($derived) | Out-Null
            $mergedCount++
        }

        if ($mergedCount -gt 0) {
            $matrix.requirements = $reqs.ToArray()
            # Update totals
            if ($matrix.PSObject.Properties.Name -contains 'total') {
                $matrix.total = $reqs.Count
            } else {
                $matrix | Add-Member -NotePropertyName 'total' -NotePropertyValue $reqs.Count -Force
            }
            if ($matrix.PSObject.Properties.Name -contains 'summary') {
                $matrix.summary.satisfied = @($reqs | Where-Object { $_.status -eq "satisfied" }).Count
                $matrix.summary.partial = @($reqs | Where-Object { $_.status -eq "partial" }).Count
                $matrix.summary.not_started = @($reqs | Where-Object { $_.status -eq "not_started" }).Count
            }
            $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
            Write-Host "  [FIGMA-DERIVE] Merged $mergedCount new requirements into matrix (total: $($reqs.Count))" -ForegroundColor Green
        } else {
            Write-Host "  [FIGMA-DERIVE] All $($allDerived.Count) derived requirements already exist in matrix" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [FIGMA-DERIVE] No requirements-matrix.json found at $matrixPath -- cannot merge" -ForegroundColor DarkYellow
    }

    # ── Save Figma requirements report ──
    $figmaDir = Join-Path $GsdDir 'figma'
    if (-not (Test-Path $figmaDir)) {
        New-Item -Path $figmaDir -ItemType Directory -Force | Out-Null
    }

    $report = @{
        timestamp          = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        total_derived      = $allDerived.Count
        total_merged       = $mergedCount
        interfaces         = @($analysisDirs | ForEach-Object { Get-InterfaceFromPath -AnalysisDir $_.FullName -RepoRoot $RepoRoot }) | Select-Object -Unique
        by_category        = @{
            screens       = @($allDerived | Where-Object { $_.category -eq 'figma-screen' }).Count
            components    = @($allDerived | Where-Object { $_.category -eq 'figma-component' }).Count
            routes        = @($allDerived | Where-Object { $_.category -eq 'figma-route' }).Count
            api_endpoints = @($allDerived | Where-Object { $_.category -eq 'figma-api' }).Count
            design_system = @($allDerived | Where-Object { $_.category -eq 'figma-design-system' }).Count
        }
        requirements       = $allDerived
    }

    $reportPath = Join-Path $figmaDir 'figma-requirements-report.json'
    $report | ConvertTo-Json -Depth 10 | Set-Content $reportPath -Encoding UTF8
    Write-Host "  [FIGMA-DERIVE] Report saved to: $reportPath" -ForegroundColor DarkGray

    return @{
        DerivedCount = $allDerived.Count
        MergedCount  = $mergedCount
        Skipped      = $false
        Interfaces   = $report.interfaces
        Report       = $report
    }
}
