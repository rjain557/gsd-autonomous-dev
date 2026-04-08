<#
.SYNOPSIS
    GSD Test Generation - Generate and execute unit, integration, and E2E tests
.DESCRIPTION
    Generates xUnit tests for .NET backend, Jest/RTL tests for React frontend,
    and Playwright E2E tests for critical user journeys. Runs all tests and
    applies a fix loop for failures.

    Phases:
      1. Inventory     - Discover existing tests and coverage gaps
      2. Unit Tests    - Generate xUnit tests for services and controllers
      3. Frontend Tests - Generate Jest/RTL tests for React components
      4. E2E Tests     - Generate Playwright scripts for user journeys
      5. Execute       - Run all tests, capture failures
      6. Fix Loop      - Claude fixes failing code or tests (up to MaxFixCycles)
      7. Report        - JSON report + markdown summary

    Usage:
      pwsh -File gsd-test-generation.ps1 -RepoRoot "D:\repos\project"
      pwsh -File gsd-test-generation.ps1 -RepoRoot "D:\repos\project" -SkipE2E -MaxFixCycles 2
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [int]$MaxFixCycles = 3,
    [ValidateSet("claude","codex")]
    [string]$FixModel = "claude",
    [switch]$SkipUnitTests,
    [switch]$SkipFrontendTests,
    [switch]$SkipE2E,
    [switch]$SkipExecution,
    [int]$MaxTestFilesPerType = 10
)

$ErrorActionPreference = "Continue"

$v3Dir    = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir   = Join-Path $RepoRoot ".gsd"
$repoName = Split-Path $RepoRoot -Leaf

$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile   = Join-Path $globalLogDir "test-generation-$timestamp.log"
$outDir    = Join-Path $GsdDir "test-generation"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }; "WARN" { "Yellow" }; "OK" { "Green" }
        "SKIP"  { "DarkGray" }; "FIX" { "Magenta" }; "PHASE" { "Cyan" }
        default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

$modulesDir    = Join-Path $v3Dir "lib/modules"
$apiClientPath = Join-Path $modulesDir "api-client.ps1"
if (Test-Path $apiClientPath) { . $apiClientPath }
$costTrackerPath = Join-Path $modulesDir "cost-tracker.ps1"
if (Test-Path $costTrackerPath) { . $costTrackerPath }
if (Get-Command Initialize-CostTracker -ErrorAction SilentlyContinue) {
    Initialize-CostTracker -Mode "test_generation" -BudgetCap 8.0 -GsdDir $GsdDir
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD Test Generation" -ForegroundColor Cyan
Write-Host "  Repo: $repoName | Fix cycles: $MaxFixCycles" -ForegroundColor DarkGray
Write-Host "  Log: $logFile" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

$report = @{
    generated_at = (Get-Date -Format "o")
    repo         = $repoName
    files_created = @()
    test_results  = @{ unit = @{ passed=0;failed=0;skipped=0 }; frontend = @{ passed=0;failed=0;skipped=0 }; e2e = @{ passed=0;failed=0;skipped=0 } }
    fix_cycles    = 0
    status        = "pass"
    summary       = ""
}

# ============================================================
# HELPERS
# ============================================================

function Get-ExistingTestProject {
    $preferredApiProject = Get-PreferredApiProject
    if ($preferredApiProject) {
        $preferredNames = @(
            "$($preferredApiProject.BaseName).Tests.csproj",
            "$($preferredApiProject.BaseName).IntegrationTests.csproj",
            "$($preferredApiProject.BaseName).UnitTests.csproj"
        )

        $matchedProject = Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -match '\\(Tests|tests|test)\\' -and
                $preferredNames -contains $_.Name
            } |
            Select-Object -First 1

        if ($matchedProject) {
            return $matchedProject
        }
    }

    return Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(Tests|IntegrationTests|UnitTests)\.' -or $_.FullName -match '\\(Tests|test)\\' } |
        Select-Object -First 1
}

