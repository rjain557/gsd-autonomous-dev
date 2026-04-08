<#
.SYNOPSIS
    GSD V3 Figma Completeness Checker - Verifies Figma-derived requirements are satisfied.
.DESCRIPTION
    For each Figma-derived requirement in the requirements matrix, checks if it's actually
    implemented in the codebase. Pure file scanning — NO LLM calls.

    Checks:
    - Screen requirements: Does a .tsx file exist with the screen name? Is it routed?
    - Route requirements: Does App.tsx/router contain the route path?
    - API wiring: Do screen files call real APIs (not mock data)?
    - Component requirements: Does a .tsx file exist for the component?
    - Design system: Does CSS contain required variables? Does ThemeProvider wrap app?
#>

# ============================================================
# CONSTANTS
# ============================================================

$script:MockDataPatterns = @(
    'const\s+mock\w*\s*=\s*\[',           # const mockData = [...]
    'const\s+mock\w*\s*=\s*\{',           # const mockData = {...}
    'const\s+fake\w*\s*=\s*[\[\{]',       # const fakeData = [...]
    'const\s+dummy\w*\s*=\s*[\[\{]',      # const dummyData = [...]
    'const\s+sample\w*\s*=\s*[\[\{]',     # const sampleData = [...]
    'const\s+stub\w*\s*=\s*[\[\{]',       # const stubData = [...]
    'const\s+test\w*Data\s*=\s*[\[\{]',   # const testData = [...]
    'const\s+hardcoded\w*\s*=\s*[\[\{]'   # const hardcodedItems = [...]
)

$script:StubPatterns = @(
    '//\s*FILL',             # // FILL
    '//\s*TODO',             # // TODO
    '//\s*FIXME',            # // FIXME
    '//\s*PLACEHOLDER',      # // PLACEHOLDER
    '//\s*STUB',             # // STUB
    '//\s*HACK',             # // HACK
    'throw\s+new\s+Error\(\s*[''"]Not\s+implemented',  # throw new Error("Not implemented")
    'return\s+null\s*;?\s*//.*todo',                     # return null; // todo
    'placeholder\s*=\s*true'                             # placeholder = true
)

$script:ExcludeDirPatterns = @(
    '*\node_modules\*', '*\bin\*', '*\obj\*',
    '*\dist\*', '*\build\*', '*\.gsd\*',
    '*\.next\*', '*\coverage\*', '*\.git\*'
)

# ============================================================
# HELPER: Find .tsx/.jsx files in the repo
# ============================================================

function Get-ReactFiles {
    param([string]$RepoRoot)

    $files = Get-ChildItem -Path $RepoRoot -Filter "*.tsx" -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $path = $_.FullName
            $excluded = $false
            foreach ($pattern in $script:ExcludeDirPatterns) {
                if ($path -like $pattern) { $excluded = $true; break }
            }
            -not $excluded
        }

    # Also include .jsx
    $jsxFiles = Get-ChildItem -Path $RepoRoot -Filter "*.jsx" -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $path = $_.FullName
            $excluded = $false
            foreach ($pattern in $script:ExcludeDirPatterns) {
                if ($path -like $pattern) { $excluded = $true; break }
            }
            -not $excluded
        }

    $all = @()
    if ($files) { $all += $files }
    if ($jsxFiles) { $all += $jsxFiles }
    return $all
}

# ============================================================
# HELPER: Find routing files (App.tsx, router config, etc.)
# ============================================================

function Get-RoutingFiles {
    param([System.IO.FileInfo[]]$ReactFiles)

    return $ReactFiles | Where-Object {
        $_.Name -match '^(App|router|routes|Router|Routes|AppRouter)\.(tsx|jsx)$' -or
        $_.FullName -match '[\\/]router[\\/]' -or
        $_.FullName -match '[\\/]routes[\\/]index\.(tsx|jsx)$'
    }
}

# ============================================================
# HELPER: Find CSS/SCSS files
# ============================================================

function Get-CssFiles {
    param([string]$RepoRoot)

    return Get-ChildItem -Path $RepoRoot -Include @("*.css", "*.scss") -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $path = $_.FullName
            $excluded = $false
            foreach ($pattern in $script:ExcludeDirPatterns) {
                if ($path -like $pattern) { $excluded = $true; break }
            }
            if ($_.Name -like '*.min.*') { $excluded = $true }
            -not $excluded
        }
}

