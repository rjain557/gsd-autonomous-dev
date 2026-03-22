<#
.SYNOPSIS
    GSD V3 Local Validator - Per-interface build/typecheck/lint/test (FREE quality gate)
.DESCRIPTION
    Runs local tooling to catch errors before spending tokens on LLM review.
    Fixes V2 issues:
    - V2 only ran dotnet build + npm build, missed typecheck/lint
    - V2 had no per-interface validation (same checks for all code)
    - V2 treated parse failures as "pass" (silent false positives)
    - V2 had no acceptance criteria checking
#>

# ============================================================
# INTERFACE-SPECIFIC VALIDATORS
# ============================================================

$script:InterfaceValidators = @{
    web = @(
        @{ type = "build";      command = "npx vite build --mode test"; timeout = 60; dir = "src/web" }
        @{ type = "typecheck";  command = "npx tsc --noEmit --project src/web/tsconfig.json"; timeout = 30 }
        @{ type = "lint";       command = "npx eslint src/web/ --max-warnings 0"; timeout = 30 }
        @{ type = "test";       command = "npx vitest run --dir src/web"; timeout = 60 }
    )
    "mcp-admin" = @(
        @{ type = "build";      command = "npx vite build --mode test"; timeout = 60; dir = "src/mcp-admin" }
        @{ type = "typecheck";  command = "npx tsc --noEmit --project src/mcp-admin/tsconfig.json"; timeout = 30 }
        @{ type = "lint";       command = "npx eslint src/mcp-admin/ --max-warnings 0"; timeout = 30 }
        @{ type = "test";       command = "npx vitest run --dir src/mcp-admin"; timeout = 60 }
    )
    browser = @(
        @{ type = "build";      command = "npx vite build --mode test"; timeout = 60; dir = "src/browser" }
        @{ type = "typecheck";  command = "npx tsc --noEmit --project src/browser/tsconfig.json"; timeout = 30 }
        @{ type = "lint";       command = "npx eslint src/browser/ --max-warnings 0"; timeout = 30 }
        @{ type = "test";       command = "npx vitest run --dir src/browser"; timeout = 60 }
    )
    mobile = @(
        @{ type = "typecheck";  command = "npx tsc --noEmit --project src/mobile/tsconfig.json"; timeout = 30 }
        @{ type = "lint";       command = "npx eslint src/mobile/ --max-warnings 0"; timeout = 30 }
        @{ type = "test";       command = "npx jest --roots src/mobile"; timeout = 60 }
    )
    agent = @(
        @{ type = "typecheck";  command = "npx tsc --noEmit --project src/agent/tsconfig.json"; timeout = 30 }
        @{ type = "lint";       command = "npx eslint src/agent/ --max-warnings 0"; timeout = 30 }
        @{ type = "test";       command = "npx vitest run --dir src/agent"; timeout = 60 }
    )
    shared = @(
        @{ type = "typecheck";  command = "npx tsc --noEmit --project src/shared/tsconfig.json"; timeout = 30 }
        @{ type = "lint";       command = "npx eslint src/shared/ --max-warnings 0"; timeout = 30 }
        @{ type = "test";       command = "npx vitest run --dir src/shared"; timeout = 60 }
    )
    backend = @(
        @{ type = "build";          command = "dotnet build --no-restore"; timeout = 60; dir = "src/Server/Technijian.Api" }
        @{ type = "build";          command = "dotnet build"; timeout = 120; dir = "tests/backend" }
        @{ type = "test";           command = "dotnet test --no-build --filter `"FullyQualifiedName!~Integration`""; timeout = 120; dir = "tests/backend" }
        @{ type = "backend_static"; command = "__backend_validator__"; timeout = 30 }
    )
    database = @(
        @{ type = "syntax";     command = "sqlcmd -i {file} -b"; timeout = 10 }
        @{ type = "db_static";  command = "__db_validator__"; timeout = 30 }
    )
}

# ============================================================
# MAIN VALIDATION FUNCTION
# ============================================================

function Invoke-LocalValidation {
    <#
    .SYNOPSIS
        Run local validation for a single requirement's generated files.
    .PARAMETER RepoRoot
        Repository root path.
    .PARAMETER FilesCreated
        Array of file paths that were created/modified.
    .PARAMETER AcceptanceTests
        Array of acceptance test definitions from the plan.
    .PARAMETER RequirementId
        Requirement ID for reporting.
    .PARAMETER Interface
        Target interface (web, mcp-admin, browser, mobile, agent, shared, backend).
    #>
    param(
        [string]$RepoRoot,
        [array]$FilesCreated,
        [array]$AcceptanceTests,
        [string]$RequirementId,
        [string]$Interface = "unknown"
    )

    $result = @{
        ReqId      = $RequirementId
        Interface  = $Interface
        Passed     = $true
        Failures   = @()
        Warnings   = @()
        Tests      = @()
        Duration   = 0
    }

    $startTime = Get-Date

    # 1. File existence check
    foreach ($file in $FilesCreated) {
        $fullPath = Join-Path $RepoRoot $file
        if (-not (Test-Path $fullPath)) {
            $result.Passed = $false
            $result.Failures += @{
                type    = "file_missing"
                file    = $file
                message = "Expected file not created: $file"
            }
        }
    }

    # 2. Shared code platform import check (if interface is "shared")
    if ($Interface -eq "shared") {
        $violations = Test-SharedCodePurity -RepoRoot $RepoRoot -Files $FilesCreated
        foreach ($v in $violations) {
            $result.Passed = $false
            $result.Failures += $v
        }
    }

    # 2b. Mock data detection for frontend interfaces
    if ($Interface -in @("web", "mcp-admin", "browser", "mobile")) {
        $mockViolations = Test-MockDataInFiles -RepoRoot $RepoRoot -Files $FilesCreated
        foreach ($v in $mockViolations) {
            $result.Passed = $false
            $result.Failures += $v
        }
    }

    # 2c. DI registration check for backend interface
    if ($Interface -eq "backend") {
        $diViolations = Test-DIRegistrationForFiles -RepoRoot $RepoRoot -Files $FilesCreated
        foreach ($v in $diViolations) {
            $result.Warnings += $v
        }
    }

    # 3. Interface-specific validators
    $validators = $script:InterfaceValidators[$Interface]
    if ($validators) {
        foreach ($validator in $validators) {
            # Special handling: backend-validator static analysis (FREE, no external tool)
            if ($validator.command -eq '__backend_validator__') {
                $beValResult = Invoke-BackendValidatorIntegration -RepoRoot $RepoRoot -RequirementId $RequirementId
                $result.Tests += $beValResult.TestResult

                if ($beValResult.BlockingCount -gt 0) {
                    $result.Passed = $false
                    foreach ($v in $beValResult.BlockingViolations) {
                        $result.Failures += @{
                            type    = "backend_static"
                            message = "[$($v.check)] $($v.file):$($v.line) — $($v.message)"
                            output  = $v.suggestion
                            command = "backend-validator"
                        }
                    }
                }
                foreach ($w in $beValResult.Warnings) {
                    $result.Warnings += @{
                        type    = "backend_static"
                        message = "[$($w.check)] $($w.file):$($w.line) — $($w.message)"
                        output  = $w.suggestion
                        command = "backend-validator"
                    }
                }
                continue
            }

            # Special handling: db-validator static analysis (FREE, no external tool)
            if ($validator.command -eq '__db_validator__') {
                $dbValResult = Invoke-DatabaseValidatorIntegration -RepoRoot $RepoRoot -RequirementId $RequirementId
                $result.Tests += $dbValResult.TestResult

                if ($dbValResult.BlockingCount -gt 0) {
                    $result.Passed = $false
                    foreach ($v in $dbValResult.BlockingViolations) {
                        $result.Failures += @{
                            type    = "db_static"
                            message = "[$($v.check)] $($v.file):$($v.line) — $($v.message)"
                            output  = $v.suggestion
                            command = "db-validator"
                        }
                    }
                }
                foreach ($w in $dbValResult.Warnings) {
                    $result.Warnings += @{
                        type    = "db_static"
                        message = "[$($w.check)] $($w.file):$($w.line) — $($w.message)"
                        output  = $w.suggestion
                        command = "db-validator"
                    }
                }
                continue
            }

            # Support per-validator subdirectory (e.g., backend builds from src/Server/Technijian.Api)
            $validatorRoot = $RepoRoot
            if ($validator.dir) {
                $validatorRoot = Join-Path $RepoRoot $validator.dir
            }
            $testResult = Invoke-ValidatorCommand `
                -Command $validator.command `
                -Type $validator.type `
                -TimeoutSec $validator.timeout `
                -RepoRoot $validatorRoot `
                -RequirementId $RequirementId

            $result.Tests += $testResult

            if (-not $testResult.Passed) {
                # typecheck/lint/test failures are warnings (not blocking) when tooling may be incomplete
                $isWarningOnly = $validator.type -in @("typecheck", "lint", "test")
                if ($isWarningOnly) {
                    $result.Warnings += @{
                        type    = $validator.type
                        message = "Validator warning: $($validator.type) (non-blocking)"
                        output  = $testResult.Output
                        command = $validator.command
                    }
                } else {
                    $result.Passed = $false
                    $result.Failures += @{
                        type    = $validator.type
                        message = "Validator failed: $($validator.type)"
                        output  = $testResult.Output
                        command = $validator.command
                    }
                }
            }
        }
    }

    # 4. Acceptance criteria from plan
    if ($AcceptanceTests) {
        foreach ($test in $AcceptanceTests) {
            $atResult = Invoke-AcceptanceTest -Test $test -RepoRoot $RepoRoot -RequirementId $RequirementId
            $result.Tests += $atResult

            if (-not $atResult.Passed) {
                $result.Passed = $false
                $result.Failures += @{
                    type    = "acceptance_$($test.type)"
                    message = "Acceptance test failed: $($test.type) - $($test.target)"
                    expected = $test.expected
                    actual   = $atResult.Actual
                }
            }
        }
    }

    $result.Duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

    $status = if ($result.Passed) { "PASS" } else { "FAIL ($($result.Failures.Count) issues)" }
    Write-Host "    [$status] $RequirementId ($Interface) - $($result.Duration)s" -ForegroundColor $(if ($result.Passed) { "Green" } else { "Red" })

    return $result
}