function Get-OrCreateTestProject {
    $existing = Get-ExistingTestProject
    if ($existing) { return $existing }

    # Find main API project to derive test project name
    $apiProj = Get-PreferredApiProject
    if (-not $apiProj) {
        $apiProj = Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test)\\' } | Select-Object -First 1
    }
    if (-not $apiProj) { return $null }

    $testProjName = $apiProj.BaseName + ".Tests"
    $testProjDir  = Join-Path (Split-Path $apiProj.FullName -Parent | Split-Path -Parent) $testProjName

    if (-not (Test-Path $testProjDir)) {
        Write-Log "Creating test project: $testProjName" "FIX"
        & dotnet new xunit -n $testProjName -o $testProjDir 2>&1 | Out-Null
        & dotnet add (Join-Path $testProjDir "$testProjName.csproj") reference $apiProj.FullName 2>&1 | Out-Null
        & dotnet add (Join-Path $testProjDir "$testProjName.csproj") package Moq 2>&1 | Out-Null
        & dotnet add (Join-Path $testProjDir "$testProjName.csproj") package FluentAssertions 2>&1 | Out-Null
        & dotnet add (Join-Path $testProjDir "$testProjName.csproj") package Microsoft.AspNetCore.Mvc.Testing 2>&1 | Out-Null
    }

    return Get-ChildItem -Path $testProjDir -Filter "*.csproj" -File | Select-Object -First 1
}

function Get-PreferredApiProject {
    $exactMatch = Get-ChildItem -Path $RepoRoot -Filter "Technijian.Api.csproj" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
        Select-Object -First 1
    if ($exactMatch) {
        return $exactMatch
    }

    return Get-ChildItem -Path $RepoRoot -Filter "*.Api.csproj" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test)\\' } |
        Select-Object -First 1
}

function Get-PrimaryPackageJson {
    $rootPackage = Join-Path $RepoRoot "package.json"
    if (Test-Path $rootPackage) {
        return Get-Item $rootPackage
    }

    return Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build|design|generated)\\' } |
        Sort-Object FullName |
        Select-Object -First 1
}

function Get-PreferredFrontendRoots {
    $candidateRoots = @(
        (Join-Path $RepoRoot "src\\web\\screens"),
        (Join-Path $RepoRoot "src\\web\\pages"),
        (Join-Path $RepoRoot "src\\screens"),
        (Join-Path $RepoRoot "src\\pages"),
        (Join-Path $RepoRoot "src\\views")
    )

    $existingRoots = @($candidateRoots | Where-Object { Test-Path $_ })
    if ($existingRoots.Count -gt 0) {
        return $existingRoots
    }

    return @($RepoRoot)
}

function Invoke-NpmInDirectory {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousCi = $env:CI
    $previousBrowser = $env:BROWSER

    try {
        $env:CI = "1"
        $env:BROWSER = "none"
        Push-Location $WorkingDirectory
        return & npm @Arguments 2>&1
    } finally {
        Pop-Location
        $env:CI = $previousCi
        $env:BROWSER = $previousBrowser
    }
}

# ============================================================
# PHASE 1: INVENTORY EXISTING TESTS
# ============================================================

Write-Log "--- Phase 1: Test Inventory ---" "PHASE"

