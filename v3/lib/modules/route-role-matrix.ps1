# route-role-matrix.ps1
# Builds a route-to-role visibility matrix from a codebase by parsing
# router config, RBAC config, route guards, and navigation config.

function Build-RouteRoleMatrix {
    <#
    .SYNOPSIS
        Parses a React codebase to build a route-to-role visibility matrix.
        Identifies routes without guards, navigation gaps, and roles with no access.
    .PARAMETER RepoRoot
        Root directory of the repository.
    .PARAMETER RouterFile
        Path to the router file (e.g., src/App.tsx, src/router.tsx). Relative to RepoRoot.
    .PARAMETER RbacFile
        Optional path to RBAC config (e.g., src/config/rbac.ts). Relative to RepoRoot.
    .PARAMETER NavFile
        Optional path to navigation/sidebar config. Relative to RepoRoot.
    .OUTPUTS
        PSCustomObject with Routes (matrix rows) and Gaps (issues found).
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$RouterFile,
        [string]$RbacFile,
        [string]$NavFile
    )

    $routes = [System.Collections.ArrayList]::new()
    $gaps = [System.Collections.ArrayList]::new()
    $allRoles = [System.Collections.Generic.HashSet[string]]::new()

    # --- Auto-detect files if not specified ---
    if (-not $RouterFile) {
        $candidates = @('src/App.tsx', 'src/web/App.tsx', 'src/router.tsx', 'src/routes.tsx',
                        'src/app/routes.tsx', 'src/Router.tsx')
        foreach ($c in $candidates) {
            $fullPath = Join-Path $RepoRoot $c
            if (Test-Path $fullPath) { $RouterFile = $c; break }
        }
    }

    if (-not $RbacFile) {
        $candidates = @('src/config/rbac.ts', 'src/config/rbac.tsx', 'src/rbac.ts',
                        'src/config/roles.ts', 'src/constants/roles.ts', 'src/auth/rbac.ts',
                        'src/web/config/rbac.ts')
        foreach ($c in $candidates) {
            $fullPath = Join-Path $RepoRoot $c
            if (Test-Path $fullPath) { $RbacFile = $c; break }
        }
    }

    if (-not $NavFile) {
        $candidates = @('src/config/navigation.ts', 'src/config/navigation.tsx',
                        'src/config/nav.ts', 'src/config/menu.ts', 'src/config/sidebar.ts',
                        'src/components/Sidebar.tsx', 'src/components/Navigation.tsx',
                        'src/web/config/navigation.ts')
        foreach ($c in $candidates) {
            $fullPath = Join-Path $RepoRoot $c
            if (Test-Path $fullPath) { $NavFile = $c; break }
        }
    }

    # --- Parse Router File ---
    if ($RouterFile) {
        $routerPath = Join-Path $RepoRoot $RouterFile
        if (Test-Path $routerPath) {
            $content = [System.IO.File]::ReadAllText($routerPath)
            $lines = [System.IO.File]::ReadAllLines($routerPath)

            # Match Route elements: <Route path="/..." component={...} /> or element={<.../>}
            $routeMatches = [regex]::Matches($content, '(?s)<Route[^>]*path\s*=\s*"([^"]+)"[^>]*(component\s*=\s*\{?\s*(\w+)\}?|element\s*=\s*\{\s*<(\w+))')
            foreach ($m in $routeMatches) {
                $path = $m.Groups[1].Value
                $component = if ($m.Groups[3].Value) { $m.Groups[3].Value } else { $m.Groups[4].Value }

                # Check if wrapped in a guard (look for ProtectedRoute, RequireAuth, AuthGuard, RoleGuard)
                $guardType = 'none'
                $requiredRoles = @()

                # Look for guard wrapper in context around this route
                $routeIndex = $m.Index
                $contextStart = [Math]::Max(0, $routeIndex - 500)
                $contextEnd = [Math]::Min($content.Length, $routeIndex + $m.Length + 200)
                $context = $content.Substring($contextStart, $contextEnd - $contextStart)

                if ($context -match '(?i)(ProtectedRoute|RequireAuth|AuthGuard|PrivateRoute|AuthenticatedRoute)') {
                    $guardType = $Matches[1]

                    # Try to extract roles from guard
                    if ($context -match '(?i)roles?\s*=\s*\{?\s*\[?\s*["\x27]([^"\x27\]]+)') {
                        $roleStr = $Matches[1]
                        $requiredRoles = $roleStr -split '\s*,\s*' | ForEach-Object { $_.Trim('"', "'", ' ') } | Where-Object { $_ }
                    }
                    elseif ($context -match '(?i)roles?\s*=\s*\{?\s*\[([^\]]+)\]') {
                        $roleStr = $Matches[1]
                        $requiredRoles = [regex]::Matches($roleStr, '["\x27](\w+)["\x27]') | ForEach-Object { $_.Groups[1].Value }
                    }
                }

                foreach ($r in $requiredRoles) { [void]$allRoles.Add($r) }

                [void]$routes.Add([PSCustomObject]@{
                    Path           = $path
                    Component      = $component
                    GuardType      = $guardType
                    RequiredRoles  = $requiredRoles
                    NavVisible     = @()
                    Source         = $RouterFile
                })
            }

            # Also check for react-router v6 object-style routes: { path: "/...", element: <.../> }
            $objectRouteMatches = [regex]::Matches($content, '(?s)path\s*:\s*["\x27]([^"\x27]+)["\x27]\s*,\s*element\s*:\s*<(\w+)')
            foreach ($m in $objectRouteMatches) {
                $path = $m.Groups[1].Value
                $component = $m.Groups[2].Value
                $alreadyFound = $routes | Where-Object { $_.Path -eq $path }
                if (-not $alreadyFound) {
                    [void]$routes.Add([PSCustomObject]@{
                        Path           = $path
                        Component      = $component
                        GuardType      = 'none'
                        RequiredRoles  = @()
                        NavVisible     = @()
                        Source         = $RouterFile
                    })
                }
            }
        }
        else {
            [void]$gaps.Add([PSCustomObject]@{
                Type        = 'missing_file'
                Description = "Router file not found: $RouterFile"
                Severity    = 'critical'
            })
        }
    }
    else {
        [void]$gaps.Add([PSCustomObject]@{
            Type        = 'missing_file'
            Description = 'No router file detected in standard locations'
            Severity    = 'critical'
        })
    }

    # --- Parse RBAC Config ---
    $rolePermissions = @{}
    if ($RbacFile) {
        $rbacPath = Join-Path $RepoRoot $RbacFile
        if (Test-Path $rbacPath) {
            $rbacContent = [System.IO.File]::ReadAllText($rbacPath)

            # Extract role definitions: admin: [...], user: [...], etc.
            $roleBlockMatches = [regex]::Matches($rbacContent, '(?i)(\w+)\s*:\s*\[([^\]]*)\]')
            foreach ($m in $roleBlockMatches) {
                $roleName = $m.Groups[1].Value
                $perms = [regex]::Matches($m.Groups[2].Value, '["\x27]([^"\x27]+)["\x27]') | ForEach-Object { $_.Groups[1].Value }
                $rolePermissions[$roleName] = $perms
                [void]$allRoles.Add($roleName)
            }
        }
    }

    # --- Parse Navigation Config ---
    $navItems = [System.Collections.ArrayList]::new()
    if ($NavFile) {
        $navPath = Join-Path $RepoRoot $NavFile
        if (Test-Path $navPath) {
            $navContent = [System.IO.File]::ReadAllText($navPath)

            # Match nav items with path and roles: { path: "/...", roles: [...] }
            $navMatches = [regex]::Matches($navContent, '(?s)path\s*:\s*["\x27]([^"\x27]+)["\x27].*?(?:roles?\s*:\s*\[([^\]]*)\])?')
            foreach ($m in $navMatches) {
                $navPath2 = $m.Groups[1].Value
                $navRoles = @()
                if ($m.Groups[2].Success) {
                    $navRoles = [regex]::Matches($m.Groups[2].Value, '["\x27](\w+)["\x27]') | ForEach-Object { $_.Groups[1].Value }
                }
                [void]$navItems.Add([PSCustomObject]@{
                    Path  = $navPath2
                    Roles = $navRoles
                })

                # Update route entry with nav visibility
                $route = $routes | Where-Object { $_.Path -eq $navPath2 }
                if ($route) {
                    $route.NavVisible = $navRoles
                }
            }
        }
    }

    # --- Identify Gaps ---

    # Routes without any guard
    foreach ($r in $routes) {
        if ($r.GuardType -eq 'none' -and $r.Path -notin @('/', '/login', '/logout', '/register', '/forgot-password', '/reset-password', '/unauthorized', '/404', '*')) {
            [void]$gaps.Add([PSCustomObject]@{
                Type        = 'unguarded_route'
                Description = "Route '$($r.Path)' ($($r.Component)) has no auth guard"
                Severity    = 'high'
                Route       = $r.Path
            })
        }
    }

    # Navigation items with no matching route
    foreach ($nav in $navItems) {
        $matchingRoute = $routes | Where-Object { $_.Path -eq $nav.Path }
        if (-not $matchingRoute) {
            [void]$gaps.Add([PSCustomObject]@{
                Type        = 'orphan_nav'
                Description = "Navigation item '$($nav.Path)' has no matching route"
                Severity    = 'high'
                Route       = $nav.Path
            })
        }
    }

    # Routes with no navigation entry
    foreach ($r in $routes) {
        if ($r.Path -notin @('/', '/login', '/logout', '/register', '/forgot-password', '/reset-password', '/unauthorized', '/404', '*')) {
            $hasNav = $navItems | Where-Object { $_.Path -eq $r.Path }
            if (-not $hasNav -and $NavFile) {
                [void]$gaps.Add([PSCustomObject]@{
                    Type        = 'hidden_route'
                    Description = "Route '$($r.Path)' ($($r.Component)) exists but has no navigation entry — users cannot reach it"
                    Severity    = 'medium'
                    Route       = $r.Path
                })
            }
        }
    }

    # Roles that have no accessible routes
    foreach ($role in $allRoles) {
        $accessibleRoutes = $routes | Where-Object { $_.RequiredRoles.Count -eq 0 -or $role -in $_.RequiredRoles }
        $publicRoutes = @('/', '/login', '/logout', '/register', '/forgot-password', '/unauthorized', '/404')
        $nonPublicAccessible = $accessibleRoutes | Where-Object { $_.Path -notin $publicRoutes }
        if ($nonPublicAccessible.Count -eq 0) {
            [void]$gaps.Add([PSCustomObject]@{
                Type        = 'empty_role'
                Description = "Role '$role' has no accessible non-public routes"
                Severity    = 'high'
                Route       = ''
            })
        }
    }

    # --- Build result ---
    $result = [PSCustomObject]@{
        Routes          = $routes
        Roles           = [string[]]$allRoles
        RolePermissions = $rolePermissions
        NavigationItems = $navItems
        Gaps            = $gaps
        Summary         = [PSCustomObject]@{
            TotalRoutes    = $routes.Count
            GuardedRoutes  = @($routes | Where-Object { $_.GuardType -ne 'none' }).Count
            UnguardedRoutes = @($routes | Where-Object { $_.GuardType -eq 'none' -and $_.Path -notin @('/', '/login', '/logout', '/register', '/forgot-password', '/reset-password', '/unauthorized', '/404', '*') }).Count
            TotalRoles     = $allRoles.Count
            TotalGaps      = $gaps.Count
            CriticalGaps   = @($gaps | Where-Object Severity -eq 'critical').Count
            HighGaps       = @($gaps | Where-Object Severity -eq 'high').Count
        }
    }

    return $result
}


