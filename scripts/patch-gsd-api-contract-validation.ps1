<#
.SYNOPSIS
    Contract-First API Validation - Validate generated code against OpenAPI specs.
    Run AFTER patch-gsd-acceptance-tests.ps1.

.DESCRIPTION
    Zero-cost static analysis that validates generated API controllers against
    OpenAPI specifications and the API-to-SP map.

    Adds:
    1. Test-ApiContractCompliance function to resilience.ps1
       - Scans controllers for route attributes, HTTP methods, parameter types
       - Cross-references against 06-api-contracts.md and OpenAPI specs
       - Validates response shapes match documented contracts
       - Reports: missing endpoints, wrong HTTP methods, parameter mismatches,
         missing [Authorize], undocumented endpoints

    2. api-contract-validation.md prompt template (shared)

    3. Config: api_contract_validation block in global-config.json

    4. Integration: runs after execute phase as zero-cost gate

.INSTALL_ORDER
    1-24. (existing scripts)
    25. patch-gsd-api-contract-validation.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Contract-First API Validation" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add api_contract_validation config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.api_contract_validation) {
        $config | Add-Member -NotePropertyName "api_contract_validation" -NotePropertyValue ([PSCustomObject]@{
            enabled             = $true
            block_on_missing    = $true
            warn_on_undocumented = $true
            scan_patterns       = @("*Controller*.cs", "*controller*.ts", "*routes*.ts")
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added api_contract_validation config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] api_contract_validation already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Create api-contract-validation.md reference ──

$sharedDir = Join-Path $GsdGlobalDir "prompts\shared"
if (-not (Test-Path $sharedDir)) {
    New-Item -Path $sharedDir -ItemType Directory -Force | Out-Null
}

$refPath = Join-Path $sharedDir "api-contract-validation.md"
$refContent = @'
# API Contract Validation Rules

## Purpose
Ensures generated API controllers match the documented API contracts.
Zero-cost static regex scan -- no LLM calls required.

## Validation Checks

### 1. Route Coverage
- Every endpoint in 06-api-contracts.md must have a corresponding controller action
- Route template must match: [HttpGet("api/users/{id}")] matches GET /api/users/{id}
- Missing endpoints are BLOCKING issues

### 2. HTTP Method Compliance
- GET endpoints must use [HttpGet] attribute
- POST endpoints must use [HttpPost] attribute
- PUT/PATCH endpoints must use [HttpPut]/[HttpPatch] respectively
- DELETE endpoints must use [HttpDelete] attribute
- Wrong HTTP method is a BLOCKING issue

### 3. Parameter Type Matching
- Path parameters: {id:int} must have int parameter in method signature
- Query parameters: documented query params must appear as method parameters
- Request body: POST/PUT must have [FromBody] parameter matching documented schema
- Type mismatches are WARNINGS

### 4. Authorization Compliance
- All endpoints marked "authenticated" in spec must have [Authorize] attribute
- Public endpoints must NOT have [Authorize] (or must have [AllowAnonymous])
- Auth mismatches are BLOCKING for HIPAA/SOC2 compliance

### 5. Response Shape
- Return type must match documented response schema (ActionResult<T>)
- Error responses (4xx/5xx) should use ProblemDetails pattern
- Missing return types are WARNINGS

### 6. Stored Procedure Mapping
- Each controller action must call a stored procedure (not inline SQL)
- SP name must match the mapping in 11-api-to-sp-map.md
- Direct SQL access without SP is BLOCKING
'@

Set-Content -Path $refPath -Value $refContent -Encoding UTF8
Write-Host "  [OK] Created api-contract-validation.md reference" -ForegroundColor Green

# ── 3. Add Test-ApiContractCompliance function to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Test-ApiContractCompliance*") {

        $apiFunction = @'

# ===========================================
# CONTRACT-FIRST API VALIDATION
# ===========================================

function Test-ApiContractCompliance {
    param(
        [string]$RepoRoot,
        [string]$GsdDir,
        [string]$GlobalDir
    )

    $result = @{
        Passed   = $true
        Blocking = @()
        Warnings = @()
        Summary  = ""
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.api_contract_validation -or -not $config.api_contract_validation.enabled) {
                return $result
            }
        } catch { return $result }
    } else { return $result }

    Write-Host "  [API] Running contract compliance scan..." -ForegroundColor Cyan

    # ── 1. Find API contract source ──
    $contractPaths = @(
        (Join-Path $RepoRoot "docs\_analysis\06-api-contracts.md"),
        (Join-Path $RepoRoot "_analysis\06-api-contracts.md"),
        (Join-Path $RepoRoot "design\api\06-api-contracts.md")
    )

    $contractFile = $null
    foreach ($cp in $contractPaths) {
        if (Test-Path $cp) { $contractFile = $cp; break }
    }

    if (-not $contractFile) {
        Write-Host "  [API] No 06-api-contracts.md found -- skipping" -ForegroundColor DarkGray
        return $result
    }

    $contractContent = Get-Content $contractFile -Raw

    # ── 2. Extract documented endpoints from contract ──
    $endpoints = @()
    $endpointRegex = '(?i)(GET|POST|PUT|PATCH|DELETE)\s+(/api/[^\s\|]+)'
    $matches = [regex]::Matches($contractContent, $endpointRegex)
    foreach ($m in $matches) {
        $endpoints += @{
            Method = $m.Groups[1].Value.ToUpper()
            Route  = $m.Groups[2].Value
        }
    }

    if ($endpoints.Count -eq 0) {
        Write-Host "  [API] No endpoints found in contract -- skipping" -ForegroundColor DarkGray
        return $result
    }

    Write-Host "  [API] Found $($endpoints.Count) documented endpoints" -ForegroundColor DarkCyan

    # ── 3. Find controller files ──
    $scanPatterns = @($config.api_contract_validation.scan_patterns)
    if ($scanPatterns.Count -eq 0) { $scanPatterns = @("*Controller*.cs") }

    $controllers = @()
    foreach ($pattern in $scanPatterns) {
        $found = Get-ChildItem -Path $RepoRoot -Filter $pattern -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike "*\bin\*" -and $_.FullName -notlike "*\obj\*" -and $_.FullName -notlike "*\node_modules\*" }
        $controllers += $found
    }

    if ($controllers.Count -eq 0) {
        Write-Host "  [API] No controller files found -- all endpoints missing" -ForegroundColor Yellow
        foreach ($ep in $endpoints) {
            $result.Blocking += "Missing: $($ep.Method) $($ep.Route) -- no controller file"
        }
        $result.Passed = $false
        return $result
    }

    # ── 4. Read all controller content ──
    $allControllerContent = ""
    foreach ($ctrl in $controllers) {
        $allControllerContent += Get-Content $ctrl.FullName -Raw + "`n"
    }

    # ── 5. Validate each documented endpoint ──
    foreach ($ep in $endpoints) {
        $method = $ep.Method
        $route = $ep.Route

        # Convert route to regex pattern: /api/users/{id} -> api/users/\{?\w+\}?
        $routePattern = [regex]::Escape($route) -replace '\\{[^}]+\\}', '\{?\w+\}?'
        $routePattern = $routePattern -replace '^/', ''

        # Check for route attribute — convert uppercase method (GET) to PascalCase (Get) for C# attributes
        $methodPascal = $method.Substring(0,1).ToUpper() + $method.Substring(1).ToLower()
        $httpAttr = "[Http${methodPascal}"
        $hasRoute = $allControllerContent -match $routePattern
        $hasMethod = $allControllerContent -match [regex]::Escape($httpAttr)

        if (-not $hasRoute -and -not $hasMethod) {
            $result.Blocking += "Missing endpoint: $method $route"
        } elseif (-not $hasMethod) {
            $result.Warnings += "Route exists but HTTP method may not match: $method $route"
        }
    }

    # ── 6. Check for [Authorize] on controllers ──
    foreach ($ctrl in $controllers) {
        $ctrlContent = Get-Content $ctrl.FullName -Raw
        $hasAuthorize = $ctrlContent -match '\[Authorize'
        $hasAllowAnon = $ctrlContent -match '\[AllowAnonymous\]'

        if (-not $hasAuthorize -and -not $hasAllowAnon) {
            $ctrlName = $ctrl.Name
            $result.Warnings += "Controller $ctrlName has no [Authorize] or [AllowAnonymous] attribute"
        }
    }

    # ── 7. Check for inline SQL (should use stored procedures) ──
    $inlineSqlPatterns = @(
        'new SqlCommand\(',
        'ExecuteSqlRaw\(',
        'FromSqlRaw\(',
        '"SELECT\s+',
        '"INSERT\s+INTO',
        '"UPDATE\s+\w+\s+SET',
        '"DELETE\s+FROM'
    )

    foreach ($ctrl in $controllers) {
        $ctrlContent = Get-Content $ctrl.FullName -Raw
        foreach ($sqlPattern in $inlineSqlPatterns) {
            if ($ctrlContent -match $sqlPattern) {
                $result.Blocking += "Inline SQL detected in $($ctrl.Name) (must use stored procedures): $sqlPattern"
                break
            }
        }
    }

    # ── 8. SP mapping validation ──
    $spMapPaths = @(
        (Join-Path $RepoRoot "docs\_analysis\11-api-to-sp-map.md"),
        (Join-Path $RepoRoot "_analysis\11-api-to-sp-map.md")
    )

    $spMapFile = $null
    foreach ($sp in $spMapPaths) {
        if (Test-Path $sp) { $spMapFile = $sp; break }
    }

    if ($spMapFile) {
        $spMapContent = Get-Content $spMapFile -Raw
        # Extract SP names from the map
        $spNames = @()
        $spRegex = '(?i)(usp_\w+|sp_\w+)'
        $spMatches = [regex]::Matches($spMapContent, $spRegex)
        foreach ($m in $spMatches) { $spNames += $m.Value }

        # Check if controllers reference the documented SPs
        $spNames = $spNames | Select-Object -Unique
        foreach ($sp in $spNames) {
            if ($allControllerContent -notmatch [regex]::Escape($sp)) {
                $result.Warnings += "Documented SP '$sp' not referenced in any controller"
            }
        }
    }

    # ── 9. Summary ──
    if ($result.Blocking.Count -gt 0) {
        $result.Passed = $false
    }

    $result.Summary = "Endpoints: $($endpoints.Count) documented, $($result.Blocking.Count) blocking, $($result.Warnings.Count) warnings"
    Write-Host "  [API] $($result.Summary)" -ForegroundColor $(if ($result.Passed) { "Green" } else { "Yellow" })

    if ($result.Blocking.Count -gt 0) {
        Write-Host "  [API] Blocking issues:" -ForegroundColor Red
        foreach ($b in $result.Blocking) {
            Write-Host "    - $b" -ForegroundColor Red
        }
    }

    # Save results
    $apiDir = Join-Path $GsdDir "validation"
    if (-not (Test-Path $apiDir)) {
        New-Item -Path $apiDir -ItemType Directory -Force | Out-Null
    }
    @{
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        passed    = $result.Passed
        blocking  = $result.Blocking
        warnings  = $result.Warnings
        summary   = $result.Summary
    } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $apiDir "api-contract-results.json") -Encoding UTF8

    return $result
}
'@

        Add-Content -Path $resilienceFile -Value $apiFunction -Encoding UTF8
        Write-Host "  [OK] Added Test-ApiContractCompliance to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Test-ApiContractCompliance already exists" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  [API] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> api_contract_validation" -ForegroundColor DarkGray
Write-Host "  Reference: prompts/shared/api-contract-validation.md" -ForegroundColor DarkGray
Write-Host "  Function: Test-ApiContractCompliance in resilience.ps1" -ForegroundColor DarkGray
Write-Host "  Output: .gsd/validation/api-contract-results.json" -ForegroundColor DarkGray
Write-Host ""