# ============================================================
# CHECK: Screen requirement satisfaction
# ============================================================

function Test-ScreenSatisfied {
    param(
        [PSObject]$Requirement,
        [System.IO.FileInfo[]]$ReactFiles,
        [System.IO.FileInfo[]]$RoutingFiles
    )

    $screenName = $Requirement.screen_name
    if (-not $screenName) {
        # Try to extract from description
        if ($Requirement.description -match "Screen '([^']+)'") {
            $screenName = $Matches[1]
        }
    }
    if (-not $screenName) { return @{ Satisfied = $false; Reason = "Cannot determine screen name" } }

    # Normalize screen name for file matching
    $normalizedName = $screenName -replace '\s+', '' -replace '-', ''
    $patterns = @(
        $screenName,
        $normalizedName,
        ($screenName -replace '\s+', '-'),
        ($screenName -replace '\s+', ''),
        ($screenName + 'Page'),
        ($screenName + 'Screen'),
        ($screenName + 'View')
    )

    # Check if a .tsx file exists with the screen name
    $found = $false
    $foundFile = $null
    foreach ($file in $ReactFiles) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        foreach ($pattern in $patterns) {
            if ($baseName -ieq $pattern -or $baseName -ieq "${pattern}Page" -or $baseName -ieq "${pattern}Screen") {
                $found = $true
                $foundFile = $file
                break
            }
        }
        if ($found) { break }

        # Also check file content for component name export
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($content) {
            foreach ($pattern in $patterns) {
                if ($content -match "export\s+(?:default\s+)?(?:function|const)\s+$pattern") {
                    $found = $true
                    $foundFile = $file
                    break
                }
            }
        }
        if ($found) { break }
    }

    if (-not $found) {
        return @{ Satisfied = $false; Reason = "No .tsx file found implementing screen '$screenName'" }
    }

    # Check for mock data and stubs in the screen file
    $content = Get-Content $foundFile.FullName -Raw -ErrorAction SilentlyContinue
    $issues = @()

    foreach ($mockPattern in $script:MockDataPatterns) {
        if ($content -match $mockPattern) {
            $issues += "Contains mock data pattern: $mockPattern"
        }
    }

    foreach ($stubPattern in $script:StubPatterns) {
        if ($content -match $stubPattern) {
            $issues += "Contains stub/placeholder: $stubPattern"
        }
    }

    # Check if routed (if route is specified)
    $route = $Requirement.route
    if ($route -and $RoutingFiles) {
        $routeFound = $false
        foreach ($routeFile in $RoutingFiles) {
            $routeContent = Get-Content $routeFile.FullName -Raw -ErrorAction SilentlyContinue
            if ($routeContent -and $routeContent.Contains($route)) {
                $routeFound = $true
                break
            }
        }
        if (-not $routeFound) {
            $issues += "Screen file exists but route '$route' not found in routing config"
        }
    }

    if ($issues.Count -gt 0) {
        return @{
            Satisfied = $false
            Partial   = $true
            Reason    = "Screen file exists at $($foundFile.Name) but: $($issues -join '; ')"
            File      = $foundFile.FullName
        }
    }

    return @{ Satisfied = $true; File = $foundFile.FullName }
}

# ============================================================
# CHECK: Route requirement satisfaction
# ============================================================

function Test-RouteSatisfied {
    param(
        [PSObject]$Requirement,
        [System.IO.FileInfo[]]$RoutingFiles
    )

    $routePath = $Requirement.route_path
    if (-not $routePath) {
        if ($Requirement.description -match "Route '([^']+)'") {
            $routePath = $Matches[1]
        }
    }
    if (-not $routePath) { return @{ Satisfied = $false; Reason = "Cannot determine route path" } }

    if (-not $RoutingFiles -or $RoutingFiles.Count -eq 0) {
        return @{ Satisfied = $false; Reason = "No routing files found (App.tsx, router.tsx, etc.)" }
    }

    # Escape the route path for regex (but keep : for params)
    $escapedRoute = [regex]::Escape($routePath)
    # Also try with :param replaced by generic pattern
    $paramRoute = $routePath -replace ':\w+', '[^/"'']+' -replace '\{[^}]+\}', '[^/"'']+'

    foreach ($routeFile in $RoutingFiles) {
        $content = Get-Content $routeFile.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Check for exact route path match
        if ($content -match $escapedRoute) {
            return @{ Satisfied = $true; File = $routeFile.FullName }
        }

        # Check with param wildcards
        if ($paramRoute -ne $escapedRoute -and $content -match $paramRoute) {
            return @{ Satisfied = $true; File = $routeFile.FullName }
        }
    }

    return @{ Satisfied = $false; Reason = "Route '$routePath' not found in any routing configuration file" }
}