$existingUnitTests = @(Get-ChildItem -Path $RepoRoot -Filter "*Tests.cs" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' })
$existingFrontendTests = @(Get-ChildItem -Path $RepoRoot -Filter "*.test.tsx" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' })
$existingE2ETests = @(Get-ChildItem -Path $RepoRoot -Filter "*.spec.ts" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' })

Write-Log "Existing: $($existingUnitTests.Count) unit, $($existingFrontendTests.Count) frontend, $($existingE2ETests.Count) E2E" "INFO"

# ============================================================
# PHASE 2: UNIT TEST GENERATION (.NET xUnit)
# ============================================================

if (-not $SkipUnitTests -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
    Write-Log "--- Phase 2: Unit Test Generation ---" "PHASE"

    $testProj = Get-OrCreateTestProject
    $testDir  = if ($testProj) { Split-Path $testProj.FullName -Parent } else { $null }

    # Find service files that don't have tests
    $preferredApiProject = Get-PreferredApiProject
    $serviceSearchRoot = if ($preferredApiProject) { Split-Path $preferredApiProject.FullName -Parent } else { $RepoRoot }

    $serviceFiles = @(Get-ChildItem -Path $serviceSearchRoot -Filter "*Service.cs" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test|Interface|I[A-Z]|Migrations)\\' -and $_.Name -notmatch '^I[A-Z]' } |
        Select-Object -First $MaxTestFilesPerType)

    foreach ($svc in $serviceFiles) {
        $svcName  = $svc.BaseName
        $testFile = if ($testDir) { Join-Path $testDir "${svcName}Tests.cs" } else { $null }
        $existingServiceTests = @(Get-ChildItem -Path $RepoRoot -Filter "${svcName}Tests.cs" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' })
        if ($existingServiceTests.Count -gt 0 -or ($testFile -and (Test-Path $testFile))) { continue }

        $svcContent  = Get-Content $svc.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $svcContent) { continue }

        # Find interface
        $ifaceName = "I$svcName"
        $ifaceFile = Get-ChildItem -Path $RepoRoot -Filter "${ifaceName}.cs" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | Select-Object -First 1
        $ifaceContent = if ($ifaceFile) { Get-Content $ifaceFile.FullName -Raw -ErrorAction SilentlyContinue } else { "" }

        $sysPrompt = "You are a .NET xUnit test generator. Generate comprehensive unit tests. Return ONLY the complete C# test file. No markdown fences."
        $userPrompt = @"
## Generate xUnit Tests for $svcName

## Service Interface
$ifaceContent

## Service Implementation
$svcContent

## Requirements
- Use xUnit [Fact] and [Theory] attributes
- Use Moq for mocking dependencies
- Use FluentAssertions for assertions
- Test happy path, null inputs, edge cases, and exception paths
- Class name: ${svcName}Tests
- Namespace should match the service namespace + .Tests
- Include [Fact] tests for each public method
- Mock all injected dependencies via constructor injection
- Do NOT test private methods
Return ONLY the complete .cs file. No markdown.
"@
        $result = Invoke-CodexApi -SystemPrompt $sysPrompt -UserMessage $userPrompt -MaxTokens 16384 -Phase "test-gen-unit"
        if ($result -and $result.Success -and $result.Text) {
            $code = $result.Text.Trim() -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
            if ($testFile -and $code.Length -gt 100) {
                $code | Set-Content $testFile -Encoding UTF8 -NoNewline
                $report.files_created += $testFile
                Write-Log "Generated: $($svc.Name) → ${svcName}Tests.cs" "FIX"
            }
        }
    }
}

# ============================================================
# PHASE 3: FRONTEND TEST GENERATION (Jest/RTL)
# ============================================================

if (-not $SkipFrontendTests -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
    Write-Log "--- Phase 3: Frontend Test Generation ---" "PHASE"

    # Check if @testing-library/react is available
    $pkgJson = Get-PrimaryPackageJson
    $hasTestingLib = $false
    if ($pkgJson) {
        $pkg = Get-Content $pkgJson.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        $hasTestingLib = $pkg.devDependencies.'@testing-library/react' -or $pkg.dependencies.'@testing-library/react'
    }

    $screenFiles = @(
        foreach ($root in Get-PreferredFrontendRoots) {
            Get-ChildItem -Path $root -Filter "*.tsx" -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -match '(pages|screens|views)[/\\]' -and
                    $_.FullName -notmatch '\\(node_modules|dist|build|design|generated)\\'
                }
        }
    ) | Sort-Object FullName -Unique | Select-Object -First $MaxTestFilesPerType

    foreach ($screen in $screenFiles) {
        $screenName = $screen.BaseName
        $testPath   = Join-Path (Split-Path $screen.FullName -Parent) "${screenName}.test.tsx"
        $existingFrontendTests = @(Get-ChildItem -Path $RepoRoot -Filter "${screenName}.test.tsx" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build)\\' })
        if ((Test-Path $testPath) -or $existingFrontendTests.Count -gt 0) { continue }

        $screenContent = Get-Content $screen.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $screenContent) { continue }

        $sysPrompt = "You are a React testing expert using Jest and React Testing Library. Return ONLY the complete test file. No markdown."
        $userPrompt = @"
## Generate Jest/RTL Tests for $screenName

## Component
$(if ($screenContent.Length -gt 4000) { $screenContent.Substring(0, 4000) + "`n// ... truncated" } else { $screenContent })

## Requirements
- Use @testing-library/react render, screen, fireEvent, waitFor
- Use @testing-library/user-event for interactions
- Test: renders without crashing, shows expected content, button interactions, form submissions
- Mock API calls with jest.mock()
- Mock react-router-dom useNavigate/useParams
- Each test is independent (no shared state)
- File: ${screenName}.test.tsx in same directory
$(if (-not $hasTestingLib) { "- Use basic React render tests only (no RTL available)" })
Return ONLY the complete .tsx test file.
"@
        $result = Invoke-CodexApi -SystemPrompt $sysPrompt -UserMessage $userPrompt -MaxTokens 12288 -Phase "test-gen-frontend"
        if ($result -and $result.Success -and $result.Text) {
            $code = $result.Text.Trim() -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
            if ($code.Length -gt 100) {
                $code | Set-Content $testPath -Encoding UTF8 -NoNewline
                $report.files_created += $testPath
                Write-Log "Generated: $screenName → ${screenName}.test.tsx" "FIX"
            }
        }
    }
}

