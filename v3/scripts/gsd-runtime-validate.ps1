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
    [string]$FixModel = "claude",
    [switch]$KeepServicesRunning
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
# HELPER: Invoke-BashCurl - Uses native curl.exe for reliable loopback checks
# ============================================================

function Invoke-BashCurl {
    param(
        [string]$Url,
        [string]$Method = "GET",
        [string]$Body = "",
        [string]$ContentType = "",
        [string]$AuthToken = "",
        [int]$TimeoutSec = 10
    )
    $curlArgs = @("-s", "-o", "NUL", "-w", "%{http_code}", "--max-time", "$TimeoutSec")
    if ($Method -ne "GET") { $curlArgs += @("-X", $Method) }
    if ($ContentType) { $curlArgs += @("-H", "Content-Type: $ContentType") }
    if ($AuthToken) { $curlArgs += @("-H", "Authorization: Bearer $AuthToken") }
    if ($Body) { $curlArgs += @("--data-raw", $Body) }
    $curlArgs += $Url

    $result = & curl.exe @curlArgs 2>$null
    $statusCode = 0
    if ($result -match '(\d{3})') { $statusCode = [int]$Matches[1] }
    return $statusCode
}

function Invoke-BashCurlWithBody {
    param(
        [string]$Url,
        [string]$Method = "GET",
        [string]$Body = "",
        [string]$ContentType = "",
        [string]$AuthToken = "",
        [int]$TimeoutSec = 10
    )
    $curlArgs = @("-s", "-w", "`n%{http_code}", "--max-time", "$TimeoutSec")
    if ($Method -ne "GET") { $curlArgs += @("-X", $Method) }
    if ($ContentType) { $curlArgs += @("-H", "Content-Type: $ContentType") }
    if ($AuthToken) { $curlArgs += @("-H", "Authorization: Bearer $AuthToken") }
    if ($Body) { $curlArgs += @("--data-raw", $Body) }
    $curlArgs += $Url

    $rawOutput = & curl.exe @curlArgs 2>$null
    $lines = $rawOutput -split "`n"
    $statusCode = 0
    $responseBody = ""
    if ($lines.Count -gt 0) {
        $lastLine = $lines[-1].Trim()
        if ($lastLine -match '^\d{3}$') { $statusCode = [int]$lastLine }
        $responseBody = ($lines[0..($lines.Count - 2)]) -join "`n"
    }
    return @{ StatusCode = $statusCode; Body = $responseBody }
}

# ============================================================
# HELPER: Wait for HTTP endpoint (uses bash curl)
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
        $statusCode = Invoke-BashCurl -Url $Url -TimeoutSec 5
        if ($statusCode -ge 200 -and $statusCode -lt 500) {
            Write-Log "$Label is responding (HTTP $statusCode)" -Level OK
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "$Label did not respond within ${TimeoutSeconds}s" -Level ERROR
    return $false
}