# ============================================================
# CHECK: API wiring requirement satisfaction
# ============================================================

function Test-ApiWiringSatisfied {
    param(
        [PSObject]$Requirement,
        [System.IO.FileInfo[]]$ReactFiles
    )

    $method = $Requirement.http_method
    $path = $Requirement.api_path
    if (-not $method) {
        if ($Requirement.description -match '(GET|POST|PUT|PATCH|DELETE)\s+(/[\w\-/{}:.*]+)') {
            $method = $Matches[1]
            $path = $Matches[2]
        }
    }
    if (-not $path) { return @{ Satisfied = $false; Reason = "Cannot determine API endpoint" } }

    # Normalize the path for matching — strip param placeholders for partial matching
    $pathBase = ($path -replace '\{[^}]+\}', '' -replace ':\w+', '' -replace '/+$', '')
    $pathSegments = $pathBase -split '/' | Where-Object { $_ -ne '' }
    $lastSegment = if ($pathSegments.Count -gt 0) { $pathSegments[-1] } else { '' }

    $found = $false
    $foundFile = $null
    $hasMockData = $false
    $hasStub = $false

    foreach ($file in $ReactFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Check for the API path in the file (in fetch, axios, apiClient calls)
        $pathFound = $false
        if ($content.Contains($path)) {
            $pathFound = $true
        }
        # Also try matching the last two segments (common pattern: /api/users -> 'users')
        elseif ($lastSegment -and $content.Contains($lastSegment)) {
            # Make sure it's in an API call context
            if ($content -match "(fetch|axios|apiClient|api\.|http\.|useQuery|useMutation).*$([regex]::Escape($lastSegment))") {
                $pathFound = $true
            }
        }

        if ($pathFound) {
            $found = $true
            $foundFile = $file

            # Check for mock data in the same file
            foreach ($mockPattern in $script:MockDataPatterns) {
                if ($content -match $mockPattern) {
                    $hasMockData = $true
                    break
                }
            }

            # Check for stubs
            foreach ($stubPattern in $script:StubPatterns) {
                if ($content -match $stubPattern) {
                    $hasStub = $true
                    break
                }
            }
            break
        }
    }

    if (-not $found) {
        return @{ Satisfied = $false; Reason = "No frontend code calls $method $path (no fetch/axios/apiClient reference found)" }
    }

    $issues = @()
    if ($hasMockData) { $issues += "File contains mock data patterns" }
    if ($hasStub) { $issues += "File contains TODO/FILL/stub patterns" }

    if ($issues.Count -gt 0) {
        return @{
            Satisfied = $false
            Partial   = $true
            Reason    = "API call to $method $path found in $($foundFile.Name) but: $($issues -join '; ')"
            File      = $foundFile.FullName
        }
    }

    return @{ Satisfied = $true; File = $foundFile.FullName }
}

# ============================================================
# CHECK: Component requirement satisfaction
# ============================================================

function Test-ComponentSatisfied {
    param(
        [PSObject]$Requirement,
        [System.IO.FileInfo[]]$ReactFiles
    )

    $compName = $Requirement.component_name
    if (-not $compName) {
        if ($Requirement.description -match "Component '([^']+)'") {
            $compName = $Matches[1]
        }
    }
    if (-not $compName) { return @{ Satisfied = $false; Reason = "Cannot determine component name" } }

    foreach ($file in $ReactFiles) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($baseName -ieq $compName) {
            return @{ Satisfied = $true; File = $file.FullName }
        }
    }

    # Also check exports inside files
    foreach ($file in $ReactFiles) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -and $content -match "export\s+(?:default\s+)?(?:function|const)\s+$compName\b") {
            return @{ Satisfied = $true; File = $file.FullName }
        }
    }

    return @{ Satisfied = $false; Reason = "No .tsx file found implementing component '$compName'" }
}

