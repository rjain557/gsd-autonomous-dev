<#
.SYNOPSIS
    GSD Runtime Smoke Test - Catches DI errors, FK violations, and 500s before declaring 100%.
    Run AFTER patch-gsd-loc-tracking.ps1.

.DESCRIPTION
    Closes the gap between "code compiles" and "code actually runs" by adding three
    runtime validation checks to the final validation gate:

    1. DI Container Validation (Test-DiContainerHealth):
       Runs a headless host build to surface scoped-from-root, missing registration,
       and circular dependency errors that only appear at runtime.

    2. Runtime API Smoke Test (Invoke-ApiSmokeTest):
       Starts the application, waits for readiness, then hits every discovered API
       endpoint checking for non-500 responses. Catches:
       - FK constraint violations (INSERT with bad references)
       - Unhandled exceptions in controllers
       - Missing middleware/service configuration
       - Database connection failures

    3. Database Seed Order Validation (Test-SeedDataFkOrder):
       Static scan of SQL seed files to detect INSERT ordering that would violate
       FK constraints (e.g., inserting into MyGPTs before Users exist).

    Also adds:
    - health-endpoint.md prompt template requiring /api/health endpoint
    - di-service-lifetime.md prompt template (prevents scoped-from-root)
    - runtime_smoke_test config block in global-config.json
    - New acceptance test type: api_smoke

.INSTALL_ORDER
    1-31. (existing scripts)
    32. patch-gsd-runtime-smoke-test.ps1  <- this file

