<#
.SYNOPSIS
    GSD V3 Backend Validator - FREE static analysis for .NET/ASP.NET Core projects.
.DESCRIPTION
    Scans all .cs files in a repository and checks for common backend runtime issues:
    duplicate route conflicts, health check dependency safety, constructor ambiguity,
    route versioning consistency, missing API documentation, and middleware order.

    This module costs ZERO tokens — pure regex/string-based static analysis.
    Catches runtime issues that dotnet build cannot detect (duplicate routes, DI ambiguity, etc.).
#>

# ============================================================
# MAIN VALIDATION FUNCTION
# ============================================================

function Invoke-BackendValidation {
    <#
    .SYNOPSIS
        Run static analysis on all .cs files for .NET backend runtime issues.
    .PARAMETER RepoRoot
        Repository root path (mandatory).
    .PARAMETER GsdDir
        GSD state directory. Defaults to .gsd under RepoRoot.
    .PARAMETER Config
        Optional config hashtable for tuning thresholds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$GsdDir,

        [hashtable]$Config = @{}
    )

    if (-not $GsdDir) {
        $GsdDir = Join-Path $RepoRoot ".gsd"
    }

    $violations = [System.Collections.ArrayList]::new()
    $warnings   = [System.Collections.ArrayList]::new()
    $stats = @{
        FilesScanned       = 0
        ControllersScanned = 0
        RoutesFound        = 0
        TotalChecks        = 0
        Blocking           = 0
        Warnings           = 0
        Passed             = 0
    }

    # Find all .cs files (exclude node_modules, bin, obj, .git, test directories)
    $csFiles = Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($RepoRoot.Length)
            $rel -notmatch '[\\/](node_modules|bin|obj|\.git|\.gsd|\.vs|design|_stubs|_analysis)[\\/]'
        }

    if (-not $csFiles -or $csFiles.Count -eq 0) {
        Write-Host "  [BACKEND-VALIDATOR] No .cs files found in $RepoRoot" -ForegroundColor Yellow
        $result = @{
            passed     = $true
            violations = @()
            warnings   = @()
            stats      = $stats
        }
        Write-BackendValidationReport -GsdDir $GsdDir -Result $result
        return $result
    }

    $stats.FilesScanned = $csFiles.Count
    Write-Host "  [BACKEND-VALIDATOR] Scanning $($csFiles.Count) C# files..." -ForegroundColor Cyan

    # Pre-parse all files for content
    $fileContents = @{}
    foreach ($csFile in $csFiles) {
        $relativePath = $csFile.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        $content = Get-Content $csFile.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($content) {
            $fileContents[$relativePath] = @{
                Content  = $content
                Lines    = $content -split "`n"
                FullPath = $csFile.FullName
                Name     = $csFile.Name
            }
        }
    }

    # --- Check 1: Duplicate Route Detection ---
    Test-DuplicateRoutes -FileContents $fileContents -Violations $violations -Stats $stats

    # --- Check 2: Health Check Dependency Safety ---
    Test-HealthCheckDependencies -FileContents $fileContents -Warnings $warnings -Stats $stats

    # --- Check 3: Constructor Ambiguity ---
    Test-ConstructorAmbiguity -FileContents $fileContents -Violations $violations -Warnings $warnings -Stats $stats

    # --- Check 4: Route Versioning Consistency ---
    Test-RouteVersioningConsistency -FileContents $fileContents -Warnings $warnings -Stats $stats

    # --- Check 5: Missing API Documentation ---
    Test-MissingApiDocumentation -FileContents $fileContents -Warnings $warnings -Stats $stats

    # --- Check 6: Middleware Order Validation ---
    Test-MiddlewareOrder -FileContents $fileContents -Warnings $warnings -Stats $stats

    $stats.Blocking = ($violations | Where-Object { $_.severity -eq 'blocking' }).Count
    $stats.Warnings = $warnings.Count
    $stats.Passed   = $stats.TotalChecks - $stats.Blocking - $stats.Warnings

    $allPassed = ($stats.Blocking -eq 0)

    $result = @{
        passed     = $allPassed
        violations = @($violations)
        warnings   = @($warnings)
        stats      = $stats
    }

    $statusColor = if ($allPassed) { "Green" } else { "Red" }
    $statusText  = if ($allPassed) { "PASS" } else { "FAIL" }
    Write-Host "  [BACKEND-VALIDATOR] [$statusText] $($stats.FilesScanned) files, $($stats.ControllersScanned) controllers, $($stats.RoutesFound) routes, $($stats.Blocking) blocking, $($stats.Warnings) warnings" -ForegroundColor $statusColor

    Write-BackendValidationReport -GsdDir $GsdDir -Result $result
    return $result
}

