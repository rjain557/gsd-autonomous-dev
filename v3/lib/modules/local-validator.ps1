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
        @{ type = "build";      command = "dotnet build --no-restore"; timeout = 60 }
        @{ type = "test";       command = "dotnet test --no-build"; timeout = 120 }
    )
    database = @(
        @{ type = "syntax";     command = "sqlcmd -i {file} -b"; timeout = 10 }
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

    # 3. Interface-specific validators
    $validators = $script:InterfaceValidators[$Interface]
    if ($validators) {
        foreach ($validator in $validators) {
            $testResult = Invoke-ValidatorCommand `
                -Command $validator.command `
                -Type $validator.type `
                -TimeoutSec $validator.timeout `
                -RepoRoot $RepoRoot `
                -RequirementId $RequirementId

            $result.Tests += $testResult

            if (-not $testResult.Passed) {
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
        $result = Invoke-LocalValidation `
            -RepoRoot $RepoRoot `
            -FilesCreated $item.FilesCreated `
            -AcceptanceTests $item.AcceptanceTests `
            -RequirementId $item.ReqId `
            -Interface $item.Interface

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
        $process = Start-Process -FilePath "pwsh" -ArgumentList "-NoProfile", "-Command", "cd '$RepoRoot'; $Command" `
            -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\gsd-val-out-$RequirementId.txt" `
            -RedirectStandardError "$env:TEMP\gsd-val-err-$RequirementId.txt"

        $completed = $process.WaitForExit($TimeoutSec * 1000)

        if (-not $completed) {
            try { $process.Kill() } catch {}
            $result.Output = "TIMEOUT after ${TimeoutSec}s"
            return $result
        }

        $stdout = Get-Content "$env:TEMP\gsd-val-out-$RequirementId.txt" -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content "$env:TEMP\gsd-val-err-$RequirementId.txt" -Raw -ErrorAction SilentlyContinue

        $result.Passed = ($process.ExitCode -eq 0)
        $result.Output = if ($stderr) { $stderr } else { $stdout }
        $result.Duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

        # Cleanup temp files
        Remove-Item "$env:TEMP\gsd-val-out-$RequirementId.txt" -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\gsd-val-err-$RequirementId.txt" -Force -ErrorAction SilentlyContinue
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
                $result.Passed = ($content -match $Test.expected)
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
            if ($content -match "import.*['""]$pattern") {
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