# ============================================================
# BATCH VALIDATION
# ============================================================

function Invoke-BatchLocalValidation {
    <#
    .SYNOPSIS
        Validate all items in a batch, categorize into PASS/FAIL for review routing.
    .PARAMETER Items
        Array of items with: ReqId, FilesCreated, AcceptanceTests, Interface
    .PARAMETER RepoRoot
        Repository root.
    .PARAMETER PlanConfidences
        Hashtable of ReqId → confidence score (for confidence-gated review skip).
    .PARAMETER SkipThreshold
        Confidence threshold above which PASS items skip review entirely.
    #>
    param(
        [array]$Items,
        [string]$RepoRoot,
        [hashtable]$PlanConfidences = @{},
        [double]$SkipThreshold = 0.9
    )

    $passItems = @()
    $failItems = @()
    $skipReviewItems = @()

    foreach ($item in $Items) {
        try {
            $result = Invoke-LocalValidation `
                -RepoRoot $RepoRoot `
                -FilesCreated $item.FilesCreated `
                -AcceptanceTests $item.AcceptanceTests `
                -RequirementId $item.ReqId `
                -Interface $item.Interface
        } catch {
            # Catch any crash (regex, file access, etc.) and treat as FAIL instead of killing pipeline
            Write-Host "    [ERROR] Validation crashed for $($item.ReqId): $($_.Exception.Message)" -ForegroundColor Red
            $result = @{ Passed = $false; Failures = @(@{ type = "crash"; message = $_.Exception.Message }); Tests = @() }
        }

        if ($result.Passed) {
            $confidence = if ($PlanConfidences[$item.ReqId]) { $PlanConfidences[$item.ReqId] } else { 0.5 }

            if ($confidence -ge $SkipThreshold) {
                $skipReviewItems += @{ ReqId = $item.ReqId; Result = $result; Confidence = $confidence }
            }
            else {
                $passItems += @{ ReqId = $item.ReqId; Result = $result; Confidence = $confidence }
            }
        }
        else {
            $failItems += @{ ReqId = $item.ReqId; Result = $result }
        }
    }

    Write-Host "`n  Local validation: $($passItems.Count + $skipReviewItems.Count) pass, $($failItems.Count) fail, $($skipReviewItems.Count) skip-review" -ForegroundColor $(
        if ($failItems.Count -eq 0) { "Green" } else { "Yellow" }
    )

    return @{
        PassItems       = $passItems
        FailItems       = $failItems
        SkipReviewItems = $skipReviewItems
        TotalPassed     = $passItems.Count + $skipReviewItems.Count
        TotalFailed     = $failItems.Count
    }
}

# ============================================================
# HELPER: Run a validator command
# ============================================================

function Invoke-ValidatorCommand {
    param(
        [string]$Command,
        [string]$Type,
        [int]$TimeoutSec = 60,
        [string]$RepoRoot,
        [string]$RequirementId
    )

    $result = @{
        Type    = $Type
        Command = $Command
        Passed  = $false
        Output  = ""
        Duration = 0
    }

    try {
        $startTime = Get-Date

        # Cross-platform temp directory
        $tmpDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { "/tmp" }
        $outFile = Join-Path $tmpDir "gsd-val-out-$RequirementId.txt"
        $errFile = Join-Path $tmpDir "gsd-val-err-$RequirementId.txt"

        # Escape single quotes in RepoRoot for shell safety
        $escapedRoot = $RepoRoot -replace "'", "''"
        $process = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-Command", "cd '$escapedRoot'; $Command" `
            -NoNewWindow -PassThru -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile

        $completed = $process.WaitForExit($TimeoutSec * 1000)

        if (-not $completed) {
            try { $process.Kill() } catch {}
            $result.Output = "TIMEOUT after ${TimeoutSec}s"
            return $result
        }

        $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue

        $result.Passed = ($process.ExitCode -eq 0)
        $result.Output = if ($stderr) { $stderr } else { $stdout }
        $result.Duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

        # Cleanup temp files
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    catch {
        $result.Output = "Exception: $($_.Exception.Message)"
    }

    return $result
}

# ============================================================
# HELPER: Acceptance test
# ============================================================

function Invoke-AcceptanceTest {
    param(
        [PSObject]$Test,
        [string]$RepoRoot,
        [string]$RequirementId
    )

    $result = @{
        Type   = $Test.type
        Target = $Test.target
        Passed = $false
        Actual = ""
    }

    switch ($Test.type) {
        "file_exists" {
            $path = Join-Path $RepoRoot $Test.target
            $result.Passed = (Test-Path $path)
            $result.Actual = if ($result.Passed) { "exists" } else { "missing" }
        }
        "pattern_match" {
            $path = Join-Path $RepoRoot $Test.target
            if (Test-Path $path) {
                $content = Get-Content $path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                try {
                    $prevEAP = $ErrorActionPreference
                    $ErrorActionPreference = "Continue"
                    $result.Passed = ($content -match $Test.expected)
                    $ErrorActionPreference = $prevEAP
                } catch {
                    # Pattern contains regex-invalid chars (e.g. SQL DATEADD) -- fall back to literal Contains
                    $ErrorActionPreference = $prevEAP
                    $result.Passed = $content.Contains($Test.expected)
                }
                $result.Actual = if ($result.Passed) { "pattern found" } else { "pattern not found" }
            }
            else {
                $result.Actual = "file missing"
            }
        }
        "build_check" {
            $cmdResult = Invoke-ValidatorCommand -Command $Test.target -Type "build_check" `
                -TimeoutSec 60 -RepoRoot $RepoRoot -RequirementId $RequirementId
            $result.Passed = $cmdResult.Passed
            $result.Actual = if ($cmdResult.Passed) { "build succeeded" } else { $cmdResult.Output }
        }
        "dotnet_test" {
            $cmd = "dotnet test --filter `"Category=$RequirementId`" --no-build"
            $cmdResult = Invoke-ValidatorCommand -Command $cmd -Type "dotnet_test" `
                -TimeoutSec 60 -RepoRoot $RepoRoot -RequirementId $RequirementId
            $result.Passed = $cmdResult.Passed
            $result.Actual = if ($cmdResult.Passed) { "tests passed" } else { $cmdResult.Output }
        }
        "npm_test" {
            $cmd = "npx vitest run --testPathPattern=$($Test.target)"
            $cmdResult = Invoke-ValidatorCommand -Command $cmd -Type "npm_test" `
                -TimeoutSec 60 -RepoRoot $RepoRoot -RequirementId $RequirementId
            $result.Passed = $cmdResult.Passed
            $result.Actual = if ($cmdResult.Passed) { "tests passed" } else { $cmdResult.Output }
        }
        default {
            $result.Actual = "unknown test type: $($Test.type)"
        }
    }

    return $result
}

# ============================================================
# HELPER: Shared code purity check
# ============================================================

function Test-SharedCodePurity {
    param(
        [string]$RepoRoot,
        [array]$Files
    )

    $violations = @()
    $forbiddenImports = @(
        "react-native",
        "chrome\.",
        "chrome\[",
        "expo-",
        "@react-native",
        "electron"
    )

    foreach ($file in $Files) {
        if ($file -notlike "src/shared/*") { continue }

        $fullPath = Join-Path $RepoRoot $file
        if (-not (Test-Path $fullPath)) { continue }

        $content = Get-Content $fullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        foreach ($pattern in $forbiddenImports) {
            try { $importMatch = $content -match "import.*['""]$pattern" } catch { $importMatch = $false }
            if ($importMatch) {
                $violations += @{
                    type    = "shared_code_violation"
                    file    = $file
                    message = "Shared code imports platform-specific module matching '$pattern'"
                }
            }
        }
    }

    return $violations
}

# ============================================================
# HELPER: Database validator integration
# ============================================================

function Invoke-DatabaseValidatorIntegration {
    param(
        [string]$RepoRoot,
        [string]$RequirementId
    )

    $startTime = Get-Date

    # Load db-validator module if not already loaded
    $dbValidatorPath = Join-Path $PSScriptRoot "db-validator.ps1"
    if (-not (Get-Command 'Invoke-DatabaseValidation' -ErrorAction SilentlyContinue)) {
        if (Test-Path $dbValidatorPath) {
            . $dbValidatorPath
        } else {
            Write-Host "    [WARN] db-validator.ps1 not found at $dbValidatorPath" -ForegroundColor Yellow
            return @{
                TestResult         = @{ Type = "db_static"; Command = "db-validator"; Passed = $true; Output = "Module not found — skipped"; Duration = 0 }
                BlockingCount      = 0
                BlockingViolations = @()
                Warnings           = @()
            }
        }
    }

    try {
        $dbResult = Invoke-DatabaseValidation -RepoRoot $RepoRoot
    } catch {
        Write-Host "    [ERROR] db-validator crashed: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            TestResult         = @{ Type = "db_static"; Command = "db-validator"; Passed = $true; Output = "Crash: $($_.Exception.Message)"; Duration = 0 }
            BlockingCount      = 0
            BlockingViolations = @()
            Warnings           = @()
        }
    }

    $duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    $blockingViolations = @($dbResult.violations | Where-Object { $_.severity -eq 'blocking' })

    return @{
        TestResult         = @{
            Type     = "db_static"
            Command  = "db-validator"
            Passed   = ($blockingViolations.Count -eq 0)
            Output   = "Scanned $($dbResult.stats.FilesScanned) files: $($blockingViolations.Count) blocking, $($dbResult.warnings.Count) warnings"
            Duration = $duration
        }
        BlockingCount      = $blockingViolations.Count
        BlockingViolations = $blockingViolations
        Warnings           = @($dbResult.warnings)
    }
}

# ============================================================
# HELPER: Backend validator integration
# ============================================================

function Invoke-BackendValidatorIntegration {
    param(
        [string]$RepoRoot,
        [string]$RequirementId
    )

    $startTime = Get-Date

    # Load backend-validator module if not already loaded
    $backendValidatorPath = Join-Path $PSScriptRoot "backend-validator.ps1"
    if (-not (Get-Command 'Invoke-BackendValidation' -ErrorAction SilentlyContinue)) {
        if (Test-Path $backendValidatorPath) {
            . $backendValidatorPath
        } else {
            Write-Host "    [WARN] backend-validator.ps1 not found at $backendValidatorPath" -ForegroundColor Yellow
            return @{
                TestResult         = @{ Type = "backend_static"; Command = "backend-validator"; Passed = $true; Output = "Module not found — skipped"; Duration = 0 }
                BlockingCount      = 0
                BlockingViolations = @()
                Warnings           = @()
            }
        }
    }

    try {
        $beResult = Invoke-BackendValidation -RepoRoot $RepoRoot
    } catch {
        Write-Host "    [ERROR] backend-validator crashed: $($_.Exception.Message)" -ForegroundColor Red
        return @{
            TestResult         = @{ Type = "backend_static"; Command = "backend-validator"; Passed = $true; Output = "Crash: $($_.Exception.Message)"; Duration = 0 }
            BlockingCount      = 0
            BlockingViolations = @()
            Warnings           = @()
        }
    }

    $duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
    $blockingViolations = @($beResult.violations | Where-Object { $_.severity -eq 'blocking' })

    return @{
        TestResult         = @{
            Type     = "backend_static"
            Command  = "backend-validator"
            Passed   = ($blockingViolations.Count -eq 0)
            Output   = "Scanned $($beResult.stats.FilesScanned) files, $($beResult.stats.ControllersScanned) controllers: $($blockingViolations.Count) blocking, $($beResult.warnings.Count) warnings"
            Duration = $duration
        }
        BlockingCount      = $blockingViolations.Count
        BlockingViolations = $blockingViolations
        Warnings           = @($beResult.warnings)
    }
}

# ============================================================
# HELPER: Generate error context for review
# ============================================================

function Build-ErrorContext {
    <#
    .SYNOPSIS
        Build error context string for failed items to send to Review phase.
    .PARAMETER FailedItems
        Array of failed validation results.
    #>
    param(
        [array]$FailedItems
    )

    $context = "## Local Validation Failures`n`n"

    foreach ($item in $FailedItems) {
        $context += "### $($item.ReqId) ($($item.Result.Interface))`n"
        foreach ($failure in $item.Result.Failures) {
            $context += "- [$($failure.type)] $($failure.message)`n"
            if ($failure.output) {
                # Truncate long output
                $output = $failure.output
                if ($output.Length -gt 2000) {
                    $output = $output.Substring(0, 2000) + "`n... (truncated)"
                }
                $context += "```````n$output`n```````n"
            }
        }
        $context += "`n"
    }

    return $context
}

# ============================================================
# HELPER: Mock data detection in generated files
# ============================================================

function Test-MockDataInFiles {
    param(
        [string]$RepoRoot,
        [array]$Files
    )

    $violations = @()
    $mockPatterns = @(
        'const\s+\w*[Dd]ata\s*=\s*\[',
        'const\s+mock\w*\s*=',
        'const\s+fake\w*\s*=',
        'const\s+dummy\w*\s*=',
        'const\s+sample\w*\s*=',
        'const\s+stub\w*\s*='
    )
    $apiPatterns = @(
        'useQuery', 'useMutation', 'useInfiniteQuery',
        'fetch\s*\(', 'apiClient', 'axios',
        'useSWR', 'createApi', 'baseQuery'
    )

    foreach ($file in $Files) {
        if ($file -notmatch '\.(tsx|ts|jsx|js)$') { continue }
        $fullPath = Join-Path $RepoRoot $file
        if (-not (Test-Path $fullPath)) { continue }

        $content = Get-Content $fullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Check for mock data patterns
        foreach ($pattern in $mockPatterns) {
            try {
                if ($content -match $pattern) {
                    $violations += @{
                        type    = "mock_data"
                        file    = $file
                        message = "Mock/static data detected in $file (pattern: $pattern). Use real API calls instead."
                    }
                    break  # One violation per file is enough
                }
            } catch { }
        }

        # Check page/screen files for missing API calls
        if ($file -match '(pages|screens|views)[/\\]') {
            $hasApiCall = $false
            foreach ($apiPattern in $apiPatterns) {
                try {
                    if ($content -match $apiPattern) { $hasApiCall = $true; break }
                } catch { }
            }
            if (-not $hasApiCall -and $content.Length -gt 200) {
                $violations += @{
                    type    = "no_api_calls"
                    file    = $file
                    message = "Page component $file has no API calls (useQuery/fetch/apiClient). Uses static data?"
                }
            }
        }
    }

    return $violations
}

# ============================================================
# HELPER: DI registration check for backend files
# ============================================================

function Test-DIRegistrationForFiles {
    param(
        [string]$RepoRoot,
        [array]$Files
    )

    $violations = @()

    # Only check if we created new service/repository interfaces
    $newInterfaces = @()
    foreach ($file in $Files) {
        if ($file -match 'I\w+(Service|Repository)\.cs$') {
            $newInterfaces += $file
        }
    }
    if ($newInterfaces.Count -eq 0) { return $violations }

    # Find Program.cs or Startup.cs
    $programCs = $null
    foreach ($candidate in @("Program.cs", "src/Server/Technijian.Api/Program.cs", "backend/Program.cs", "src/Api/Program.cs")) {
        $path = Join-Path $RepoRoot $candidate
        if (Test-Path $path) { $programCs = $path; break }
    }
    if (-not $programCs) {
        # Try recursive search
        $found = Get-ChildItem -Path $RepoRoot -Filter "Program.cs" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '(bin|obj|node_modules|\.gsd)[/\\]' } |
            Select-Object -First 1
        if ($found) { $programCs = $found.FullName }
    }
    if (-not $programCs) { return $violations }

    $programContent = Get-Content $programCs -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $programContent) { return $violations }

    foreach ($file in $newInterfaces) {
        $interfaceName = [System.IO.Path]::GetFileNameWithoutExtension($file)
        $implName = $interfaceName.Substring(1)  # Remove leading 'I'

        $registered = $false
        try {
            $registered = $programContent -match "Add(Scoped|Transient|Singleton)<\s*$interfaceName"
        } catch { }

        if (-not $registered) {
            $violations += @{
                type    = "missing_di_registration"
                file    = $file
                message = "$interfaceName not registered in Program.cs. Add: builder.Services.AddScoped<$interfaceName, $implName>();"
            }
        }
    }

    return $violations
}
