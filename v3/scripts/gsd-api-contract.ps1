<#
.SYNOPSIS
    GSD API Contract - Extract OpenAPI spec, detect breaking changes, verify frontend alignment
.DESCRIPTION
    After runtime validation confirms the backend is running, this phase:
    1. Extracts the OpenAPI/Swagger spec from the running backend
    2. Falls back to code-based extraction if the endpoint is unavailable
    3. Diffs against the previous spec to detect breaking changes
    4. Verifies frontend API calls align with the spec
    5. Optionally generates a TypeScript API client from the spec

    Usage:
      pwsh -File gsd-api-contract.ps1 -RepoRoot "D:\repos\project" -BackendPort 5000
      pwsh -File gsd-api-contract.ps1 -RepoRoot "D:\repos\project" -BackendPort 5000 -GenerateTsClient
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [int]$BackendPort     = 5000,
    [switch]$GenerateTsClient,
    [switch]$FailOnBreakingChange,
    [switch]$SkipFrontendAlignment
)

$ErrorActionPreference = "Continue"

$v3Dir    = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir   = Join-Path $RepoRoot ".gsd"
$repoName = Split-Path $RepoRoot -Leaf

$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }
$timestamp    = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile      = Join-Path $globalLogDir "api-contract-$timestamp.log"
$outDir       = Join-Path $GsdDir "api-contract"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }; "WARN" { "Yellow" }; "OK" { "Green" }
        "SKIP"  { "DarkGray" }; "PHASE" { "Cyan" }; default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

function Get-HttpResponseBody {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 5
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -ErrorAction Stop
        if ($response -and $response.Content) {
            return [string]$response.Content
        }
    } catch { }

    return $null
}

$modulesDir    = Join-Path $v3Dir "lib/modules"
$apiClientPath = Join-Path $modulesDir "api-client.ps1"
if (Test-Path $apiClientPath) { . $apiClientPath }

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD API Contract" -ForegroundColor Cyan
Write-Host "  Repo: $repoName | Backend port: $BackendPort" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

$report = @{
    generated_at     = (Get-Date -Format "o")
    repo             = $repoName
    spec_source      = "unknown"
    endpoints_total  = 0
    breaking_changes = @()
    alignment_issues = @()
    status           = "pass"
    summary          = ""
}

# ============================================================
# PHASE 1: EXTRACT OPENAPI SPEC
# ============================================================

Write-Log "--- Phase 1: Extract OpenAPI Spec ---" "PHASE"

$openApiSpec     = $null
$specPath        = Join-Path $outDir "openapi.json"
$prevSpecPath    = Join-Path $outDir "openapi.previous.json"

# Try to fetch from running backend
$swaggerBaseUrls = @(
    "http://localhost:${BackendPort}",
    "http://127.0.0.1:${BackendPort}"
)

$swaggerUrls = foreach ($baseUrl in $swaggerBaseUrls) {
    @(
        "$baseUrl/swagger/v1/swagger.json",
        "$baseUrl/api/swagger/v1/swagger.json",
        "$baseUrl/openapi.json",
        "$baseUrl/api/openapi.json"
    )
}

foreach ($url in $swaggerUrls) {
    try {
        $response = Get-HttpResponseBody -Url $url -TimeoutSec 5
        if ($response -and $response -match '"openapi"|"swagger"') {
            $openApiSpec = $response | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($openApiSpec) {
                Write-Log "Extracted OpenAPI spec from live backend: $url" "OK"
                $report.spec_source = $url
                break
            }
        }
    } catch { }
}

# Fallback: use spec cached by runtime-validate phase (if backend already stopped)
if (-not $openApiSpec -and (Test-Path $specPath)) {
    try {
        $cached = Get-Content $specPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($cached -and ($cached.openapi -or $cached.swagger)) {
            $openApiSpec = $cached
            $report.spec_source = "cached-from-runtime"
            Write-Log "Using OpenAPI spec cached during RUNTIME phase" "OK"
        }
    } catch { }
}