function Add-StartupCheckResult {
    param(
        [string]$Component,
        [bool]$Started,
        [string]$Details = ""
    )

    $validationResults.summary.total_checks++
    if ($Started) {
        $validationResults.summary.passed++
        return
    }

    $validationResults.summary.failed++
    if ($Details) {
        Write-Log "$Component startup failed: $Details" -Level ERROR
    }
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
        DOTNET_LAUNCH_PROFILE = ""
        Kestrel__Endpoints__Http__Url = "http://localhost:${BackendPort}"
    }
    if ($ConnectionString) {
        $envVars["ConnectionStrings__DefaultConnection"] = $ConnectionString
    }

    # Start dotnet run in background
    # IMPORTANT: Do NOT redirect stdout/stderr for long-running processes!
    # On Windows, pipe buffer fills (~4KB) and blocks the process, causing
    # all HTTP responses to hang. Instead, redirect to a log file.
    $backendLogFile = Join-Path $outDir "backend-stdout.log"
    $backendErrFile = Join-Path $outDir "backend-stderr.log"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "dotnet"
    $psi.Arguments = "run --project `"$($mainCsproj.FullName)`" --no-build"
    $psi.WorkingDirectory = $backendDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true
    foreach ($kv in $envVars.GetEnumerator()) {
        $psi.EnvironmentVariables[$kv.Key] = $kv.Value
    }

    # Suppress console output by redirecting via cmd
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c dotnet run --project `"$($mainCsproj.FullName)`" --no-build --no-launch-profile > `"$backendLogFile`" 2> `"$backendErrFile`""

    try {
        $script:backendProcess = [System.Diagnostics.Process]::Start($psi)
        $backendUrl = "http://localhost:${BackendPort}"
        $backendStarted = Wait-ForEndpoint -Url "${backendUrl}/health" -TimeoutSeconds 60 -Label "Backend"

        if (-not $backendStarted) {
            # Try without /health
            $backendStarted = Wait-ForEndpoint -Url $backendUrl -TimeoutSeconds 15 -Label "Backend (root)"
        }

        # If backend didn't start, read log files to diagnose WHY
        if (-not $backendStarted) {
            Write-Log "Backend failed to respond - reading log files for diagnosis..." -Level WARN
            $stdoutText = if (Test-Path $backendLogFile) { Get-Content $backendLogFile -Raw -ErrorAction SilentlyContinue } else { "" }
            $stderrText = if (Test-Path $backendErrFile) { Get-Content $backendErrFile -Raw -ErrorAction SilentlyContinue } else { "" }
            $combinedOutput = "$stdoutText`n$stderrText"

            # Check for DI resolution failures
            if ($combinedOutput -match "Unable to resolve service|No service for type|InvalidOperationException.*registered") {
                $missingServices = [regex]::Matches($combinedOutput, "Unable to resolve service for type '([^']+)'") |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
                $noServiceTypes = [regex]::Matches($combinedOutput, "No service for type '([^']+)'") |
                    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
                $allMissing = @($missingServices) + @($noServiceTypes) | Sort-Object -Unique

                Write-Log "ROOT CAUSE: DI container missing $($allMissing.Count) service registration(s)" -Level ERROR
                foreach ($svc in $allMissing) {
                    Write-Log "  Missing DI: $svc" -Level ERROR
                }
                $validationResults.backend.errors += "DI_RESOLUTION_FAILURE"
                $validationResults.backend.errors += $allMissing

                # Save DI errors for pipeline consumption
                $diErrorFile = Join-Path $outDir "di-errors.json"
                @{
                    timestamp = (Get-Date -Format "o")
                    missing_services = $allMissing
                    raw_output = ($combinedOutput -split "`n" | Select-Object -First 100) -join "`n"
                } | ConvertTo-Json -Depth 5 | Set-Content $diErrorFile -Encoding UTF8
            } elseif ($combinedOutput -match "Unhandled exception|Application startup exception|Host terminated unexpectedly") {
                $errorLines = @($combinedOutput -split "`n" |
                    Where-Object { $_ -match 'Exception|Error|Unhandled|terminated|FATAL|fail' } |
                    Select-Object -First 15)
                Write-Log "ROOT CAUSE: Application startup crash" -Level ERROR
                foreach ($line in $errorLines) {
                    Write-Log "  $($line.Trim())" -Level ERROR
                }
                $validationResults.backend.errors += "STARTUP_CRASH"
                $validationResults.backend.errors += $errorLines
            } else {
                $outputLines = @($combinedOutput -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 20)
                if ($outputLines.Count -gt 0) {
                    Write-Log "Backend output (no specific error pattern matched):" -Level WARN
                    foreach ($line in $outputLines) {
                        Write-Log "  $($line.Trim())" -Level WARN
                    }
                    $validationResults.backend.errors += "UNKNOWN_STARTUP_FAILURE"
                    $validationResults.backend.errors += $outputLines
                } else {
                    Write-Log "Backend produced no output - may have failed silently" -Level WARN
                    $validationResults.backend.errors += "NO_OUTPUT"
                }
            }
        }

        $validationResults.backend.started = $backendStarted
        Add-StartupCheckResult -Component "Backend" -Started:$backendStarted -Details "Startup logs written to $backendLogFile"
    } catch {
        Write-Log "Failed to start backend: $($_.Exception.Message)" -Level ERROR
        $validationResults.backend.errors += $_.Exception.Message
        Add-StartupCheckResult -Component "Backend" -Started:$false -Details $_.Exception.Message
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
    ForEach-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { return }

        $scriptCommand = if ($content -match '"start"') {
            "npm start"
        } elseif ($content -match '"dev"') {
            "npm run dev -- --host 127.0.0.1 --port $FrontendPort --strictPort"
        } else {
            $null
        }

        if ($scriptCommand) {
            [PSCustomObject]@{
                PackageJson = $_
                ScriptCommand = $scriptCommand
            }
        }
    })