# ============================================================
# CHECK 1: Duplicate Route Detection
# ============================================================

function Test-DuplicateRoutes {
    param($FileContents, $Violations, $Stats)

    $Stats.TotalChecks++

    # Collect all routes: { HttpMethod = "GET"; RoutePath = "v1/api/admin/connectors"; File = "..."; Line = N }
    $allRoutes = [System.Collections.ArrayList]::new()

    foreach ($entry in $FileContents.GetEnumerator()) {
        $file    = $entry.Key
        $content = $entry.Value.Content
        $lines   = $entry.Value.Lines
        $name    = $entry.Value.Name

        # Only process controller files
        if ($name -notmatch 'Controller\.cs$') { continue }
        if ($content -notmatch '(?i)(ControllerBase|Controller|ApiController)') { continue }

        $Stats.ControllersScanned++

        # Extract controller-level [Route("...")] attribute
        $controllerRoute = ""
        $routeMatch = [regex]::Match($content, '(?m)^\s*\[Route\(\s*"([^"]+)"\s*\)\]')
        if ($routeMatch.Success) {
            $controllerRoute = $routeMatch.Groups[1].Value
            # Resolve [controller] placeholder
            $controllerName = $name -replace 'Controller\.cs$', ''
            $controllerRoute = $controllerRoute -replace '\[controller\]', $controllerName.ToLower()
        }

        # Extract method-level HTTP attributes
        $httpMethods = @('HttpGet', 'HttpPost', 'HttpPut', 'HttpDelete', 'HttpPatch')
        foreach ($method in $httpMethods) {
            # Match [HttpGet], [HttpGet("path")], [HttpGet("path/{id}")]
            $pattern = "(?m)\[$method(?:\(\s*`"([^`"]*)`"\s*\))?\]"
            $attrMatches = [regex]::Matches($content, $pattern)

            foreach ($m in $attrMatches) {
                $lineNum = Get-BackendLineNumber -Content $content -Position $m.Index
                $actionRoute = $m.Groups[1].Value  # may be empty

                # Build full route path
                $fullRoute = Build-FullRoute -ControllerRoute $controllerRoute -ActionRoute $actionRoute
                $httpVerb = $method -replace '^Http', ''

                $Stats.RoutesFound++
                $null = $allRoutes.Add(@{
                    HttpMethod = $httpVerb.ToUpper()
                    RoutePath  = $fullRoute.ToLower()
                    File       = $file
                    Line       = $lineNum
                })
            }
        }
    }

    # Find duplicates: same HTTP method + same route path
    $routeGroups = @{}
    foreach ($route in $allRoutes) {
        $key = "$($route.HttpMethod)|$($route.RoutePath)"
        if (-not $routeGroups[$key]) {
            $routeGroups[$key] = [System.Collections.ArrayList]::new()
        }
        $null = $routeGroups[$key].Add($route)
    }

    foreach ($entry in $routeGroups.GetEnumerator()) {
        $routes = $entry.Value
        if ($routes.Count -gt 1) {
            # Check if they are in different files (cross-controller conflict)
            $files = $routes | ForEach-Object { $_.File } | Sort-Object -Unique
            $locations = ($routes | ForEach-Object { "$($_.File):$($_.Line)" }) -join ", "
            $parts = $entry.Key -split '\|', 2
            $verb = $parts[0]
            $path = $parts[1]

            $null = $Violations.Add(@{
                check      = 'duplicate_route'
                severity   = 'blocking'
                file       = $routes[0].File
                line       = $routes[0].Line
                message    = "Duplicate route: [$verb] $path declared in $($routes.Count) locations: $locations"
                suggestion = "Remove duplicate or rename one route. Each HTTP method + path combination must be unique across all controllers."
            })
        }
    }
}

function Build-FullRoute {
    param([string]$ControllerRoute, [string]$ActionRoute)

    # If action route starts with / or ~/, it's absolute — ignore controller route
    if ($ActionRoute -match '^[~/]') {
        return ($ActionRoute.TrimStart('~', '/'))
    }

    # Combine controller route + action route
    $parts = @()
    if ($ControllerRoute) { $parts += $ControllerRoute.Trim('/') }
    if ($ActionRoute)     { $parts += $ActionRoute.Trim('/') }

    $combined = ($parts -join '/').Trim('/')
    return $combined
}

# ============================================================
# CHECK 2: Health Check Dependency Safety
# ============================================================

function Test-HealthCheckDependencies {
    param($FileContents, $Warnings, $Stats)

    $Stats.TotalChecks++

    foreach ($entry in $FileContents.GetEnumerator()) {
        $file    = $entry.Key
        $content = $entry.Value.Content
        $lines   = $entry.Value.Lines

        # Only check Program.cs and Startup.cs
        if ($entry.Value.Name -notmatch '^(Program|Startup)\.cs$') { continue }

        # Check for AddHealthChecks() usage
        if ($content -notmatch 'AddHealthChecks') { continue }

        # Check 2a: Azurite / development storage dependency
        if ($content -match '(?i)UseDevelopmentStorage\s*=\s*true') {
            $m = [regex]::Match($content, '(?i)UseDevelopmentStorage\s*=\s*true')
            $lineNum = Get-BackendLineNumber -Content $content -Position $m.Index
            $null = $Warnings.Add(@{
                check      = 'healthcheck_dependency'
                severity   = 'warning'
                file       = $file
                line       = $lineNum
                message    = "Health check depends on Azurite (UseDevelopmentStorage=true) which may not be running"
                suggestion = "Conditionally register storage health check based on environment. Add timeout and fallback."
            })
        }

        # Check 2b: localhost/127.0.0.1 connection strings in health checks
        $localhostMatches = [regex]::Matches($content, '(?i)(localhost|127\.0\.0\.1|:5432|:6379|:27017|:5672)')
        foreach ($m in $localhostMatches) {
            $lineNum = Get-BackendLineNumber -Content $content -Position $m.Index
            # Only flag if near health check registration context
            $startLine = [Math]::Max(0, $lineNum - 15)
            $endLine   = [Math]::Min($lines.Count - 1, $lineNum + 5)
            $surrounding = ($lines[$startLine..$endLine]) -join "`n"
            if ($surrounding -match '(?i)(AddHealthChecks|HealthCheck|AddCheck|AddDbContext|AddRedis|AddRabbitMQ)') {
                $null = $Warnings.Add(@{
                    check      = 'healthcheck_dependency'
                    severity   = 'warning'
                    file       = $file
                    line       = $lineNum
                    message    = "Health check may depend on localhost service ($($m.Value)) — not guaranteed to be running"
                    suggestion = "Register health check conditionally. Add timeout: TimeSpan.FromSeconds(5). Use configuration to toggle."
                })
            }
        }

        # Check 2c: Health checks without timeout
        $addCheckMatches = [regex]::Matches($content, '(?i)\.AddCheck\s*[<(]')
        foreach ($m in $addCheckMatches) {
            $lineNum = Get-BackendLineNumber -Content $content -Position $m.Index
            # Look ahead for timeout in the next few lines
            $endLine = [Math]::Min($lines.Count - 1, $lineNum + 5)
            $callBlock = ($lines[($lineNum - 1)..$endLine]) -join "`n"
            if ($callBlock -notmatch '(?i)timeout') {
                $null = $Warnings.Add(@{
                    check      = 'healthcheck_timeout'
                    severity   = 'warning'
                    file       = $file
                    line       = $lineNum
                    message    = "Health check registered without timeout — can hang indefinitely"
                    suggestion = "Add timeout parameter: .AddCheck(""name"", check, timeout: TimeSpan.FromSeconds(5))"
                })
            }
        }

        # Check 2d: Health checks without tags
        $addCheckMatches2 = [regex]::Matches($content, '(?i)\.AddCheck\s*[<(]')
        foreach ($m in $addCheckMatches2) {
            $lineNum = Get-BackendLineNumber -Content $content -Position $m.Index
            $endLine = [Math]::Min($lines.Count - 1, $lineNum + 5)
            $callBlock = ($lines[($lineNum - 1)..$endLine]) -join "`n"
            if ($callBlock -notmatch '(?i)tags\s*:') {
                $null = $Warnings.Add(@{
                    check      = 'healthcheck_tags'
                    severity   = 'warning'
                    file       = $file
                    line       = $lineNum
                    message    = "Health check registered without tags — cannot separate liveness vs readiness probes"
                    suggestion = "Add tags: .AddCheck(""name"", check, tags: new[] { ""ready"" })"
                })
            }
        }
    }
}

# ============================================================
# CHECK 3: Constructor Ambiguity
# ============================================================

function Test-ConstructorAmbiguity {
    param($FileContents, $Violations, $Warnings, $Stats)

    $Stats.TotalChecks++

    foreach ($entry in $FileContents.GetEnumerator()) {
        $file    = $entry.Key
        $content = $entry.Value.Content
        $lines   = $entry.Value.Lines
        $name    = $entry.Value.Name

        # Extract class names that match DI-relevant patterns
        $classMatches = [regex]::Matches($content, '(?m)^\s*public\s+(?:partial\s+)?class\s+(\w+)')

        foreach ($cm in $classMatches) {
            $className = $cm.Groups[1].Value
            $classLineNum = Get-BackendLineNumber -Content $content -Position $cm.Index

            # Count public constructors for this class
            $ctorPattern = "(?m)^\s*public\s+$([regex]::Escape($className))\s*\("
            $ctorMatches = [regex]::Matches($content, $ctorPattern)

            if ($ctorMatches.Count -lt 2) { continue }

            $ctorLines = ($ctorMatches | ForEach-Object { Get-BackendLineNumber -Content $content -Position $_.Index }) -join ", "

            # Determine severity: controllers are blocking, other classes are warnings
            $isController = ($name -match 'Controller\.cs$') -or
                           ($content -match "(?i)class\s+$([regex]::Escape($className))\s*:\s*\w*(Controller|ControllerBase)") -or
                           ($content -match '\[ApiController\]')

            $isService = ($name -match '(Service|Repository|Handler|Manager|Provider)\.cs$')

            if ($isController) {
                $null = $Violations.Add(@{
                    check      = 'constructor_ambiguity'
                    severity   = 'blocking'
                    file       = $file
                    line       = $classLineNum
                    message    = "Controller '$className' has $($ctorMatches.Count) public constructors (lines: $ctorLines) — ASP.NET Core DI cannot resolve which to use"
                    suggestion = "Remove extra constructors. Controllers must have exactly ONE public constructor with all dependencies as parameters."
                })
            } elseif ($isService) {
                $null = $Violations.Add(@{
                    check      = 'constructor_ambiguity'
                    severity   = 'blocking'
                    file       = $file
                    line       = $classLineNum
                    message    = "Service '$className' has $($ctorMatches.Count) public constructors (lines: $ctorLines) — DI container cannot resolve which to use"
                    suggestion = "Remove extra constructors. Use a single constructor with all dependencies injected as parameters."
                })
            } else {
                $null = $Warnings.Add(@{
                    check      = 'constructor_ambiguity'
                    severity   = 'warning'
                    file       = $file
                    line       = $classLineNum
                    message    = "Class '$className' has $($ctorMatches.Count) public constructors — may cause DI issues if registered"
                    suggestion = "Consider using a single public constructor for DI compatibility."
                })
            }
        }
    }
}

# ============================================================
# CHECK 4: Route Versioning Consistency
# ============================================================

function Test-RouteVersioningConsistency {
    param($FileContents, $Warnings, $Stats)

    $Stats.TotalChecks++

    $versionedControllers = [System.Collections.ArrayList]::new()
    $unversionedControllers = [System.Collections.ArrayList]::new()
    $apiVersionAttrCount = 0

    foreach ($entry in $FileContents.GetEnumerator()) {
        $file    = $entry.Key
        $content = $entry.Value.Content
        $name    = $entry.Value.Name

        if ($name -notmatch 'Controller\.cs$') { continue }
        if ($content -notmatch '(?i)(ControllerBase|Controller|ApiController)') { continue }

        # Check for [ApiVersion] attribute
        if ($content -match '\[ApiVersion') { $apiVersionAttrCount++ }

        # Extract route prefix
        $routeMatch = [regex]::Match($content, '\[Route\(\s*"([^"]+)"\s*\)\]')
        if ($routeMatch.Success) {
            $route = $routeMatch.Groups[1].Value

            if ($route -match '(?i)v\d+[/\\]') {
                $null = $versionedControllers.Add(@{ File = $file; Route = $route })
            } elseif ($route -match '(?i)api[/\\]') {
                $null = $unversionedControllers.Add(@{ File = $file; Route = $route })
            }
        }
    }

    # Flag inconsistency if both versioned and unversioned routes exist
    if ($versionedControllers.Count -gt 0 -and $unversionedControllers.Count -gt 0) {
        $vFiles = ($versionedControllers | ForEach-Object { $_.File }) -join ", "
        $uvFiles = ($unversionedControllers | ForEach-Object { $_.File }) -join ", "

        $null = $Warnings.Add(@{
            check      = 'route_versioning'
            severity   = 'warning'
            file       = $unversionedControllers[0].File
            line       = 1
            message    = "Inconsistent route versioning: $($versionedControllers.Count) controllers use versioned routes ($vFiles), $($unversionedControllers.Count) use unversioned ($uvFiles)"
            suggestion = "Standardize all controller routes to use the same versioning pattern (e.g., all v1/api/... or all api/v1/...)."
        })
    }
}

# ============================================================
# CHECK 5: Missing API Documentation
# ============================================================

function Test-MissingApiDocumentation {
    param($FileContents, $Warnings, $Stats)

    $Stats.TotalChecks++

    foreach ($entry in $FileContents.GetEnumerator()) {
        $file    = $entry.Key
        $content = $entry.Value.Content
        $lines   = $entry.Value.Lines
        $name    = $entry.Value.Name

        if ($name -notmatch 'Controller\.cs$') { continue }
        if ($content -notmatch '\[ApiController\]') { continue }

        # Find all action methods (public methods with [Http*] attributes)
        $httpMethods = @('HttpGet', 'HttpPost', 'HttpPut', 'HttpDelete', 'HttpPatch')
        foreach ($method in $httpMethods) {
            $pattern = "(?m)\[$method"
            $attrMatches = [regex]::Matches($content, $pattern)

            foreach ($m in $attrMatches) {
                $lineNum = Get-BackendLineNumber -Content $content -Position $m.Index

                # Check preceding 5 lines for [ProducesResponseType]
                $startLine = [Math]::Max(0, $lineNum - 6)
                $precedingBlock = ($lines[$startLine..($lineNum - 1)]) -join "`n"

                if ($precedingBlock -notmatch 'ProducesResponseType') {
                    # Extract method name from the line after the attribute
                    $methodLine = if ($lineNum -lt $lines.Count) { $lines[$lineNum] } else { "" }
                    $methodNameMatch = [regex]::Match($methodLine, '(?i)\s+(\w+)\s*\(')
                    $methodName = if ($methodNameMatch.Success) { $methodNameMatch.Groups[1].Value } else { "unknown" }

                    $null = $Warnings.Add(@{
                        check      = 'missing_api_docs'
                        severity   = 'warning'
                        file       = $file
                        line       = $lineNum
                        message    = "Action '$methodName' in $name missing [ProducesResponseType] — Swagger docs will be incomplete"
                        suggestion = "Add [ProducesResponseType(typeof(ReturnType), StatusCodes.Status200OK)] and error response types."
                    })
                }
            }
        }
    }
}

# ============================================================
# CHECK 6: Middleware Order Validation
# ============================================================

function Test-MiddlewareOrder {
    param($FileContents, $Warnings, $Stats)

    $Stats.TotalChecks++

    foreach ($entry in $FileContents.GetEnumerator()) {
        $file    = $entry.Key
        $content = $entry.Value.Content
        $lines   = $entry.Value.Lines
        $name    = $entry.Value.Name

        # Only check Program.cs and Startup.cs
        if ($name -notmatch '^(Program|Startup)\.cs$') { continue }

        # Build ordered list of middleware calls with their positions
        $middlewareOrder = @(
            @{ Name = 'UseRouting';         Pattern = '\.UseRouting\s*\(' }
            @{ Name = 'UseCors';            Pattern = '\.UseCors\s*\(' }
            @{ Name = 'UseAuthentication';  Pattern = '\.UseAuthentication\s*\(' }
            @{ Name = 'UseAuthorization';   Pattern = '\.UseAuthorization\s*\(' }
            @{ Name = 'UseEndpoints';       Pattern = '\.UseEndpoints\s*\(' }
            @{ Name = 'MapControllers';     Pattern = '\.MapControllers\s*\(' }
            @{ Name = 'UseSwagger';         Pattern = '\.UseSwagger\s*\(' }
            @{ Name = 'UseSwaggerUI';       Pattern = '\.UseSwaggerUI\s*\(' }
        )

        $positions = @{}
        foreach ($mw in $middlewareOrder) {
            $match = [regex]::Match($content, $mw.Pattern)
            if ($match.Success) {
                $positions[$mw.Name] = $match.Index
            }
        }

        # Rule: UseRouting before UseAuthentication
        if ($positions['UseRouting'] -and $positions['UseAuthentication']) {
            if ($positions['UseRouting'] -gt $positions['UseAuthentication']) {
                $lineNum = Get-BackendLineNumber -Content $content -Position $positions['UseAuthentication']
                $null = $Warnings.Add(@{
                    check      = 'middleware_order'
                    severity   = 'warning'
                    file       = $file
                    line       = $lineNum
                    message    = "UseAuthentication() called before UseRouting() — authentication won't have route data"
                    suggestion = "Move UseRouting() before UseAuthentication() in the middleware pipeline."
                })
            }
        }

        # Rule: UseAuthentication before UseAuthorization
        if ($positions['UseAuthentication'] -and $positions['UseAuthorization']) {
            if ($positions['UseAuthentication'] -gt $positions['UseAuthorization']) {
                $lineNum = Get-BackendLineNumber -Content $content -Position $positions['UseAuthorization']
                $null = $Warnings.Add(@{
                    check      = 'middleware_order'
                    severity   = 'warning'
                    file       = $file
                    line       = $lineNum
                    message    = "UseAuthorization() called before UseAuthentication() — authorization will fail"
                    suggestion = "Move UseAuthentication() before UseAuthorization()."
                })
            }
        }

        # Rule: UseCors before UseAuthentication
        if ($positions['UseCors'] -and $positions['UseAuthentication']) {
            if ($positions['UseCors'] -gt $positions['UseAuthentication']) {
                $lineNum = Get-BackendLineNumber -Content $content -Position $positions['UseAuthentication']
                $null = $Warnings.Add(@{
                    check      = 'middleware_order'
                    severity   = 'warning'
                    file       = $file
                    line       = $lineNum
                    message    = "UseAuthentication() called before UseCors() — CORS preflight requests may be rejected"
                    suggestion = "Move UseCors() before UseAuthentication()."
                })
            }
        }

        # Rule: UseRouting before UseEndpoints/MapControllers
        foreach ($endpoint in @('UseEndpoints', 'MapControllers')) {
            if ($positions['UseRouting'] -and $positions[$endpoint]) {
                if ($positions['UseRouting'] -gt $positions[$endpoint]) {
                    $lineNum = Get-BackendLineNumber -Content $content -Position $positions[$endpoint]
                    $null = $Warnings.Add(@{
                        check      = 'middleware_order'
                        severity   = 'warning'
                        file       = $file
                        line       = $lineNum
                        message    = "$endpoint() called before UseRouting() — endpoints won't be matched"
                        suggestion = "Move UseRouting() before $endpoint()."
                    })
                }
            }
        }

        # Rule: UseSwagger/UseSwaggerUI should be guarded by environment check
        foreach ($swagger in @('UseSwagger', 'UseSwaggerUI')) {
            if ($positions[$swagger]) {
                $swaggerLine = Get-BackendLineNumber -Content $content -Position $positions[$swagger]
                # Check surrounding context for IsDevelopment guard
                $startLine = [Math]::Max(0, $swaggerLine - 10)
                $precedingBlock = ($lines[$startLine..($swaggerLine - 1)]) -join "`n"

                if ($precedingBlock -notmatch '(?i)(IsDevelopment|IsEnvironment|ASPNETCORE_ENVIRONMENT|#if\s+DEBUG)') {
                    $null = $Warnings.Add(@{
                        check      = 'middleware_order'
                        severity   = 'warning'
                        file       = $file
                        line       = $swaggerLine
                        message    = "$swagger() not guarded by environment check — Swagger will be exposed in production"
                        suggestion = "Wrap in: if (app.Environment.IsDevelopment()) { app.$swagger(); }"
                    })
                }
            }
        }
    }
}

# ============================================================
# HELPER: Get line number from character position
# ============================================================

function Get-BackendLineNumber {
    param(
        [string]$Content,
        [int]$Position
    )

    if ($Position -le 0) { return 1 }
    $beforeText = $Content.Substring(0, [Math]::Min($Position, $Content.Length))
    return ($beforeText -split "`n").Count
}

# ============================================================
# HELPER: Write report to .gsd/backend/
# ============================================================

function Write-BackendValidationReport {
    param(
        [string]$GsdDir,
        [hashtable]$Result
    )

    $backendDir = Join-Path $GsdDir "backend"
    if (-not (Test-Path $backendDir)) {
        New-Item -Path $backendDir -ItemType Directory -Force | Out-Null
    }

    $reportPath = Join-Path $backendDir "backend-validation-report.json"

    $report = @{
        timestamp  = (Get-Date -Format "o")
        passed     = $Result.passed
        stats      = $Result.stats
        violations = $Result.violations
        warnings   = $Result.warnings
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8

    Write-Host "  [BACKEND-VALIDATOR] Report written to $reportPath" -ForegroundColor Gray
}