# Fallback: code-based extraction using LLM
if (-not $openApiSpec -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
    Write-Log "Backend not running - extracting spec from source code..." "WARN"
    $report.spec_source = "code-extraction"

    $controllerFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*Controller.cs" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test)\\' } | Select-Object -First 15)

    $ctrlContent = ""
    foreach ($f in $controllerFiles) {
        $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($c) {
            $relPath = $f.FullName.Replace($RepoRoot,'').TrimStart('\','/')
            $truncated = if ($c.Length -gt 3000) { $c.Substring(0,3000) + "`n// truncated" } else { $c }
            $ctrlContent += "`n### $relPath`n$truncated`n"
        }
    }

    $extractPrompt = @"
## Extract OpenAPI 3.0 Spec

Analyze the following .NET controllers and generate a valid OpenAPI 3.0 JSON spec.

## Controllers
$ctrlContent

## Requirements
- openapi: "3.0.0"
- Include all endpoints with correct HTTP methods, paths, parameters, and response schemas
- Infer request/response body schemas from method signatures and DTOs
- Include security schemes if [Authorize] attributes are present
- Use realistic schema names matching the DTO/model class names
- Return ONLY valid JSON conforming to OpenAPI 3.0 spec. No markdown.
"@

    $result = Invoke-SonnetApi -SystemPrompt "You extract OpenAPI specs from .NET controllers. Return only valid OpenAPI 3.0 JSON." `
        -UserMessage $extractPrompt -MaxTokens 8192 -Phase "api-contract-extract"

    if ($result -and $result.Success -and $result.Text) {
        $jsonText = $result.Text.Trim() -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
        $openApiSpec = $jsonText | ConvertFrom-Json -ErrorAction SilentlyContinue
    }
}

if (-not $openApiSpec) {
    Write-Log "Could not extract OpenAPI spec - skipping contract phase" "WARN"
    $report.status = "skip"
    $report.summary = "OpenAPI spec extraction failed"
    $report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "api-contract-report.json") -Encoding UTF8
    exit 0
}

# Save current spec (preserve previous for diff)
if (Test-Path $specPath) {
    Copy-Item $specPath $prevSpecPath -Force
}
$openApiSpec | ConvertTo-Json -Depth 20 | Set-Content $specPath -Encoding UTF8
Write-Log "OpenAPI spec saved: $specPath" "OK"

# Count endpoints
$pathCount = if ($openApiSpec.paths) { ($openApiSpec.paths | Get-Member -MemberType NoteProperty).Count } else { 0 }
$report.endpoints_total = $pathCount
Write-Log "Spec contains $pathCount path(s)" "INFO"

# ============================================================
# PHASE 2: BREAKING CHANGE DETECTION
# ============================================================

Write-Log "--- Phase 2: Breaking Change Detection ---" "PHASE"

if ((Test-Path $prevSpecPath) -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
    $prevSpec = Get-Content $prevSpecPath -Raw -ErrorAction SilentlyContinue
    $currSpec = Get-Content $specPath -Raw -ErrorAction SilentlyContinue

    if ($prevSpec -and $currSpec -and $prevSpec -ne $currSpec) {
        $diffPrompt = @"
## Breaking Change Detection

Compare these two OpenAPI specs and identify BREAKING changes only.

## Previous Spec
$(if ($prevSpec.Length -gt 5000) { $prevSpec.Substring(0,5000) + "..." } else { $prevSpec })

## Current Spec
$(if ($currSpec.Length -gt 5000) { $currSpec.Substring(0,5000) + "..." } else { $currSpec })

## Breaking changes are:
- Removed endpoints
- Changed HTTP method for an endpoint
- Removed required request parameters
- Changed parameter types in an incompatible way
- Removed response fields that consumers depend on
- Changed authentication requirements

## Output
Return JSON: {"breaking_changes":[{"endpoint":"PATH METHOD","type":"removed|method_changed|param_removed|type_changed","description":"...","impact":"..."}]}
Return ONLY JSON. No markdown.
"@

        $diffResult = Invoke-SonnetApi -SystemPrompt "You are an API breaking change detector. Return only JSON." `
            -UserMessage $diffPrompt -MaxTokens 4096 -Phase "api-contract-diff"

        if ($diffResult -and $diffResult.Success -and $diffResult.Text) {
            $jsonText = $diffResult.Text.Trim() -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
            $diffData = $jsonText | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($diffData -and $diffData.breaking_changes) {
                $report.breaking_changes = @($diffData.breaking_changes)
                foreach ($bc in $diffData.breaking_changes) {
                    Write-Log "BREAKING CHANGE: $($bc.endpoint) - $($bc.description)" "WARN"
                }
            }
        }
    } else {
        Write-Log "No spec changes detected" "OK"
    }
} else {
    Write-Log "No previous spec to diff against (first run)" "SKIP"
}