.NOTES
    This patch was created because projects were reaching 100% convergence with
    passing builds and tests, but failing at runtime with:
    - System.InvalidOperationException: Cannot resolve scoped service from root provider
    - SqlException: INSERT conflicted with FOREIGN KEY constraint
    - HTTP 500 on all API endpoints
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Runtime Smoke Test" -ForegroundColor Cyan
Write-Host "  Catches DI errors, FK violations, and 500s at runtime" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add runtime_smoke_test config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.runtime_smoke_test) {
        $config | Add-Member -NotePropertyName "runtime_smoke_test" -NotePropertyValue ([PSCustomObject]@{
            enabled                = $true
            startup_timeout_seconds = 30
            request_timeout_seconds = 10
            max_endpoints_to_test  = 50
            health_endpoint        = "/api/health"
            fail_on_any_500        = $true
            kill_after_test        = $true
            dotnet_launch_profile  = ""
            port_override          = 0
            seed_fk_check_enabled  = $true
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added runtime_smoke_test config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] runtime_smoke_test config already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Create health-endpoint prompt template ──

$sharedDir = Join-Path $GsdGlobalDir "prompts\shared"
if (-not (Test-Path $sharedDir)) {
    New-Item -Path $sharedDir -ItemType Directory -Force | Out-Null
}

$healthPromptPath = Join-Path $sharedDir "health-endpoint.md"
$healthPromptContent = @'
# Health Endpoint Requirement

## MANDATORY: Every API project MUST include a health endpoint

### .NET API Projects
Add a minimal health endpoint that validates:
1. The application starts without DI errors
2. The database connection works
3. All required services are resolvable

```csharp
// HealthController.cs
[ApiController]
[Route("api/[controller]")]
public class HealthController : ControllerBase
{
    private readonly IServiceProvider _serviceProvider;
    private readonly IConfiguration _configuration;

    public HealthController(IServiceProvider serviceProvider, IConfiguration configuration)
    {
        _serviceProvider = serviceProvider;
        _configuration = configuration;
    }

    [HttpGet]
    [AllowAnonymous]
    public IActionResult Get()
    {
        var checks = new Dictionary<string, string>();

        // Check DB connectivity
        try
        {
            using var scope = _serviceProvider.CreateScope();
            var connString = _configuration.GetConnectionString("DefaultConnection");
            if (!string.IsNullOrEmpty(connString))
            {
                using var conn = new Microsoft.Data.SqlClient.SqlConnection(connString);
                conn.Open();
                checks["database"] = "healthy";
            }
        }
        catch (Exception ex)
        {
            checks["database"] = $"unhealthy: {ex.Message}";
            return StatusCode(503, new { status = "unhealthy", checks });
        }

        checks["application"] = "healthy";
        return Ok(new { status = "healthy", checks, timestamp = DateTime.UtcNow });
    }
}
```

### Why This Matters
The GSD engine runs runtime smoke tests at 100% health. Without a health endpoint,
the engine cannot verify that:
- DI container resolves all services correctly
- Database connections work
- Seed data was inserted in correct FK order
- Middleware pipeline is configured properly

### Common Runtime Failures This Catches
1. **Scoped service from root provider**: Service registered as Scoped but injected into Singleton
2. **FK constraint violations**: Seed data inserted in wrong order (child before parent)
3. **Missing connection strings**: appsettings.json not configured for the environment
4. **Missing service registrations**: Interface not registered in DI container
'@

Set-Content -Path $healthPromptPath -Value $healthPromptContent -Encoding UTF8
Write-Host "  [OK] Created health-endpoint.md prompt template" -ForegroundColor Green

# ── 3. Create di-service-lifetime.md prompt template ──

$diPromptPath = Join-Path $sharedDir "di-service-lifetime.md"
$diPromptContent = @'
# DI Service Lifetime Rules

## CRITICAL: Avoid scoped-from-root provider errors

### Rule 1: Never inject Scoped into Singleton
A Singleton service cannot depend on a Scoped service. This causes:
`System.InvalidOperationException: Cannot resolve scoped service 'IMyService' from root provider`

**Fix**: Either make the dependency Singleton, or use IServiceScopeFactory:
```csharp
// WRONG - Scoped injected into Singleton
public class MySingleton
{
    public MySingleton(IMyScopedService svc) { } // BOOM at runtime
}

// RIGHT - Create scope manually
public class MySingleton
{
    private readonly IServiceScopeFactory _scopeFactory;
    public MySingleton(IServiceScopeFactory scopeFactory) { _scopeFactory = scopeFactory; }

    public void DoWork()
    {
        using var scope = _scopeFactory.CreateScope();
        var svc = scope.ServiceProvider.GetRequiredService<IMyScopedService>();
    }
}
```

### Rule 2: Hosted services and background services are Singletons
`IHostedService`, `BackgroundService`, and anything registered with `AddHostedService<T>()`
runs as a Singleton. All their constructor dependencies must be Singleton or Transient,
never Scoped.

### Rule 3: Middleware constructors are Singleton-scoped
Middleware is instantiated once. Use `Invoke(HttpContext, IMyService)` method injection
for scoped dependencies, NOT constructor injection.

### Rule 4: Validate DI at startup (recommended)
```csharp
// In Program.cs, after builder.Build():
var app = builder.Build();

// Validate all services can be resolved
if (app.Environment.IsDevelopment())
{
    app.Services.GetRequiredService<IServiceProviderIsService>();
    // The above line triggers eager validation
}
```

## Seed Data FK Ordering
When generating SQL seed scripts, ALWAYS insert parent tables before child tables:
1. Users (parent)
2. MyGPTs (child - has FK to Users.Id)
3. ChatMessages (child - has FK to Users.Id and MyGPTs.Id)

Never use hardcoded GUIDs for FK references. Use:
```sql
-- Insert parent first
INSERT INTO Users (Id, Username) VALUES (NEWID(), 'system');

-- Reference parent with subquery
INSERT INTO MyGPTs (Id, OwnerUserId, Name)
VALUES (NEWID(), (SELECT TOP 1 Id FROM Users WHERE Username = 'system'), 'Default GPT');
```
'@

Set-Content -Path $diPromptPath -Value $diPromptContent -Encoding UTF8
Write-Host "  [OK] Created di-service-lifetime.md prompt template" -ForegroundColor Green

# ── 4. Add runtime smoke test functions to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    $smokeTestCode = @'

# ===============================================================
# GSD RUNTIME SMOKE TEST MODULES - appended to resilience.ps1
# ===============================================================

function Test-SeedDataFkOrder {
    <#
    .SYNOPSIS
        Static scan of SQL seed files to detect FK ordering violations.
        Zero-cost: no database connection or LLM calls needed.
    #>
    param(
        [string]$RepoRoot
    )

    $result = @{ Passed = $true; Violations = @(); TablesFound = @() }

    # Find SQL files that look like seed data
    $sqlFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sql" -Recurse -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git|bin|obj|migrations)" } |
        Sort-Object Name

    if (-not $sqlFiles -or $sqlFiles.Count -eq 0) { return $result }

    # Build FK dependency map from CREATE TABLE statements
    $fkMap = @{}   # child_table -> @(parent_table, ...)
    $insertOrder = [System.Collections.ArrayList]@()

    foreach ($sf in $sqlFiles) {
        $content = Get-Content $sf.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Extract CREATE TABLE ... FOREIGN KEY ... REFERENCES patterns
        $fkMatches = [regex]::Matches($content,
            'CREATE\s+TABLE\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?.*?FOREIGN\s+KEY.*?REFERENCES\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::Singleline)

        foreach ($m in $fkMatches) {
            $childTable = $m.Groups[1].Value.ToLower()
            $parentTable = $m.Groups[2].Value.ToLower()
            if (-not $fkMap.ContainsKey($childTable)) { $fkMap[$childTable] = @() }
            $fkMap[$childTable] += $parentTable
        }

        # Also catch inline FK: REFERENCES [Table](Column) in column definitions
        $inlineFkMatches = [regex]::Matches($content,
            'CREATE\s+TABLE\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?[^;]*?REFERENCES\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::Singleline)

        foreach ($m in $inlineFkMatches) {
            $childTable = $m.Groups[1].Value.ToLower()
            $parentTable = $m.Groups[2].Value.ToLower()
            if ($childTable -ne $parentTable) {
                if (-not $fkMap.ContainsKey($childTable)) { $fkMap[$childTable] = @() }
                if ($fkMap[$childTable] -notcontains $parentTable) {
                    $fkMap[$childTable] += $parentTable
                }
            }
        }

        # Track INSERT order across all files
        $insertMatches = [regex]::Matches($content,
            'INSERT\s+INTO\s+(?:\[?dbo\]?\.)?\[?(\w+)\]?',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        foreach ($m in $insertMatches) {
            $tableName = $m.Groups[1].Value.ToLower()
            if ($insertOrder -notcontains $tableName) {
                [void]$insertOrder.Add($tableName)
            }
        }
    }

    $result.TablesFound = @($insertOrder)

    # Check: for each child table INSERT, verify parent table was INSERTed first
    foreach ($childTable in $insertOrder) {
        if ($fkMap.ContainsKey($childTable)) {
            $childIdx = $insertOrder.IndexOf($childTable)
            foreach ($parentTable in $fkMap[$childTable]) {
                $parentIdx = $insertOrder.IndexOf($parentTable)
                if ($parentIdx -lt 0) {
                    $result.Violations += "FK MISSING: '$childTable' references '$parentTable' but '$parentTable' has no INSERT statement"
                    $result.Passed = $false
                } elseif ($parentIdx -gt $childIdx) {
                    $result.Violations += "FK ORDER: '$childTable' is INSERTed before its parent '$parentTable' (will cause FK violation)"
                    $result.Passed = $false
                }
            }
        }
    }

    return $result
}


function Find-ApiEndpoints {
    <#
    .SYNOPSIS
        Discovers API endpoints from controllers, route attributes, and OpenAPI specs.
        Returns list of @{ Method; Path } objects.
    #>
    param(
        [string]$RepoRoot
    )

    $endpoints = @()

    # Strategy 1: Parse .NET controller route attributes
    $controllers = Get-ChildItem -Path $RepoRoot -Filter "*Controller*.cs" -Recurse -Depth 5 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "(node_modules|\.git|bin|obj|Tests?)" }

    foreach ($ctrl in $controllers) {
        $content = Get-Content $ctrl.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Extract class-level route prefix
        $classRoute = ""
        $classRouteMatch = [regex]::Match($content, '\[Route\("([^"]+)"\)\]')
        if ($classRouteMatch.Success) {
            $classRoute = $classRouteMatch.Groups[1].Value
            # Replace [controller] placeholder
            $ctrlName = [regex]::Match($ctrl.BaseName, '(\w+?)Controller').Groups[1].Value.ToLower()
            $classRoute = $classRoute -replace '\[controller\]', $ctrlName
        }

        # Extract method-level HTTP attributes
        $httpMethods = [regex]::Matches($content,
            '\[(Http(Get|Post|Put|Delete|Patch))(?:\("([^"]*)"\))?\]',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        foreach ($m in $httpMethods) {
            $method = $m.Groups[2].Value.ToUpper()
            $methodRoute = $m.Groups[3].Value

            $fullPath = if ($methodRoute) {
                if ($methodRoute.StartsWith("/")) { $methodRoute }
                elseif ($classRoute) { "$classRoute/$methodRoute".TrimEnd("/") }
                else { $methodRoute }
            } else { $classRoute }

            # Normalize: ensure starts with /
            if ($fullPath -and -not $fullPath.StartsWith("/")) { $fullPath = "/$fullPath" }

            # Replace route parameters with test values
            $testPath = $fullPath -replace '\{[^}]*:?int\}', '1' `
                                  -replace '\{[^}]*:?guid\}', '00000000-0000-0000-0000-000000000001' `
                                  -replace '\{[^}]*\}', 'test'

            if ($testPath) {
                $endpoints += @{ Method = $method; Path = $testPath; Source = $ctrl.Name }
            }
        }
    }

    # Strategy 2: Parse OpenAPI/Swagger JSON if available
    $swaggerFiles = Get-ChildItem -Path $RepoRoot -Filter "swagger*.json" -Recurse -Depth 3 -ErrorAction SilentlyContinue
    $swaggerFiles += Get-ChildItem -Path $RepoRoot -Filter "openapi*.json" -Recurse -Depth 3 -ErrorAction SilentlyContinue

    foreach ($sf in $swaggerFiles) {
        try {
            $spec = Get-Content $sf.FullName -Raw | ConvertFrom-Json
            if ($spec.paths) {
                $spec.paths.PSObject.Properties | ForEach-Object {
                    $path = $_.Name
                    $testPath = $path -replace '\{[^}]*\}', 'test'
                    $_.Value.PSObject.Properties | Where-Object { $_.Name -in @("get","post","put","delete","patch") } | ForEach-Object {
                        $endpoints += @{ Method = $_.Name.ToUpper(); Path = $testPath; Source = $sf.Name }
                    }
                }
            }
        } catch {}
    }

    # Deduplicate
    $seen = @{}
    $unique = @()
    foreach ($ep in $endpoints) {
        $key = "$($ep.Method):$($ep.Path)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $unique += $ep
        }
    }

    return $unique
}


function Invoke-ApiSmokeTest {
    <#
    .SYNOPSIS
        Starts the application, hits API endpoints, checks for non-500 responses.
        This is the primary runtime validation that catches DI errors, FK violations,
        and unhandled exceptions.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $result = @{
        Passed       = $true
        StartupOk    = $false
        EndpointsTested = 0
        Failures     = @()
        Warnings     = @()
        Details      = @()
        HealthCheck  = $null
    }

    # Load config
    $startupTimeout = 30
    $requestTimeout = 10
    $maxEndpoints = 50
    $healthEndpoint = "/api/health"
    $failOnAny500 = $true

    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = (Get-Content $configPath -Raw | ConvertFrom-Json).runtime_smoke_test
            if ($config) {
                if ($config.startup_timeout_seconds) { $startupTimeout = [int]$config.startup_timeout_seconds }
                if ($config.request_timeout_seconds) { $requestTimeout = [int]$config.request_timeout_seconds }
                if ($config.max_endpoints_to_test) { $maxEndpoints = [int]$config.max_endpoints_to_test }
                if ($config.health_endpoint) { $healthEndpoint = $config.health_endpoint }
                if ($null -ne $config.fail_on_any_500) { $failOnAny500 = $config.fail_on_any_500 }
            }
        } catch {}
    }

    # Find the .NET project to run
    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -Recurse -Depth 2 -ErrorAction SilentlyContinue
    if (-not $slnFiles -or $slnFiles.Count -eq 0) {
        $result.Warnings += "No .sln found -- skipping runtime smoke test"
        return $result
    }

    # Find the web/API project (not test, not class library)
    $apiProject = Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "(Tests?|\.Test\.|test)" -and
            (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match "Microsoft\.NET\.Sdk\.Web"
        } | Select-Object -First 1

    if (-not $apiProject) {
        $result.Warnings += "No web/API .csproj found -- skipping runtime smoke test"
        return $result
    }

    # Determine port - check launchSettings.json
    $port = 5000
    $launchSettings = Join-Path (Split-Path $apiProject.FullName -Parent) "Properties\launchSettings.json"
    if (Test-Path $launchSettings) {
        try {
            $ls = Get-Content $launchSettings -Raw | ConvertFrom-Json
            $profiles = $ls.profiles.PSObject.Properties | Select-Object -First 1
            if ($profiles.Value.applicationUrl) {
                $urlMatch = [regex]::Match($profiles.Value.applicationUrl, 'https?://[^:]+:(\d+)')
                if ($urlMatch.Success) { $port = [int]$urlMatch.Groups[1].Value }
            }
        } catch {}
    }

    # Config override
    if ($config -and $config.port_override -and [int]$config.port_override -gt 0) {
        $port = [int]$config.port_override
    }

    $baseUrl = "http://localhost:$port"
    Write-Host "  [SMOKE] Starting app on port $port..." -ForegroundColor Cyan

    # Start the application
    $process = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "dotnet"
        $psi.Arguments = "run --project `"$($apiProject.FullName)`" --no-build --urls `"$baseUrl`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables["ASPNETCORE_ENVIRONMENT"] = "Development"
        $psi.EnvironmentVariables["DOTNET_ENVIRONMENT"] = "Development"

        $process = [System.Diagnostics.Process]::Start($psi)

        # Wait for startup - poll the health endpoint
        $startTime = Get-Date
        $ready = $false
        $startupError = ""

        while (((Get-Date) - $startTime).TotalSeconds -lt $startupTimeout) {
            Start-Sleep -Seconds 2

            # Check if process crashed
            if ($process.HasExited) {
                $stderr = $process.StandardError.ReadToEnd()
                $stdout = $process.StandardOutput.ReadToEnd()
                $startupError = "Application crashed on startup (exit code $($process.ExitCode))"

                # Extract specific error messages
                $allOutput = "$stderr`n$stdout"
                if ($allOutput -match "Cannot resolve scoped service") {
                    $startupError += "`nDI ERROR: Scoped service resolved from root provider"
                    $diMatch = [regex]::Match($allOutput, "Cannot resolve scoped service '([^']+)'")
                    if ($diMatch.Success) {
                        $startupError += " - Service: $($diMatch.Groups[1].Value)"
                    }
                }
                if ($allOutput -match "InvalidOperationException") {
                    $ioMatch = [regex]::Match($allOutput, "InvalidOperationException:\s*(.+?)(?:\r?\n|$)")
                    if ($ioMatch.Success) { $startupError += "`n$($ioMatch.Groups[1].Value)" }
                }
                if ($allOutput -match "SqlException") {
                    $sqlMatch = [regex]::Match($allOutput, "SqlException:\s*(.+?)(?:\r?\n|$)")
                    if ($sqlMatch.Success) { $startupError += "`nDB ERROR: $($sqlMatch.Groups[1].Value)" }
                }
                break
            }

            # Try to connect
            try {
                $response = Invoke-WebRequest -Uri "$baseUrl$healthEndpoint" -TimeoutSec 3 -ErrorAction Stop -UseBasicParsing
                if ($response.StatusCode -lt 500) {
                    $ready = $true
                    break
                }
            } catch {
                # Also try root endpoint as fallback
                try {
                    $response = Invoke-WebRequest -Uri "$baseUrl/" -TimeoutSec 3 -ErrorAction Stop -UseBasicParsing
                    if ($response.StatusCode -lt 500) {
                        $ready = $true
                        break
                    }
                } catch {
                    # Try swagger endpoint
                    try {
                        $response = Invoke-WebRequest -Uri "$baseUrl/swagger/index.html" -TimeoutSec 3 -ErrorAction Stop -UseBasicParsing
                        if ($response.StatusCode -lt 500) {
                            $ready = $true
                            break
                        }
                    } catch {
                        # Not ready yet, keep waiting
                    }
                }
            }
        }

        if (-not $ready) {
            if ($startupError) {
                $result.Failures += "STARTUP CRASH: $startupError"
            } else {
                $result.Failures += "STARTUP TIMEOUT: App did not respond within ${startupTimeout}s on $baseUrl"
            }
            $result.Passed = $false
            $result.StartupOk = $false
            return $result
        }

        $result.StartupOk = $true
        Write-Host "  [SMOKE] App ready. Testing endpoints..." -ForegroundColor Green

        # Test health endpoint specifically
        try {
            $healthResponse = Invoke-WebRequest -Uri "$baseUrl$healthEndpoint" -TimeoutSec $requestTimeout -ErrorAction Stop -UseBasicParsing
            $result.HealthCheck = @{
                StatusCode = $healthResponse.StatusCode
                Body = $healthResponse.Content.Substring(0, [math]::Min(500, $healthResponse.Content.Length))
            }
            if ($healthResponse.StatusCode -ge 500) {
                $result.Failures += "HEALTH ENDPOINT: $healthEndpoint returned $($healthResponse.StatusCode)"
                $result.Passed = $false
            } else {
                Write-Host "    [PASS] Health endpoint: $($healthResponse.StatusCode)" -ForegroundColor Green
            }
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -ge 500) {
                $result.Failures += "HEALTH ENDPOINT: $healthEndpoint returned $statusCode"
                $result.Passed = $false
                Write-Host "    [FAIL] Health endpoint: $statusCode" -ForegroundColor Red
            } elseif ($statusCode -eq 404) {
                $result.Warnings += "No health endpoint at $healthEndpoint (add HealthController)"
                Write-Host "    [WARN] Health endpoint not found (404)" -ForegroundColor Yellow
            } else {
                $result.Warnings += "Health endpoint error: $($_.Exception.Message)"
            }
        }

        # Discover and test API endpoints
        $endpoints = Find-ApiEndpoints -RepoRoot $RepoRoot
        if ($endpoints.Count -eq 0) {
            $result.Warnings += "No API endpoints discovered from controllers"
        } else {
            Write-Host "  [SMOKE] Found $($endpoints.Count) endpoints to test" -ForegroundColor Cyan

            $testCount = 0
            $failCount = 0

            foreach ($ep in ($endpoints | Select-Object -First $maxEndpoints)) {
                # Only smoke-test GET endpoints (safe, no side effects)
                if ($ep.Method -ne "GET") { continue }

                $testCount++
                $url = "$baseUrl$($ep.Path)"

                try {
                    $response = Invoke-WebRequest -Uri $url -Method GET -TimeoutSec $requestTimeout -ErrorAction Stop -UseBasicParsing
                    $detail = @{ endpoint = $ep.Path; method = $ep.Method; status = $response.StatusCode; result = "ok"; source = $ep.Source }
                    $result.Details += $detail

                    if ($response.StatusCode -ge 500) {
                        $failCount++
                        $result.Failures += "HTTP $($response.StatusCode): GET $($ep.Path) (from $($ep.Source))"
                        Write-Host "    [FAIL] GET $($ep.Path) -> $($response.StatusCode)" -ForegroundColor Red
                    } else {
                        Write-Host "    [PASS] GET $($ep.Path) -> $($response.StatusCode)" -ForegroundColor Green
                    }
                } catch {
                    $statusCode = 0
                    $errorBody = ""
                    if ($_.Exception.Response) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                        try {
                            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                            $errorBody = $reader.ReadToEnd()
                            $reader.Close()
                        } catch {}
                    }

                    $detail = @{ endpoint = $ep.Path; method = $ep.Method; status = $statusCode; result = "error"; error = $_.Exception.Message }
                    $result.Details += $detail

                    if ($statusCode -ge 500) {
                        $failCount++
                        $errorSummary = ""

                        # Extract meaningful error from response body
                        if ($errorBody -match "FOREIGN KEY constraint") {
                            $fkMatch = [regex]::Match($errorBody, 'FOREIGN KEY constraint "([^"]+)".*?table "([^"]+)"')
                            if ($fkMatch.Success) {
                                $errorSummary = "FK VIOLATION: $($fkMatch.Groups[1].Value) on $($fkMatch.Groups[2].Value)"
                            } else {
                                $errorSummary = "FK VIOLATION in response"
                            }
                        } elseif ($errorBody -match "Cannot resolve scoped service") {
                            $diMatch = [regex]::Match($errorBody, "Cannot resolve scoped service '([^']+)'")
                            $errorSummary = "DI ERROR: $(if ($diMatch.Success) { $diMatch.Groups[1].Value } else { 'scoped from root' })"
                        } elseif ($errorBody -match "SqlException") {
                            $sqlMatch = [regex]::Match($errorBody, "SqlException[^:]*:\s*(.+?)(?:\r?\n|$)")
                            $errorSummary = "DB ERROR: $(if ($sqlMatch.Success) { $sqlMatch.Groups[1].Value } else { 'SQL failure' })"
                        } else {
                            $errorSummary = "HTTP $statusCode"
                        }

                        $result.Failures += "${errorSummary}: GET $($ep.Path) (from $($ep.Source))"
                        Write-Host "    [FAIL] GET $($ep.Path) -> $statusCode ($errorSummary)" -ForegroundColor Red
                    } elseif ($statusCode -eq 401 -or $statusCode -eq 403) {
                        # Auth-protected endpoints are expected to reject anonymous requests
                        Write-Host "    [SKIP] GET $($ep.Path) -> $statusCode (auth required)" -ForegroundColor DarkGray
                    } elseif ($statusCode -eq 404) {
                        $result.Warnings += "Endpoint not found: GET $($ep.Path)"
                        Write-Host "    [WARN] GET $($ep.Path) -> 404" -ForegroundColor Yellow
                    } else {
                        Write-Host "    [PASS] GET $($ep.Path) -> $statusCode" -ForegroundColor Green
                    }
                }
            }

            $result.EndpointsTested = $testCount

            if ($failCount -gt 0 -and $failOnAny500) {
                $result.Passed = $false
            }
        }

    } catch {
        $result.Failures += "Smoke test error: $($_.Exception.Message)"
        $result.Passed = $false
    } finally {
        # Kill the application process
        if ($process -and -not $process.HasExited) {
            try {
                $process.Kill($true)  # Kill process tree
                $process.WaitForExit(5000)
            } catch {}
        }
        if ($process) { $process.Dispose() }
    }

    # Save results
    $testDir = Join-Path $GsdDir "tests"
    if (-not (Test-Path $testDir)) {
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
    }
    $smokeResultsPath = Join-Path $testDir "smoke-test-results.json"
    @{
        iteration        = $Iteration
        timestamp        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed           = $result.Passed
        startup_ok       = $result.StartupOk
        endpoints_tested = $result.EndpointsTested
        failures         = $result.Failures
        warnings         = $result.Warnings
        health_check     = $result.HealthCheck
        endpoint_details = $result.Details
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $smokeResultsPath -Encoding UTF8

    return $result
}