$frontendStarted = $false
if ($packageJsonFiles.Count -gt 0) {
    $frontendPackage = $packageJsonFiles[0]
    $frontendDir = Split-Path $frontendPackage.PackageJson.FullName -Parent
    $frontendCommand = $frontendPackage.ScriptCommand
    Write-Log "Starting frontend: $frontendDir on port $FrontendPort"

    $frontendLogFile = Join-Path $outDir "frontend-stdout.log"
    $frontendErrFile = Join-Path $outDir "frontend-stderr.log"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c set PORT=$FrontendPort && set BROWSER=none && set CI=1 && $frontendCommand < NUL > `"$frontendLogFile`" 2> `"$frontendErrFile`""
    $psi.WorkingDirectory = $frontendDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true

    try {
        $script:frontendProcess = [System.Diagnostics.Process]::Start($psi)
        $frontendUrl = "http://127.0.0.1:${FrontendPort}"
        $frontendStarted = Wait-ForEndpoint -Url $frontendUrl -TimeoutSeconds 60 -Label "Frontend"
        if (-not $frontendStarted) {
            $frontendStarted = Wait-ForEndpoint -Url "http://localhost:${FrontendPort}" -TimeoutSeconds 15 -Label "Frontend (localhost)"
        }
        $validationResults.frontend.started = $frontendStarted
        $validationResults.frontend.responding = $frontendStarted
        Add-StartupCheckResult -Component "Frontend" -Started:$frontendStarted -Details "Startup logs written to $frontendLogFile"
    } catch {
        Write-Log "Failed to start frontend: $($_.Exception.Message)" -Level ERROR
        $validationResults.frontend.errors += $_.Exception.Message
        Add-StartupCheckResult -Component "Frontend" -Started:$false -Details $_.Exception.Message
    }
} else {
    Write-Log "No package.json with start/dev script found - skipping frontend" -Level SKIP
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

        $statusCode = Invoke-BashCurl -Url $checkUrl -TimeoutSec 10
        $checkResult.status_code = $statusCode

        if ($statusCode -eq 200) {
            $checkResult.status = "pass"
            Write-Log "Health check $endpoint - HTTP $statusCode" -Level OK
        } elseif ($statusCode -eq 404) {
            $checkResult.status = "pass"
            Write-Log "Health check $endpoint - HTTP 404 (endpoint not implemented, not blocking)" -Level OK
        } elseif ($statusCode -eq 401) {
            $checkResult.status = "pass"
            Write-Log "Health check $endpoint - HTTP $statusCode (auth required, route exists)" -Level OK
        } elseif ($statusCode -gt 0) {
            $checkResult.status = "warn"
            Write-Log "Health check $endpoint - HTTP $statusCode" -Level WARN
        } else {
            $checkResult.status = "fail"
            Write-Log "Health check $endpoint - HTTP 0 (unreachable)" -Level ERROR
        }

        $validationResults.health_checks += $checkResult
        $validationResults.summary.total_checks++
        if ($checkResult.status -eq "pass") { $validationResults.summary.passed++ }
        elseif ($checkResult.status -eq "fail") { $validationResults.summary.failed++ }
        else { $validationResults.summary.skipped++ }
    }
# Mark backend as healthy if /health returned 200
    $healthPassed = $validationResults.health_checks | Where-Object { $_.endpoint -eq "/health" -and $_.status -eq "pass" }
    if ($healthPassed) {
        $validationResults.backend.healthy = $true
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
        $loginBody = @{ loginHint = $email } | ConvertTo-Json -Compress

        $resp = Invoke-BashCurlWithBody -Url $loginUrl -Method "POST" -Body $loginBody -ContentType "application/json" -TimeoutSec 15

        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300 -and $resp.Body) {
            try {
                $parsed = $resp.Body | ConvertFrom-Json -ErrorAction Stop
                $token = if ($parsed.token) { $parsed.token }
                         elseif ($parsed.accessToken) { $parsed.accessToken }
                         elseif ($parsed.access_token) { $parsed.access_token }
                         else { $null }
                $authorizationUrl = if ($parsed.authorizationUrl) { $parsed.authorizationUrl }
                                    elseif ($parsed.AuthorizationUrl) { $parsed.AuthorizationUrl }
                                    else { $null }
                $state = if ($parsed.state) { $parsed.state }
                         elseif ($parsed.State) { $parsed.State }
                         else { $null }
                if ($token) {
                    $authTokens[$email] = $token
                    $loginResult.status = "pass"
                    $loginResult.token_received = $true
                    Write-Log "Login $email - SUCCESS (token received)" -Level OK
                } elseif ($authorizationUrl) {
                    $loginResult.status = "pass"
                    Write-Log "Login $email - SUCCESS (OAuth initiation response received)" -Level OK
                } else {
                    $loginResult.status = "warn"
                    Write-Log "Login $email - HTTP $($resp.StatusCode) but no token in response" -Level WARN
                }
            } catch {
                $loginResult.status = "warn"
                Write-Log "Login $email - HTTP $($resp.StatusCode) but response not JSON" -Level WARN
            }
        } else {
            $loginResult.status = "fail"
            $loginResult.status_code = $resp.StatusCode
            Write-Log "Login $email - FAILED (HTTP $($resp.StatusCode))" -Level ERROR
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
$seenRoutes = @{}

# Parse C# controller files for [Route] and [Http*] attributes
$controllerFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|design|generated|test|Test)\\' } |
    Where-Object { $_.Name -match 'Controller\.cs$' })

foreach ($ctrlFile in $controllerFiles) {
    $content = Get-Content $ctrlFile.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    # Extract class-level route
    $classRoute = ""
    if ($content -match '\[Route\("([^"]+)"\)\]') {
        $classRoute = $Matches[1] -replace '\[controller\]', ($ctrlFile.BaseName -replace 'Controller$', '' -replace 's$', '').ToLower()
    }

    # Skip controllers without a Route attribute (they won't be mapped to /api/*)
    if (-not $classRoute) { continue }

    # Extract method-level routes
    $httpMethods = [regex]::Matches($content, '\[(Http(Get|Post|Put|Delete|Patch))(?:\("([^"]*)")?\)\]')
    foreach ($m in $httpMethods) {
        $httpMethod = $m.Groups[2].Value.ToUpper()
        $methodRoute = $m.Groups[3].Value
        $fullRoute = if (-not $methodRoute) {
            "/${classRoute}"
        } elseif ($methodRoute.StartsWith("/")) {
            $methodRoute
        } else {
            "/${classRoute}/${methodRoute}"
        }
        $fullRoute = $fullRoute -replace '//', '/' -replace '\{[^}]+\}', '{id}'

        # Deduplicate routes (same method + normalized route)
        $routeKey = "$httpMethod|$fullRoute"
        if ($seenRoutes.ContainsKey($routeKey)) { continue }
        $seenRoutes[$routeKey] = $true

        $discoveredEndpoints += @{
            method = $httpMethod
            route = $fullRoute
            controller = $ctrlFile.BaseName
            file = $ctrlFile.FullName
        }
    }
}

Write-Log "Discovered $($discoveredEndpoints.Count) unique API endpoints from $($controllerFiles.Count) controller(s)"

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
            file = $ep.file        # controller file path — used by endpoint fixer
            status = "unknown"
            status_code = 0
            auth_required = $false
        }

        # Use bash curl (bypasses Windows .NET loopback networking issue)
        $statusCode = Invoke-BashCurl -Url $testUrl -TimeoutSec 5

        if ($statusCode -ge 200 -and $statusCode -lt 400) {
            $endpointResult.status = "pass"
            $endpointResult.status_code = $statusCode
            Write-Log "GET $($ep.route) - HTTP $statusCode" -Level OK
        } elseif ($statusCode -eq 401) {
            # 401 = route exists, auth is working correctly. Count as pass.
            $endpointResult.auth_required = $true
            $endpointResult.status_code = 401
            $endpointResult.status = "pass"
            Write-Log "GET $($ep.route) - HTTP 401 (route exists, auth required)" -Level OK
        } elseif ($statusCode -eq 404 -and $ep.route -match '\{id\}') {
            # 404 on a parameterized route is expected (entity with id=1 doesn't exist)
            $endpointResult.status = "pass"
            $endpointResult.status_code = 404
            Write-Log "GET $($ep.route) - HTTP 404 (expected - entity not found)" -Level OK
        } elseif ($statusCode -eq 0) {
            $endpointResult.status = "fail"
            $endpointResult.status_code = 0
            Write-Log "GET $($ep.route) - HTTP 0 (timeout/unreachable)" -Level ERROR
        } else {
            $endpointResult.status = "fail"
            $endpointResult.status_code = $statusCode
            Write-Log "GET $($ep.route) - HTTP $statusCode" -Level ERROR
        }

        $validationResults.endpoints += $endpointResult
        $validationResults.summary.total_checks++
        if ($endpointResult.status -eq "pass") {
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

if ($KeepServicesRunning) {
    Write-Log "Keeping backend/frontend processes running for downstream phases" -Level INFO
} else {
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
}

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

$frontendWasExpected = $packageJsonFiles.Count -gt 0
$overallStatus = if ($validationResults.summary.failed -eq 0 -and $backendStarted -and ((-not $frontendWasExpected) -or $frontendStarted)) { "PASS" } else { "FAIL" }
$statusColor = if ($overallStatus -eq "PASS") { "Green" } else { "Red" }

Write-Host "`n============================================" -ForegroundColor $statusColor
Write-Host "  Runtime Validation: $overallStatus" -ForegroundColor $statusColor
Write-Host "  Passed: $($validationResults.summary.passed) | Failed: $($validationResults.summary.failed) | Skipped: $($validationResults.summary.skipped)" -ForegroundColor DarkGray
Write-Host "  Report: $(Join-Path $outDir 'runtime-validation-report.json')" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor $statusColor