# ============================================================
# PHASE 3: FRONTEND API ALIGNMENT
# ============================================================

if (-not $SkipFrontendAlignment -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
    Write-Log "--- Phase 3: Frontend API Alignment ---" "PHASE"

    # Find frontend API calls
    $apiCallFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.ts" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' -and ($_.Name -match '(?i)(api|service|client|fetch|http)') } |
        Select-Object -First 10)
    $apiCallFiles += @(Get-ChildItem -Path $RepoRoot -Filter "*.tsx" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' } | Select-Object -First 10)

    $frontendApiContent = ""
    foreach ($f in $apiCallFiles) {
        $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $c) { continue }
        # Only include files with fetch/axios calls
        if ($c -notmatch '(fetch\(|axios\.|api\.|\.get\(|\.post\(|\.put\(|\.delete\()') { continue }
        $relPath = $f.FullName.Replace($RepoRoot,'').TrimStart('\','/')
        $truncated = if ($c.Length -gt 3000) { $c.Substring(0,3000) + "..." } else { $c }
        $frontendApiContent += "`n### $relPath`n$truncated`n"
    }

    if ($frontendApiContent) {
        $alignPrompt = @"
## Frontend-Backend API Alignment Check

Compare frontend API calls against the OpenAPI spec to find mismatches.

## OpenAPI Spec (Backend)
$(($openApiSpec | ConvertTo-Json -Depth 10 | ForEach-Object { if ($_.Length -gt 6000) { $_.Substring(0,6000) + "..." } else { $_ } }))

## Frontend API Calls
$frontendApiContent

## Find
1. Frontend calling endpoints that don't exist in the spec (404 risk)
2. Frontend using wrong HTTP method (e.g., GET instead of POST)
3. Frontend sending parameters with wrong names/types
4. Frontend expecting response fields that don't exist in spec
5. Missing authentication headers on protected endpoints

## Output
Return JSON: {"issues":[{"severity":"high|medium|low","frontend_file":"path","endpoint_called":"METHOD /path","description":"...","recommendation":"..."}]}
Return ONLY JSON. No markdown.
"@

        $alignResult = Invoke-SonnetApi -SystemPrompt "You verify frontend-backend API alignment. Return only JSON." `
            -UserMessage $alignPrompt -MaxTokens 4096 -Phase "api-contract-align"

        if ($alignResult -and $alignResult.Success -and $alignResult.Text) {
            $jsonText = $alignResult.Text.Trim() -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
            $alignData = $jsonText | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($alignData -and $alignData.issues) {
                $report.alignment_issues = @($alignData.issues)
                foreach ($issue in $alignData.issues) {
                    Write-Log "ALIGNMENT [$($issue.severity)]: $($issue.description)" $(if ($issue.severity -eq "high") { "WARN" } else { "INFO" })
                }
            }
        }
    } else {
        Write-Log "No frontend API call files found - skipping alignment check" "SKIP"
    }
}

# ============================================================
# PHASE 4: GENERATE TS API CLIENT (optional)
# ============================================================

if ($GenerateTsClient -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
    Write-Log "--- Phase 4: TypeScript API Client Generation ---" "PHASE"

    $pkgJson = Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' } | Select-Object -First 1

    if ($pkgJson) {
        $srcDir = Join-Path (Split-Path $pkgJson.FullName -Parent) "src/api"
        if (-not (Test-Path $srcDir)) { New-Item -ItemType Directory -Path $srcDir -Force | Out-Null }
        $clientFile = Join-Path $srcDir "api-client.generated.ts"

        if (-not (Test-Path $clientFile)) {
            $clientPrompt = @"
## Generate TypeScript API Client

Generate a type-safe TypeScript API client from this OpenAPI spec.

## OpenAPI Spec
$(($openApiSpec | ConvertTo-Json -Depth 10 | ForEach-Object { if ($_.Length -gt 8000) { $_.Substring(0,8000)+'...' } else { $_ } }))

## Requirements
- Use fetch (no external dependencies)
- Export TypeScript interfaces for all request/response types
- Export async functions for each endpoint
- Include proper error handling (throw on non-2xx)
- Accept a base URL from environment: const BASE_URL = import.meta.env.VITE_API_BASE_URL
- Include authentication header injection (accept token as parameter)
- File: api-client.generated.ts
Return ONLY the complete TypeScript file.
"@
            $clientResult = Invoke-SonnetApi -SystemPrompt "Generate a TypeScript API client. Return only the complete .ts file." `
                -UserMessage $clientPrompt -MaxTokens 8192 -Phase "api-contract-ts-client"

            if ($clientResult -and $clientResult.Success -and $clientResult.Text) {
                $code = $clientResult.Text.Trim() -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
                $code | Set-Content $clientFile -Encoding UTF8 -NoNewline
                Write-Log "Generated TypeScript API client: src/api/api-client.generated.ts" "FIX"
            }
        } else {
            Write-Log "TypeScript client already exists - skipping regeneration" "SKIP"
        }
    }
}