# ============================================================
# CHECK: Design system requirement satisfaction
# ============================================================

function Test-DesignSystemSatisfied {
    param(
        [PSObject]$Requirement,
        [string]$RepoRoot,
        [System.IO.FileInfo[]]$ReactFiles,
        [System.IO.FileInfo[]]$CssFiles
    )

    $desc = $Requirement.description

    # ThemeProvider check
    if ($desc -match 'ThemeProvider') {
        $themePatterns = @('ThemeProvider', 'FluentProvider', 'MuiThemeProvider', 'ChakraProvider', 'MantineProvider', 'CssVarsProvider')
        foreach ($file in $ReactFiles) {
            if ($file.Name -match '^(App|main|index|_app)\.(tsx|jsx)$') {
                $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    foreach ($tp in $themePatterns) {
                        if ($content -match $tp) {
                            return @{ Satisfied = $true; File = $file.FullName }
                        }
                    }
                }
            }
        }
        return @{ Satisfied = $false; Reason = "No ThemeProvider found in App.tsx/main.tsx entry point" }
    }

    # Design tokens CSS file check
    if ($desc -match 'Design tokens CSS file') {
        foreach ($css in $CssFiles) {
            if ($css.Name -match '^(tokens|theme|globals|variables|index)\.(css|scss)$') {
                $content = Get-Content $css.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -and $content -match '--[\w][\w-]*\s*:') {
                    return @{ Satisfied = $true; File = $css.FullName }
                }
            }
        }
        return @{ Satisfied = $false; Reason = "No CSS file with design token custom properties found" }
    }

    # Dark mode check
    if ($desc -match '(?i)dark\s*mode') {
        foreach ($css in $CssFiles) {
            $content = Get-Content $css.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and ($content -match '\.dark\s*\{' -or $content -match 'prefers-color-scheme:\s*dark')) {
                return @{ Satisfied = $true; File = $css.FullName }
            }
        }
        # Also check for Tailwind dark: prefix
        foreach ($file in $ReactFiles) {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match 'dark:') {
                return @{ Satisfied = $true; File = $file.FullName }
            }
        }
        return @{ Satisfied = $false; Reason = "No dark mode implementation found (no .dark CSS class, no prefers-color-scheme)" }
    }

    # Elevation/shadow token check
    if ($desc -match '(?i)elevation|shadow') {
        foreach ($css in $CssFiles) {
            $content = Get-Content $css.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match '--shadow-\w+\s*:') {
                return @{ Satisfied = $true; File = $css.FullName }
            }
        }
        return @{ Satisfied = $false; Reason = "No shadow/elevation CSS custom properties found (--shadow-*)" }
    }

    # Border radius token check
    if ($desc -match '(?i)border.*radius') {
        foreach ($css in $CssFiles) {
            $content = Get-Content $css.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -match '--radius-\w+\s*:') {
                return @{ Satisfied = $true; File = $css.FullName }
            }
        }
        return @{ Satisfied = $false; Reason = "No border-radius CSS custom properties found (--radius-*)" }
    }

    return @{ Satisfied = $false; Reason = "Unknown design system requirement type" }
}

# ============================================================
# MAIN FUNCTION: Invoke-FigmaCompletenessCheck
# ============================================================

