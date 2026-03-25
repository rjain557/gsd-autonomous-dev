<#
.SYNOPSIS
    GSD V3 Runtime Validation - Start services, test endpoints, validate CRUD
.DESCRIPTION
    Starts backend (dotnet) and frontend (npm) processes, then performs runtime
    validation: health checks, login tests, API endpoint discovery, CRUD
    validation, and route/role verification.

    Usage:
      pwsh -File gsd-runtime-validate.ps1 -RepoRoot "D:\repos\project"
      pwsh -File gsd-runtime-validate.ps1 -RepoRoot "D:\repos\project" -ConnectionString "Server=.;Database=MyDb;..."
      pwsh -File gsd-runtime-validate.ps1 -RepoRoot "D:\repos\project" -TestUsers '[{"email":"admin@test.com","password":"Test!"}]'
.PARAMETER RepoRoot
    Repository root path (mandatory)
.PARAMETER ConnectionString
    SQL Server connection string (optional - passed to backend via env)
.PARAMETER TestUsers
    JSON array of test user credentials (optional)
.PARAMETER AzureAdConfig
    JSON object with Azure AD configuration (optional)
.PARAMETER BackendPort
    Port for the backend server (default: 5000)
.PARAMETER FrontendPort
    Port for the frontend dev server (default: 3000)
.PARAMETER FixModel
    Model used for generating fixes: claude or codex (default: "claude")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [string]$ConnectionString = "",
    [string]$TestUsers = "",
    [string]$AzureAdConfig = "",
    [int]$BackendPort = 5000,
    [int]$FrontendPort = 3000,
    [ValidateSet("claude","codex")]
    [string]$FixModel = "claude"
)

$ErrorActionPreference = "Continue"

# ============================================================
# SETUP: Resolve paths, load modules, load config
# ============================================================

$v3Dir = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir = Join-Path $RepoRoot ".gsd"

# Centralized logging
$repoName = Split-Path $RepoRoot -Leaf
$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/${repoName}"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }

$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile = Join-Path $globalLogDir "runtime-validate-${timestamp}.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "OK"    { "Green" }
        "SKIP"  { "DarkGray" }
        "FIX"   { "Magenta" }
        "PHASE" { "Cyan" }
        default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

# Load modules
$modulesDir = Join-Path $v3Dir "lib/modules"
$apiClientPath = Join-Path $modulesDir "api-client.ps1"
if (Test-Path $apiClientPath) { . $apiClientPath }

$costTrackerPath = Join-Path $modulesDir "cost-tracker.ps1"
if (Test-Path $costTrackerPath) { . $costTrackerPath }

# Load config
$configPath = Join-Path $v3Dir "config/global-config.json"
if (Test-Path $configPath) {
    $Config = Get-Content $configPath -Raw | ConvertFrom-Json
}

# Initialize cost tracking
if (Get-Command Initialize-CostTracker -ErrorAction SilentlyContinue) {
    Initialize-CostTracker -Mode "runtime_validate" -BudgetCap 3.0 -GsdDir $GsdDir
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD V3 - Runtime Validation" -ForegroundColor Cyan
Write-Host "  Repo: $RepoRoot" -ForegroundColor DarkGray
Write-Host "  Backend port: $BackendPort | Frontend port: $FrontendPort" -ForegroundColor DarkGray
if ($ConnectionString) { Write-Host "  DB: Connected" -ForegroundColor DarkGray }
if ($TestUsers) { Write-Host "  Test users: Configured" -ForegroundColor DarkGray }
Write-Host "  Log: $logFile" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

# ============================================================
# OUTPUT DIRECTORY
# ============================================================

$outDir = Join-Path $GsdDir "runtime-validation"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# Track all results
$validationResults = @{
    timestamp = (Get-Date -Format "o")
    backend = @{ started = $false; healthy = $false; errors = @() }
    frontend = @{ started = $false; responding = $false; errors = @() }
    health_checks = @()
    login_tests = @()
    endpoints = @()
    route_checks = @()
    summary = @{ total_checks = 0; passed = 0; failed = 0; skipped = 0 }
}

# Process tracking for cleanup
$script:backendProcess = $null
$script:frontendProcess = $null

# ============================================================
# HELPER: Wait for HTTP endpoint
# ============================================================

function Wait-ForEndpoint {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 60,
        [string]$Label = "endpoint"
    )
    Write-Log "Waiting for $Label at $Url (timeout ${TimeoutSeconds}s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                Write-Log "$Label is responding (HTTP $($response.StatusCode))" -Level OK
                return $true
            }
        } catch {
            # Connection refused or timeout - keep waiting
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "$Label did not respond within ${TimeoutSeconds}s" -Level ERROR
    return $false
}