# ============================================================
# REPORT
# ============================================================

$breakingCount  = $report.breaking_changes.Count
$alignIssueHigh = @($report.alignment_issues | Where-Object { $_.severity -eq "high" }).Count
$report.status  = if ($FailOnBreakingChange -and $breakingCount -gt 0) { "fail" }
                  elseif ($breakingCount -gt 0 -or $alignIssueHigh -gt 0) { "warn" }
                  else { "pass" }
$report.summary = "Endpoints: $pathCount | Breaking changes: $breakingCount | Alignment issues: $($report.alignment_issues.Count)"

$report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "api-contract-report.json") -Encoding UTF8

$md = @()
$md += "# API Contract Report"
$md += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Source: $($report.spec_source) | Status: $($report.status.ToUpper())"
$md += ""
$md += "**Endpoints:** $pathCount | **Breaking changes:** $breakingCount | **Alignment issues:** $($report.alignment_issues.Count)"
$md += ""
if ($breakingCount -gt 0) {
    $md += "## Breaking Changes"
    foreach ($bc in $report.breaking_changes) { $md += "- **[$($bc.type)]** $($bc.endpoint): $($bc.description)" }
    $md += ""
}
if ($report.alignment_issues.Count -gt 0) {
    $md += "## Frontend Alignment Issues"
    foreach ($ai in $report.alignment_issues) { $md += "- **[$($ai.severity)]** $($ai.frontend_file): $($ai.description)`n  Fix: $($ai.recommendation)" }
}
$md -join "`n" | Set-Content (Join-Path $outDir "api-contract-summary.md") -Encoding UTF8

$statusColor = switch ($report.status) { "pass" { "Green" }; "warn" { "Yellow" }; default { "Red" } }
Write-Host "`n============================================" -ForegroundColor $statusColor
Write-Host "  API Contract: $($report.status.ToUpper())" -ForegroundColor $statusColor
Write-Host "  $($report.summary)" -ForegroundColor DarkGray
Write-Host "  Spec: $specPath" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor $statusColor