# ============================================================
# PHASE 4: E2E TEST GENERATION (Playwright) — ALL SCREENS
# Discovers every screen component and generates a spec per feature group.
# ============================================================

if (-not $SkipE2E -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
    Write-Log "--- Phase 4: E2E Test Generation (Playwright - all screens) ---" "PHASE"

    # Ensure Playwright is installed
    $pkgJson = Get-PrimaryPackageJson
    if ($pkgJson) {
        $pkg = Get-Content $pkgJson.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        $hasPlaywright = $pkg.devDependencies.'@playwright/test' -or $pkg.dependencies.'@playwright/test'
        if (-not $hasPlaywright) {
            Write-Log "Installing @playwright/test..." "FIX"
            Invoke-NpmInDirectory -WorkingDirectory (Split-Path $pkgJson.FullName -Parent) `
                -Arguments @("install", "--save-dev", "@playwright/test") | Out-Null
        }
    }

    # Read docs for context
    $docsContent = ""
    $docFiles = @(Get-ChildItem -Path $RepoRoot -Filter "*.md" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build)\\' } | Select-Object -First 3)
    foreach ($doc in $docFiles) {
        $c = Get-Content $doc.FullName -Raw -ErrorAction SilentlyContinue
        if ($c) { $docsContent += "`n### $($doc.Name)`n$(if ($c.Length -gt 2000) { $c.Substring(0,2000)+'...' } else { $c })" }
    }

    # Discover ALL screen files across all frontend source dirs
    $allScreenFiles = @()
    $srcRoots = @("src/web/src", "src/Client/technijian-spa/src", "src", "frontend/src", "client/src")
    foreach ($rel in $srcRoots) {
        $absRoot = Join-Path $RepoRoot $rel
        if (-not (Test-Path $absRoot)) { continue }
        $found = Get-ChildItem -Path $absRoot -Filter "*.tsx" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -match '(pages|screens|views)[/\\]' -and
                $_.FullName -notmatch '\\(node_modules|dist|build|design|generated|__tests__)\\'
            }
        $allScreenFiles += $found
    }
    $allScreenFiles = @($allScreenFiles | Sort-Object FullName -Unique)
    Write-Log "Discovered $($allScreenFiles.Count) screen file(s) for E2E coverage" "INFO"

    # Group screens by feature area (directory name is the group key)
    $featureGroups = @{}
    foreach ($f in $allScreenFiles) {
        # Use the parent directory name as the group, with 'root' for top-level screens
        $parentDir = Split-Path (Split-Path $f.FullName -Parent) -Leaf
        $screenParent = Split-Path $f.FullName -Parent
        $screenFolder = Split-Path $screenParent -Leaf

        # If parent is 'pages', 'screens', 'views' - use grandparent or 'main'
        $group = if ($screenFolder -match '^(pages|screens|views)$') { "main" } else { $screenFolder }
        $group = $group.ToLower() -replace '[^a-z0-9]', '-'

        if (-not $featureGroups.ContainsKey($group)) { $featureGroups[$group] = @() }
        $featureGroups[$group] += $f
    }

    # Always add 'auth' group (login/register) as first spec
    if (-not $featureGroups.ContainsKey("auth")) {
        $featureGroups["auth"] = @()  # will generate from docs context
    }

    Write-Log "Feature groups: $($featureGroups.Keys -join ', ')" "INFO"

    $e2eDir = Join-Path $RepoRoot "e2e"
    if (-not (Test-Path $e2eDir)) { New-Item -ItemType Directory -Path $e2eDir -Force | Out-Null }

    $sysPrompt = "You are a Playwright E2E test expert. Generate comprehensive tests covering all listed screens. Return ONLY the complete .spec.ts file. No markdown fences."

    foreach ($group in ($featureGroups.Keys | Sort-Object)) {
        $specFile = Join-Path $e2eDir "${group}.spec.ts"
        if (Test-Path $specFile) {
            Write-Log "E2E spec already exists: ${group}.spec.ts - skipping" "SKIP"
            continue
        }

        $screens = $featureGroups[$group]

        # Build screen inventory for prompt
        $screenList = ""
        foreach ($sf in $screens | Select-Object -First 12) {
            $screenName = $sf.BaseName
            $relPath = $sf.FullName.Replace($RepoRoot, '').TrimStart('\', '/').Replace('\', '/')
            $content = Get-Content $sf.FullName -Raw -ErrorAction SilentlyContinue
            $truncated = if ($content -and $content.Length -gt 1500) { $content.Substring(0, 1500) + "`n// ... truncated" } else { $content }
            $screenList += "`n### $screenName ($relPath)`n$truncated`n"
        }

        # Derive route paths from screen names (heuristic)
        $routeHints = ($screens | Select-Object -First 12 | ForEach-Object {
            $n = $_.BaseName -replace 'Screen$|Page$|View$', '' -replace '([A-Z])', '-$1' -replace '^-', ''
            "/$($n.ToLower().TrimStart('-'))"
        }) -join ', '

        $promptLines = @(
            "## Generate Playwright E2E Tests: $group feature area",
            "",
            "## App Context",
            $docsContent,
            "",
            "## Screens to Cover",
            $screenList,
            "",
            "## Inferred Routes (approximate)",
            $routeHints,
            "",
            "## Requirements",
            "- File: e2e/$group.spec.ts",
            "- Use @playwright/test",
            "- import { test, expect } from '@playwright/test'",
            "- const BASE_URL = process.env.BASE_URL || 'http://localhost:3000'",
            "- For EACH screen listed above, write at least one test.describe() block with:",
            "  * test renders without error - navigate to the route and assert no crash",
            "  * test shows key UI elements - assert heading/title/table/form presence",
            "  * Additional tests for interactions (buttons, forms, navigation) where obvious from the component code",
            "- Use page.goto(BASE_URL + '/route'), expect(page).toHaveURL(), expect(page.locator('...')).toBeVisible()",
            "- Use data-testid selectors where possible; fall back to role/text",
            "- Wrap authenticated routes with beforeEach that logs in via storage state OR skips if auth not configured",
            "- Auth group: test successful login, invalid credentials, redirect-after-login, logout",
            "- Never hard-code user credentials - read from process.env.TEST_EMAIL and process.env.TEST_PASSWORD",
            "Return ONLY the complete .spec.ts file."
        )
        $userPrompt = $promptLines -join "`n"

        Write-Log "Generating E2E spec: ${group}.spec.ts ($($screens.Count) screens)" "INFO"
        $result = Invoke-CodexApi -SystemPrompt $sysPrompt -UserMessage $userPrompt -MaxTokens 16384 -Phase "test-gen-e2e-$group"
        if ($result -and $result.Success -and $result.Text) {
            $code = $result.Text.Trim() -replace '(?s)^```[a-z]*\s*\n', '' -replace '\n```\s*$', ''
            if ($code.Length -gt 100) {
                $code | Set-Content $specFile -Encoding UTF8 -NoNewline
                $report.files_created += $specFile
                Write-Log "Generated E2E: ${group}.spec.ts ($($screens.Count) screens)" "FIX"
            }
        } else {
            Write-Log "E2E generation failed for group: $group - $($result.Error)" "WARN"
        }

        Start-Sleep -Milliseconds 500  # brief pause between API calls
    }

    Write-Log "E2E generation complete: $($featureGroups.Count) spec file(s) covering $($allScreenFiles.Count) screen(s)" "OK"
}

# ============================================================
# PHASE 5: EXECUTE TESTS + FIX LOOP
# ============================================================

if (-not $SkipExecution) {
    Write-Log "--- Phase 5: Test Execution ---" "PHASE"

    for ($cycle = 1; $cycle -le $MaxFixCycles; $cycle++) {
        Write-Log "Execution cycle $cycle / $MaxFixCycles" "INFO"
        $totalFailed = 0

        # Run dotnet tests
        $testProj = Get-ExistingTestProject
        if ($testProj) {
            Write-Log "Running dotnet test..." "INFO"
            $dotnetOut = & dotnet test $testProj.FullName --logger "json;LogFileName=$(Join-Path $outDir 'unit-test-results.json')" 2>&1
            $failed = ($dotnetOut | Where-Object { $_ -match 'Failed:\s+(\d+)' } | ForEach-Object { [int]$Matches[1] } | Measure-Object -Sum).Sum
            $passed = ($dotnetOut | Where-Object { $_ -match 'Passed:\s+(\d+)' } | ForEach-Object { [int]$Matches[1] } | Measure-Object -Sum).Sum
            $report.test_results.unit.passed = $passed
            $report.test_results.unit.failed = $failed
            $totalFailed += $failed
            Write-Log "Unit tests: $passed passed, $failed failed" $(if ($failed -eq 0) { "OK" } else { "WARN" })

            if ($failed -gt 0 -and $cycle -lt $MaxFixCycles -and (Get-Command Invoke-SonnetApi -ErrorAction SilentlyContinue)) {
                $errorLines = $dotnetOut | Where-Object { $_ -match '(FAILED|Error|Exception)' } | Select-Object -First 20
                $fixPrompt = "Fix the failing .NET unit tests. Errors:`n$($errorLines -join "`n")`n`nFix the implementation code (not the test) if the test is correct, or fix the test if it has a wrong assertion."
                Invoke-CodexApi -SystemPrompt "Fix .NET test failures. Be precise." -UserMessage $fixPrompt -MaxTokens 16384 -Phase "test-fix" | Out-Null
            }
        }

        # Run npm tests (non-interactive)
        $pkgJson = Get-PrimaryPackageJson
        if ($pkgJson) {
            Write-Log "Running npm test..." "INFO"
            $pkgDir = Split-Path $pkgJson.FullName -Parent
            $pkg = Get-Content $pkgJson.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
            $testScript = [string]$pkg.scripts.test
            $frontendResultsPath = Join-Path $outDir "frontend-test-results.json"
            if (Test-Path $frontendResultsPath) { Remove-Item -LiteralPath $frontendResultsPath -Force -ErrorAction SilentlyContinue }

            if ($testScript -match 'vitest') {
                $npmOut = Invoke-NpmInDirectory -WorkingDirectory $pkgDir -Arguments @("test", "--", "--run", "--reporter=json", "--outputFile=$frontendResultsPath")
            } elseif ($testScript -match 'jest|react-scripts test') {
                $npmOut = Invoke-NpmInDirectory -WorkingDirectory $pkgDir -Arguments @("test", "--", "--watchAll=false", "--ci", "--json", "--outputFile=$frontendResultsPath")
            } else {
                $npmOut = Invoke-NpmInDirectory -WorkingDirectory $pkgDir -Arguments @("test", "--", "--ci")
            }

            $npmData = $null
            if (Test-Path $frontendResultsPath) {
                try {
                    $npmData = Get-Content $frontendResultsPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                } catch { }
            }

            if ($npmData) {
                $frontendPassed = if ($null -ne $npmData.numPassedTests) { [int]$npmData.numPassedTests } else { 0 }
                $frontendFailed = if ($null -ne $npmData.numFailedTests) { [int]$npmData.numFailedTests } else { 0 }
                $report.test_results.frontend.passed = $frontendPassed
                $report.test_results.frontend.failed = $frontendFailed
                $totalFailed += $frontendFailed
                Write-Log "Frontend tests: $frontendPassed passed, $frontendFailed failed" $(if ($frontendFailed -eq 0) { "OK" } else { "WARN" })
            } elseif ($LASTEXITCODE -ne 0 -or ($npmOut | Where-Object { $_ -match 'failed|error' })) {
                $report.test_results.frontend.failed = 1
                $totalFailed += 1
                Write-Log "Frontend tests did not produce structured results; treating as failed execution" "WARN"
            }
        }

        $report.fix_cycles = $cycle
        if ($totalFailed -eq 0) { Write-Log "All tests passing!" "OK"; break }
        if ($cycle -eq $MaxFixCycles) { Write-Log "Max fix cycles reached with $totalFailed failing tests" "WARN" }
    }
}

# ============================================================
# REPORT
# ============================================================

$totalFailed = $report.test_results.unit.failed + $report.test_results.frontend.failed + $report.test_results.e2e.failed
$report.status = if ($totalFailed -eq 0) { "pass" } else { "warn" }
$report.summary = "Unit: $($report.test_results.unit.passed)p/$($report.test_results.unit.failed)f | Frontend: $($report.test_results.frontend.passed)p/$($report.test_results.frontend.failed)f | Files created: $($report.files_created.Count)"

$report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "test-generation-report.json") -Encoding UTF8

$statusColor = if ($report.status -eq "pass") { "Green" } else { "Yellow" }
Write-Host "`n============================================" -ForegroundColor $statusColor
Write-Host "  Test Generation: $($report.status.ToUpper())" -ForegroundColor $statusColor
Write-Host "  $($report.summary)" -ForegroundColor DarkGray
Write-Host "  Files created: $($report.files_created.Count)" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor $statusColor