function Format-RouteRoleMatrix {
    <#
    .SYNOPSIS
        Formats the route-role matrix as a readable table for display or logging.
    .PARAMETER Matrix
        Output from Build-RouteRoleMatrix.
    #>
    param(
        [Parameter(Mandatory)]$Matrix
    )

    Write-Host "`n=== Route-Role Matrix ===" -ForegroundColor Cyan
    Write-Host "Routes: $($Matrix.Summary.TotalRoutes) | Roles: $($Matrix.Summary.TotalRoles) | Gaps: $($Matrix.Summary.TotalGaps)" -ForegroundColor Gray

    # Table header
    $roles = $Matrix.Roles
    $header = "{0,-30} {1,-25} {2,-20}" -f "Route", "Component", "Guard"
    foreach ($r in $roles) {
        $header += " {0,-10}" -f $r
    }
    Write-Host "`n$header" -ForegroundColor White
    Write-Host ("-" * $header.Length) -ForegroundColor DarkGray

    # Table rows
    foreach ($route in $Matrix.Routes) {
        $row = "{0,-30} {1,-25} {2,-20}" -f $route.Path, $route.Component, $route.GuardType
        foreach ($role in $roles) {
            $hasAccess = $route.RequiredRoles.Count -eq 0 -or $role -in $route.RequiredRoles
            $isNavVisible = $route.NavVisible.Count -eq 0 -or $role -in $route.NavVisible
            $symbol = if ($hasAccess -and $isNavVisible) { "OK" }
                      elseif ($hasAccess) { "ROUTE" }
                      elseif ($isNavVisible) { "NAV" }
                      else { "-" }
            $color = switch ($symbol) {
                "OK"    { 'Green' }
                "ROUTE" { 'Yellow' }
                "NAV"   { 'Red' }
                "-"     { 'DarkGray' }
            }
            $row += " {0,-10}" -f $symbol
        }
        Write-Host $row
    }

    Write-Host "`nLegend: OK=full access, ROUTE=route allows but no nav, NAV=nav shows but route blocks, -=no access" -ForegroundColor DarkGray

    # Show gaps
    if ($Matrix.Gaps.Count -gt 0) {
        Write-Host "`n=== Gaps Found ===" -ForegroundColor Yellow
        foreach ($gap in $Matrix.Gaps) {
            $color = switch ($gap.Severity) { 'critical' { 'Red' } 'high' { 'Yellow' } 'medium' { 'DarkYellow' } default { 'Gray' } }
            Write-Host "  [$($gap.Severity.ToUpper())] $($gap.Type): $($gap.Description)" -ForegroundColor $color
        }
    }

    return $Matrix
}


function Export-RouteRoleMatrix {
    <#
    .SYNOPSIS
        Exports the route-role matrix to a JSON file.
    .PARAMETER Matrix
        Output from Build-RouteRoleMatrix.
    .PARAMETER OutputFile
        Path to write the JSON output.
    #>
    param(
        [Parameter(Mandatory)]$Matrix,
        [Parameter(Mandatory)][string]$OutputFile
    )

    $Matrix | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host "Route-role matrix exported to: $OutputFile" -ForegroundColor Green
}
