<#
.SYNOPSIS
    Per-Requirement Acceptance Tests - Auto-generate and run tests per requirement.
    Run AFTER patch-gsd-pre-execute-gate.ps1.

.DESCRIPTION
    Adds automated acceptance test generation and execution:

    1. Plan phase enhancement: Claude outputs acceptance_test field per requirement
       in queue-current.json (simple assert, API call, or file check)

    2. Test-RequirementAcceptance function in resilience.ps1
       - After execute phase, runs acceptance tests for each requirement
       - Tests are lightweight: file exists, pattern match, build succeeds, endpoint responds
       - Results stored in .gsd/tests/acceptance-results.json

    3. Acceptance test prompt fragment injected into plan.md

    4. Config: acceptance_tests block in global-config.json

.INSTALL_ORDER
    1-23. (existing scripts)
    24. patch-gsd-acceptance-tests.ps1  <- this file
#>

param([string]$UserHome = $env:USERPROFILE)
$ErrorActionPreference = "Stop"

$GsdGlobalDir = Join-Path $UserHome ".gsd-global"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  GSD Per-Requirement Acceptance Tests" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Add acceptance_tests config ──

$configPath = Join-Path $GsdGlobalDir "config\global-config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    if (-not $config.acceptance_tests) {
        $config | Add-Member -NotePropertyName "acceptance_tests" -NotePropertyValue ([PSCustomObject]@{
            enabled                = $true
            block_on_failure       = $false
            test_types             = @("file_exists", "pattern_match", "build_check", "dotnet_test", "npm_test")
            max_test_time_seconds  = 60
        })
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
        Write-Host "  [OK] Added acceptance_tests config" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] acceptance_tests already exists" -ForegroundColor DarkGray
    }
}

# ── 2. Add acceptance test instructions to plan.md ──

$planPromptPath = Join-Path $GsdGlobalDir "prompts\claude\plan.md"
if (Test-Path $planPromptPath) {
    $planContent = Get-Content $planPromptPath -Raw

    if ($planContent -notlike "*acceptance_test*") {
        $acceptanceInstructions = @'

## Acceptance Test Requirements

For EACH requirement in the batch, include an `acceptance_test` field in queue-current.json.
The acceptance test defines how to verify the requirement is satisfied after code generation.

### Test Types:
- **file_exists**: Check that target files were created
  `{"type": "file_exists", "paths": ["src/Controllers/UserController.cs"]}`

- **pattern_match**: Check that generated code contains required patterns
  `{"type": "pattern_match", "file": "src/Controllers/UserController.cs", "patterns": ["[Authorize]", "[HttpGet]", "IUserRepository"]}`

- **build_check**: Verify the project compiles after changes
  `{"type": "build_check"}`

- **dotnet_test**: Run specific test class/method
  `{"type": "dotnet_test", "filter": "FullyQualifiedName~UserControllerTests"}`

- **npm_test**: Run specific frontend test
  `{"type": "npm_test", "filter": "UserProfile"}`

### Example queue-current.json batch item:
```json
{
  "req_id": "REQ-042",
  "description": "User profile API endpoint",
  "target_files": ["src/Controllers/UserController.cs"],
  "generation_instructions": "...",
  "acceptance": "GET /api/users/{id} returns user profile",
  "acceptance_test": {
    "type": "pattern_match",
    "file": "src/Controllers/UserController.cs",
    "patterns": ["[Authorize]", "[HttpGet(\"{id}\")]", "async Task<ActionResult<UserDto>>"]
  }
}
```
'@

        $planContent += $acceptanceInstructions
        Set-Content -Path $planPromptPath -Value $planContent -Encoding UTF8
        Write-Host "  [OK] Added acceptance test instructions to plan.md" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] plan.md already has acceptance test instructions" -ForegroundColor DarkGray
    }
}

# ── 3. Add Test-RequirementAcceptance function to resilience.ps1 ──