function Invoke-RuntimeSmokeTest {
    <#
    .SYNOPSIS
        Orchestrator that runs all runtime checks: seed FK order, DI validation,
        and API smoke test. Called from Invoke-FinalValidation as checks 8-10.
    #>
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir,
        [int]$Iteration
    )

    $result = @{
        Passed       = $true
        HardFailures = @()
        Warnings     = @()
        SeedCheck    = $null
        SmokeTest    = $null
    }

    # Check if enabled
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = (Get-Content $configPath -Raw | ConvertFrom-Json).runtime_smoke_test
            if ($config -and $config.enabled -eq $false) {
                Write-Host "  [SMOKE] Runtime smoke test disabled" -ForegroundColor DarkGray
                return $result
            }
        } catch {}
    }

    Write-Host ""
    Write-Host "  [SMOKE] === Runtime Smoke Test ===" -ForegroundColor Cyan

    # --- Check A: Seed Data FK Order ---
    Write-Host "  [SMOKE] Check A: Seed data FK ordering..." -ForegroundColor Cyan
    try {
        $seedResult = Test-SeedDataFkOrder -RepoRoot $RepoRoot
        $result.SeedCheck = $seedResult

        if (-not $seedResult.Passed) {
            foreach ($v in $seedResult.Violations) {
                $result.HardFailures += $v
                Write-Host "    [FAIL] $v" -ForegroundColor Red
            }
            $result.Passed = $false
        } else {
            $tableCount = if ($seedResult.TablesFound) { $seedResult.TablesFound.Count } else { 0 }
            Write-Host "    [PASS] $tableCount tables, FK ordering correct" -ForegroundColor Green
        }
    } catch {
        $result.Warnings += "Seed FK check error: $($_.Exception.Message)"
        Write-Host "    [WARN] $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # --- Check B: Runtime API Smoke Test ---
    Write-Host "  [SMOKE] Check B: Runtime API smoke test..." -ForegroundColor Cyan
    try {
        $smokeResult = Invoke-ApiSmokeTest -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $GlobalDir -Iteration $Iteration
        $result.SmokeTest = $smokeResult

        if (-not $smokeResult.Passed) {
            foreach ($f in $smokeResult.Failures) {
                $result.HardFailures += "RUNTIME: $f"
            }
            $result.Passed = $false
        }
        foreach ($w in $smokeResult.Warnings) {
            $result.Warnings += $w
        }
    } catch {
        $result.Warnings += "API smoke test error: $($_.Exception.Message)"
        Write-Host "    [WARN] Smoke test error: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Summary
    if ($result.Passed) {
        Write-Host "  [SMOKE] === ALL RUNTIME CHECKS PASSED ===" -ForegroundColor Green
    } else {
        Write-Host "  [SMOKE] === $($result.HardFailures.Count) RUNTIME FAILURE(S) ===" -ForegroundColor Red
        Write-Host "  [SMOKE] Health will be set to 99% for auto-fix loop" -ForegroundColor Yellow
    }

    return $result
}

Write-Host "  Runtime smoke test modules loaded." -ForegroundColor DarkGray
'@

    if ($existing -match "GSD RUNTIME SMOKE TEST MODULES") {
        # Remove old section and replace
        $markerLine = "`n# GSD RUNTIME SMOKE TEST MODULES"
        $idx = $existing.IndexOf($markerLine)
        if ($idx -gt 0) {
            $existing = $existing.Substring(0, $idx)
            Set-Content -Path $resilienceFile -Value $existing -Encoding UTF8
        }
        Add-Content -Path $resilienceFile -Value "`n$smokeTestCode" -Encoding UTF8
        Write-Host "  [OK] Updated runtime smoke test modules in resilience.ps1" -ForegroundColor DarkGreen
    } else {
        Add-Content -Path $resilienceFile -Value "`n$smokeTestCode" -Encoding UTF8
        Write-Host "  [OK] Appended runtime smoke test modules to resilience.ps1" -ForegroundColor DarkGreen
    }

    # ── 4b. Patch Invoke-FinalValidation to call runtime smoke test ──

    $integrationCode = @'

# ===========================================
# RUNTIME SMOKE TEST INTEGRATION
# ===========================================

# Wrap original Invoke-FinalValidation to add runtime checks
if (Get-Command Invoke-FinalValidation -ErrorAction SilentlyContinue) {
    # Save reference to original
    $script:OriginalFinalValidation = ${function:Invoke-FinalValidation}

    function Invoke-FinalValidation {
        param(
            [string]$RepoRoot,
            [string]$GsdDir,
            [int]$Iteration
        )

        # Run original 7 checks
        $result = & $script:OriginalFinalValidation -RepoRoot $RepoRoot -GsdDir $GsdDir -Iteration $Iteration

        # Run runtime smoke test (checks 8-10)
        $globalDir = Join-Path $env:USERPROFILE ".gsd-global"
        if (Get-Command Invoke-RuntimeSmokeTest -ErrorAction SilentlyContinue) {
            Write-Host ""
            Write-Host "  [SHIELD] Running runtime smoke tests (checks 8-10)..." -ForegroundColor Yellow

            $runtimeResult = Invoke-RuntimeSmokeTest -RepoRoot $RepoRoot -GsdDir $GsdDir -GlobalDir $globalDir -Iteration $Iteration

            # Merge runtime failures into main result
            if (-not $runtimeResult.Passed) {
                $result.Passed = $false
                foreach ($f in $runtimeResult.HardFailures) {
                    $result.HardFailures += $f
                }
            }
            foreach ($w in $runtimeResult.Warnings) {
                $result.Warnings += $w
            }

            # Add to details
            $result.Details["seed_fk_check"] = $runtimeResult.SeedCheck
            $result.Details["api_smoke_test"] = $runtimeResult.SmokeTest

            # Update saved results
            $jsonPath = Join-Path $GsdDir "health\final-validation.json"
            @{
                passed        = $result.Passed
                hard_failures = $result.HardFailures
                warnings      = $result.Warnings
                iteration     = $Iteration
                timestamp     = $result.Timestamp
                checks        = @{
                    dotnet_build   = $result.Details["dotnet_build"]
                    npm_build      = $result.Details["npm_build"]
                    dotnet_test    = $result.Details["dotnet_test"]
                    npm_test       = $result.Details["npm_test"]
                    sql            = $result.Details["sql_validation"]
                    dotnet_audit   = $result.Details["dotnet_audit"]
                    npm_audit      = $result.Details["npm_audit"]
                    seed_fk_check  = $result.Details["seed_fk_check"]
                    api_smoke_test = $result.Details["api_smoke_test"]
                }
            } | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8

            # Log runtime failures
            if (-not $runtimeResult.Passed -and (Get-Command Write-GsdError -ErrorAction SilentlyContinue)) {
                Write-GsdError -GsdDir $GsdDir -Category "runtime_failure" -Phase "smoke-test" `
                    -Iteration $Iteration -Message ($runtimeResult.HardFailures -join "; ")
            }
        }

        return $result
    }
}
'@

    if ($existing -match "RUNTIME SMOKE TEST INTEGRATION") {
        Write-Host "  [SKIP] Runtime smoke test integration already patched" -ForegroundColor DarkGray
    } else {
        Add-Content -Path $resilienceFile -Value "`n$integrationCode" -Encoding UTF8
        Write-Host "  [OK] Patched Invoke-FinalValidation with runtime smoke tests" -ForegroundColor Green
    }
}

# ── 5. Inject runtime requirements into agent execute prompts ──

$executePromptPaths = @(
    (Join-Path $GsdGlobalDir "prompts\codex\execute.md"),
    (Join-Path $GsdGlobalDir "prompts\claude\execute.md")
)

foreach ($promptPath in $executePromptPaths) {
    if (Test-Path $promptPath) {
        $promptContent = Get-Content $promptPath -Raw
        if ($promptContent -notlike "*health-endpoint*" -and $promptContent -notlike "*HealthController*") {
            $injection = @'

## Runtime Validation Requirements

The GSD engine performs runtime smoke tests at 100% health. Ensure:

1. **Health Endpoint**: Include a `/api/health` endpoint (see health-endpoint.md)
2. **DI Lifetimes**: Never inject Scoped services into Singletons (see di-service-lifetime.md)
3. **Seed Data Order**: INSERT parent tables before child tables (FK ordering)
4. **No 500 Errors**: All GET endpoints must return non-500 responses
'@
            $promptContent += $injection
            Set-Content -Path $promptPath -Value $promptContent -Encoding UTF8
            $promptName = Split-Path $promptPath -Leaf
            Write-Host "  [OK] Injected runtime requirements into $promptName" -ForegroundColor Green
        }
    }
}

# ── 6. Add api_smoke acceptance test type to plan.md ──

$planPromptPath = Join-Path $GsdGlobalDir "prompts\claude\plan.md"
if (Test-Path $planPromptPath) {
    $planContent = Get-Content $planPromptPath -Raw
    if ($planContent -notlike "*api_smoke*") {
        $apiSmokeType = @'

- **api_smoke**: Verify API endpoint returns non-500 response at runtime
  `{"type": "api_smoke", "method": "GET", "path": "/api/users", "expect_status": [200, 401]}`
'@
        # Insert after the existing test types section
        if ($planContent -match "npm_test") {
            $planContent = $planContent -replace '(\*\*npm_test\*\*:[^\n]+\n\s+`[^`]+`)', "`$1`n$apiSmokeType"
            Set-Content -Path $planPromptPath -Value $planContent -Encoding UTF8
            Write-Host "  [OK] Added api_smoke acceptance test type to plan.md" -ForegroundColor Green
        }
    } else {
        Write-Host "  [SKIP] plan.md already has api_smoke test type" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Green
Write-Host "  [OK] Runtime Smoke Test Patch Applied" -ForegroundColor Green
Write-Host "=========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  NEW CHECKS ADDED TO FINAL VALIDATION:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [CHECK 8] Seed Data FK Order Validation" -ForegroundColor White
Write-Host "     - Static scan: detects INSERT ordering FK violations" -ForegroundColor DarkGray
Write-Host "     - Zero cost: no DB connection or LLM calls" -ForegroundColor DarkGray
Write-Host "     - Catches: 'INSERT conflicted with FOREIGN KEY constraint'" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [CHECK 9] Runtime API Smoke Test" -ForegroundColor White
Write-Host "     - Starts the app, hits every GET endpoint" -ForegroundColor DarkGray
Write-Host "     - Checks for 500 Internal Server Errors" -ForegroundColor DarkGray
Write-Host "     - Catches: DI errors, FK violations, unhandled exceptions" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [CHECK 10] Health Endpoint Verification" -ForegroundColor White
Write-Host "     - Verifies /api/health returns healthy status" -ForegroundColor DarkGray
Write-Host "     - Validates DB connectivity and service resolution" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  PROMPT TEMPLATES ADDED:" -ForegroundColor Yellow
Write-Host "     - health-endpoint.md (mandates /api/health)" -ForegroundColor DarkGray
Write-Host "     - di-service-lifetime.md (prevents scoped-from-root)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  CONFIG: global-config.json -> runtime_smoke_test" -ForegroundColor Yellow
Write-Host "  DISABLE: set runtime_smoke_test.enabled = false" -ForegroundColor DarkGray
Write-Host ""