function Invoke-FigmaCompletenessCheck {
    <#
    .SYNOPSIS
        Checks if Figma-derived requirements are actually satisfied in the codebase.
    .DESCRIPTION
        For each FIGMA-* requirement in the requirements matrix, scans the codebase
        to verify implementation. Updates requirement statuses. Pure file scanning,
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

    Write-Host "  [FIGMA-CHECK] Starting Figma completeness check..." -ForegroundColor Cyan

    # ── Check if design source exists (screens should be COPIED not generated) ──
    $designSrc = $null
    $hasDesignSrc = $false
    $designWebDir = Join-Path $RepoRoot "design" | Join-Path -ChildPath "web"
    if (Test-Path $designWebDir) {
        $latestVersion = Get-ChildItem -Path $designWebDir -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($latestVersion) {
            $candidateSrc = Join-Path $latestVersion.FullName "src"
            if (Test-Path $candidateSrc) {
                $designSrc = $candidateSrc
                $hasDesignSrc = $true
            }
        }
    }
    if ($hasDesignSrc) {
        Write-Host "    [FIGMA] Design source detected: $designSrc" -ForegroundColor Cyan
        Write-Host "    [FIGMA] Screens should be COPIED from design/, not generated" -ForegroundColor Cyan
    }

    # ── Load requirements matrix ──
    $matrixPath = Join-Path $GsdDir "requirements/requirements-matrix.json"
    if (-not (Test-Path $matrixPath)) {
        Write-Host "  [FIGMA-CHECK] No requirements-matrix.json found -- skipping" -ForegroundColor DarkGray
        return @{ Checked = 0; Satisfied = 0; Partial = 0; NotSatisfied = 0; Skipped = $true }
    }

    $matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
    $figmaReqs = @($matrix.requirements | Where-Object {
        $id = if ($_.id) { $_.id } else { $_.req_id }
        $id -match '^FIGMA-'
    })

    if ($figmaReqs.Count -eq 0) {
        Write-Host "  [FIGMA-CHECK] No FIGMA-* requirements found in matrix -- skipping" -ForegroundColor DarkGray
        return @{ Checked = 0; Satisfied = 0; Partial = 0; NotSatisfied = 0; Skipped = $true }
    }

    Write-Host "  [FIGMA-CHECK] Checking $($figmaReqs.Count) Figma-derived requirements..." -ForegroundColor DarkCyan

    # ── Gather codebase files (one-time scan) ──
    $reactFiles = @(Get-ReactFiles -RepoRoot $RepoRoot)
    $routingFiles = @(Get-RoutingFiles -ReactFiles $reactFiles)
    $cssFiles = @(Get-CssFiles -RepoRoot $RepoRoot)

    Write-Host "  [FIGMA-CHECK] Codebase: $($reactFiles.Count) React files, $($routingFiles.Count) routing files, $($cssFiles.Count) CSS files" -ForegroundColor DarkGray

    # ── Check each requirement ──
    $results = @()
    $satisfiedCount = 0
    $partialCount = 0
    $notSatisfiedCount = 0
    $matrixChanged = $false

    foreach ($req in $figmaReqs) {
        $reqId = if ($req.id) { $req.id } else { $req.req_id }
        $category = $req.category

        $checkResult = switch ($category) {
            'figma-screen' {
                Test-ScreenSatisfied -Requirement $req -ReactFiles $reactFiles -RoutingFiles $routingFiles
            }
            'figma-route' {
                Test-RouteSatisfied -Requirement $req -RoutingFiles $routingFiles
            }
            'figma-api' {
                Test-ApiWiringSatisfied -Requirement $req -ReactFiles $reactFiles
            }
            'figma-component' {
                Test-ComponentSatisfied -Requirement $req -ReactFiles $reactFiles
            }
            'figma-design-system' {
                Test-DesignSystemSatisfied -Requirement $req -RepoRoot $RepoRoot -ReactFiles $reactFiles -CssFiles $cssFiles
            }
            default {
                @{ Satisfied = $false; Reason = "Unknown category: $category" }
            }
        }

        # Update status in matrix
        $matrixReq = $matrix.requirements | Where-Object { ($_.id -eq $reqId) -or ($_.req_id -eq $reqId) }
        if ($matrixReq) {
            $oldStatus = $matrixReq.status
            if ($checkResult.Satisfied) {
                $matrixReq.status = 'satisfied'
                $satisfiedCount++
            } elseif ($checkResult.Partial) {
                $matrixReq.status = 'partial'
                $partialCount++
            } else {
                if ($matrixReq.status -ne 'satisfied') {
                    # Don't downgrade already-satisfied reqs (may have been manually promoted)
                    $matrixReq.status = 'not_started'
                }
                $notSatisfiedCount++
            }

            if ($matrixReq.status -ne $oldStatus) {
                $matrixChanged = $true
            }

            # Add evidence
            if ($checkResult.File) {
                $matrixReq | Add-Member -NotePropertyName 'evidence_file' -NotePropertyValue $checkResult.File -Force
            }
            if ($checkResult.Reason) {
                $matrixReq | Add-Member -NotePropertyName 'figma_check_reason' -NotePropertyValue $checkResult.Reason -Force
            }
        }

        $results += @{
            req_id    = $reqId
            category  = $category
            satisfied = $checkResult.Satisfied
            partial   = [bool]$checkResult.Partial
            reason    = $checkResult.Reason
            file      = $checkResult.File
        }
    }

    # ── Save updated matrix ──
    if ($matrixChanged) {
        if ($matrix.PSObject.Properties.Name -contains 'summary') {
            $matrix.summary.satisfied = @($matrix.requirements | Where-Object { $_.status -eq "satisfied" }).Count
            $matrix.summary.partial = @($matrix.requirements | Where-Object { $_.status -eq "partial" }).Count
            $matrix.summary.not_started = @($matrix.requirements | Where-Object { $_.status -eq "not_started" }).Count
        }
        $matrix | ConvertTo-Json -Depth 10 | Set-Content $matrixPath -Encoding UTF8
    }

    # ── Summary ──
    $total = $figmaReqs.Count
    $pct = if ($total -gt 0) { [math]::Round(($satisfiedCount / $total) * 100, 1) } else { 0 }

    $color = if ($pct -ge 90) { 'Green' } elseif ($pct -ge 50) { 'Yellow' } else { 'Red' }
    Write-Host "  [FIGMA-CHECK] Results: $satisfiedCount/$total satisfied ($pct%), $partialCount partial, $notSatisfiedCount not started" -ForegroundColor $color

    # Log unsatisfied requirements
    $unsatisfied = $results | Where-Object { -not $_.satisfied }
    if ($unsatisfied.Count -gt 0 -and $unsatisfied.Count -le 20) {
        foreach ($u in $unsatisfied) {
            Write-Host "    MISSING: $($u.req_id) -- $($u.reason)" -ForegroundColor DarkYellow
        }
    } elseif ($unsatisfied.Count -gt 20) {
        $unsatisfied | Select-Object -First 15 | ForEach-Object {
            Write-Host "    MISSING: $($_.req_id) -- $($_.reason)" -ForegroundColor DarkYellow
        }
        Write-Host "    ... and $($unsatisfied.Count - 15) more" -ForegroundColor DarkYellow
    }

    # ── Save completeness report ──
    $figmaDir = Join-Path $GsdDir 'figma'
    if (-not (Test-Path $figmaDir)) {
        New-Item -Path $figmaDir -ItemType Directory -Force | Out-Null
    }

    $report = @{
        timestamp           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        total_checked       = $total
        satisfied           = $satisfiedCount
        partial             = $partialCount
        not_satisfied       = $notSatisfiedCount
        completeness        = $pct
        design_source_path  = if ($hasDesignSrc) { $designSrc } else { $null }
        design_source_found = $hasDesignSrc
        by_category    = @{
            screens       = @{
                total     = @($results | Where-Object { $_.category -eq 'figma-screen' }).Count
                satisfied = @($results | Where-Object { $_.category -eq 'figma-screen' -and $_.satisfied }).Count
            }
            components    = @{
                total     = @($results | Where-Object { $_.category -eq 'figma-component' }).Count
                satisfied = @($results | Where-Object { $_.category -eq 'figma-component' -and $_.satisfied }).Count
            }
            routes        = @{
                total     = @($results | Where-Object { $_.category -eq 'figma-route' }).Count
                satisfied = @($results | Where-Object { $_.category -eq 'figma-route' -and $_.satisfied }).Count
            }
            api_endpoints = @{
                total     = @($results | Where-Object { $_.category -eq 'figma-api' }).Count
                satisfied = @($results | Where-Object { $_.category -eq 'figma-api' -and $_.satisfied }).Count
            }
            design_system = @{
                total     = @($results | Where-Object { $_.category -eq 'figma-design-system' }).Count
                satisfied = @($results | Where-Object { $_.category -eq 'figma-design-system' -and $_.satisfied }).Count
            }
        }
        unsatisfied    = @($results | Where-Object { -not $_.satisfied })
    }

    $reportPath = Join-Path $figmaDir 'figma-completeness-report.json'
    $report | ConvertTo-Json -Depth 10 | Set-Content $reportPath -Encoding UTF8
    Write-Host "  [FIGMA-CHECK] Report saved to: $reportPath" -ForegroundColor DarkGray

    return @{
        Checked           = $total
        Satisfied         = $satisfiedCount
        Partial           = $partialCount
        NotSatisfied      = $notSatisfiedCount
        Completeness      = $pct
        Skipped           = $false
        HasDesignSrc      = $hasDesignSrc
        DesignSourcePath  = $designSrc
        Report            = $report
    }
}