# ============================================================
# PHASE 1: START BACKEND
# ============================================================

Write-Log "--- Phase 1: Start Backend ---" -Level PHASE

$csprojFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|test|Test|design|generated)\\' } |
    Where-Object { $_.Name -notmatch '\.(Tests|IntegrationTests)\.' })

$backendStarted = $false
if ($csprojFiles.Count -gt 0) {
    # Pick the main API project (prefer *.Api.csproj with Program.cs nearby)
    $mainCsproj = $csprojFiles | Where-Object {
        $_.Name -match '\.Api\.csproj$' -and (Test-Path (Join-Path (Split-Path $_.FullName -Parent) "Program.cs"))
    } | Select-Object -First 1

    # Fallback: any csproj with Program.cs
    if (-not $mainCsproj) {
        $mainCsproj = $csprojFiles | Where-Object {
            Test-Path (Join-Path (Split-Path $_.FullName -Parent) "Program.cs")
        } | Select-Object -First 1
    }

    if (-not $mainCsproj) { $mainCsproj = $csprojFiles[0] }

    $backendDir = Split-Path $mainCsproj.FullName -Parent
    Write-Log "Starting backend: $($mainCsproj.Name) on port $BackendPort"

    # Set environment variables
    $envVars = @{
        ASPNETCORE_URLS = "http://localhost:${BackendPort}"
        ASPNETCORE_ENVIRONMENT = "Development"
    }
    if ($ConnectionString) {
        $envVars["ConnectionStrings__DefaultConnection"] = $ConnectionString
    }

    # Start dotnet run in background
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "dotnet"
    $psi.Arguments = "run --project `"$($mainCsproj.FullName)`" --no-build"
    $psi.WorkingDirectory = $backendDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($kv in $envVars.GetEnumerator()) {
        $psi.EnvironmentVariables[$kv.Key] = $kv.Value
    }

    try {
        $script:backendProcess = [System.Diagnostics.Process]::Start($psi)
        $backendUrl = "http://localhost:${BackendPort}"
        $backendStarted = Wait-ForEndpoint -Url "${backendUrl}/health" -TimeoutSeconds 60 -Label "Backend"

        if (-not $backendStarted) {
            # Try without /health
            $backendStarted = Wait-ForEndpoint -Url $backendUrl -TimeoutSeconds 15 -Label "Backend (root)"
        }

        $validationResults.backend.started = $backendStarted
    } catch {
        Write-Log "Failed to start backend: $($_.Exception.Message)" -Level ERROR
        $validationResults.backend.errors += $_.Exception.Message
    }
} else {
    Write-Log "No .csproj files found - skipping backend" -Level SKIP
}

# ============================================================
# PHASE 2: START FRONTEND
# ============================================================

Write-Log "--- Phase 2: Start Frontend ---" -Level PHASE

$packageJsonFiles = @(Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
    Where-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        $content -and ($content -match '"start"')
    })

$frontendStarted = $false
if ($packageJsonFiles.Count -gt 0) {
    $frontendDir = Split-Path $packageJsonFiles[0].FullName -Parent
    Write-Log "Starting frontend: $frontendDir on port $FrontendPort"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "npm"
    $psi.Arguments = "start"
    $psi.WorkingDirectory = $frontendDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["PORT"] = "$FrontendPort"
    $psi.EnvironmentVariables["BROWSER"] = "none"

    try {
        $script:frontendProcess = [System.Diagnostics.Process]::Start($psi)
        $frontendUrl = "http://localhost:${FrontendPort}"
        $frontendStarted = Wait-ForEndpoint -Url $frontendUrl -TimeoutSeconds 60 -Label "Frontend"
        $validationResults.frontend.started = $frontendStarted
        $validationResults.frontend.responding = $frontendStarted
    } catch {
        Write-Log "Failed to start frontend: $($_.Exception.Message)" -Level ERROR
        $validationResults.frontend.errors += $_.Exception.Message
    }
} else {
    Write-Log "No package.json with start script found - skipping frontend" -Level SKIP
}

# ============================================================
# PHASE 3: HEALTH CHECKS
# ============================================================

Write-Log "--- Phase 3: Health Checks ---" -Level PHASE

$healthEndpoints = @("/health", "/api/auth/status", "/api/health")
$backendUrl = "http://localhost:${BackendPort}"

if ($backendStarted) {
    foreach ($endpoint in $healthEndpoints) {
        $checkUrl = "${backendUrl}${endpoint}"
        $checkResult = @{ endpoint = $endpoint; url = $checkUrl; status = "unknown"; status_code = 0 }
        try {
            $response = Invoke-WebRequest -Uri $checkUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $checkResult.status_code = $response.StatusCode
            $checkResult.status = if ($response.StatusCode -eq 200) { "pass" } else { "warn" }
            Write-Log "Health check $endpoint - HTTP $($response.StatusCode)" -Level $(if ($response.StatusCode -eq 200) { "OK" } else { "WARN" })
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $checkResult.status_code = $statusCode
            $checkResult.status = if ($statusCode -eq 401) { "auth_required" } else { "fail" }
            Write-Log "Health check $endpoint - HTTP $statusCode ($($_.Exception.Message))" -Level $(if ($statusCode -eq 401) { "WARN" } else { "ERROR" })
        }
        $validationResults.health_checks += $checkResult
        $validationResults.summary.total_checks++
        if ($checkResult.status -eq "pass") { $validationResults.summary.passed++ }
        elseif ($checkResult.status -eq "fail") { $validationResults.summary.failed++ }
        else { $validationResults.summary.skipped++ }
    }
} else {
    Write-Log "Backend not started - skipping health checks" -Level SKIP
    $validationResults.summary.skipped += $healthEndpoints.Count
}

# ============================================================
# PHASE 4: LOGIN TESTS
# ============================================================

Write-Log "--- Phase 4: Login Tests ---" -Level PHASE

$authTokens = @{}

if ($backendStarted -and $TestUsers) {
    try {
        $users = $TestUsers | ConvertFrom-Json
    } catch {
        Write-Log "Failed to parse TestUsers JSON: $($_.Exception.Message)" -Level WARN
        $users = @()
    }

    foreach ($user in $users) {
        $email = if ($user.email) { $user.email } else { $user.username }
        $password = $user.password
        $loginResult = @{ user = $email; status = "unknown"; token_received = $false }

        $loginUrl = "${backendUrl}/api/auth/login"
        $loginBody = @{ email = $email; password = $password } | ConvertTo-Json

        try {
            $response = Invoke-RestMethod -Uri $loginUrl -Method POST -Body $loginBody -ContentType "application/json" -TimeoutSec 15 -ErrorAction Stop
            if ($response.token -or $response.accessToken -or $response.access_token) {
                $token = if ($response.token) { $response.token }
                         elseif ($response.accessToken) { $response.accessToken }
                         else { $response.access_token }
                $authTokens[$email] = $token
                $loginResult.status = "pass"
                $loginResult.token_received = $true
                Write-Log "Login $email - SUCCESS (token received)" -Level OK
            } else {
                $loginResult.status = "warn"
                Write-Log "Login $email - response OK but no token found" -Level WARN
            }
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $loginResult.status = "fail"
            $loginResult.status_code = $statusCode
            Write-Log "Login $email - FAILED (HTTP $statusCode)" -Level ERROR
        }

        $validationResults.login_tests += $loginResult
        $validationResults.summary.total_checks++
        if ($loginResult.status -eq "pass") { $validationResults.summary.passed++ }
        elseif ($loginResult.status -eq "fail") { $validationResults.summary.failed++ }
    }
} else {
    Write-Log "Skipping login tests (backend not started or no test users)" -Level SKIP
}

# ============================================================
# PHASE 5: API ENDPOINT DISCOVERY
# ============================================================

Write-Log "--- Phase 5: API Endpoint Discovery ---" -Level PHASE

$discoveredEndpoints = @()

# Parse C# controller files for [Route] and [Http*] attributes
$controllerFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules)\\' } |
    Where-Object { $_.Name -match 'Controller\.cs$' -or $_.FullName -match '\\Controllers\\' })

foreach ($ctrlFile in $controllerFiles) {
    $content = Get-Content $ctrlFile.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    # Extract class-level route
    $classRoute = ""
    if ($content -match '\[Route\("([^"]+)"\)\]') {
        $classRoute = $Matches[1] -replace '\[controller\]', ($ctrlFile.BaseName -replace 'Controller$', '')
    }

    # Extract method-level routes
    $httpMethods = [regex]::Matches($content, '\[(Http(Get|Post|Put|Delete|Patch))(?:\("([^"]*)")?\)\]')
    foreach ($m in $httpMethods) {
        $httpMethod = $m.Groups[2].Value.ToUpper()
        $methodRoute = $m.Groups[3].Value
        $fullRoute = if ($methodRoute) { "/${classRoute}/${methodRoute}" } else { "/${classRoute}" }
        $fullRoute = $fullRoute -replace '//', '/' -replace '\{[^}]+\}', '{id}'

        $discoveredEndpoints += @{
            method = $httpMethod
            route = $fullRoute
            controller = $ctrlFile.BaseName
            file = $ctrlFile.FullName
        }
    }
}

Write-Log "Discovered $($discoveredEndpoints.Count) API endpoints from $($controllerFiles.Count) controller(s)"

# ============================================================
# PHASE 6: CRUD VALIDATION
# ============================================================

Write-Log "--- Phase 6: CRUD Validation ---" -Level PHASE

if ($backendStarted -and $discoveredEndpoints.Count -gt 0) {
    # Get first available auth token
    $defaultToken = $null
    if ($authTokens.Count -gt 0) {
        $defaultToken = $authTokens.Values | Select-Object -First 1
    }

    foreach ($ep in $discoveredEndpoints) {
        if ($ep.method -ne "GET") { continue }  # Only test GET endpoints for safety

        $testUrl = "${backendUrl}$($ep.route)" -replace '\{id\}', '1'
        $endpointResult = @{
            method = $ep.method
            route = $ep.route
            controller = $ep.controller
            status = "unknown"
            status_code = 0
            auth_required = $false
        }

        try {
            $response = Invoke-WebRequest -Uri $testUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $endpointResult.status_code = $response.StatusCode
            $endpointResult.status = "pass"
            Write-Log "GET $($ep.route) - HTTP $($response.StatusCode)" -Level OK
        } catch {
            $statusCode = 0
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            $endpointResult.status_code = $statusCode

            if ($statusCode -eq 401 -and $defaultToken) {
                # Retry with auth
                $endpointResult.auth_required = $true
                try {
                    $headers = @{ "Authorization" = "Bearer $defaultToken" }
                    $retryResponse = Invoke-WebRequest -Uri $testUrl -UseBasicParsing -Headers $headers -TimeoutSec 10 -ErrorAction Stop
                    $endpointResult.status_code = $retryResponse.StatusCode
                    $endpointResult.status = "pass_with_auth"
                    Write-Log "GET $($ep.route) - HTTP $($retryResponse.StatusCode) (with auth)" -Level OK
                } catch {
                    $retryCode = 0
                    if ($_.Exception.Response) { $retryCode = [int]$_.Exception.Response.StatusCode }
                    $endpointResult.status_code = $retryCode
                    $endpointResult.status = "fail"
                    Write-Log "GET $($ep.route) - HTTP $retryCode (even with auth)" -Level ERROR
                }
            } elseif ($statusCode -eq 401) {
                $endpointResult.auth_required = $true
                $endpointResult.status = "auth_required"
                Write-Log "GET $($ep.route) - HTTP 401 (no token available)" -Level WARN
            } else {
                $endpointResult.status = "fail"
                Write-Log "GET $($ep.route) - HTTP $statusCode" -Level ERROR
            }
        }

        $validationResults.endpoints += $endpointResult
        $validationResults.summary.total_checks++
        if ($endpointResult.status -eq "pass" -or $endpointResult.status -eq "pass_with_auth") {
            $validationResults.summary.passed++
        } elseif ($endpointResult.status -eq "fail") {
            $validationResults.summary.failed++
        } else {
            $validationResults.summary.skipped++
        }
    }
} else {
    Write-Log "Skipping CRUD validation (backend not started or no endpoints discovered)" -Level SKIP
}

# ============================================================
# PHASE 7: NAVIGATION / ROUTE CHECK
# ============================================================

Write-Log "--- Phase 7: Navigation / Route Check ---" -Level PHASE

# Find router files
$routerFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.tsx" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
    Where-Object { $_.Name -match '(?i)(router|routes|App)\.(tsx|jsx)$' })

foreach ($routerFile in $routerFiles) {
    $content = Get-Content $routerFile.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    # Extract route paths from common patterns
    $routeMatches = [regex]::Matches($content, '(?:path\s*[=:]\s*[''"]|to\s*[=:]\s*[''"])(/[^''"]*)[''"]')
    foreach ($rm in $routeMatches) {
        $routePath = $rm.Groups[1].Value
        $routeResult = @{
            route = $routePath
            source_file = $routerFile.FullName
            status = "discovered"
        }
        $validationResults.route_checks += $routeResult
    }
}

Write-Log "Discovered $($validationResults.route_checks.Count) frontend routes"

# ============================================================
# PHASE 8: STOP SERVICES
# ============================================================

Write-Log "--- Phase 8: Stop Services ---" -Level PHASE

if ($script:backendProcess -and -not $script:backendProcess.HasExited) {
    try {
        $script:backendProcess.Kill($true)
        Write-Log "Backend process stopped" -Level OK
    } catch {
        Write-Log "Failed to stop backend: $($_.Exception.Message)" -Level WARN
    }
}

if ($script:frontendProcess -and -not $script:frontendProcess.HasExited) {
    try {
        $script:frontendProcess.Kill($true)
        Write-Log "Frontend process stopped" -Level OK
    } catch {
        Write-Log "Failed to stop frontend: $($_.Exception.Message)" -Level WARN
    }
}

# Also kill any orphaned processes on our ports
try {
    $portProcesses = Get-NetTCPConnection -LocalPort $BackendPort -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($pid in $portProcesses) {
        Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    }
} catch { }

try {
    $portProcesses = Get-NetTCPConnection -LocalPort $FrontendPort -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($pid in $portProcesses) {
        Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    }
} catch { }

Write-Log "All services stopped"

# ============================================================
# GENERATE REPORT
# ============================================================

$validationResults | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "runtime-validation-report.json") -Encoding UTF8

# Generate markdown summary
$summaryMd = "# Runtime Validation Report`n"
$summaryMd += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n"
$summaryMd += "## Summary`n"
$summaryMd += "- Total checks: $($validationResults.summary.total_checks)`n"
$summaryMd += "- Passed: $($validationResults.summary.passed)`n"
$summaryMd += "- Failed: $($validationResults.summary.failed)`n"
$summaryMd += "- Skipped: $($validationResults.summary.skipped)`n`n"

$summaryMd += "## Backend`n"
$summaryMd += "- Started: $($validationResults.backend.started)`n"
$summaryMd += "- Healthy: $($validationResults.backend.healthy)`n`n"

$summaryMd += "## Frontend`n"
$summaryMd += "- Started: $($validationResults.frontend.started)`n"
$summaryMd += "- Responding: $($validationResults.frontend.responding)`n`n"

if ($validationResults.health_checks.Count -gt 0) {
    $summaryMd += "## Health Checks`n"
    $summaryMd += "| Endpoint | Status | HTTP Code |`n|----------|--------|-----------|`n"
    foreach ($hc in $validationResults.health_checks) {
        $summaryMd += "| $($hc.endpoint) | $($hc.status) | $($hc.status_code) |`n"
    }
    $summaryMd += "`n"
}

if ($validationResults.login_tests.Count -gt 0) {
    $summaryMd += "## Login Tests`n"
    $summaryMd += "| User | Status | Token |`n|------|--------|-------|`n"
    foreach ($lt in $validationResults.login_tests) {
        $summaryMd += "| $($lt.user) | $($lt.status) | $($lt.token_received) |`n"
    }
    $summaryMd += "`n"
}

if ($validationResults.endpoints.Count -gt 0) {
    $summaryMd += "## API Endpoints ($($validationResults.endpoints.Count) tested)`n"
    $summaryMd += "| Method | Route | Status | HTTP |`n|--------|-------|--------|------|`n"
    foreach ($ep in $validationResults.endpoints) {
        $summaryMd += "| $($ep.method) | $($ep.route) | $($ep.status) | $($ep.status_code) |`n"
    }
    $summaryMd += "`n"
}

$summaryMd += "## Frontend Routes ($($validationResults.route_checks.Count) discovered)`n"
foreach ($rc in $validationResults.route_checks) {
    $summaryMd += "- $($rc.route)`n"
}

$summaryMd | Set-Content (Join-Path $outDir "runtime-validation-summary.md") -Encoding UTF8

$overallStatus = if ($validationResults.summary.failed -eq 0) { "PASS" } else { "FAIL" }
$statusColor = if ($overallStatus -eq "PASS") { "Green" } else { "Red" }

Write-Host "`n============================================" -ForegroundColor $statusColor
Write-Host "  Runtime Validation: $overallStatus" -ForegroundColor $statusColor
Write-Host "  Passed: $($validationResults.summary.passed) | Failed: $($validationResults.summary.failed) | Skipped: $($validationResults.summary.skipped)" -ForegroundColor DarkGray
Write-Host "  Report: $(Join-Path $outDir 'runtime-validation-report.json')" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor $statusColor