$resilienceFile = Join-Path $GsdGlobalDir "lib\modules\resilience.ps1"
if (Test-Path $resilienceFile) {
    $existing = Get-Content $resilienceFile -Raw

    if ($existing -notlike "*function Test-RequirementAcceptance*") {

        $testFunction = @'

# ===========================================
# PER-REQUIREMENT ACCEPTANCE TESTS
# ===========================================

function Test-RequirementAcceptance {
    param(
        [string]$GsdDir,
        [string]$GlobalDir,
        [string]$RepoRoot,
        [int]$Iteration
    )

    $results = @{
        Total   = 0
        Passed  = 0
        Failed  = 0
        Skipped = 0
        Details = @()
    }

    # Check config
    $configPath = Join-Path $GlobalDir "config\global-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            if (-not $config.acceptance_tests -or -not $config.acceptance_tests.enabled) {
                Write-Host "  [TEST] Acceptance tests disabled" -ForegroundColor DarkGray
                return $results
            }
        } catch { return $results }
    } else { return $results }

    $maxTime = if ($config.acceptance_tests.max_test_time_seconds) {
        [int]$config.acceptance_tests.max_test_time_seconds
    } else { 60 }

    # Load queue
    $queuePath = Join-Path $GsdDir "generation-queue\queue-current.json"
    if (-not (Test-Path $queuePath)) {
        Write-Host "  [TEST] No queue-current.json -- skipping acceptance tests" -ForegroundColor DarkGray
        return $results
    }

    try {
        $queue = Get-Content $queuePath -Raw | ConvertFrom-Json
        $batch = @($queue.batch)
    } catch {
        Write-Host "  [TEST] Failed to parse queue-current.json" -ForegroundColor Yellow
        return $results
    }

    Write-Host "  [TEST] Running acceptance tests for $($batch.Count) requirements..." -ForegroundColor Cyan

    foreach ($item in $batch) {
        $results.Total++
        $reqId = $item.req_id
        $test = $item.acceptance_test

        if (-not $test) {
            $results.Skipped++
            $results.Details += @{ req_id = $reqId; status = "skipped"; reason = "No acceptance_test defined" }
            continue
        }

        $testType = $test.type
        $passed = $false
        $reason = ""

        try {
            switch ($testType) {
                "file_exists" {
                    $allExist = $true
                    foreach ($p in $test.paths) {
                        $fullPath = Join-Path $RepoRoot $p
                        if (-not (Test-Path $fullPath)) {
                            $allExist = $false
                            $reason = "File not found: $p"
                            break
                        }
                    }
                    $passed = $allExist
                    if ($passed) { $reason = "All $($test.paths.Count) files exist" }
                }

                "pattern_match" {
                    $filePath = Join-Path $RepoRoot $test.file
                    if (-not (Test-Path $filePath)) {
                        $reason = "File not found: $($test.file)"
                    } else {
                        $content = Get-Content $filePath -Raw
                        $missingPatterns = @()
                        foreach ($pattern in $test.patterns) {
                            if ($content -notmatch [regex]::Escape($pattern)) {
                                $missingPatterns += $pattern
                            }
                        }
                        if ($missingPatterns.Count -eq 0) {
                            $passed = $true
                            $reason = "All $($test.patterns.Count) patterns found"
                        } else {
                            $reason = "Missing patterns: $($missingPatterns -join ', ')"
                        }
                    }
                }

                "build_check" {
                    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue
                    if ($slnFiles) {
                        $output = & dotnet build $slnFiles[0].FullName --no-restore 2>&1 | Out-String
                        $passed = ($LASTEXITCODE -eq 0)
                        $reason = if ($passed) { "Build succeeded" } else { "Build failed" }
                    } else {
                        $passed = $true
                        $reason = "No .sln found -- skipped"
                    }
                }

                "dotnet_test" {
                    $slnFiles = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -ErrorAction SilentlyContinue
                    if ($slnFiles -and $test.filter) {
                        $output = & dotnet test $slnFiles[0].FullName --filter $test.filter --no-build 2>&1 | Out-String
                        $passed = ($LASTEXITCODE -eq 0)
                        $reason = if ($passed) { "Tests passed" } else { "Tests failed" }
                    } else {
                        $results.Skipped++
                        continue
                    }
                }

                "npm_test" {
                    $pkgJson = Join-Path $RepoRoot "package.json"
                    if ((Test-Path $pkgJson) -and $test.filter) {
                        Push-Location $RepoRoot
                        $env:TEST_FILTER = $test.filter
                        $output = & npm test -- --testPathPattern="$($test.filter)" 2>&1 | Out-String
                        Pop-Location
                        $passed = ($LASTEXITCODE -eq 0)
                        $reason = if ($passed) { "Tests passed" } else { "Tests failed" }
                    } else {
                        $results.Skipped++
                        continue
                    }
                }

                default {
                    $results.Skipped++
                    $results.Details += @{ req_id = $reqId; status = "skipped"; reason = "Unknown test type: $testType" }
                    continue
                }
            }
        } catch {
            $reason = "Exception: $($_.Exception.Message)"
            $passed = $false
        }

        if ($passed) {
            $results.Passed++
            Write-Host "    [PASS] $reqId ($testType)" -ForegroundColor Green
        } else {
            $results.Failed++
            Write-Host "    [FAIL] $reqId ($testType): $reason" -ForegroundColor Red
        }

        $results.Details += @{
            req_id  = $reqId
            status  = if ($passed) { "passed" } else { "failed" }
            type    = $testType
            reason  = $reason
        }
    }

    # Save results
    $testDir = Join-Path $GsdDir "tests"
    if (-not (Test-Path $testDir)) {
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
    }
    $resultsPath = Join-Path $testDir "acceptance-results.json"
    @{
        iteration = $Iteration
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        summary   = @{ total = $results.Total; passed = $results.Passed; failed = $results.Failed; skipped = $results.Skipped }
        details   = $results.Details
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $resultsPath -Encoding UTF8

    # Append to history
    $historyPath = Join-Path $testDir "acceptance-history.jsonl"
    $historyLine = @{ iteration = $Iteration; passed = $results.Passed; failed = $results.Failed; skipped = $results.Skipped; timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") } | ConvertTo-Json -Compress
    Add-Content -Path $historyPath -Value $historyLine -Encoding UTF8

    $tested = $results.Total - $results.Skipped
    $passRate = if ($tested -gt 0) { [math]::Round(($results.Passed / $tested) * 100, 1) } else { 0 }
    Write-Host "  [TEST] Results: $($results.Passed)/$($results.Total) passed ($passRate%), $($results.Skipped) skipped" -ForegroundColor $(if ($results.Failed -eq 0) { "Green" } else { "Yellow" })

    return $results
}
'@

        Add-Content -Path $resilienceFile -Value $testFunction -Encoding UTF8
        Write-Host "  [OK] Added Test-RequirementAcceptance to resilience.ps1" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] Test-RequirementAcceptance already exists" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  [ACCEPTANCE] Installation complete." -ForegroundColor Green
Write-Host "  Config: global-config.json -> acceptance_tests" -ForegroundColor DarkGray
Write-Host "  Prompt: plan.md updated with acceptance_test field requirement" -ForegroundColor DarkGray
Write-Host "  Function: Test-RequirementAcceptance in resilience.ps1" -ForegroundColor DarkGray
Write-Host "  Output: .gsd/tests/acceptance-results.json, acceptance-history.jsonl" -ForegroundColor DarkGray
Write-Host ""
